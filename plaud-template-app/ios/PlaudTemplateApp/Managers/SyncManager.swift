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
    private var currentFileStartTime: Date?
    private var currentFileSize: Int = 0
    private var lastProgressUpdate: Date?
    private var lastProgressBytes: Double = 0
    private var currentExportSessionId: Int?

    private init() {
        // Load synced files from local disk (including cached transcriptJSON etc.)
        filesSubject = CurrentValueSubject(RecordingStore.shared.allFiles.filter { $0.isSynced })
    }

    /// Silent mode flag (fetch list only, no download, no banner update)
    private var silentFetch = false

    // MARK: - Sync Control

    func fetchFileList() {
        print("[SyncManager] fetchFileList called")
        silentFetch = true
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    func startSync() {
        guard !stateSubject.value.isActive else { return }
        print("[SyncManager] startSync called")
        silentFetch = false
        stateSubject.send(.syncing(SyncProgress(totalFiles: 0, syncedFiles: 0, currentFileName: nil)))
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    /// 位置权限管理（WiFi 快传需要）
    private let locationManager = CLLocationManager()

    func startWiFiTransfer() {
        // Allow switching from BLE sync to WiFi fast transfer (stop BLE first)
        if case .syncing = stateSubject.value {
            PlaudDeviceAgent.shared.stopDownloadFile()
            pendingDownloads.removeAll()
        }
        // Skip if already connecting or transferring via WiFi
        if case .wifiConnecting = stateSubject.value { return }
        if case .wifiTransferring = stateSubject.value { return }

        // iOS 13+ 的 NEHotspotConfigurationManager 需要位置权限
        let status = CLLocationManager.authorizationStatus()
        if status == .notDetermined {
            print("[SyncManager] Requesting location permission for WiFi transfer")
            locationManager.requestWhenInUseAuthorization()
            // 权限弹窗后用户需要重新触发
            return
        }
        if status == .denied || status == .restricted {
            print("[SyncManager] Location permission denied, WiFi transfer unavailable")
            stateSubject.send(.failed("Location permission required for WiFi transfer. Please enable in Settings."))
            return
        }

        print("[SyncManager] startWiFiTransfer")
        expectingWiFiCallbacks = true
        stateSubject.send(.wifiConnecting(.openingHotspot))
        PlaudWiFiAgent.shared.delegate = self
        PlaudDeviceAgent.shared.setDeviceWiFi(open: true)
    }

    /// Stop WiFi fast transfer and restore original WiFi
    func stopWiFiTransfer() {
        expectingWiFiCallbacks = false
        isWiFiConnecting = false
        wifiExportCallback = nil
        PlaudWiFiAgent.shared.disconnect()
        PlaudDeviceAgent.shared.setDeviceWiFi(open: false)
        PlaudDeviceAgent.shared.endWiFiTransfer()
        connectedWiFiSSID = nil
        wifiPendingFiles.removeAll()
        stateSubject.send(.idle)
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

        let deviceFiles: [RecordingFile] = bleFiles.map { bf in
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

        // Files to download = all files on device (synced ones have been deleted, won't appear in bleFiles)
        let newFiles = bleFiles
        let allFiles = localSynced + deviceFiles
        RecordingStore.shared.replaceAllFiles(allFiles)
        print("[SyncManager] handleFileList: \(bleFiles.count) on device, \(localSynced.count) local synced, \(newFiles.count) to download")

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
        downloadNextFile()
    }

    func handleSyncFileHead(sessionId: Int, status: Int) {
        guard status == 0 else {
            stateSubject.send(.failed("File \(sessionId) sync failed (status: \(status))"))
            return
        }
    }

    func handleDownloadProgress(sessionId: Int, progress: Int) {
        // Instantaneous speed: calculate from delta between callbacks
        let now = Date()
        let currentBytes = Double(currentFileSize) * Double(progress) / 100.0
        var speed: Double = 0
        if let lastTime = lastProgressUpdate {
            let dt = now.timeIntervalSince(lastTime)
            let dBytes = currentBytes - lastProgressBytes
            if dt > 0.1 { // Update speed only if at least 100ms elapsed
                speed = dBytes / dt
                lastProgressUpdate = now
                lastProgressBytes = currentBytes
            } else {
                // Interval too short, keep previous speed
                return
            }
        } else {
            lastProgressUpdate = now
            lastProgressBytes = currentBytes
            return
        }
        let currentFile = RecordingStore.shared.allFiles.first { $0.sessionId == sessionId }
        var prog = SyncProgress(
            totalFiles: totalToSync,
            syncedFiles: syncedCount,
            currentFileName: currentFile?.name
        )
        prog.fileProgress = progress
        prog.bytesPerSecond = speed
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
            print("[SyncManager] handleWiFiOpen ignored: expecting=\(expectingWiFiCallbacks), isConnecting=\(isWiFiConnecting)")
            return
        }
        isWiFiConnecting = true
        stateSubject.send(.wifiConnecting(.connectingWiFi))
        connectedWiFiSSID = ssid

        PlaudWiFiAgent.shared.bleDevice = BleAgent.shared.bleDevice
        PlaudWiFiAgent.shared.delegate = self
        print("[SyncManager] SDK connectWifi: ssid=\(ssid), passLen=\(password.count), bleDevice=\(BleAgent.shared.bleDevice != nil)")
        // 延迟 1 秒等待设备热点完全就绪
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            PlaudWiFiAgent.shared.connectWifi(ssid, password, 60)
        }
    }

    /// Device WiFi closed
    func handleWiFiClose() {
        expectingWiFiCallbacks = false
        isWiFiConnecting = false
        connectedWiFiSSID = nil
        PlaudDeviceAgent.shared.endWiFiTransfer()
        if case .wifiTransferring = stateSubject.value {
            stateSubject.send(.completed)
        } else if case .wifiConnecting = stateSubject.value {
            stateSubject.send(.idle)
        }
    }

    // MARK: - WiFi Fast Transfer Internal State

    private var wifiPendingFiles: [BleFile] = []
    private var wifiTotalToSync = 0
    private var wifiSyncedCount = 0
    /// Currently connected device WiFi SSID (for removing config on disconnect)
    private var connectedWiFiSSID: String?
    /// Retained WiFi export callback to prevent ARC deallocation
    private var wifiExportCallback: WiFiExportHandler?

    private func wifiDownloadNextFile() {
        guard let next = wifiPendingFiles.first else {
            // All files downloaded, close device WiFi
            expectingWiFiCallbacks = false
            isWiFiConnecting = false
            wifiExportCallback = nil
            PlaudWiFiAgent.shared.disconnect()
            PlaudDeviceAgent.shared.setDeviceWiFi(open: false)
            PlaudDeviceAgent.shared.endWiFiTransfer()
            DispatchQueue.main.async { [weak self] in
                self?.stateSubject.send(.completed)
            }
            return
        }
        wifiPendingFiles.removeFirst()

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
        print("[SyncManager] WiFi exportAudio: sessionId=\(next.sessionId), dir=\(outputDir)")
        PlaudWiFiAgent.shared.exportAudioViaWiFi(
            sessionId: next.sessionId,
            outputDir: outputDir,
            format: AudioExportFormat.opus,
            channels: 1,
            callback: handler
        )
    }

    fileprivate func handleWiFiExportComplete(sessionId: Int, outputPath: String) {
        wifiSyncedCount += 1
        RecordingStore.shared.markAsSynced(sessionId: sessionId, localPath: outputPath)
        DispatchQueue.main.async { [weak self] in
            self?.filesSubject.send(RecordingStore.shared.allFiles)
        }
        // Delete file from device after download (consistent with BLE sync)
        PlaudWiFiAgent.shared.deleteFile(sessionId, 1)
        wifiDownloadNextFile()
    }

    fileprivate func handleWiFiExportError(sessionId: Int, error: String) {
        // Single file failed, skip and continue to next
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

        currentFileStartTime = Date()
        currentFileSize = next.size
        currentExportSessionId = next.sessionId
        lastProgressUpdate = nil
        lastProgressBytes = 0

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
        print("[SyncManager] exportAudio: sessionId=\(next.sessionId), format=mp3, dir=\(outputDir)")
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
        print("[SyncManager] exportAudio progress: \(progress)% - \(message)")
        handleDownloadProgress(sessionId: sessionId, progress: progress)
    }

    public func onComplete(outputPath: String) {
        guard let sessionId = currentExportSessionId else { return }
        let exists = FileManager.default.fileExists(atPath: outputPath)
        let size = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
        print("[SyncManager] exportAudio complete: sessionId=\(sessionId), path=\(outputPath), exists=\(exists), size=\(size)")
        currentExportSessionId = nil
        handleDownloadComplete(sessionId: sessionId, outputPath: outputPath)
    }

    public func onError(_ error: String) {
        print("[SyncManager] exportAudio error: \(error)")
        currentExportSessionId = nil
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

    func wifiHandshake(_ status: Int) {
        print("[SyncManager] wifiHandshake status=\(status)")
        guard status == 0 else {
            DispatchQueue.main.async { [weak self] in
                self?.stateSubject.send(.failed("WiFi handshake failed (status: \(status))"))
            }
            PlaudDeviceAgent.shared.setDeviceWiFi(open: false)
            return
        }
        // Handshake succeeded, start WiFi fast transfer
        print("[SyncManager] WiFi handshake succeeded, fetching file list")
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(.wifiTransferring(SyncProgress(totalFiles: 0, syncedFiles: 0, currentFileName: nil)))
        }
        PlaudWiFiAgent.shared.getFileList(Int(Date().timeIntervalSince1970), 0, false)
    }

    func wifiFileList(_ files: [BleFile]) {
        let localSessionIds = Set(RecordingStore.shared.allFiles.filter { $0.syncedAt != nil }.map { $0.sessionId })
        let newFiles = files.filter { !localSessionIds.contains($0.sessionId) }

        guard !newFiles.isEmpty else {
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
        wifiDownloadNextFile()
    }

    func wifiFileListFail(_ status: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.stateSubject.send(.failed("WiFi file list fetch failed (status: \(status))"))
        }
        PlaudDeviceAgent.shared.setDeviceWiFi(open: false)
    }

    func wifiSyncFile(_ sessionId: Int, _ status: Int) {}
    func wifiSyncFileData(_ sessionId: Int, _ offset: Int, _ count: Int, _ binData: Data) {}
    func wifiDataComplete() {}
    func wifiSyncFileStop(_ status: Int) {}
    func wifiFileDelete(_ sessionId: Int, _ status: Int) {}
    func wifiClientFail() {
        print("[SyncManager] wifiClientFail — WebSocket connection failed")
    }
    func wifiPower(_ power: Int, _ voltage: Int) {}
    func wifiRateFail(_ status: Int) {}
    func wifiRate(_ instantRate: Int, _ averageRate: Int, _ lossRate: Double) {}
    func wifiLogsFail(_ status: Int) {}
    func wifiLogs(_ logData: Data?) {}
    func wifiTips(_ tips: Int) {}
    func wifiOTAStatus(_ status: Int, _ uid: Int) {}

    func wifiClose(_ status: Int) {
        handleWiFiClose()
    }

    func wifiCommonErr(_ cmd: Int, _ status: Int) {
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
        print("[WiFiExport] progress: \(progress)% - \(message)")
    }

    func onComplete(outputPath: String) {
        print("[WiFiExport] complete: sessionId=\(sessionId), path=\(outputPath)")
        syncManager?.handleWiFiExportComplete(sessionId: sessionId, outputPath: outputPath)
    }

    func onError(_ error: String) {
        print("[WiFiExport] error: \(error)")
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
