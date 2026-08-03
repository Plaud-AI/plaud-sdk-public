import Foundation
import Combine
import PlaudDeviceBasicSDK
import PlaudBleSDK

// MARK: - Protocol

/// DeviceManager public interface, conformed by both mock and real implementations
protocol DeviceManagerProtocol: AnyObject {
    /// Device connection state stream
    var connectionStatePublisher: AnyPublisher<DeviceConnectionState, Never> { get }
    /// Connected device info (nil when disconnected)
    var connectedDevicePublisher: AnyPublisher<PlaudDevice?, Never> { get }
    /// BLE scan results (continuously updated during scanning)
    var scannedDevicesPublisher: AnyPublisher<[ScannedDevice], Never> { get }

    /// Configure SDK, call after user login (with userId)
    func configure(userId: String)
    func startScan()
    func stopScan()
    func connect(_ device: ScannedDevice, userId: String)
    func disconnect()
    func unpair()
    /// Switch to another paired device (disconnect current -> scan -> connect target SN)
    func switchDevice(sn: String)
    /// Get list of paired devices
    func getPairedDevices() -> [PairedDeviceInfo]
    func refreshDeviceInfo()
    /// Check firmware update (SDK internal implementation)
    func checkFirmwareUpdate(completion: @escaping (PlaudFirmwareCheckResult) -> Void)
    /// One-click firmware upgrade (SDK internal: download -> verify -> OTA -> reconnect)
    func startFirmwareUpdate(progress: @escaping (PlaudFirmwarePhase, Float) -> Void, completion: @escaping (PlaudFirmwareUpdateResult) -> Void)
    func setAutoSync(enabled: Bool)
}

// MARK: - Real Implementation

/// Wraps PlaudDeviceAgent SDK as the sole PlaudDeviceAgentProtocol delegate,
/// forwarding recording/sync callbacks to the corresponding Managers
final class DeviceManager: NSObject, DeviceManagerProtocol {

    static let shared = DeviceManager()

    // MARK: Publishers

