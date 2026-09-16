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
    /// Brick recovery (lifecycle guide §3.3): queries GET /sdk/binding for bind_history,
    /// handshakes with each historical id, wipes the stale bond (depair), then reconnects as the
    /// current user. Progress/outcome surface through connectionStatePublisher.
    func startDeviceRecovery(_ device: ScannedDevice)
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

    /// Offer the brick-recovery flow for a device whose handshake was rejected during
    /// AUTO-reconnect (no connect sheet is open to catch the Failed state, so Home/MainTab
    /// subscribes and presents the offer).
    private let recoveryOfferSubject = PassthroughSubject<ScannedDevice, Never>()
    var recoveryOfferPublisher: AnyPublisher<ScannedDevice, Never> { recoveryOfferSubject.eraseToAnyPublisher() }

    /// The in-flight connect was started by auto-reconnect (no user in front of a sheet).
    private var isAutoReconnectAttempt = false

    /// User-initiated connect awaiting the E2EE handshake. GATT-level connect (bleConnectState 1)
    /// is NOT success for these devices: a firmware locked by another account accepts the GATT
    /// link, rejects the handshake, and silently drops — which used to read as connected→
    /// disconnected and never produced a Failed, so the recovery offer was unreachable.
    private var awaitingHandshakeSN: String?

    /// Device recovery (lifecycle guide §3.3) in flight. While set, connect/bind/pen-state
    /// callbacks are rerouted to the recovery continuation instead of the normal
    /// connected-handling: the handshake uses a HISTORICAL client_user_id, so treating it as a
    /// real connection would cloud-bind the device to the current user and persist pairing state
    /// before the stale bond is wiped.
    private var recoveryInProgress = false
    /// One-shot outcome hook for the current recovery handshake attempt.
    private var recoveryAttemptResult: ((Bool) -> Void)?
    /// One-shot hook for the device's depair confirmation during recovery.
    private var recoveryDepairDone: (() -> Void)?
    /// depair changes the device's MAC, so the cached BleDevice is stale afterwards. During the
    /// post-depair rescan we wait for the SN to re-advertise and capture the fresh BleDevice.
    private var recoveryRescanSN: String?
    private var recoveryRescanHook: ((BleDevice) -> Void)?
    private let recoveryQueue = DispatchQueue(label: "com.plaud.template.device-recovery")
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
        // Route the BLE SDK's internal handshake logs (mlog/wlog) to NSLog so they are captured
        // in the exported .plaud file. Without this the export only holds scan-level NSLog and the
        // RSA pre-handshake / first-handshake / disconnect-reason lines — the detail needed to
        // diagnose a rejected connection — live only in the live Xcode console.
        BleAgent.shared.openLog(true, logBlock: { NSLog("[BLE] %@", $0) },
                                wlogBlock: { NSLog("[BLE] %@", $0) })
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
        awaitingHandshakeSN = device.serialNumber
        isAutoReconnectAttempt = false
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

    // MARK: - Device Recovery (lifecycle guide §3.3 / §4.5)

    /// Fire the current recovery attempt's outcome exactly once (bind / pen-state / connect-state
    /// can all report for the same handshake).
    private func fireRecoveryAttempt(_ unlocked: Bool) {
        let callback = recoveryAttemptResult
        recoveryAttemptResult = nil
        callback?(unlocked)
    }

    /// Brick recovery (lifecycle guide §3.3): the firmware still holds some previous user's
    /// client_user_id, so the current user's handshake is rejected. Query bind_history, handshake
    /// with each historical id (transformed the same way the SDK derives the token from the JWT:
    /// strip the client_user_ prefix, drop hyphens), and on success wipe the stale bond with
    /// depair — then reconnect as the current user. No reflashing tool needed.
    func startDeviceRecovery(_ device: ScannedDevice) {
        let sn = device.serialNumber
        AppLog.log("[DeviceManager] recovery: start for sn=\(sn)")
        connectionStateSubject.send(.connecting(device))

        PlaudAPIService.shared.queryDeviceBinding(
            type: PairedDeviceInfo.deviceType(for: sn), sn: sn
        ) { [weak self] result in
            guard let self else { return }
            guard let result = result else {
                self.failRecovery("Recovery failed: could not query the cloud binding state."); return
            }
            if result.isBind == true {
                self.failRecovery("This device is bound to another account. That owner must unbind it first."); return
            }
            // bind_history has one entry PER device.bind event, so the same id repeats for every
            // past connect (live-verified: 50+ duplicates of one id) — dedupe before bounding,
            // otherwise the attempts would try the same key five times.
            var seen = Set<String>()
            let history = Array(result.bindHistory.filter { seen.insert($0).inserted }
                .prefix(Self.recoveryMaxAttempts))
            if history.isEmpty {
                self.failRecovery("Recovery not possible: the device has no bind history."); return
            }
            guard let bleDevice = self.cachedBleDevices[sn] else {
                self.failRecovery("Device not found, please rescan."); return
            }
            self.recoveryQueue.async { self.runRecovery(device: device, bleDevice: bleDevice, history: history) }
        }
    }

    /// Blocking orchestration on recoveryQueue: one recoveryConnect attempt per historical id.
    /// SDK 1.0.13+ `recoveryConnectBleDevice` pins the historical id as the handshake token and
    /// connects with isForceClear (PRE_HANDSHAKE_AND_CLEAR 0xFE20) so the firmware wipes its stale
    /// key material; the current user's sn-sign / RSA material is reused (no backend signing for the
    /// historical user), and the SDK auto-restores the current user's identity when the attempt
    /// ends. On a matching id the device accepts the handshake (bleBind / blePenState). We then
    /// depair, rescan (depair changes the MAC, so the cached BleDevice is stale) and reconnect as
    /// the current user.
    private func runRecovery(device: ScannedDevice, bleDevice: BleDevice, history: [String]) {
        suppressAutoReconnect = true
        recoveryInProgress = true
        defer { recoveryInProgress = false; recoveryAttemptResult = nil }

        for (index, historicalId) in history.enumerated() {
            AppLog.log("[DeviceManager] recovery: attempt \(index + 1)/\(history.count) with \(historicalId.prefix(20))…")

            let semaphore = DispatchSemaphore(value: 0)
            var unlocked = false
            recoveryAttemptResult = { ok in unlocked = ok; semaphore.signal() }
            DispatchQueue.main.async {
                PlaudDeviceAgent.shared.recoveryConnectBleDevice(bleDevice: bleDevice, historicalUserId: historicalId)
            }
            _ = semaphore.wait(timeout: .now() + Self.recoveryHandshakeTimeout)
            recoveryAttemptResult = nil

            if !unlocked {
                AppLog.log("[DeviceManager] recovery: attempt \(index + 1) rejected")
                DispatchQueue.main.async { PlaudDeviceAgent.shared.disconnect() }
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }

            AppLog.log("[DeviceManager] recovery: handshake OK — wiping the stale bond (depair)")
            let depairSemaphore = DispatchSemaphore(value: 0)
            recoveryDepairDone = { depairSemaphore.signal() }
            DispatchQueue.main.async { PlaudDeviceAgent.shared.depair(clear: false) }
            if depairSemaphore.wait(timeout: .now() + Self.recoveryDepairTimeout) == .timedOut {
                AppLog.log("[DeviceManager] recovery: no depair confirmation, proceeding anyway")
            }
            recoveryDepairDone = nil
            recoveryInProgress = false
            DispatchQueue.main.async { PlaudDeviceAgent.shared.disconnect() }
            Thread.sleep(forTimeInterval: 1.5)

            // depair changes the device's MAC, so the cached BleDevice is now stale — rescan and
            // match by SN before reconnecting as the current user (SDK doc requirement).
            let sn = device.serialNumber
            AppLog.log("[DeviceManager] recovery: bond wiped — rescanning (MAC changes after depair)")
            let rescanSemaphore = DispatchSemaphore(value: 0)
            var freshDevice: BleDevice?
            recoveryRescanSN = sn
            recoveryRescanHook = { dev in freshDevice = dev; rescanSemaphore.signal() }
            DispatchQueue.main.async { PlaudDeviceAgent.shared.startScan() }
            let rescanned = rescanSemaphore.wait(timeout: .now() + Self.recoveryRescanTimeout)
            recoveryRescanSN = nil
            recoveryRescanHook = nil
            DispatchQueue.main.async { PlaudDeviceAgent.shared.stopScan() }

            guard rescanned == .success, let fresh = freshDevice else {
                failRecovery("The device was unlocked but did not reappear — please rescan and connect it.")
                return
            }
            AppLog.log("[DeviceManager] recovery: device reappeared — reconnecting as the current user")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.suppressAutoReconnect = false
                let scanned = ScannedDevice(
                    name: Self.scanDisplayName(rawName: fresh.name, sn: sn),
                    serialNumber: sn, rssi: fresh.rssi
                )
                self.connect(scanned, userId: RecordingStore.shared.userId ?? "")
            }
            return
        }
        failRecovery("Recovery failed: none of the previous accounts matched the device lock.")
    }

    private func failRecovery(_ message: String) {
        AppLog.log("[DeviceManager] recovery: \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.connectionStateSubject.send(.failed(message))
        }
    }

    /// Depair confirmation from the device (only consumed during recovery; the normal unpair
    /// flow does not wait for it).
    func bleDepair(status: Int) {
        AppLog.log("[DeviceManager] bleDepair: status=\(status)")
        recoveryDepairDone?()
    }

    private static let recoveryHandshakeTimeout: TimeInterval = 25
    private static let recoveryDepairTimeout: TimeInterval = 5
    private static let recoveryRescanTimeout: TimeInterval = 20
    private static let recoveryMaxAttempts = 5

    /// Fine-grained connect stage relayed by the SDK (bleConnectStage), e.g.
    /// `preHandshake` / `sendRSAPublic` / `firstHandshake` with a detail such as
    /// `sn_signature_invalid`. Logged for diagnostics — this is where a rejected handshake
    /// reveals which layer refused (RSA pre-handshake vs the userToken handshake).
    @objc func bleConnectStage(sn: String?, stage: String, detail: String?) {
        AppLog.log("[DeviceManager] bleConnectStage sn=\(sn ?? "-") stage=\(stage) detail=\(detail ?? "-")")
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

        // Recovery post-depair rescan: the device re-advertises under a new MAC. Capture the fresh
        // BleDevice for the recovery flow's reconnect and skip auto-reconnect for this result.
        if let rescanSN = recoveryRescanSN,
           let fresh = bleDevices.first(where: { $0.serialNumber == rescanSN }) {
            let hook = recoveryRescanHook
            recoveryRescanSN = nil
            recoveryRescanHook = nil
            hook?(fresh)
            return
        }

        // Auto reconnect: connect automatically when the last bound device is found
        // suppressAutoReconnect = true 时跳过（Add Device 流程中不自动重连旧设备）
        if !suppressAutoReconnect,
           let lastSN = RecordingStore.shared.lastConnectedDeviceSN,
           let match = bleDevices.first(where: { $0.serialNumber == lastSN }),
           case .scanning = connectionStateSubject.value {
            let userId = RecordingStore.shared.userId ?? ""
            let scanned = ScannedDevice(name: match.name, serialNumber: match.serialNumber, rssi: match.rssi)
            // Auto-reconnect is also handshake-gated: a rejection surfaces the recovery offer on
            // Home instead of looping silently (the user asked for launch-path recovery too).
            awaitingHandshakeSN = match.serialNumber
            isAutoReconnectAttempt = true
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
        if recoveryInProgress {
            // Recovery handshake attempt. GATT connect (state 1) is NOT proof the historical id
            // matched the firmware lock — depair sent before the handshake completes is ignored
            // by the device. Success is only signaled by bleBind(status 0) / blePenState; here we
            // only report failures (drop / error before the handshake finished).
            if state == 0 || state == 2 { fireRecoveryAttempt(false) }
            return
        }
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
            // Dropped before the handshake completed on a user-initiated connect: this is how a
            // firmware locked by another account rejects us. Surface a Failed (which offers the
            // recovery flow) instead of a silent disconnected→reconnect loop.
            if let sn = awaitingHandshakeSN {
                awaitingHandshakeSN = nil
                let wasAuto = isAutoReconnectAttempt
                isAutoReconnectAttempt = false
                stopAutoReconnect()
                AppLog.log("[DeviceManager] handshake rejected for sn=\(sn) (dropped before completion, auto=\(wasAuto))")
                let display = cachedBleDevices[sn].map { Self.scanDisplayName(rawName: $0.name, sn: sn) } ?? sn
                let device = ScannedDevice(name: display, serialNumber: sn, rssi: cachedBleDevices[sn]?.rssi ?? 0)
                DispatchQueue.main.async { [weak self] in
                    self?.connectionStateSubject.send(.failed(
                        "The device refused the connection — it may still be locked by another account."))
                    // No sheet is watching during auto-reconnect — offer recovery on Home instead.
                    if wasAuto { self?.recoveryOfferSubject.send(device) }
                }
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
            // GATT connected — NOT success yet. The E2EE handshake follows and can still be
            // rejected by a firmware locked to another account. .connected is sent from
            // bleBind(status 0) once the handshake actually completes.
            stopAutoReconnect()
            isUserDisconnect = false
            AppLog.log("[DeviceManager] GATT connected, awaiting handshake")
        case 2, -1, -2:
            // A brick can also surface as a connect failure (never reaching GATT) rather than a
            // GATT-then-drop. If a connect was awaiting the handshake, treat it like the state-0
            // rejection: offer recovery instead of a dead "Connection failed".
            if let sn = awaitingHandshakeSN {
                awaitingHandshakeSN = nil
                let wasAuto = isAutoReconnectAttempt
                isAutoReconnectAttempt = false
                stopAutoReconnect()
                AppLog.log("[DeviceManager] handshake rejected for sn=\(sn) (connect failed code=\(state), auto=\(wasAuto))")
                let display = cachedBleDevices[sn].map { Self.scanDisplayName(rawName: $0.name, sn: sn) } ?? sn
                let device = ScannedDevice(name: display, serialNumber: sn, rssi: cachedBleDevices[sn]?.rssi ?? 0)
                DispatchQueue.main.async { [weak self] in
                    self?.connectionStateSubject.send(.failed(
                        "The device refused the connection — it may still be locked by another account."))
                    if wasAuto { self?.recoveryOfferSubject.send(device) }
                }
                return
            }
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
        if recoveryInProgress { fireRecoveryAttempt(status == 0); return }
        guard status == 0, let sn = sn else { return }
        // Handshake complete — THIS is connection success (see bleConnectState case 1).
        awaitingHandshakeSN = nil
        DispatchQueue.main.async { [weak self] in
            self?.connectionStateSubject.send(.connected)
        }
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
        if recoveryInProgress { fireRecoveryAttempt(true); return }
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

