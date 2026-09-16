import Foundation
import Combine
import CoreLocation
import NetworkExtension
import PlaudDeviceBasicSDK
import PlaudBleSDK
import PlaudWiFiSDK

// MARK: - Protocol

protocol SyncManagerProtocol: AnyObject {
    /// Sync state stream
    var statePublisher: AnyPublisher<SyncState, Never> { get }
    /// Local file list (sorted by time descending)
    var filesPublisher: AnyPublisher<[RecordingFile], Never> { get }

    /// True when location access was denied/restricted — WiFi fast transfer can't run and iOS
    /// will never show the system prompt again, so the UI must send the user to Settings.
    var isLocationPermissionDenied: Bool { get }

    /// Silently fetch file list (no banner, no download)
    func fetchFileList()
    /// Start BLE file sync (show banner + download files)
    func startSync()
    /// Start WiFi fast transfer
    func startWiFiTransfer()
    /// Stop WiFi fast transfer and restore original WiFi
    func stopWiFiTransfer()
    /// Stop sync
    func stopSync()
    func deleteFile(_ file: RecordingFile)
    func renameFile(_ file: RecordingFile, name: String)
    func exportAudio(
        _ file: RecordingFile,
        completion: @escaping (Result<URL, Error>) -> Void
    )
}

// MARK: - Real Implementation

final class SyncManager: SyncManagerProtocol {

    static let shared = SyncManager()

    // MARK: Publishers

    var statePublisher: AnyPublisher<SyncState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    var filesPublisher: AnyPublisher<[RecordingFile], Never> {
        filesSubject.eraseToAnyPublisher()
    }

    private let stateSubject = CurrentValueSubject<SyncState, Never>(.idle)
    private let filesSubject: CurrentValueSubject<[RecordingFile], Never>

    // Download queue state
    private var pendingDownloads: [BleFile] = []
    private var totalToSync = 0
    private var syncedCount = 0
    /// Last shown transfer speed (bytes/sec), retained between callbacks so the readout stays
    /// steady when the SDK's speed momentarily reads 0 (e.g. during the local transcode phase).
    /// Shared by BLE and WiFi (they never transfer at the same time).
    private var lastDisplayedSpeed: Double = 0
    private var currentExportSessionId: Int?

    private init() {
        // Load synced files from local disk (including cached transcriptJSON etc.)
        filesSubject = CurrentValueSubject(RecordingStore.shared.allFiles.filter { $0.isSynced })
    }

    /// Silent mode flag (fetch list only, no download, no banner update)
    private var silentFetch = false

    // MARK: - Sync Control