    var connectionStatePublisher: AnyPublisher<DeviceConnectionState, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }
    var connectedDevicePublisher: AnyPublisher<PlaudDevice?, Never> {
        connectedDeviceSubject.eraseToAnyPublisher()
    }
    var scannedDevicesPublisher: AnyPublisher<[ScannedDevice], Never> {
        scannedDevicesSubject.eraseToAnyPublisher()
    }
    /// Current connection state (for synchronous reads without subscribing)
    var currentConnectionState: DeviceConnectionState { connectionStateSubject.value }

    // MARK: Internal Subjects

    private let connectionStateSubject = CurrentValueSubject<DeviceConnectionState, Never>(.disconnected)
    private let connectedDeviceSubject = CurrentValueSubject<PlaudDevice?, Never>(nil)
    private let scannedDevicesSubject = CurrentValueSubject<[ScannedDevice], Never>([])
    /// User-facing alerts from cloud binding (e.g. device bound to another account)
    private let cloudAlertSubject = PassthroughSubject<String, Never>()
    var cloudAlertPublisher: AnyPublisher<String, Never> { cloudAlertSubject.eraseToAnyPublisher() }

    /// Scan result cache: serialNumber -> BleDevice, used when connecting
    private var cachedBleDevices: [String: BleDevice] = [:]
    private var isUserDisconnect = false
    /// Set when BLE drops during a WiFi transfer (the drop is swallowed to avoid UI flicker), so
    /// after the transfer we know the link is actually down and must reconnect.
    private var bleDroppedDuringWiFi = false
    /// Coalesces the post-WiFi reconnect so multiple teardown paths schedule only one.
    private var wifiReconnectWork: DispatchWorkItem?
    private var hasPopulatedDevice = false
    /// Set when a WiFi fast transfer ends: the device hotspot still needs closing, but BLE is down
    /// at that moment so neither the SDK nor we can send the command. Consumed on the next connect.
    var pendingDeviceWiFiClose = false
    private(set) var isOTAInProgress = false
    private var autoReconnectTimer: Timer?
    private var autoReconnectAttempts = 0
    /// Add Device 流程中禁用自动重连
    var suppressAutoReconnect = false
    /// Phone Bluetooth power state, relayed by the SDK's bleState(powered:) callback.
    private(set) var isBluetoothPowered = true

    /// Failure text used when a scan is refused because the phone's Bluetooth is off.
    static let bluetoothOffMessage = "Bluetooth is off. Turn it on to find your device."

    /// User Access Token — runtime override (Settings → Replace, persisted) takes precedence,
    /// then the xcconfig-injected UserAccessToken, then the legacy PartnerToken.
    var userAccessToken: String {
        if let override = UserDefaults.standard.string(forKey: "userAccessTokenOverride"), !override.isEmpty {
            return override
        }
        if let token = Bundle.main.object(forInfoDictionaryKey: "UserAccessToken") as? String, !token.isEmpty {
            return token
        }
        return Bundle.main.object(forInfoDictionaryKey: "PartnerToken") as? String ?? ""
    }

    /// [Deprecated] Legacy alias for userAccessToken
    var partnerToken: String { userAccessToken }

    private override init() {
        super.init()
        PlaudDeviceAgent.shared.delegate = self
    }

    // MARK: - Configuration

    /// Server domain, switchable via Settings → Environment (restart to apply).
    private var customDomain: String { RecordingStore.shared.activeServerDomain }

    func configure(userId: String) {
        RecordingStore.shared.userId = userId
        PlaudDeviceAgent.shared.initSDK(
            userAccessToken: userAccessToken,
            customDomain: customDomain
        )
        PlaudLogUploadManager.shared.setAutoUploadEnabled(false)
        // Raise SDK log retention to 25 files x 20MB = 500MB total (default 10 x 10MB = 100MB)
        // so multi-round stress-test logs are not evicted before export.
        PlaudLogConfig.shared.updateFileConfiguration(
            maxFileCount: 25,
            maxFileAge: 7 * 24 * 60 * 60,
            maxFileSize: 20 * 1024 * 1024
        )
    }

    // MARK: - Scanning

    func startScan() {
        cachedBleDevices.removeAll()
        scannedDevicesSubject.send([])
        // With the radio off the SDK's scan silently finds nothing and the page spins forever with
        // no hint that Bluetooth is the problem (PLA2-321). Fail fast and say why.
        if !isBluetoothPowered {
            AppLog.log("[DeviceManager] startScan aborted — phone Bluetooth is off")
            connectionStateSubject.send(.failed(Self.bluetoothOffMessage))
            return
        }
        connectionStateSubject.send(.scanning)
        PlaudDeviceAgent.shared.startScan()
    }

    func stopScan() {
        PlaudDeviceAgent.shared.stopScan()
        if case .scanning = connectionStateSubject.value {
            connectionStateSubject.send(.disconnected)
        }
    }

    // MARK: - Connection Management

    func connect(_ device: ScannedDevice, userId: String) {
        guard let bleDevice = cachedBleDevices[device.serialNumber] else { return }
        connectionStateSubject.send(.connecting(device))
        PlaudDeviceAgent.shared.connectBleDevice(bleDevice: bleDevice, deviceToken: userId)
    }

    func disconnect() {
        isUserDisconnect = true
        stopAutoReconnect()
        PlaudDeviceAgent.shared.disconnect()
    }

    func unpair() {
        isUserDisconnect = true
        stopAutoReconnect()
        let currentSN = connectedDeviceSubject.value?.serialNumber
        // Cloud unbind first (lifecycle guide order), best-effort: failure never blocks the
        // local depair — worst case the cloud record stays bound until the owner unbinds again.
        if let sn = currentSN { cloudUnbind(sn: sn) }
        PlaudDeviceAgent.shared.depair(clear: true)

        // Only remove the current device, don't clear all
        if let sn = currentSN {
            RecordingStore.shared.removePairedDevice(sn: sn)
        }
        SyncManager.shared.reset()

        DispatchQueue.main.async { [weak self] in
            self?.hasPopulatedDevice = false
            self?.connectedDeviceSubject.send(nil)
            self?.connectionStateSubject.send(.disconnected)
        }
    }

    func switchDevice(sn: String) {
        // Disconnect current device
        isUserDisconnect = true
        stopAutoReconnect()
        PlaudDeviceAgent.shared.disconnect()
        hasPopulatedDevice = false
        connectedDeviceSubject.send(nil)

        // Set new active device (SDK caches per-device signatures internally, no manual cleanup needed)
        RecordingStore.shared.activeDeviceSN = sn
        isUserDisconnect = false
        connectionStateSubject.send(.scanning)

        // Delay to let BLE stack finish disconnecting, then scan for the new device
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            PlaudDeviceAgent.shared.startScan()
        }
    }

    func getPairedDevices() -> [PairedDeviceInfo] {
        RecordingStore.shared.pairedDeviceSNs.map { sn in
            PairedDeviceInfo(
                serialNumber: sn,
                name: RecordingStore.shared.deviceName(for: sn),
                type: PairedDeviceInfo.deviceType(for: sn)
            )
        }
    }

    func refreshDeviceInfo() {
        PlaudDeviceAgent.shared.getState()
        PlaudDeviceAgent.shared.getStorage()
    }


    // MARK: - Auto Reconnect

    func startAutoReconnect(initialDelay: TimeInterval = 3.0) {
        stopAutoReconnect()
        autoReconnectAttempts = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            self?.autoReconnectTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.autoReconnectAttempts += 1
                if self.autoReconnectAttempts > 10 {
                    self.stopAutoReconnect()
                    return
                }
                // Set .scanning state; auto-connect logic in bleScanResult depends on this
                self.connectionStateSubject.send(.scanning)
                PlaudDeviceAgent.shared.startScan()
            }
            self?.autoReconnectTimer?.fire()
        }
    }

    func stopAutoReconnect() {
        autoReconnectTimer?.invalidate()
        autoReconnectTimer = nil
    }

    /// Called by SyncManager when a WiFi fast transfer ends. BLE was dropped for the device hotspot
    /// and that drop was swallowed (to avoid UI flicker), so the connection state may be stale and
    /// no reconnect was scheduled. Reflect the disconnect and auto-reconnect to the bound device.
    /// Coalesced so multiple teardown paths only trigger one reconnect.
    func reconnectAfterWiFiTransfer() {
        // endWiFiTransfer only reaches the device while BLE is up. If BLE is down right now, defer
        // the close to the next successful connect, else the device sits in WiFi mode until its
        // ~2 min firmware timeout. When BLE is up the SDK already sent it — don't duplicate.
        pendingDeviceWiFiClose = !PlaudDeviceAgent.shared.isConnected()
        wifiReconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Still in WiFi (e.g. a new transfer started) — skip.
            if PlaudDeviceAgent.shared.isWiFiTransferActive { return }
            guard self.bleDroppedDuringWiFi else { return }
            self.bleDroppedDuringWiFi = false
            #if DEBUG
            AppLog.log("[DeviceManager] WiFi transfer ended — BLE was down, reconnecting")
            #endif
            DispatchQueue.main.async {
                self.connectionStateSubject.send(.disconnected)
                self.connectedDeviceSubject.send(nil)
            }
            self.startAutoReconnect(initialDelay: 0)
        }
        wifiReconnectWork = work
        // Give the radio a moment to switch back from AP to BLE before scanning.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Cloud Binding (device lifecycle guide §3.1/§3.2)

    /// POST /sdk/bind after every successful connect. Same-owner rebind is idempotent server-side.
    /// 403 DEVICE_BOUND (bound to ANOTHER account) is surfaced via cloudAlertPublisher,
    /// without revealing the owning account.
    private func cloudBind(sn: String) {
        PlaudAPIService.shared.reportDeviceBinding(
            action: "bind", type: PairedDeviceInfo.deviceType(for: sn), sn: sn
        ) { [weak self] status in
            if status == 403 {
                self?.cloudAlertSubject.send(
                    "This device is already bound to another account. Unbind it from that account first, then reconnect."
                )
            }
        }
    }

    /// POST /sdk/unbind — cloud first, then local depair (guide order), best-effort:
    /// unbinding an unbound device is an idempotent no-op; failures are logged only.
    private func cloudUnbind(sn: String) {
        PlaudAPIService.shared.reportDeviceBinding(
            action: "unbind", type: PairedDeviceInfo.deviceType(for: sn), sn: sn
        ) { _ in }
    }

    // MARK: - Firmware Update (SDK Internal)

    func checkFirmwareUpdate(completion: @escaping (PlaudFirmwareCheckResult) -> Void) {
        PlaudDeviceAgent.shared.checkFirmwareUpdate(completion: completion)
    }

    func startFirmwareUpdate(progress: @escaping (PlaudFirmwarePhase, Float) -> Void, completion: @escaping (PlaudFirmwareUpdateResult) -> Void) {
        isOTAInProgress = true
        PlaudDeviceAgent.shared.startFirmwareUpdate(progress: progress) { [weak self] result in
            guard let self = self else { return }
            self.isOTAInProgress = false
            if !result.success {
                // OTA failed, reset connection state and trigger auto reconnect
                self.hasPopulatedDevice = false
                DispatchQueue.main.async {
                    self.connectionStateSubject.send(.disconnected)
                    self.connectedDeviceSubject.send(nil)
                    self.startAutoReconnect(initialDelay: 3.0)
                }
            }
            completion(result)
        }
    }

    // MARK: - Settings

    func setAutoSync(enabled: Bool) {
        RecordingStore.shared.isAutoSyncEnabled = enabled
    }
}