    func fetchFileList() {
        AppLog.log("[SyncManager] fetchFileList called")
        silentFetch = true
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    func startSync() {
        guard !stateSubject.value.isActive else { return }
        AppLog.log("[SyncManager] startSync called")
        silentFetch = false
        stateSubject.send(.syncing(SyncProgress(totalFiles: 0, syncedFiles: 0, currentFileName: nil)))
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    /// 位置权限管理（WiFi 快传需要）
    private let locationManager = CLLocationManager()
    private lazy var locationObserver = LocationAuthObserver { [weak self] status in
        self?.handleLocationAuthChange(status)
    }
    /// True while waiting for the user's answer to the location prompt, so the grant can resume.
    private var awaitingLocationForWiFi = false

    var isLocationPermissionDenied: Bool {
        let status = locationManager.authorizationStatus
        return status == .denied || status == .restricted
    }

    /// Set when the running export received the file's tail packet (device done, local work left).
    private var deviceTransferFinishedForCurrentExport = false
    /// Set when WiFi transfer was requested while a BLE export was already transcoding locally.
    private var wifiRequestedDuringExport = false

    /// Called from DeviceManager.bleSyncFileTail — the device finished sending the current file.
    func handleDeviceTransferFinished(sessionId: Int) {
        guard sessionId == currentExportSessionId else { return }
        deviceTransferFinishedForCurrentExport = true
    }

    /// Kick off the WiFi transfer that was deferred while a BLE export finished its local transcode.
    /// By then the file is synced and dropped from the device, so the "nothing pending" guard in
    /// startWiFiTransfer usually short-circuits to Completed instead of opening a dead session.
    private func resumeDeferredWiFiTransferIfNeeded() {
        guard wifiRequestedDuringExport else { return }
        wifiRequestedDuringExport = false
        AppLog.log("[SyncManager] Resuming deferred WiFi transfer request", level: "WIFI")
        DispatchQueue.main.async { [weak self] in self?.startWiFiTransfer() }
    }


    func startWiFiTransfer() {
        // Skip if already connecting or transferring via WiFi
        if case .wifiConnecting = stateSubject.value { return }
        if case .wifiTransferring = stateSubject.value { return }

        // iOS 13+ 的 NEHotspotConfigurationManager 需要位置权限。
        // Gate on permission BEFORE touching the BLE sync: stopping the download first and then
        // bailing out here killed an in-flight transfer and left the UI with no feedback at all
        // (PLA2-392).
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            AppLog.log("[SyncManager] Requesting location permission for WiFi transfer")
            awaitingLocationForWiFi = true
            locationManager.delegate = locationObserver
            locationManager.requestWhenInUseAuthorization()
            // Resumed from handleLocationAuthChange once the user answers the prompt.
            return
        }
        if status == .denied || status == .restricted {
            AppLog.log("[SyncManager] Location permission denied, WiFi transfer unavailable")
            awaitingLocationForWiFi = false
            stateSubject.send(.failed(Self.locationDeniedMessage))
            return
        }

        // A BLE export that already received the file's tail packet is only doing local work
        // (decrypt/transcode); the device is idle. Killing it there wastes that work AND makes WiFi
        // re-transfer the same file, since the device only drops it once the export completes.
        // Wait for it (a few seconds) and re-evaluate. bleSyncFileTail is an explicit protocol
        // event, so unlike the earlier progress-string heuristic this can't mis-fire.
        if currentExportSessionId != nil, deviceTransferFinishedForCurrentExport {
            AppLog.log("[SyncManager] WiFi transfer deferred — current file is finishing its local transcode", level: "WIFI")
            wifiRequestedDuringExport = true
            stateSubject.send(.syncing(SyncProgress(
                totalFiles: totalToSync, syncedFiles: syncedCount, currentFileName: nil
            )))
            return
        }

        // NOTE: deliberately no "are there unsynced files?" pre-check here. The local store can lag
        // behind the device (a fresh recording may not be in the list yet), and guessing wrong
        // silently swallowed the user's tap. The device itself tells us when there is nothing to
        // transfer by closing the session cleanly — handled in handleWiFiClose(cleanClose:).

        // Permission is in place — now it's safe to hand the radio over from BLE to WiFi.
        if case .syncing = stateSubject.value {
            PlaudDeviceAgent.shared.stopDownloadFile()
            pendingDownloads.removeAll()
        }

        AppLog.log("[SyncManager] startWiFiTransfer")
        expectingWiFiCallbacks = true
        lastDisplayedSpeed = 0
        stateSubject.send(.wifiConnecting(.openingHotspot))
        PlaudWiFiAgent.shared.delegate = self
        PlaudDeviceAgent.shared.setDeviceWiFi(open: true)
        // Covers the device never opening its hotspot; re-armed once we get the creds.
        armWiFiConnectWatchdog()
    }

    /// User-facing text for a denied location permission (WiFi fast transfer is unavailable).
    static let locationDeniedMessage =
        "Location permission is required for WiFi fast transfer. Enable it in Settings > Privacy > Location Services."

    /// Resume (or abort) the pending WiFi transfer once the user answers the location prompt.
    private func handleLocationAuthChange(_ status: CLAuthorizationStatus) {
        guard awaitingLocationForWiFi else { return }
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            awaitingLocationForWiFi = false
            AppLog.log("[SyncManager] Location permission granted — resuming WiFi transfer")
            DispatchQueue.main.async { [weak self] in self?.startWiFiTransfer() }
        case .denied, .restricted:
            awaitingLocationForWiFi = false
            AppLog.log("[SyncManager] Location permission denied at prompt")
            stateSubject.send(.failed(Self.locationDeniedMessage))
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    /// Stop WiFi fast transfer and restore original WiFi
    func stopWiFiTransfer() {
        cancelWiFiConnectWatchdog()
        wifiTeardownWork?.cancel()
        wifiTeardownWork = nil
        expectingWiFiCallbacks = false
        isWiFiConnecting = false
        wifiExportCallback = nil
        PlaudDeviceAgent.shared.setDeviceWiFi(open: false)
        PlaudDeviceAgent.shared.endWiFiTransfer()
        PlaudWiFiAgent.shared.disconnect()
        connectedWiFiSSID = nil
        connectedWiFiPassword = nil
        wifiPendingFiles.removeAll()
        wifiSyncedSessionIds.removeAll()
        wifiPendingDeletes = 0
        stateSubject.send(.idle)
        DeviceManager.shared.reconnectAfterWiFiTransfer()
    }

    func stopSync() {
        PlaudDeviceAgent.shared.stopDownloadFile()
        pendingDownloads.removeAll()
        stateSubject.send(.idle)
    }

    /// Reset all state (called on unpair/sign out)
    func reset() {
        stopSync()
        filesSubject.send([])
    }

    // MARK: - File Operations

    func deleteFile(_ file: RecordingFile) {
        if let path = file.localPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        RecordingStore.shared.deleteFile(id: file.id)
        filesSubject.send(RecordingStore.shared.allFiles)
    }

    func renameFile(_ file: RecordingFile, name: String) {
        RecordingStore.shared.renameFile(id: file.id, name: name)
        filesSubject.send(RecordingStore.shared.allFiles)
    }

    func exportAudio(_ file: RecordingFile, completion: @escaping (Result<URL, Error>) -> Void) {
        let outputDir = RecordingStore.shared.exportDir
        let callback = ExportCallbackHandler(completion: completion)
        PlaudDeviceAgent.shared.exportAudio(
            sessionId: file.sessionId,
            outputDir: outputDir,
            format: .wav,
            channels: 1,
            callback: callback
        )
    }

    // MARK: - Internal Callbacks (forwarded by DeviceManager)

    func handleFileList(_ bleFiles: [BleFile]) {
        // Files on device are all unsynced (synced ones have been deleted)
        // Merge: locally synced files + unsynced files on device
        let localSynced = RecordingStore.shared.allFiles.filter { $0.isSynced }
        let localSyncedIds = Set(localSynced.map { $0.sessionId })

        // For DISPLAY, only add placeholders for device files we haven't already synced locally —
        // otherwise an already-synced file still on the device shows up twice (synced + placeholder),
        // inflating the count. (Download decision below is unchanged.)
        let deviceFiles: [RecordingFile] = bleFiles
            .filter { !localSyncedIds.contains($0.sessionId) }
            .map { bf in
                let createdAt = Date(timeIntervalSince1970: Double(bf.sessionId))
                let durationSec = TimeInterval(bf.duration()) / 1000.0
                return RecordingFile(
                    id: UUID().uuidString,
                    sessionId: bf.sessionId,
                    deviceSN: bf.sn,
                    name: RecordingFile.defaultName,
                    duration: durationSec,
                    createdAt: createdAt,
                    syncedAt: nil,
                    localPath: nil,
                    summaryText: nil,
                    transcriptJSON: nil
                )
            }

        // Files to download = all files on device (synced ones are normally deleted from the device).
        let newFiles = bleFiles
        let allFiles = localSynced + deviceFiles
        RecordingStore.shared.replaceAllFiles(allFiles)
        AppLog.log("[SyncManager] handleFileList: \(bleFiles.count) on device, \(localSynced.count) local synced, \(newFiles.count) to download")

        // Refresh UI file list
        DispatchQueue.main.async { [weak self] in
            self?.filesSubject.send(allFiles)
        }

        // Silent mode: fetch list only, auto-start download if new files exist
        if silentFetch {
            silentFetch = false
            if !newFiles.isEmpty {
                // New files found, switch to active sync mode
                pendingDownloads = newFiles
                totalToSync = newFiles.count
                syncedCount = 0
                downloadNextFile()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.stateSubject.send(.idle)
                }
            }
            return
        }

        // No new files to download
        guard !newFiles.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.stateSubject.send(.completed)
            }
            return
        }

        // Start downloading new files
        pendingDownloads = newFiles
        totalToSync = newFiles.count
        syncedCount = 0
        lastDisplayedSpeed = 0
        downloadNextFile()
    }

    func handleSyncFileHead(sessionId: Int, status: Int) {
        guard status == 0 else {
            stateSubject.send(.failed("File \(sessionId) sync failed (status: \(status))"))
            return
        }
    }

    func handleDownloadProgress(sessionId: Int, progress: Int, message: String) {
        // New SDK contract: progress 0–99 = download (drives the bar), progress 100 = local
        // transcode/write ("Converting…"), which must NOT move the bar and shows no speed.
        let converting = progress >= 100
        if !converting {
            let kbps = PlaudDeviceAgent.shared.currentDownloadSpeedKBps
            if kbps > 0 { lastDisplayedSpeed = kbps * 1024 }
        }
        let currentFile = RecordingStore.shared.allFiles.first { $0.sessionId == sessionId }
        var prog = SyncProgress(
            totalFiles: totalToSync,
            syncedFiles: syncedCount,
            currentFileName: currentFile?.name
        )
        prog.fileProgress = progress
        prog.bytesPerSecond = converting ? 0 : lastDisplayedSpeed
        prog.isConverting = converting
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(.syncing(prog))
        }
    }

    func handleDownloadComplete(sessionId: Int, outputPath: String) {
        syncedCount += 1
        RecordingStore.shared.markAsSynced(sessionId: sessionId, localPath: outputPath)
        DispatchQueue.main.async { [weak self] in
            self?.filesSubject.send(RecordingStore.shared.allFiles)
        }
        // Delete file from device after download completes
        PlaudDeviceAgent.shared.deleteFile(sessionId: sessionId)
        downloadNextFile()
    }

    // MARK: - WiFi Fast Transfer Callbacks (forwarded by DeviceManager)

    private var isWiFiConnecting = false

    /// Whether WiFi callbacks are expected (true only after initiating fast transfer)
    private var expectingWiFiCallbacks = false

    /// Device WiFi hotspot opened, received SSID and password
    func handleWiFiOpen(ssid: String, password: String) {
        guard expectingWiFiCallbacks, !isWiFiConnecting else {
            AppLog.log("[SyncManager] handleWiFiOpen ignored: expecting=\(expectingWiFiCallbacks), isConnecting=\(isWiFiConnecting)")
            return
        }
        isWiFiConnecting = true
        stateSubject.send(.wifiConnecting(.connectingWiFi))
        connectedWiFiSSID = ssid
        connectedWiFiPassword = password

        PlaudWiFiAgent.shared.bleDevice = BleAgent.shared.bleDevice
        PlaudWiFiAgent.shared.delegate = self
        AppLog.log("[SyncManager] SDK connectWifi: ssid=\(ssid), passLen=\(password.count), bleDevice=\(BleAgent.shared.bleDevice != nil)")
        // Wait 3s for the device hotspot to become fully ready before joining, matching the
        // production C-end (waitDeviceWifiDuration = 3s). Then hand the join to the SDK with a
        // 180s budget: the SDK internally re-applies the NEHotspotConfiguration and retries on its
        // own (needRetry defaults to true) until handshake or timeout (AppConfig.connectWiFiTimeout = 180).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            PlaudWiFiAgent.shared.connectWifi(ssid, password, 180)
            self?.armWiFiConnectWatchdog()
        }
    }

    /// Device WiFi closed. `cleanClose` marks a normal WebSocket shutdown (code 1000), which the
    /// device also uses when it has nothing to transfer — that must not be reported as a failure.
    func handleWiFiClose(cleanClose: Bool = false) {
        AppLog.log("[SyncManager] handleWiFiClose — WiFi session ended (state: \(stateSubject.value))", level: "WIFI")
        cancelWiFiConnectWatchdog()
        // Device self-disconnected (or closed) — cancel the force-teardown fallback.
        wifiTeardownWork?.cancel()
        wifiTeardownWork = nil
        expectingWiFiCallbacks = false
        isWiFiConnecting = false
        connectedWiFiSSID = nil
        connectedWiFiPassword = nil
        wifiPendingDeletes = 0
        // SDK 1.0.9+: endWiFiTransfer also asks the device to close its hotspot, so no manual
        // setDeviceWiFi(open: false) here (a second close can make the device answer with an
        // error status).
        PlaudDeviceAgent.shared.endWiFiTransfer()
        if case .wifiTransferring = stateSubject.value {
            stateSubject.send(.completed)
        } else if case .wifiConnecting = stateSubject.value {
            if cleanClose {
                // Device ended the session cleanly before transferring: it had nothing left to
                // send (e.g. a short recording that BLE auto-sync already pulled and deleted).
                // Reporting "couldn't join the hotspot" here was misleading.
                AppLog.log("[SyncManager] WiFi session closed cleanly with nothing to transfer — treating as complete", level: "WIFI")
                stateSubject.send(.completed)
            } else {
                // Closed abnormally before any transfer started — the phone most likely failed to
                // join the device hotspot (iOS "unable to join" / Local Network blocked).
                AppLog.log("[SyncManager] WiFi connect FAILED — session closed during connect (phone likely could not join the hotspot)", level: "WIFI")
                stateSubject.send(.failed("Could not join the device hotspot. Please try again."))
            }
        }
        DeviceManager.shared.reconnectAfterWiFiTransfer()
    }

    // MARK: - WiFi Connect Watchdog

    /// (Re)start the watchdog. Any previously scheduled one is cancelled first.
    private func armWiFiConnectWatchdog() {
        wifiConnectWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.handleWiFiConnectTimeout()
        }
        wifiConnectWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wifiConnectTimeout, execute: work)
    }

    private func cancelWiFiConnectWatchdog() {
        wifiConnectWatchdog?.cancel()
        wifiConnectWatchdog = nil
    }

    /// Safety net only. The SDK already retries the join internally for its full 180s budget and
    /// reports the final result via wifiConnectResult(-1/-2). This fires slightly after that budget
    /// (185s) and only if the SDK never called back — then we surface a clean failure. Do NOT
    /// disconnect+reconnect here: that would fight the SDK's in-flight internal retry.
    private func handleWiFiConnectTimeout() {
        guard expectingWiFiCallbacks else { return }
        guard case .wifiConnecting = stateSubject.value else { return }
        AppLog.log("[SyncManager] WiFi connect watchdog fired (no handshake within \(Int(wifiConnectTimeout))s) — giving up", level: "WIFI")
        failWiFiConnect()
    }

    /// Tear down a stuck/failed connect attempt and surface the reason to the UI.
    private func failWiFiConnect(_ reason: String = "Could not connect to the device for fast transfer. Please try again.") {
        AppLog.log("[SyncManager] WiFi fast transfer connect FAILED — \(reason)", level: "WIFI")
        cancelWiFiConnectWatchdog()
        expectingWiFiCallbacks = false
        isWiFiConnecting = false
        connectedWiFiSSID = nil
        connectedWiFiPassword = nil
        wifiTeardownWork?.cancel()
        wifiTeardownWork = nil
        PlaudDeviceAgent.shared.setDeviceWiFi(open: false)
        PlaudDeviceAgent.shared.endWiFiTransfer()
        PlaudWiFiAgent.shared.disconnect()
        stateSubject.send(.failed(reason))
        DeviceManager.shared.reconnectAfterWiFiTransfer()
    }

    // MARK: - WiFi Fast Transfer Internal State

    private var wifiPendingFiles: [BleFile] = []
    private var wifiTotalToSync = 0
    private var wifiSyncedCount = 0
    /// Sessions downloaded over WiFi; deleted in one batch after the transfer, never mid-session
    /// (a deleteFile between two exportAudioViaWiFi calls disrupts the WebSocket and stalls the next file).
    private var wifiSyncedSessionIds: [Int] = []
    /// Outstanding device-side deletes awaited before tearing down (so deletes actually land).
    private var wifiPendingDeletes = 0
    /// Fallback teardown if delete confirmations are slow/silent.
    private var wifiTeardownWork: DispatchWorkItem?
    /// Currently connected device WiFi SSID (for removing config on disconnect)
    private var connectedWiFiSSID: String?
    /// Hotspot password, retained so the connect watchdog can re-issue connectWifi on retry
    private var connectedWiFiPassword: String?
    /// Retained WiFi export callback to prevent ARC deallocation
    private var wifiExportCallback: WiFiExportHandler?

    // MARK: - WiFi Connect Watchdog
    // Joining the device's freshly-opened, internet-less hotspot is timing-sensitive on iOS. The
    // SDK's connectWifi(overtimeSec:180, needRetry:true) owns the retry loop — it re-applies the
    // NEHotspotConfiguration internally until handshake or timeout. This watchdog is a pure safety
    // net: it fires just past that 180s budget and only matters if the SDK never calls back.
    private var wifiConnectWatchdog: DispatchWorkItem?
    private let wifiConnectTimeout: TimeInterval = 185

    private func wifiDownloadNextFile() {
        guard let next = wifiPendingFiles.first else {
            // All files downloaded. Delete them from the device while the WiFi session is still up,
            // then tear down only AFTER the device confirms the deletes (wifiFileDelete) or a short
            // timeout — tearing down immediately closes the socket before the deletes are sent.
            let toDelete = wifiSyncedSessionIds
            wifiSyncedSessionIds.removeAll()
            guard !toDelete.isEmpty else {
                awaitDeviceWiFiClose()
                return
            }
            AppLog.log("[SyncManager] WiFi transfer done, deleting \(toDelete.count) file(s) from device: \(toDelete)", level: "WIFI")
            wifiPendingDeletes = toDelete.count
            for sid in toDelete {
                PlaudWiFiAgent.shared.deleteFile(sid, 1)
            }
            // If delete confirmations never arrive, proceed to the close-wait anyway.
            let work = DispatchWorkItem { [weak self] in
                AppLog.log("[SyncManager] WiFi delete confirmations timed out — proceeding to close-wait", level: "WIFI")
                self?.wifiPendingDeletes = 0
                self?.awaitDeviceWiFiClose()
            }
            wifiTeardownWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
            return
        }
        // NOTE: do not remove `next` from the queue yet — it is dropped only on success or on
        // giving up, so a "busy" rejection can retry the same file.
        let currentFile = RecordingStore.shared.allFiles.first { $0.sessionId == next.sessionId }
        let progress = SyncProgress(
            totalFiles: wifiTotalToSync,
            syncedFiles: wifiSyncedCount,
            currentFileName: currentFile?.name
        )
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(.wifiTransferring(progress))
        }

        let outputDir = RecordingStore.shared.audioDir()
        let handler = WiFiExportHandler(syncManager: self, sessionId: next.sessionId)
        wifiExportCallback = handler // Keep strong reference to prevent ARC deallocation
        AppLog.log("[SyncManager] WiFi exportAudio: sessionId=\(next.sessionId), dir=\(outputDir)")
        PlaudWiFiAgent.shared.exportAudioViaWiFi(
            sessionId: next.sessionId,
            outputDir: outputDir,
            // MP3 like the BLE path: opus output is unplayable for some decoders and the
            // transcription backend returns an empty result for it.
            format: AudioExportFormat.mp3,
            channels: 1,
            callback: handler
        )
    }

    /// Transfer + deletes are done. The device exits on its own (3 heartbeats → self-disconnect)
    /// and resumes BLE quickly, so DON'T force-close the WebSocket — that preempts the graceful
    /// exit and drops the device into a ~2.5min fallback. Mark complete, keep the socket alive, and
    /// let the device's close (handleWiFiClose) drive cleanup + reconnect. Force teardown only if
    /// the device never self-disconnects within the fallback window.
    private func awaitDeviceWiFiClose() {
        wifiTeardownWork?.cancel()
        AppLog.log("[SyncManager] WiFi transfer complete — waiting for device to self-disconnect", level: "WIFI")
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(.completed)
        }
        let work = DispatchWorkItem { [weak self] in
            AppLog.log("[SyncManager] Device did not self-disconnect in time — forcing WiFi teardown", level: "WIFI")
            self?.teardownWiFiSession(.completed)
        }
        wifiTeardownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0, execute: work)
    }

    /// Per-file WiFi export progress → drive the sync banner so it actually moves during a transfer.
    fileprivate func handleWiFiExportProgress(sessionId: Int, progress: Int, message: String) {
        // New SDK contract: progress 0–99 = download (drives the bar, byte-accurate), progress 100 =
        // local convert/write ("Converting…") which must NOT move the bar and shows no speed.
        let converting = progress >= 100
        if !converting {
            let kbps = PlaudWiFiAgent.shared.currentDownloadSpeedKBps
            if kbps > 0 { lastDisplayedSpeed = kbps * 1024 }
        }
        let currentFile = RecordingStore.shared.allFiles.first { $0.sessionId == sessionId }
        var prog = SyncProgress(
            totalFiles: wifiTotalToSync,
            syncedFiles: wifiSyncedCount,
            currentFileName: currentFile?.name
        )
        prog.fileProgress = progress
        prog.bytesPerSecond = converting ? 0 : lastDisplayedSpeed
        prog.isConverting = converting
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(.wifiTransferring(prog))
        }
    }

    /// Single teardown path for a finished WiFi batch: send the close command while the socket is
    /// still up, drop it, surface the final state, then reconnect BLE (dropped for the hotspot).
    /// Runs once — guarded by expectingWiFiCallbacks.
    private func teardownWiFiSession(_ finalState: SyncState) {
        AppLog.log("[SyncManager] teardownWiFiSession entered (expecting=\(expectingWiFiCallbacks), finalState=\(finalState)) — leaving hotspot", level: "WIFI")
        wifiTeardownWork?.cancel()
        wifiTeardownWork = nil
        guard expectingWiFiCallbacks else { return }
        expectingWiFiCallbacks = false
        isWiFiConnecting = false
        wifiExportCallback = nil
        wifiPendingDeletes = 0
        PlaudDeviceAgent.shared.setDeviceWiFi(open: false)
        PlaudDeviceAgent.shared.endWiFiTransfer()
        PlaudWiFiAgent.shared.disconnect()
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(finalState)
        }
        DeviceManager.shared.reconnectAfterWiFiTransfer()
    }

    fileprivate func handleWiFiExportComplete(sessionId: Int, outputPath: String) {
        wifiPendingFiles.removeAll { $0.sessionId == sessionId }
        wifiSyncedCount += 1
        RecordingStore.shared.markAsSynced(sessionId: sessionId, localPath: outputPath)
        DispatchQueue.main.async { [weak self] in
            self?.filesSubject.send(RecordingStore.shared.allFiles)
        }
        // Defer device-side deletion until the whole batch finishes (see wifiSyncedSessionIds).
        wifiSyncedSessionIds.append(sessionId)
        // SDK now releases the export slot before onComplete, so start the next file directly.
        wifiDownloadNextFile()
    }

    fileprivate func handleWiFiExportError(sessionId: Int, error: String) {
        AppLog.log("[SyncManager] WiFi export failed for \(sessionId): \(error)", level: "WIFI")
        wifiPendingFiles.removeAll { $0.sessionId == sessionId }
        wifiSyncedCount += 1
        wifiDownloadNextFile()
    }

    // MARK: - Private

    private func downloadNextFile() {
        guard let next = pendingDownloads.first else {
            DispatchQueue.main.async { [weak self] in
                self?.stateSubject.send(.completed)
            }
            return
        }
        pendingDownloads.removeFirst()

        currentExportSessionId = next.sessionId

        let currentFile = RecordingStore.shared.allFiles.first { $0.sessionId == next.sessionId }
        let progress = SyncProgress(
            totalFiles: totalToSync,
            syncedFiles: syncedCount,
            currentFileName: currentFile?.name
        )
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(.syncing(progress))
        }

        let outputDir = RecordingStore.shared.audioDir()
        AppLog.log("[SyncManager] exportAudio: sessionId=\(next.sessionId), format=mp3, dir=\(outputDir)")
        PlaudDeviceAgent.shared.exportAudio(
            sessionId: next.sessionId,
            outputDir: outputDir,
            format: .mp3,
            channels: 1,
            callback: self
        )
    }
}