// MARK: - PlaudDeviceAgentProtocol

extension DeviceManager: PlaudDeviceAgentProtocol {

    // MARK: Scan & Connect

    /// Template app scope: NotePro (881) and NotePin S (882) only.
    static func isSupportedDevice(sn: String) -> Bool {
        sn.hasPrefix("881") || sn.hasPrefix("882")
    }

    /// Pick-list label for a scan hit. BLE local names sometimes arrive with control bytes or broken
    /// UTF-8, which rendered as garbage in the device list (PLA2-325): drop those and fall back to
    /// the model name from the SN prefix, like the connected-device card does.
    static func scanDisplayName(rawName: String, sn: String) -> String {
        let cleaned = String(rawName.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint
            && !CharacterSet.controlCharacters.contains($0) && $0 != "\u{FFFD}" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { return cleaned }
        if sn.hasPrefix("881") { return "Plaud NotePro" }
        if sn.hasPrefix("882") { return "Plaud NotePin S" }
        return "Plaud Device"
    }

    func bleScanResult(bleDevices: [BleDevice]) {
        // Filter out unsupported project codes (880 NotePin / 888 Note / ...) at the single
        // entry point — the pick list and auto-reconnect both consume this result.
        let bleDevices = bleDevices.filter { Self.isSupportedDevice(sn: $0.serialNumber) }
        cachedBleDevices = Dictionary(uniqueKeysWithValues: bleDevices.map { ($0.serialNumber, $0) })
        // NOTE: deliberately NOT filtering out already-paired devices. A paired device that is
        // currently connected does not advertise, so it cannot show up here anyway; one that is
        // disconnected DOES advertise and must stay selectable so the user can bring it back.
        // Hiding them only masked connect failures caused by a stale userAccessToken (PLA2-323).
        let devices = bleDevices
            .map {
                ScannedDevice(
                    name: Self.scanDisplayName(rawName: $0.name, sn: $0.serialNumber),
                    serialNumber: $0.serialNumber,
                    rssi: $0.rssi
                )
            }
            .sorted { $0.rssi > $1.rssi }
        DispatchQueue.main.async { [weak self] in
            self?.scannedDevicesSubject.send(devices)
        }

        // Auto reconnect: connect automatically when the last bound device is found
        // suppressAutoReconnect = true 时跳过（Add Device 流程中不自动重连旧设备）
        if !suppressAutoReconnect,
           let lastSN = RecordingStore.shared.lastConnectedDeviceSN,
           let match = bleDevices.first(where: { $0.serialNumber == lastSN }),
           case .scanning = connectionStateSubject.value {
            let userId = RecordingStore.shared.userId ?? ""
            let scanned = ScannedDevice(name: match.name, serialNumber: match.serialNumber, rssi: match.rssi)
            connectionStateSubject.send(.connecting(scanned))
            PlaudDeviceAgent.shared.connectBleDevice(bleDevice: match, deviceToken: userId)
        }
    }

    /// SDK relays CoreBluetooth's power state here. Defaults to true so we never block a scan
    /// before the first callback lands; only an explicit powered=false refuses (PLA2-321).
    func bleState(powered: Bool) {
        isBluetoothPowered = powered
        AppLog.log("[DeviceManager] Bluetooth powered: \(powered)")
        if !powered, case .scanning = connectionStateSubject.value {
            DispatchQueue.main.async { [weak self] in
                self?.connectionStateSubject.send(.failed(Self.bluetoothOffMessage))
            }
        }
    }

    func bleScanOverTime() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if case .scanning = self.connectionStateSubject.value {
                self.connectionStateSubject.send(.disconnected)
            }
        }
    }

    func bleConnectState(state: Int) {
        #if DEBUG
        AppLog.log("[DeviceManager] bleConnectState: \(state), isOTA=\(isOTAInProgress)")
        #endif
        switch state {
        case 0:
            hasPopulatedDevice = false
            // During OTA the device disconnects and reboots; SDK handles reconnection internally
            if isOTAInProgress {
                hasPopulatedDevice = false
                #if DEBUG
                AppLog.log("[DeviceManager] OTA in progress, skipping auto reconnect")
                #endif
                return
            }
            // WiFi 快传期间 BLE 会断连，不要自动重连（会干扰 WiFi 连接）
            if PlaudDeviceAgent.shared.isWiFiTransferActive {
                bleDroppedDuringWiFi = true
                #if DEBUG
                AppLog.log("[DeviceManager] WiFi transfer active, BLE dropped — will reconnect after transfer")
                #endif
                return
            }
            let wasUserDisconnect = isUserDisconnect
            isUserDisconnect = false
            DispatchQueue.main.async { [weak self] in
                self?.connectionStateSubject.send(.disconnected)
                self?.connectedDeviceSubject.send(nil)
                if !wasUserDisconnect {
                    self?.startAutoReconnect(initialDelay: 3.0)
                }
            }
        case 1:
            stopAutoReconnect()
            isUserDisconnect = false
            DispatchQueue.main.async { [weak self] in
                self?.connectionStateSubject.send(.connected)
            }
        case 2, -1, -2:
            DispatchQueue.main.async { [weak self] in
                self?.connectionStateSubject.send(.failed("Connection failed (code: \(state))"))
            }
        default:
            break
        }
    }

    /// Populate device info from SDK-cached BleDevice (reconnection scenario)
    /// versionCode is encoded as major.minor.patch, prefixed with versionType (e.g. "V")
    private func formatFirmwareVersion(_ raw: BleDevice) -> String {
        let type = raw.versionTypeStr
        return "\(type)\(formatVersionCode(raw.versionCode))"
    }

    private func formatVersionCode(_ code: Int) -> String {
        if code <= 0 { return "unknown" }
        if code < 255 { return String(format: "%04d", code) }
        let major = (code >> 16) & 0xFF
        let minor = (code >> 8) & 0xFF
        let patch = code & 0xFF
        return "\(major).\(minor).\(patch)"
    }

    private func populateDeviceFromCache() {
        guard let raw = PlaudDeviceAgent.shared.recentConnectDevice else { return }

        // Execute only once to avoid overwriting latestFirmwareVersion on repeated calls
        guard !hasPopulatedDevice else { return }
        hasPopulatedDevice = true

        let sn = raw.serialNumber
        let device = PlaudDevice(
            serialNumber: sn,
            name: raw.name,
            batteryLevel: raw.power,
            isCharging: raw.isCharging,
            storageUsed: 0,
            storageTotal: 0,
            firmwareVersion: formatFirmwareVersion(raw),
            latestFirmwareVersion: nil,
            latestFirmwareVersionCode: nil,
            supportWiFi: raw.supportWiFi
        )
        connectedDeviceSubject.send(device)
        refreshDeviceInfo()
        // SDK auto-reports device metadata (reportDeviceMetadata), no app-layer call needed

        // Auto-check firmware update after connection
        PlaudDeviceAgent.shared.checkFirmwareUpdate { [weak self] result in
            guard result.hasUpdate else { return }
            DispatchQueue.main.async {
                guard var device = self?.connectedDeviceSubject.value else { return }
                device.latestFirmwareVersion = result.latestVersion
                self?.connectedDeviceSubject.send(device)
            }
        }
    }

    func bleBind(sn: String?, status: Int, protVersion: Int, timezone: Int) {
        guard status == 0, let sn = sn else { return }
        if pendingDeviceWiFiClose {
            pendingDeviceWiFiClose = false
            PlaudDeviceAgent.shared.setDeviceWiFi(open: false)
            AppLog.log("[DeviceManager] Closed device WiFi after post-transfer BLE reconnect", level: "WIFI")
        }
        // Report cloud binding on every successful connect (idempotent for the same owner)
        cloudBind(sn: sn)
        let deviceName = PlaudDeviceAgent.shared.recentConnectDevice?.name ?? sn
        RecordingStore.shared.addPairedDevice(sn: sn, name: deviceName)
        let raw = PlaudDeviceAgent.shared.recentConnectDevice
        let device = PlaudDevice(
            serialNumber: sn,
            name: raw?.name ?? sn,
            batteryLevel: raw?.power ?? 0,
            isCharging: raw?.isCharging ?? false,
            storageUsed: 0,
            storageTotal: 0,
            firmwareVersion: raw.map { formatFirmwareVersion($0) } ?? "",
            latestFirmwareVersion: nil,
            latestFirmwareVersionCode: nil,
            supportWiFi: raw?.supportWiFi ?? false
        )
        DispatchQueue.main.async { [weak self] in
            self?.connectedDeviceSubject.send(device)
        }
        refreshDeviceInfo()
    }

    func bleDeviceDisconnectErr() {
        AppLog.log("[DeviceManager] 🔌 bleDeviceDisconnectErr")
        hasPopulatedDevice = false
        DispatchQueue.main.async { [weak self] in
            self?.connectionStateSubject.send(.disconnected)
            self?.connectedDeviceSubject.send(nil)
        }
    }

    // MARK: Device State Updates

    func blePowerChange(power: Int, oldPower: Int) {
        DispatchQueue.main.async { [weak self] in
            guard var device = self?.connectedDeviceSubject.value else { return }
            device.batteryLevel = power
            self?.connectedDeviceSubject.send(device)
        }
    }

    func bleChargingState(isCharging: Bool, level: Int) {
        DispatchQueue.main.async { [weak self] in
            guard var device = self?.connectedDeviceSubject.value else { return }
            device.isCharging = isCharging
            device.batteryLevel = level
            self?.connectedDeviceSubject.send(device)
        }
    }

    func bleStorage(total: Int, free: Int, duration: Int) {
        DispatchQueue.main.async { [weak self] in
            guard var device = self?.connectedDeviceSubject.value else { return }
            device.storageTotal = Int64(total)
            device.storageUsed = Int64(total - free)
            self?.connectedDeviceSubject.send(device)
        }
    }

    func bleDeviceName(name: String?) {
        guard let name = name else { return }
        DispatchQueue.main.async { [weak self] in
            guard var device = self?.connectedDeviceSubject.value else { return }
            device.name = name
            self?.connectedDeviceSubject.send(device)
        }
    }

    // MARK: Forward to RecordingManager

    func bleRecordStart(sessionId: Int, start: Int, status: Int, scene: Int, startTime: Int, reason: Int) {
        RecordingManager.shared.handleRecordStart(sessionId: sessionId, startTime: startTime)
        if status == 0 {
            PlaudDeviceAgent.shared.syncFile(sessionId: sessionId, start: start, end: 0)
        }
    }

    func bleRecordStop(sessionId: Int, reason: Int, fileExist: Bool, fileSize: Int) {
        AppLog.log("[DeviceManager] bleRecordStop: sessionId=\(sessionId), reason=\(reason), fileExist=\(fileExist), fileSize=\(fileSize)")
        RecordingManager.shared.handleRecordStop(sessionId: sessionId)
    }

    func bleRecordPause(sessionId: Int, reason: Int, fileExist: Bool, fileSize: Int) {
        RecordingManager.shared.handleRecordPause(sessionId: sessionId)
    }

    func bleRecordResume(sessionId: Int, start: Int, status: Int, scene: Int, startTime: Int) {
        RecordingManager.shared.handleRecordResume(sessionId: sessionId, startTime: startTime)
    }

    func blePcmData(sessionId: Int, millsec: Int, pcmData: Data, isMusic: Bool) {
        RecordingManager.shared.handlePcmData(pcmData: pcmData) // Decoded PCM, 640 bytes mono
    }

    // MARK: Required Callbacks (@required)

    func blePenState(state: Int, privacy: Int, keyState: Int, uDisk: Int, findMyToken: Int, hasSndpKey: Int, deviceAccessToken: Int) {
        AppLog.log("[DeviceManager] ✅ blePenState called! state=\(state)")
        // Handshake complete, populate device info + check firmware + report metadata
        DispatchQueue.main.async { [weak self] in
            self?.populateDeviceFromCache()
        }

        // state == 4099 (0x1003) means the device is currently recording
        let agent = BleAgent.shared
        if state == 4099 || agent.isRecording,
           case .idle = RecordingManager.shared.stateSubject.value {
            let sessionId = agent.sessionId
            RecordingManager.shared.handleRecordStart(sessionId: sessionId, startTime: sessionId)
            PlaudDeviceAgent.shared.syncFile(sessionId: sessionId, start: 0, end: 0)
        }
    }

    // MARK: Forward to SyncManager

    func bleFileList(bleFiles: [BleFile]) {
        SyncManager.shared.handleFileList(bleFiles)
    }

    /// Progress/completion callback for downloadFile high-level API
    func bleDownloadFile(sessionId: Int, desiredOutputPath: String, status: Int, progress: Int, tips: String) {
        AppLog.log("[DeviceManager] 📥 bleDownloadFile: sessionId=\(sessionId), status=\(status), progress=\(progress)%, tips=\(tips)")
        if status == 0 && progress == 100 {
            AppLog.log("[DeviceManager] 📥 Download complete: sessionId=\(sessionId), path=\(desiredOutputPath)")
            SyncManager.shared.handleDownloadComplete(sessionId: sessionId, outputPath: desiredOutputPath)
        } else if status == 0 {
            SyncManager.shared.handleDownloadProgress(sessionId: sessionId, progress: progress, message: tips)
        } else {
            AppLog.log("[DeviceManager] ⚠️ Download error: sessionId=\(sessionId), status=\(status), tips=\(tips)")
            SyncManager.shared.handleSyncFileHead(sessionId: sessionId, status: status)
        }
    }

    func bleDownloadFileStop() {
        AppLog.log("[DeviceManager] ⚠️ bleDownloadFileStop called")
    }

    func bleSyncFileTail(sessionId: Int, crc: Int) {
        AppLog.log("[DeviceManager] 📥 bleSyncFileTail: sessionId=\(sessionId), crc=\(crc)")
        // Device finished sending this file — only local transcode remains (device is idle now).
        SyncManager.shared.handleDeviceTransferFinished(sessionId: sessionId)
    }

    func bleSyncFileHead(sessionId: Int, status: Int) {
        AppLog.log("[DeviceManager] 📥 bleSyncFileHead: sessionId=\(sessionId), status=\(status)")
    }

    func bleData(sessionId: Int, start: Int, data: Data) {}

    // MARK: WiFi Fast Transfer

    func bleWiFiOpen(_ status: Int, _ wifiName: String, _ wholeName: String, _ wifiPass: String) {
        AppLog.log("[DeviceManager] bleWiFiOpen: status=\(status), wifiName=\(wifiName), wholeName=\(wholeName), passLen=\(wifiPass.count)")
        guard status == 0 else { return }
        // SDK 1.0.9+ guarantees a non-empty wifiPass here (it falls back to the SN-derived default
        // when the device doesn't echo one), so it can be handed straight to connectWifi.
        SyncManager.shared.handleWiFiOpen(ssid: wholeName, password: wifiPass)
    }

    func bleWiFiClose(_ status: Int) {
        SyncManager.shared.handleWiFiClose()
    }
}