// MARK: - AudioExportCallback

extension SyncManager: AudioExportCallback {

    public func onProgress(_ progress: Int, message: String) {
        guard let sessionId = currentExportSessionId else { return }
        AppLog.log("[SyncManager] exportAudio progress: \(progress)% - \(message)")
        handleDownloadProgress(sessionId: sessionId, progress: progress, message: message)
    }

    public func onComplete(outputPath: String) {
        guard let sessionId = currentExportSessionId else { return }
        let exists = FileManager.default.fileExists(atPath: outputPath)
        let size = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
        AppLog.log("[SyncManager] exportAudio complete: sessionId=\(sessionId), path=\(outputPath), exists=\(exists), size=\(size)")
        currentExportSessionId = nil
        deviceTransferFinishedForCurrentExport = false
        handleDownloadComplete(sessionId: sessionId, outputPath: outputPath)
        resumeDeferredWiFiTransferIfNeeded()
    }

    public func onError(_ error: String) {
        AppLog.log("[SyncManager] exportAudio error: \(error)")
        currentExportSessionId = nil
        deviceTransferFinishedForCurrentExport = false
        resumeDeferredWiFiTransferIfNeeded()
        // Switching to WiFi fast transfer or already in WiFi mode, ignore BLE errors
        if expectingWiFiCallbacks || isWiFiConnecting { return }
        if case .wifiConnecting = stateSubject.value { return }
        if case .wifiTransferring = stateSubject.value { return }
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(.failed("Export failed: \(error)"))
        }
    }
}

// MARK: - PlaudWiFiAgentProtocol (DeviceBasicSDK layer, all methods optional)

extension SyncManager: PlaudWiFiAgentProtocol {

    /// Result of joining the device hotspot (NEHotspotConfiguration). On failure the SDK now
    /// reports the iOS reason — message is human-readable, errorCode maps to NEHotspotConfigurationError.
    func wifiConnectResult(_ success: Bool, _ errorCode: Int, _ message: String) {
        if success {
            AppLog.log("[SyncManager] WiFi join succeeded — phone is on the device hotspot", level: "WIFI")
            return
        }
        // Authority for "channel usable" is wifiHandshake(0). Once we've moved past the connecting
        // phase (transferring/completed), a join-failure callback is stale — ignore it so a
        // successful transfer is never flipped to failed.
        guard case .wifiConnecting = stateSubject.value else {
            AppLog.log("[SyncManager] Ignoring stale WiFi join failure (code=\(errorCode)) — already past connect", level: "WIFI")
            return
        }
        AppLog.log("[SyncManager] WiFi join FAILED — code=\(errorCode), reason: \(message)", level: "WIFI")
        DispatchQueue.main.async { [weak self] in
            self?.failWiFiConnect("Could not join the device hotspot: \(message)")
        }
    }

    func wifiHandshake(_ status: Int) {
        AppLog.log("[SyncManager] wifiHandshake status=\(status)")
        // Device reached us — the connect phase is over, stand down the watchdog.
        cancelWiFiConnectWatchdog()
        guard status == 0 else {
            AppLog.log("[SyncManager] WiFi handshake FAILED (status: \(status)) — aborting fast transfer", level: "WIFI")
            DispatchQueue.main.async { [weak self] in
                self?.stateSubject.send(.failed("WiFi handshake failed (status: \(status))"))
            }
            PlaudDeviceAgent.shared.setDeviceWiFi(open: false)
            return
        }
        // Handshake succeeded, start WiFi fast transfer
        AppLog.log("[SyncManager] WiFi handshake succeeded, fetching file list")
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(.wifiTransferring(SyncProgress(totalFiles: 0, syncedFiles: 0, currentFileName: nil)))
        }
        PlaudWiFiAgent.shared.getFileList(Int(Date().timeIntervalSince1970), 0, false)
    }

    func wifiFileList(_ files: [BleFile]) {
        let localSessionIds = Set(RecordingStore.shared.allFiles.filter { $0.syncedAt != nil }.map { $0.sessionId })
        let newFiles = files.filter { !localSessionIds.contains($0.sessionId) }
        AppLog.log("[SyncManager] WiFi file list received: \(files.count) on device, \(newFiles.count) new to transfer", level: "WIFI")

        guard !newFiles.isEmpty else {
            AppLog.log("[SyncManager] WiFi: no new files, closing transfer", level: "WIFI")
            PlaudDeviceAgent.shared.setDeviceWiFi(open: false)
            DispatchQueue.main.async { [weak self] in
                self?.stateSubject.send(.completed)
            }
            return
        }

        // Create placeholder records for new files
        let records = newFiles.map { bf in
            let createdAt = Date(timeIntervalSince1970: Double(bf.sessionId))
            let durationSec = TimeInterval(bf.duration()) / 1000.0
            return RecordingFile(
                id: UUID().uuidString,
                sessionId: bf.sessionId,
                deviceSN: bf.sn,
                name: RecordingFile.defaultName,
                duration: durationSec,
                createdAt: createdAt,
                syncedAt: nil,
                localPath: nil,
                summaryText: nil,
                transcriptJSON: nil
            )
        }
        RecordingStore.shared.addFiles(records)
        DispatchQueue.main.async { [weak self] in
            self?.filesSubject.send(RecordingStore.shared.allFiles)
        }

        wifiPendingFiles = newFiles
        wifiTotalToSync = newFiles.count
        wifiSyncedCount = 0
        wifiSyncedSessionIds.removeAll()
        wifiDownloadNextFile()
    }

    func wifiFileListFail(_ status: Int) {
        AppLog.log("[SyncManager] WiFi file list fetch FAILED (status: \(status))", level: "WIFI")
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(.failed("WiFi file list fetch failed (status: \(status))"))
        }
        PlaudDeviceAgent.shared.setDeviceWiFi(open: false)
    }

    func wifiSyncFile(_ sessionId: Int, _ status: Int) {}
    func wifiSyncFileData(_ sessionId: Int, _ offset: Int, _ count: Int, _ binData: Data) {}
    func wifiDataComplete() {}
    func wifiSyncFileStop(_ status: Int) {}
    func wifiFileDelete(_ sessionId: Int, _ status: Int) {
        AppLog.log("[SyncManager] WiFi device-side delete result: sessionId=\(sessionId), status=\(status)", level: "WIFI")
        guard wifiPendingDeletes > 0 else { return }
        wifiPendingDeletes -= 1
        if wifiPendingDeletes == 0 {
            // All deletes confirmed — now wait for the device to self-disconnect (3 heartbeats).
            awaitDeviceWiFiClose()
        }
    }
    func wifiClientFail() {
        AppLog.log("[SyncManager] wifiClientFail — WebSocket connection failed")
    }
    func wifiPower(_ power: Int, _ voltage: Int) {}
    func wifiRateFail(_ status: Int) {}
    func wifiRate(_ instantRate: Int, _ averageRate: Int, _ lossRate: Double) {}
    func wifiLogsFail(_ status: Int) {}
    func wifiLogs(_ logData: Data?) {}
    func wifiTips(_ tips: Int) {}
    func wifiOTAStatus(_ status: Int, _ uid: Int) {}

    func wifiClose(_ status: Int) {
        AppLog.log("[SyncManager] WiFi closed by device (status: \(status))", level: "WIFI")
        // 1000 is a clean WebSocket close: the device finished the session on its own terms
        // (typically "nothing left to transfer"), which is not a connect failure.
        handleWiFiClose(cleanClose: status == 1000)
    }

    func wifiCommonErr(_ cmd: Int, _ status: Int) {
        AppLog.log("[SyncManager] WiFi common error (cmd: \(cmd), status: \(status))", level: "WIFI")
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(.failed("WiFi error (cmd: \(cmd), status: \(status))"))
        }
    }
}

// MARK: - WiFi Export Callback

private class WiFiExportHandler: NSObject, AudioExportCallback {
    private weak var syncManager: SyncManager?
    private let sessionId: Int

    init(syncManager: SyncManager, sessionId: Int) {
        self.syncManager = syncManager
        self.sessionId = sessionId
    }

    func onProgress(_ progress: Int, message: String) {
        syncManager?.handleWiFiExportProgress(sessionId: sessionId, progress: progress, message: message)
    }

    func onComplete(outputPath: String) {
        AppLog.log("[WiFiExport] complete: sessionId=\(sessionId), path=\(outputPath)")
        syncManager?.handleWiFiExportComplete(sessionId: sessionId, outputPath: outputPath)
    }

    func onError(_ error: String) {
        AppLog.log("[WiFiExport] error: \(error)")
        syncManager?.handleWiFiExportError(sessionId: sessionId, error: error)
    }
}

// MARK: - AudioExportCallback Adapter

private class ExportCallbackHandler: NSObject, AudioExportCallback {
    private let completion: (Result<URL, Error>) -> Void

    init(completion: @escaping (Result<URL, Error>) -> Void) {
        self.completion = completion
    }

    func onProgress(_ progress: Int, message: String) {
        // Export progress, can be used for UI display (0-100)
    }

    func onComplete(outputPath: String) {
        completion(.success(URL(fileURLWithPath: outputPath)))
    }

    func onError(_ error: String) {
        completion(.failure(SyncError.exportFailed(error)))
    }
}

enum SyncError: LocalizedError {
    case fileNotSynced
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotSynced: return "File not synced yet, cannot export"
        case .exportFailed(let msg): return "Export failed: \(msg)"
        }
    }
}

/// Bridges CLLocationManager's delegate callback into a closure so SyncManager (a plain class)
/// can react to authorization changes without becoming an NSObject subclass.
private final class LocationAuthObserver: NSObject, CLLocationManagerDelegate {
    private let onChange: (CLAuthorizationStatus) -> Void

    init(onChange: @escaping (CLAuthorizationStatus) -> Void) {
        self.onChange = onChange
        super.init()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onChange(manager.authorizationStatus)
    }
}
