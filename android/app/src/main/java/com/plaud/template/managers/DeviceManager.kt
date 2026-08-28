package com.plaud.template.managers

import android.content.Context
import android.util.Log
import com.plaud.template.common.AppLog
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import sdk.NiceBuildSdk
import sdk.PlaudDeviceAgent
import sdk.PlaudDeviceAgentListener
import sdk.firmware.FirmwareUpdateCallback
import sdk.firmware.FirmwareUpdateInfo
import sdk.firmware.FirmwareDownloadResult
import sdk.firmware.FirmwareInstallResult
import sdk.firmware.FirmwareTransferPhase
import sdk.firmware.UpdateProgress
import com.tinnotech.penblesdk.TntAgent
import com.tinnotech.penblesdk.Constants
import com.tinnotech.penblesdk.entity.AgentCallback
import com.tinnotech.penblesdk.entity.BleDevice
import com.tinnotech.penblesdk.entity.BleFile
import com.tinnotech.penblesdk.entity.bean.blepkg.response.GetStateRsp
import com.tinnotech.penblesdk.entity.bean.blepkg.response.TimeSyncRsp
import com.plaud.template.models.*
import com.plaud.template.storage.RecordingStore

/**
 * Wraps the unified GA facade sdk.PlaudDeviceAgent (callbacks via PlaudDeviceAgentListener),
 * managing device scanning/connection/state. Aligned with the iOS PlaudDeviceAgent integration.
 *
 * Documented facade gaps (raw SDK used as a workaround, remove once the facade covers them):
 *  - Partner API baseUrl does not follow initSDK's customDomain → NiceBuildSdk.getPartnerApiManager().updateBaseUrl
 *  - blePenState carries no sessionId (iOS has 9 params) → legacy getState for record-state drift sync
 *  - No time-sync / firmware-version accessor on the facade → TntAgent for syncTime & versionName
 */
class DeviceManager private constructor() : DeviceManagerProtocol {

    companion object {
        private const val TAG = "DeviceManager"

        /** Template app scope: NotePro (881) and NotePin S (882) only. */
        fun isSupportedDevice(sn: String?): Boolean =
            sn != null && (sn.startsWith("881") || sn.startsWith("882"))
        private const val CONNECT_TIMEOUT = 30_000L
        private const val HANDSHAKE_TIMEOUT = 60_000L

        /** Device recovery (lifecycle guide §3.3): bound the per-attempt handshake wait. */
        private const val RECOVERY_HANDSHAKE_TIMEOUT_MS = 25_000L

        /** Device recovery: newest-first bind_history entries to try before giving up. */
        private const val RECOVERY_MAX_ATTEMPTS = 5

        /** Device recovery: wait for the device's depair confirmation before moving on. */
        private const val RECOVERY_DEPAIR_TIMEOUT_MS = 5_000L

        /** Device recovery: wait for the device to re-advertise (new MAC) after depair. */
        private const val RECOVERY_RESCAN_TIMEOUT_MS = 20_000L

        /** Failure text used when a scan is refused because the phone's Bluetooth is off. */
        const val BLUETOOTH_OFF_MESSAGE = "Bluetooth is off. Turn it on to find your device."

        /**
         * Pick-list label for a scan hit. BLE local names sometimes arrive with control bytes or
         * broken UTF-8, which rendered as garbage in the device list (PLA2-325): drop those and
         * fall back to the model name from the SN prefix, like the connected-device card does.
         */
        fun scanDisplayName(rawName: String?, sn: String): String {
            val cleaned = rawName?.filter { !it.isISOControl() && it != '�' }?.trim().orEmpty()
            if (cleaned.isNotEmpty()) return cleaned
            return when {
                sn.startsWith("881") -> "Plaud NotePro"
                sn.startsWith("882") -> "Plaud NotePin S"
                else -> "Plaud Device"
            }
        }

        @Volatile
        private var instance: DeviceManager? = null

        val shared: DeviceManager
            get() = instance ?: synchronized(this) {
                instance ?: DeviceManager().also { instance = it }
            }
    }

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // MARK: - StateFlow

    private val _connectionState = MutableStateFlow<DeviceConnectionState>(DeviceConnectionState.Disconnected)
    override val connectionState: StateFlow<DeviceConnectionState> = _connectionState.asStateFlow()

    private val _connectedDevice = MutableStateFlow<PlaudDevice?>(null)
    override val connectedDevice: StateFlow<PlaudDevice?> = _connectedDevice.asStateFlow()

    private val _scannedDevices = MutableStateFlow<List<ScannedDevice>>(emptyList())
    override val scannedDevices: StateFlow<List<ScannedDevice>> = _scannedDevices.asStateFlow()

    private val _firmwareProgress = MutableStateFlow<Float?>(null)
    override val firmwareProgress: StateFlow<Float?> = _firmwareProgress.asStateFlow()

    private val _firmwareUpdateState = MutableStateFlow<FirmwareUpdateUiState?>(null)
    override val firmwareUpdateState: StateFlow<FirmwareUpdateUiState?> = _firmwareUpdateState.asStateFlow()

    private val _cloudAlerts = MutableSharedFlow<String>(extraBufferCapacity = 1)
    override val cloudAlerts: SharedFlow<String> = _cloudAlerts.asSharedFlow()

    private val _recoveryOffers = MutableSharedFlow<ScannedDevice>(extraBufferCapacity = 1)
    override val recoveryOffers: SharedFlow<ScannedDevice> = _recoveryOffers.asSharedFlow()

    /** Firmware update info from the latest check, reused by startFirmwareUpdate. */
    private var pendingUpdateInfo: FirmwareUpdateInfo? = null

    private var appContext: Context? = null
    private var scanTimeoutJob: Job? = null

    /** Raw scanned BleDevice objects (needed when connecting) */
    private val scannedBleDevices = mutableListOf<BleDevice>()

    /** Cache of scanned device names (sn -> BLE advertised name, e.g. "Plaud NotePin S") */
    private val scannedNames = mutableMapOf<String, String>()

    // MARK: - Auto-reconnect
    /** Set to true while adding a device / during a user-initiated disconnect, to suppress auto-reconnect to the last device */
    @Volatile
    override var suppressAutoReconnect: Boolean = false

    /**
     * Set by SyncManager when a WiFi fast transfer ends: the device hotspot still has to be closed,
     * but BLE is down at that moment so neither the SDK nor we can send the command. Consumed on
     * the next successful BLE connect.
     */
    @Volatile
    var pendingDeviceWiFiClose = false

    private var reconnectAttempts = 0
    private val maxReconnectAttempts = 10

    /** Active User Access Token: runtime override (Settings → Replace) ?: build-injected. */
    private val partnerToken get() = RecordingStore.activeUserAccessToken

    /** Server host, switchable via Settings → Environment (restart to apply). */
    private val platformHost get() = "https://${RecordingStore.activeServerDomain}"

    // MARK: - Initialization

    fun setContext(context: Context) {
        appContext = context.applicationContext
    }

    override fun configure(userId: String) {
        val ctx = appContext ?: run {
            AppLog.e(TAG, "configure: appContext is null, call setContext() first")
            return
        }
        RecordingStore.userId = userId

        // Important: the SDK's Partner API (gen-key / sn-sign) defaults to platform-jp,
        // and the platformHost passed to initSdk is not forwarded to the Partner API (known SDK issue).
        // We must manually switch the Partner API domain to the target environment before initSdk;
        // otherwise a US-account token sent to jp returns 401 CLIENT_USER_NOT_FOUND → RSA key fetch fails → handshake fails.
        try {
            NiceBuildSdk.getPartnerApiManager().updateBaseUrl(platformHost)
            AppLog.i(TAG, "Partner API baseUrl set to $platformHost")
        } catch (e: Exception) {
            AppLog.w(TAG, "set Partner API baseUrl failed", e)
        }

        // GA facade init (E2EE devices need no appKey/appSecret; token = userAccessToken model)
        PlaudDeviceAgent.listener = agentListener
        PlaudDeviceAgent.initSDK(
            context = ctx,
            userAccessToken = partnerToken,
            customDomain = platformHost.removePrefix("https://")
        )

        // Silence the BLE SDK's per-packet DEBUG spam (OtaPushHelper logs ~5 lines per 80-byte
        // packet during OTA ≈ 200 lines/s); INFO keeps connection/state logs.
        try {
            com.tinnotech.penblesdk.utils.TntBleLog.setLogLevel(android.util.Log.INFO)
        } catch (e: Exception) { AppLog.w(TAG, "setLogLevel failed", e) }

        AppLog.i(TAG, "SDK configured for userId=$userId")
    }

    /** SN of the device the user asked to connect (facade bleConnectState carries no SN). */
    @Volatile
    private var pendingConnectSN: String? = null

    /**
     * Connect in flight, E2EE handshake not yet confirmed. GATT-level connect (bleConnectState 1)
     * is NOT success: a firmware locked by another account accepts the GATT link, rejects the
     * handshake and silently drops — which used to read as connected→disconnected and never
     * produced a Failed, so the recovery offer was unreachable.
     */
    @Volatile
    private var awaitingHandshake = false

    /** The in-flight connect was started by auto-reconnect (no connect sheet is open). */
    @Volatile
    private var isAutoReconnectAttempt = false

    /** Device of the in-flight connect, kept for the recovery offer on rejection. */
    @Volatile
    private var pendingConnectDevice: ScannedDevice? = null

    private val agentListener = object : PlaudDeviceAgentListener {

        override fun bleScanResult(devices: List<BleDevice>) {
            scope.launch {
                // Template app supports NotePro (881) and NotePin S (882) only — filter out
                // other project codes (880 NotePin / 888 Note / ...) at the single entry point.
                val supported = devices.filter { isSupportedDevice(it.getSerialNumber()) }
                scannedBleDevices.clear()
                scannedBleDevices.addAll(supported)

                val scanned = supported.mapNotNull { device ->
                    val sn = device.getSerialNumber() ?: device.getMacAddress() ?: return@mapNotNull null
                    val bleName = scanDisplayName(device.getName(), sn)
                    if (bleName.isNotBlank()) scannedNames[sn] = bleName
                    ScannedDevice(
                        name = bleName,
                        serialNumber = sn,
                        rssi = device.getRssi()
                    )
                }
                // NOTE: deliberately NOT filtering out already-paired devices. A paired device that
                // is currently connected does not advertise, so it cannot show up here anyway; one
                // that is disconnected DOES advertise and must stay selectable so the user can
                // bring it back. Hiding them only masked connect failures caused by a stale
                // userAccessToken (PLA2-323).
                // Sort by signal strength (mirrors iOS RSSI-descending ordering)
                _scannedDevices.value = scanned.sortedByDescending { it.rssi }

                // Recovery post-depair rescan: the device re-advertises under a new MAC. Hand the
                // fresh BleDevice to the recovery flow and skip auto-reconnect for this result.
                val rescanSN = recoveryRescanSN
                if (rescanSN != null) {
                    supported.firstOrNull { it.getSerialNumber() == rescanSN }?.let { fresh ->
                        recoveryRescanSN = null
                        recoveryRescanSignal?.complete(fresh)
                        return@launch
                    }
                }

                // Auto-reconnect to the last bound device (not triggered while adding a device / during a user-initiated disconnect)
                val lastSN = RecordingStore.lastConnectedDeviceSN
                if (!suppressAutoReconnect && lastSN != null &&
                    _connectionState.value is DeviceConnectionState.Scanning
                ) {
                    scanned.firstOrNull { it.serialNumber == lastSN }
                        ?.let { connect(it, RecordingStore.userId ?: "", userInitiated = false) }
                }
            }
        }

        override fun bleConnectState(state: Int) {
            AppLog.i(TAG, "bleConnectState: $state")
            if (recoveryInProgress) {
                // Recovery handshake attempt. GATT connect (state 1) is NOT proof the historical
                // id matched the firmware lock — depair sent before the handshake completes is
                // ignored by the device. Success is only signaled by bleBind(status 0); here we
                // only report failures (drop / error before the handshake finished).
                when (state) {
                    0, 2 -> recoverySignal?.complete(false)
                }
                return
            }
            scope.launch {
                when (state) {
                    1 -> {
                        if (awaitingHandshake) {
                            // GATT connected — success is only declared on bleBind(status 0),
                            // after the E2EE handshake actually completes.
                            AppLog.i(TAG, "GATT connected, awaiting handshake")
                        } else {
                            onDeviceConnected(pendingConnectSN ?: RecordingStore.lastConnectedDeviceSN)
                        }
                    }
                    0 -> {
                        if (awaitingHandshake) {
                            // Dropped before the handshake completed: a firmware locked by another
                            // account rejects us this way. Surface it as a handshake rejection.
                            onHandshakeRejected()
                        } else {
                            onDeviceDisconnected()
                        }
                    }
                    2 -> {
                        if (awaitingHandshake) {
                            // A brick manifests differently per platform: iOS drops after GATT
                            // (state 1 -> 0), Android reports a connect failure (state 2, ~10s
                            // timeout) without ever reaching the handshake stages. Treat both the
                            // same — offer recovery rather than a dead "Connection failed".
                            onHandshakeRejected()
                        } else {
                            awaitingHandshake = false
                            _connectionState.value = DeviceConnectionState.Failed("Connection failed")
                        }
                    }
                }
            }
        }

        override fun bleConnectStage(sn: String?, stage: String, detail: String?) {
            // Fine-grained connect stage (preHandshake / sendRsaPublic / firstHandshake with a detail
            // such as sn_signature_invalid). Logged for diagnostics — this reveals which layer refused
            // a rejected handshake (RSA pre-handshake vs the userToken handshake).
            AppLog.i(TAG, "bleConnectStage sn=${sn ?: "-"} stage=$stage detail=${detail ?: "-"}")
        }

        override fun bleBind(sn: String?, status: Int, protVersion: Int, timezone: Int) {
            AppLog.i(TAG, "bleBind: sn=$sn, status=$status")
            if (recoveryInProgress) {
                recoverySignal?.complete(status == 0)
                return
            }
            if (status == 0) awaitingHandshake = false
            if (status == 0 && sn != null) {
                scope.launch { onDeviceConnected(sn) }
                // Report cloud binding on every successful connect (idempotent for the same owner)
                cloudBind(sn)
            }
        }

        override fun blePowerChange(power: Int, oldPower: Int) {
            scope.launch {
                _connectedDevice.value?.let { _connectedDevice.value = it.copy(batteryLevel = power) }
            }
        }

        override fun bleChargingState(isCharging: Boolean, level: Int) {
            scope.launch {
                _connectedDevice.value?.let {
                    _connectedDevice.value = it.copy(isCharging = isCharging, batteryLevel = level)
                }
            }
        }

        override fun bleStorage(total: Long, free: Long, duration: Long) {
            scope.launch {
                _connectedDevice.value?.let {
                    _connectedDevice.value = it.copy(storageUsed = total - free, storageTotal = total)
                }
            }
        }

        override fun bleRecordStart(sessionId: Long, start: Long, status: Int, scene: Int, startTime: Long, reason: Int) {
            AppLog.i(TAG, "bleRecordStart: sessionId=$sessionId")
            RecordingManager.shared.handleRecordStart(sessionId.toInt(), sessionId.toInt())
        }

        override fun bleRecordStop(sessionId: Long, reason: Int, fileExist: Boolean, fileSize: Long) {
            AppLog.i(TAG, "bleRecordStop: sessionId=$sessionId")
            RecordingManager.shared.handleRecordStop(sessionId.toInt())
        }

        override fun bleRecordPause(sessionId: Long, reason: Int, fileExist: Boolean, fileSize: Long) {
            AppLog.i(TAG, "bleRecordPause: sessionId=$sessionId")
            RecordingManager.shared.handleRecordPause(sessionId.toInt())
        }

        override fun bleRecordResume(sessionId: Long, start: Long, status: Int, scene: Int, startTime: Long) {
            AppLog.i(TAG, "bleRecordResume: sessionId=$sessionId")
            RecordingManager.shared.handleRecordResume(sessionId.toInt(), startTime.toInt())
        }

        override fun blePenState(state: Int, privacy: Int, keyState: Int, uDisk: Int) {
            // NOTE: facade blePenState carries no sessionId (iOS has 9 params) — record-state drift
            // sync stays on the legacy getState path in refreshRecordState(). TODO(SDK): add sessionId.
            AppLog.i(TAG, "blePenState: state=$state")
        }

        override fun bleFileList(files: List<BleFile>) {
            SyncManager.shared.handleBleFileList(files)
        }

        override fun bleDeleteFile(sessionId: Long, status: Int) {
            AppLog.i(TAG, "bleDeleteFile: sessionId=$sessionId, status=$status")
        }

        override fun bleDepair(status: Int) {
            AppLog.i(TAG, "bleDepair: status=$status")
            onDepairResult?.invoke(status)
        }
    }

    /** One-shot depair completion hook used by unpair(). */
    @Volatile
    private var onDepairResult: ((Int) -> Unit)? = null

    /**
     * Device recovery (lifecycle guide §3.3) in flight. While set, the connect/bind callbacks are
     * rerouted to [recoverySignal] instead of the normal connected-handling: the handshake is being
     * made with a HISTORICAL client_user_id, so treating it as a real connection would cloud-bind
     * the device to the current user and persist pairing state before the stale bond is wiped.
     */
    @Volatile
    private var recoveryInProgress = false

    /** Completes with the outcome of the current recovery handshake attempt. */
    @Volatile
    private var recoverySignal: CompletableDeferred<Boolean>? = null

    /** depair changes the device's MAC, so the cached BleDevice is stale afterwards. During the
     *  post-depair rescan we wait for the SN to re-advertise and complete with the fresh BleDevice. */
    @Volatile
    private var recoveryRescanSN: String? = null
    @Volatile
    private var recoveryRescanSignal: CompletableDeferred<BleDevice>? = null

    // MARK: - Successful-connection handling

    private fun onDeviceConnected(sn: String?) {
        if (_connectionState.value is DeviceConnectionState.Connected) return
        _connectionState.value = DeviceConnectionState.Connected
        // Connection succeeded; reset the auto-reconnect state
        reconnectJob?.cancel()
        reconnectAttempts = 0
        suppressAutoReconnect = false

        // A WiFi fast transfer just ended: the SDK could not tell the device to close its hotspot
        // because BLE was down at teardown time. Now that BLE is back, send it — otherwise the
        // device sits in WiFi mode (blue LED) until its own ~2 min firmware timeout.
        if (pendingDeviceWiFiClose) {
            pendingDeviceWiFiClose = false
            try {
                PlaudDeviceAgent.setDeviceWiFi(false)
                AppLog.i(TAG, "Closed device WiFi after post-transfer BLE reconnect")
            } catch (e: Exception) {
                AppLog.w(TAG, "setDeviceWiFi(false) after reconnect failed", e)
            }
        }
        val deviceSN = sn ?: RecordingStore.lastConnectedDeviceSN ?: ""
        val deviceName = resolveDeviceName(deviceSN)
        _connectedDevice.value = PlaudDevice(
            serialNumber = deviceSN,
            name = deviceName,
            batteryLevel = 0, isCharging = false,
            storageUsed = 0L, storageTotal = 0L,
            firmwareVersion = "", latestFirmwareVersion = null, supportWiFi = false
        )
        // Register/refresh this device in the paired list and mark it active
        RecordingStore.addPairedDevice(deviceSN, deviceName)

        // Sync the device time (consistent with the sdk_output demo BleManager)
        try {
            TntAgent.getInstant().getBleAgent().syncTime(
                object : AgentCallback.OnRequest { override fun onCallback(p0: Boolean) { } },
                object : AgentCallback.OnResponse<TimeSyncRsp> {
                    override fun onCallback(rsp: TimeSyncRsp?) {
                        AppLog.i(TAG, "syncTime response: timezone=${rsp?.timezone}")
                    }
                }
            )
        } catch (e: Exception) {
            AppLog.w(TAG, "syncTime failed", e)
        }

        // Populate the current firmware version from the connected device
        try {
            val v = TntAgent.getInstant().getBleAgent().currentConnectedDevice?.versionName
            if (!v.isNullOrEmpty()) {
                _connectedDevice.value = _connectedDevice.value?.copy(firmwareVersion = formatFirmwareVersion(v))
            }
        } catch (e: Exception) { AppLog.w(TAG, "read versionName failed", e) }

        refreshDeviceInfo()
        // After connecting, query the device recording state to correct possible state drift (mirrors the iOS blePenState recording sync)
        refreshRecordState()
        // Check for a firmware update (sets latestFirmwareVersion when available)
        checkFirmwareUpdate()
        // Refresh the device file list shortly after every connect (mirrors iOS: 3s delay, skipped
        // while recording) so Recent Files / Files aren't stale after a reconnect.
        scope.launch {
            delay(3_000)
            if (_connectionState.value is DeviceConnectionState.Connected &&
                RecordingManager.shared.state.value is RecordingState.Idle
            ) {
                SyncManager.shared.fetchFileList()
            }
        }
    }

    // MARK: - Firmware OTA

    override fun refreshFirmwareCheck() {
        checkFirmwareUpdate()
    }

    /**
     * Firmware versions arrive as a raw code ("V65546"/"65546") where
     * code = major×65536 + minor×256 + patch → display as "V1.0.10".
     * Legacy short forms (e.g. "V0147") and already-semantic strings pass through unchanged.
     */
    private fun formatFirmwareVersion(raw: String?): String {
        if (raw.isNullOrBlank()) return ""
        val code = raw.removePrefix("V").removePrefix("v").toLongOrNull() ?: return raw
        if (code < 65536) return raw
        return "V${code / 65536}.${(code % 65536) / 256}.${code % 256}"
    }

    /**
     * Check for a firmware update for the connected device; stores the result for startFirmwareUpdate.
     *
     * App-side implementation (mirrors the iOS SDK): GET /version/latest authenticated with
     * X-Device-Signature (the sn-sign signature). The Android SDK's own checkFirmwareUpdate
     * cannot work through the GA facade: it requires an internal sdkToken obtained from
     * appKey/appSecret via /api/oauth/sdk-token — an endpoint that does not exist on the
     * developer platform (404 on platform-us) — see sdk-requests-android-parity.md #11.
     * Download/install still go through the facade (they only need FirmwareUpdateInfo).
     */
    private fun checkFirmwareUpdate() {
        if (!PlaudDeviceAgent.isConnected()) { AppLog.w(TAG, "checkFirmwareUpdate: no connected device"); return }
        val sn = _connectedDevice.value?.serialNumber
        if (sn.isNullOrBlank()) { AppLog.w(TAG, "checkFirmwareUpdate: no SN"); return }

        scope.launch(kotlinx.coroutines.Dispatchers.IO) {
            try {
                val rawVersion = try {
                    TntAgent.getInstant().getBleAgent().currentConnectedDevice?.versionName
                } catch (e: Exception) { null }
                val deviceCode = rawVersion?.removePrefix("V")?.removePrefix("v")?.toLongOrNull() ?: 0L
                val deviceType = getDeviceType(sn)

                // Signature stored by signAndStoreDeviceSn at connect time; re-sign as fallback.
                var signature = com.tinnotech.penblesdk.impl.ble.BluetoothLeOperation
                    .flutterMapData["snSignature"] as? String
                if (signature.isNullOrBlank()) {
                    signature = sdk.network.manager.PartnerApiManager.getInstance()
                        .signDeviceSn(deviceType, sn)?.signature
                }
                if (signature.isNullOrBlank()) {
                    AppLog.w(TAG, "checkFirmwareUpdate: no device signature available")
                    return@launch
                }

                val url = "$platformHost/developer/api/open/partner/sdk/version/latest" +
                    "?type=$deviceType&sn=$sn&current_version=-1"
                val request = okhttp3.Request.Builder().url(url)
                    .header("X-Device-Signature", signature)
                    .build()
                val json = okhttp3.OkHttpClient().newCall(request).execute().use { resp ->
                    val body = resp.body?.string() ?: ""
                    if (!resp.isSuccessful) {
                        AppLog.w(TAG, "checkFirmwareUpdate: HTTP ${resp.code}: ${body.take(200)}")
                        return@launch
                    }
                    org.json.JSONObject(body)
                }

                val serverCode = json.optLong("version_code", 0L)
                val downloadUrl = json.optString("download_url")
                val hasUpdate = serverCode > deviceCode && downloadUrl.isNotBlank()
                AppLog.i(TAG, "checkFirmwareUpdate: current=$deviceCode, latest=$serverCode, hasUpdate=$hasUpdate")

                // Install-time validation requires "^[VT]\d+$" (e.g. "V66055"), matching the
                // device's own versionName format — keep the V/T prefix on versionCode.
                val versionType = json.optString("version_type").ifBlank { "V" }
                val info = FirmwareUpdateInfo(
                    versionResponse = sdk.network.model.DeviceVersionResponse(
                        type = deviceType,
                        model = sn.take(3),
                        versionType = versionType,
                        versionCode = "$versionType$serverCode",
                        versionNumber = json.optString("version_number"),
                        versionDescription = json.optString("version_description"),
                        isForce = json.optBoolean("is_force", false),
                        isStrongGuidance = json.optBoolean("is_strong_guidance", false),
                        fileMd5 = json.optString("file_md5"),
                        downloadUrl = downloadUrl
                    ),
                    currentVersion = rawVersion ?: "",
                    hasUpdate = hasUpdate,
                    isForceUpdate = json.optBoolean("is_force", false)
                )
                pendingUpdateInfo = if (hasUpdate) info else null
                _connectedDevice.value = _connectedDevice.value?.copy(
                    firmwareVersion = formatFirmwareVersion(rawVersion),
                    latestFirmwareVersion = if (hasUpdate) formatFirmwareVersion(serverCode.toString()) else null
                )
            } catch (e: Exception) {
                AppLog.w(TAG, "checkFirmwareUpdate failed", e)
            }
        }
    }

    /**
     * Query the device's current recording state and align it with RecordingManager.
     * Fixes "device has stopped but the app still shows recording" and "the button on the recording screen does nothing" (state drift).
     */
    override fun refreshRecordState() {
        try {
            TntAgent.getInstant().getBleAgent().getState(
                object : AgentCallback.OnRequest { override fun onCallback(p0: Boolean) { } },
                object : AgentCallback.OnResponse<GetStateRsp> {
                    override fun onCallback(rsp: GetStateRsp?) {
                        rsp?.let { syncRecordState(it) }
                    }
                }
            )
        } catch (e: Exception) {
            AppLog.w(TAG, "refreshRecordState failed", e)
        }
    }

    private fun syncRecordState(rsp: GetStateRsp) {
        val st = rsp.getState()
        val sid = rsp.getSessionId()
        val deviceRecording = st == Constants.DeviceStatus.RECORD || st == Constants.DeviceStatus.RECORDING
        val appState = RecordingManager.shared.state.value
        AppLog.i(TAG, "syncRecordState: deviceRecording=$deviceRecording (state=$st), appState=$appState, sessionId=$sid")
        if (deviceRecording) {
            if (appState is RecordingState.Idle) {
                RecordingManager.shared.handleRecordStart(sid.toInt(), sid.toInt())
            }
        } else {
            // Device idle: if the app is still in a recording/paused state, correct it to Idle
            if (appState !is RecordingState.Idle) {
                RecordingManager.shared.handleRecordStop(sid.toInt())
            }
        }
    }

    /**
     * The connect reached us but never completed the E2EE handshake — a firmware still locked to a
     * previous account rejects the current user this way (iOS: GATT then drop; Android: connect-fail
     * timeout). Surface a Failed and, when this was a background auto-reconnect (no connect sheet is
     * watching), stop the reconnect loop and offer the recovery flow on Home (lifecycle guide §3.3).
     */
    private fun onHandshakeRejected() {
        awaitingHandshake = false
        val wasAuto = isAutoReconnectAttempt
        isAutoReconnectAttempt = false
        AppLog.w(TAG, "handshake rejected (auto=$wasAuto)")
        _connectionState.value = DeviceConnectionState.Failed(
            "The device refused the connection — it may still be locked by another account."
        )
        if (wasAuto) {
            suppressAutoReconnect = true
            pendingConnectDevice?.let { _recoveryOffers.tryEmit(it) }
        }
    }

    private fun onDeviceDisconnected() {
        _connectionState.value = DeviceConnectionState.Disconnected
        _connectedDevice.value = null

        // Unexpected disconnect → persistent auto-reconnect (not during user-initiated
        // disconnect/unpair/adding a device/OTA)
        if (!suppressAutoReconnect && RecordingStore.lastConnectedDeviceSN != null) {
            startAutoReconnect(initialDelayMs = 2_000)
        }
    }

    private var reconnectJob: Job? = null

    /**
     * Persistent auto-reconnect (mirrors iOS startAutoReconnect): rescan every 30s up to
     * [maxReconnectAttempts] times, surviving individual 10s scan timeouts. Stops on success
     * (bleConnectState resets the counter), user-initiated flows (suppressAutoReconnect), or
     * exhaustion.
     */
    private fun startAutoReconnect(initialDelayMs: Long = 0) {
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            delay(initialDelayMs)
            while (reconnectAttempts < maxReconnectAttempts) {
                if (suppressAutoReconnect || RecordingStore.lastConnectedDeviceSN == null) return@launch
                when (_connectionState.value) {
                    is DeviceConnectionState.Connected,
                    is DeviceConnectionState.Connecting -> return@launch
                    else -> {}
                }
                reconnectAttempts++
                AppLog.i(TAG, "auto-reconnect attempt #$reconnectAttempts/$maxReconnectAttempts")
                startScan()
                delay(30_000)
            }
            AppLog.i(TAG, "auto-reconnect exhausted after $maxReconnectAttempts attempts")
        }
    }

    /** Device name resolution: scanned name > stored paired name > default. */
    private fun resolveDeviceName(sn: String?): String {
        if (sn == null) return "Plaud Device"
        scannedNames[sn]?.let { return it }
        val stored = RecordingStore.deviceName(sn)
        return if (stored != sn) stored else "Plaud Device"
    }

    override fun getPairedDevices(): List<PairedDeviceInfo> =
        RecordingStore.pairedDeviceSNs.map { sn ->
            PairedDeviceInfo(
                serialNumber = sn,
                name = resolveDeviceName(sn),
                type = PairedDeviceInfo.deviceType(sn)
            )
        }

    override fun switchDevice(sn: String) {
        // Disconnect current device, then scan + auto-connect the selected one
        suppressAutoReconnect = false
        reconnectAttempts = 0
        try { PlaudDeviceAgent.disconnect() } catch (e: Exception) { }
        _connectedDevice.value = null
        RecordingStore.lastConnectedDeviceSN = sn
        _connectionState.value = DeviceConnectionState.Scanning
        // Delay to let the BLE stack finish disconnecting before scanning again
        scope.launch {
            delay(1_500)
            startScan()
        }
    }

    override fun attemptReconnect() {
        if (suppressAutoReconnect) return
        // Explicit OTA guard (mirrors iOS isOTAInProgress check)
        when (_firmwareUpdateState.value?.phase) {
            FirmwareUpdateUiState.Phase.DOWNLOADING,
            FirmwareUpdateUiState.Phase.INSTALLING,
            FirmwareUpdateUiState.Phase.RESTARTING -> return
            else -> {}
        }
        if (RecordingStore.lastConnectedDeviceSN == null) return
        when (_connectionState.value) {
            is DeviceConnectionState.Connected,
            is DeviceConnectionState.Connecting,
            is DeviceConnectionState.Scanning -> return
            else -> {}
        }
        reconnectAttempts = 0
        AppLog.i(TAG, "attemptReconnect: starting persistent reconnect for ${RecordingStore.lastConnectedDeviceSN}")
        startAutoReconnect()
    }

    // MARK: - Scanning

    /**
     * Phone Bluetooth actually on? With it off the SDK's startScan silently finds nothing, so the
     * UI span forever on "Searching..." with no hint that the radio is the problem (PLA2-321).
     * Unknown (no adapter / no permission to read it) counts as ON so we never block a real scan.
     */
    val isBluetoothEnabled: Boolean
        get() {
            val ctx = appContext ?: return true
            return try {
                val mgr = ctx.getSystemService(Context.BLUETOOTH_SERVICE)
                        as? android.bluetooth.BluetoothManager
                mgr?.adapter?.isEnabled ?: true
            } catch (e: Exception) {
                AppLog.w(TAG, "isBluetoothEnabled check failed", e)
                true
            }
        }

    override fun startScan() {
        _scannedDevices.value = emptyList()
        scannedBleDevices.clear()

        // Fail fast and say why, instead of spinning for 10s and going quiet.
        if (!isBluetoothEnabled) {
            AppLog.w(TAG, "startScan aborted — phone Bluetooth is off")
            _connectionState.value = DeviceConnectionState.Failed(BLUETOOTH_OFF_MESSAGE)
            return
        }

        _connectionState.value = DeviceConnectionState.Scanning

        try {
            PlaudDeviceAgent.startScan()
        } catch (e: Exception) {
            AppLog.e(TAG, "startScan failed", e)
        }

        scanTimeoutJob?.cancel()
        scanTimeoutJob = scope.launch {
            delay(10_000)
            if (_connectionState.value is DeviceConnectionState.Scanning) stopScan()
        }
    }

    override fun stopScan() {
        scanTimeoutJob?.cancel()
        try { PlaudDeviceAgent.stopScan() } catch (e: Exception) { }
        if (_connectionState.value is DeviceConnectionState.Scanning) {
            _connectionState.value = DeviceConnectionState.Disconnected
        }
    }

    // MARK: - Connection

    /**
     * Infer the device type from the SN prefix, used by signAndStoreDeviceSn.
     * Kept consistent with BleManager.getDeviceType in the TOB source.
     */
    private fun getDeviceType(sn: String): String = when {
        sn.startsWith("881") -> "notepro"
        sn.startsWith("880") -> "notepin"
        sn.startsWith("882") -> "notepins"
        sn.startsWith("888") -> "note"
        else -> "note"
    }


    override fun connect(device: ScannedDevice, userId: String, userInitiated: Boolean) {
        isAutoReconnectAttempt = !userInitiated
        pendingConnectDevice = device
        // Explicit user connect: re-enable auto-reconnect
        suppressAutoReconnect = false
        reconnectAttempts = 0
        _connectionState.value = DeviceConnectionState.Connecting(device)

        val bleDevice = scannedBleDevices.firstOrNull { it.getSerialNumber() == device.serialNumber }
        if (bleDevice == null) {
            AppLog.e(TAG, "connect: BleDevice not found for sn=${device.serialNumber}")
            _connectionState.value = DeviceConnectionState.Failed("Device not found, please rescan")
            return
        }

        val sn = device.serialNumber
        val deviceType = getDeviceType(sn)

        pendingConnectSN = sn
        awaitingHandshake = true
        scope.launch(Dispatchers.IO) {
            try {
                // Step 1: wait for the partner RSA key pair to be ready.
                // initSDK fetches keys asynchronously (gen-key over HTTP); if connect runs before the
                // response, the SN signature is missing and the handshake fails.
                val deadline = System.currentTimeMillis() + 10_000L
                while (!NiceBuildSdk.isPartnerDataReady() && System.currentTimeMillis() < deadline) {
                    delay(200)
                }
                if (!NiceBuildSdk.isPartnerDataReady()) {
                    AppLog.w(TAG, "connect: RSA key pair not ready within 10s, handshake may fail")
                }

                // Step 2: sign and store the device SN (public SDK API; handshake needs snSignature)
                val signSuccess = NiceBuildSdk.signAndStoreDeviceSn(deviceType, sn)
                if (!signSuccess) {
                    AppLog.w(TAG, "signAndStoreDeviceSn failed (sn=$sn)")
                }

                // Step 3: BLE connect via the facade (handshake token resolved from the JWT internally)
                AppLog.i(TAG, "connectBleDevice: sn=$sn, signSuccess=$signSuccess")
                PlaudDeviceAgent.connectBleDevice(bleDevice)
            } catch (e: Exception) {
                AppLog.e(TAG, "connectBleDevice failed", e)
                scope.launch {
                    _connectionState.value = DeviceConnectionState.Failed("Connection failed: ${e.message}")
                }
            }
        }
    }

    override fun disconnect() {
        // User-initiated disconnect: suppress auto-reconnect
        suppressAutoReconnect = true
        try { PlaudDeviceAgent.disconnect() } catch (e: Exception) { }
    }

    override fun unpair() {
        suppressAutoReconnect = true
        reconnectAttempts = 0

        // Multi-device aware: remove ONLY the current device, keep the others (mirrors iOS).
        // removePairedDevice falls the active SN back to the first remaining device, if any.
        val currentSN = _connectedDevice.value?.serialNumber ?: RecordingStore.lastConnectedDeviceSN
        // Cloud unbind first (lifecycle guide order), best-effort: failure never blocks the
        // local depair — worst case the cloud record stays bound until the owner unbinds again.
        currentSN?.let { cloudUnbind(it) }
        currentSN?.let { RecordingStore.removePairedDevice(it) }
        SyncManager.shared.reset()
        _connectedDevice.value = null
        _connectionState.value = DeviceConnectionState.Disconnected
        scannedBleDevices.clear()

        // Best-effort: tell the device to depair, then drop the BLE link.
        // Completion arrives via listener.bleDepair; a timeout fallback ensures the link is
        // closed even if the device does not respond.
        scope.launch {
            var done = false
            onDepairResult = { if (!done) { done = true; safeDisconnect() } }
            try {
                PlaudDeviceAgent.depair(false)
                delay(3_000)
                if (!done) { done = true; safeDisconnect() }
            } catch (e: Exception) {
                AppLog.e(TAG, "depair failed", e)
                if (!done) { done = true; safeDisconnect() }
            } finally {
                onDepairResult = null
            }
        }
    }

    private fun safeDisconnect() {
        try { PlaudDeviceAgent.disconnect() } catch (e: Exception) { }
    }

    override fun refreshDeviceInfo() {
        // Battery/charging and storage arrive via listener.bleChargingState / bleStorage and are
        // merged into _connectedDevice there.
        try {
            PlaudDeviceAgent.getChargingState()
            PlaudDeviceAgent.getStorage()
        } catch (e: Exception) {
            AppLog.e(TAG, "refreshDeviceInfo failed", e)
        }
    }

    // MARK: - Firmware update

    /**
     * Run the OTA chain: download firmware -> push to device -> reboot.
     * Download counts as the first half of progress, install as the second.
     * Progress and phase are published via firmwareUpdateState (and firmwareProgress).
     */
    override fun startFirmwareUpdate() {
        val info = pendingUpdateInfo
        if (!PlaudDeviceAgent.isConnected()) {
            emitFirmwareState(_firmwareProgress.value ?: 0f, FirmwareUpdateUiState.Phase.FAILED, "Update failed", "Device not connected")
            return
        }
        if (info == null || !info.hasUpdate) {
            emitFirmwareState(0f, FirmwareUpdateUiState.Phase.NO_UPDATE, "No update available")
            return
        }

        // Device reboots during install; don't auto-reconnect mid-OTA.
        suppressAutoReconnect = true
        emitFirmwareState(0f, FirmwareUpdateUiState.Phase.DOWNLOADING, "Downloading Firmware...")

        PlaudDeviceAgent.downloadFirmware(info, object : FirmwareUpdateCallback {
            override fun onUpdateCheckResult(result: Result<FirmwareUpdateInfo>) {}
            override fun onDownloadProgress(progress: UpdateProgress) {
                emitFirmwareState(progress.progress / 100f * 0.5f, FirmwareUpdateUiState.Phase.DOWNLOADING, "Downloading Firmware...")
            }
            override fun onDownloadComplete(result: FirmwareDownloadResult) {
                val file = result.file
                if (!result.success || file == null) {
                    suppressAutoReconnect = false
                    emitFirmwareState(_firmwareProgress.value ?: 0f, FirmwareUpdateUiState.Phase.FAILED, "Download failed", result.error)
                    return
                }
                installFirmware(file, info)
            }
            override fun onInstallProgress(progress: UpdateProgress) {}
            override fun onInstallComplete(result: FirmwareInstallResult) {}
        })
    }

    /**
     * BLE push driven directly via bleAgent.appFotaPush, bypassing the facade's installFirmware:
     * its hardcoded 5-minute timeout is shorter than the push itself on non-notepro devices
     * (the BLE SDK forces 80B/18ms pacing ≈ 3-4 KB/s for projectCode != 881, so a ~1.1MB image
     * takes ~6 min), and when that timeout fires it resumes its continuation OUTSIDE the
     * double-resume guard — the device's later result callback resumes again and crashes the
     * app ("Already resumed"). Tracked in sdk-requests-android-parity.md #13/#14.
     */
    private fun installFirmware(file: java.io.File, info: FirmwareUpdateInfo) {
        emitFirmwareState(0.5f, FirmwareUpdateUiState.Phase.INSTALLING, "Installing on device...")

        val done = java.util.concurrent.atomic.AtomicBoolean(false)
        fun finish(success: Boolean, error: String? = null) {
            if (!done.compareAndSet(false, true)) return
            if (success) {
                emitFirmwareState(1f, FirmwareUpdateUiState.Phase.COMPLETED, "Update complete!")
                pendingUpdateInfo = null
                scope.launch {
                    _connectedDevice.value = _connectedDevice.value?.copy(
                        firmwareVersion = formatFirmwareVersion(info.versionResponse.versionCode),
                        latestFirmwareVersion = null
                    )
                }
            } else {
                emitFirmwareState(_firmwareProgress.value ?: 0f, FirmwareUpdateUiState.Phase.FAILED, "Update failed", error)
            }
            // Allow the device to reconnect after the reboot, and actively kick a persistent
            // reconnect — the mid-OTA disconnect was suppressed, so nothing else will scan.
            suppressAutoReconnect = false
            scope.launch {
                delay(3_000) // give the device a moment to reboot before scanning
                attemptReconnect()
            }
        }

        // Safety net sized to the real transfer speed (~3-4 KB/s): file size / 2 KB/s + 5 min slack.
        val timeoutMs = file.length() / 2 * 1000L / 1024 + 5 * 60 * 1000L
        scope.launch {
            delay(timeoutMs)
            if (!done.get()) {
                AppLog.w(TAG, "OTA push timed out after ${timeoutMs / 1000}s")
                finish(false, "Update timed out")
            }
        }

        try {
            TntAgent.getInstant().getBleAgent().appFotaPush(
                file.absolutePath,
                info.currentVersion,
                info.versionResponse.versionCode,
                0,
                object : com.tinnotech.penblesdk.entity.AgentCallback.BleAgentOtaPushListener {
                    override fun otaPushProgress(progress: Double) {
                        if (done.get()) return
                        emitFirmwareState(
                            0.5f + progress.toFloat() / 100f * 0.5f,
                            FirmwareUpdateUiState.Phase.INSTALLING,
                            "Installing on device... ${progress.toInt()}%"
                        )
                    }

                    override fun otaPushSpeed(speed: Double, avgSpeed: Double) {}

                    override fun otaPushError(error: com.tinnotech.penblesdk.Constants.OtaPushError) {
                        AppLog.w(TAG, "OTA push error: $error")
                        finish(false, error.errMsg)
                    }

                    override fun otaPushFinish() {
                        // Transfer complete; the device verifies the image and reboots to apply.
                        // A device-side rejection (e.g. Retry Too Much) arrives via otaPushError
                        // shortly after, so give it a grace window before declaring success.
                        AppLog.i(TAG, "OTA push finished, waiting for device verdict")
                        emitFirmwareState(1f, FirmwareUpdateUiState.Phase.RESTARTING, "Restarting device...")
                        scope.launch {
                            delay(8_000)
                            finish(true)
                        }
                    }
                }
            )
        } catch (e: Exception) {
            AppLog.w(TAG, "appFotaPush failed", e)
            finish(false, e.message)
        }
    }

    private fun emitFirmwareState(progress: Float, phase: FirmwareUpdateUiState.Phase, message: String, error: String? = null) {
        scope.launch {
            _firmwareProgress.value = progress
            _firmwareUpdateState.value = FirmwareUpdateUiState(progress, phase, message, error)
        }
    }

    // MARK: - Device recovery (lifecycle guide §3.3 / §4.5)

    /** GET /sdk/binding result: three-state is_bind + newest-first client_user_id history. */
    private data class CloudBindingInfo(val isBind: Boolean?, val bindHistory: List<String>)

    /**
     * GET /open/partner/sdk/binding — authoritative cloud binding state for (type, sn).
     * Returns null on any failure. Doc caveats honored here: a missing device is a BARE 404 with no
     * ErrorCode body, and bind_history is NOT client-scoped — entries may belong to other clients.
     */
    private fun queryCloudBinding(sn: String): CloudBindingInfo? = try {
        val deviceType = getDeviceType(sn)
        val url = "$platformHost/developer/api/open/partner/sdk/binding?type=$deviceType&sn=$sn"
        AppLog.i(TAG, "cloud binding >>> GET $url")
        val request = okhttp3.Request.Builder().url(url)
            .header("Authorization", "Bearer $partnerToken")
            .get().build()
        okhttp3.OkHttpClient().newCall(request).execute().use { resp ->
            val body = resp.body?.string() ?: ""
            AppLog.i(TAG, "cloud binding <<< HTTP ${resp.code} ${body.take(300)}")
            if (!resp.isSuccessful) null
            else {
                val json = JSONObject(body)
                CloudBindingInfo(
                    isBind = if (json.isNull("is_bind")) null else json.optBoolean("is_bind"),
                    bindHistory = json.optJSONArray("bind_history")?.let { arr ->
                        (0 until arr.length()).mapNotNull { arr.optString(it).takeIf { id -> id.isNotBlank() } }
                    } ?: emptyList()
                )
            }
        }
    } catch (e: Exception) {
        AppLog.w(TAG, "cloud binding query failed", e)
        null
    }

    /**
     * Brick recovery (lifecycle guide §3.3): the firmware still holds some previous user's
     * client_user_id, so the current user's handshake is rejected. Query bind_history, handshake
     * with each historical id (transformed the same way the SDK derives the token from the JWT:
     * strip the client_user_ prefix, drop hyphens), and on success wipe the stale bond with depair —
     * then reconnect as the current user. No reflashing tool needed.
     */
    override fun startDeviceRecovery(device: ScannedDevice) {
        val sn = device.serialNumber
        AppLog.i(TAG, "recovery: start for sn=$sn")
        _connectionState.value = DeviceConnectionState.Connecting(device)

        scope.launch(Dispatchers.IO) {
            val info = queryCloudBinding(sn)
            if (info == null) {
                failRecovery("Recovery failed: could not query the cloud binding state."); return@launch
            }
            if (info.isBind == true) {
                failRecovery("This device is bound to another account. That owner must unbind it first."); return@launch
            }
            // bind_history has one entry PER device.bind event, so the same id repeats for every
            // past connect (live-verified: 50+ duplicates of one id) — dedupe before bounding,
            // otherwise the attempts would try the same key five times.
            val history = info.bindHistory.distinct().take(RECOVERY_MAX_ATTEMPTS)
            if (history.isEmpty()) {
                failRecovery("Recovery not possible: the device has no bind history."); return@launch
            }
            val bleDevice = scannedBleDevices.firstOrNull { it.getSerialNumber() == sn }
            if (bleDevice == null) {
                failRecovery("Device not found, please rescan."); return@launch
            }

            suppressAutoReconnect = true
            recoveryInProgress = true
            try {
                for ((index, historicalId) in history.withIndex()) {
                    AppLog.i(TAG, "recovery: attempt ${index + 1}/${history.size} with ${historicalId.take(20)}…")
                    val signal = CompletableDeferred<Boolean>()
                    recoverySignal = signal
                    try {
                        // SDK 1.0.13: recoveryConnectBleDevice pins the historical id as the handshake
                        // token and connects with isForceClear (PRE_HANDSHAKE_AND_CLEAR) so the firmware
                        // wipes its stale key material; the current user's sn-sign / RSA material is
                        // reused (no backend signing for the historical user), and the SDK auto-restores
                        // the current user's identity when the attempt ends.
                        PlaudDeviceAgent.recoveryConnectBleDevice(bleDevice, historicalId)
                    } catch (e: Exception) {
                        AppLog.w(TAG, "recovery: recoveryConnectBleDevice threw", e)
                        continue
                    }
                    val unlocked = withTimeoutOrNull(RECOVERY_HANDSHAKE_TIMEOUT_MS) { signal.await() } ?: false
                    if (!unlocked) {
                        AppLog.i(TAG, "recovery: attempt ${index + 1} rejected")
                        try { PlaudDeviceAgent.disconnect() } catch (e: Exception) { }
                        delay(1_000)
                        continue
                    }

                    AppLog.i(TAG, "recovery: handshake OK — wiping the stale bond (depair)")
                    val confirmed = depairAndAwait()
                    if (!confirmed) AppLog.w(TAG, "recovery: no depair confirmation, proceeding anyway")
                    recoveryInProgress = false
                    delay(1_500)

                    // depair changes the device's MAC, so the cached BleDevice is now stale — rescan
                    // and match by SN before reconnecting as the current user (SDK doc requirement).
                    AppLog.i(TAG, "recovery: bond wiped — rescanning (MAC changes after depair)")
                    val fresh = rescanForDevice(sn)
                    if (fresh == null) {
                        failRecovery("The device was unlocked but did not reappear — please rescan and connect it.")
                        return@launch
                    }
                    AppLog.i(TAG, "recovery: device reappeared — reconnecting as the current user")
                    withContext(Dispatchers.Main) {
                        suppressAutoReconnect = false
                        connect(device, RecordingStore.userId ?: "")
                    }
                    return@launch
                }
                failRecovery("Recovery failed: none of the previous accounts matched the device lock.")
            } finally {
                recoveryInProgress = false
                recoverySignal = null
            }
        }
    }

    /** Depair the (recovery-) connected device and wait for its confirmation. */
    private suspend fun depairAndAwait(): Boolean {
        val signal = CompletableDeferred<Boolean>()
        onDepairResult = { signal.complete(true) }
        return try {
            PlaudDeviceAgent.depair(false)
            withTimeoutOrNull(RECOVERY_DEPAIR_TIMEOUT_MS) { signal.await() } ?: false
        } catch (e: Exception) {
            AppLog.w(TAG, "recovery: depair threw", e)
            false
        } finally {
            onDepairResult = null
            try { PlaudDeviceAgent.disconnect() } catch (e: Exception) { }
        }
    }

    /** Scan until the given SN re-advertises (post-depair the MAC changes), returning the fresh
     *  BleDevice, or null on timeout. */
    private suspend fun rescanForDevice(sn: String): BleDevice? {
        val signal = CompletableDeferred<BleDevice>()
        recoveryRescanSN = sn
        recoveryRescanSignal = signal
        return try {
            withContext(Dispatchers.Main) { try { PlaudDeviceAgent.startScan() } catch (e: Exception) { } }
            withTimeoutOrNull(RECOVERY_RESCAN_TIMEOUT_MS) { signal.await() }
        } finally {
            recoveryRescanSN = null
            recoveryRescanSignal = null
            withContext(Dispatchers.Main) { try { PlaudDeviceAgent.stopScan() } catch (e: Exception) { } }
        }
    }

    private suspend fun failRecovery(message: String) {
        AppLog.w(TAG, "recovery: $message")
        withContext(Dispatchers.Main) {
            _connectionState.value = DeviceConnectionState.Failed(message)
        }
    }

    // MARK: - Cloud binding (device lifecycle guide §3.1/§3.2)

    /**
     * POST /open/partner/sdk/bind — reported after every successful connect. Same-owner rebind
     * is idempotent server-side. 403 DEVICE_BOUND (bound to ANOTHER account) is surfaced to the
     * UI via cloudAlerts, without revealing the owning account.
     */
    private fun cloudBind(sn: String) {
        scope.launch(Dispatchers.IO) {
            val code = cloudBindingRequest("bind", sn) ?: return@launch
            if (code == 403) {
                _cloudAlerts.emit(
                    "This device is already bound to another account. Unbind it from that account first, then reconnect."
                )
            }
        }
    }

    /**
     * POST /open/partner/sdk/unbind — cloud first, then local depair (guide order), best-effort:
     * unbinding an unbound device is an idempotent no-op; failures are logged only and never
     * block the local unpair.
     */
    private fun cloudUnbind(sn: String) {
        scope.launch(Dispatchers.IO) { cloudBindingRequest("unbind", sn) }
    }

    /** Shared POST for bind/unbind; returns the HTTP status, or null on transport failure. */
    private fun cloudBindingRequest(action: String, sn: String): Int? = try {
        val url = "$platformHost/developer/api/open/partner/sdk/$action"
        val body = JSONObject().put("type", getDeviceType(sn)).put("sn", sn)
        val token = RecordingStore.activeUserAccessToken
        AppLog.i(TAG, "cloud $action >>> POST $url body=$body Authorization=Bearer ${token.take(16)}…")
        val request = okhttp3.Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $token")
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .build()
        okhttp3.OkHttpClient().newCall(request).execute().use { resp ->
            val text = resp.body?.string() ?: ""
            AppLog.i(TAG, "cloud $action <<< HTTP ${resp.code} ${text.take(300)}")
            resp.code
        }
    } catch (e: Exception) {
        AppLog.w(TAG, "cloud $action request failed", e)
        null
    }

    // MARK: - Settings

    override fun setAutoSync(enabled: Boolean) {
        RecordingStore.isAutoSyncEnabled = enabled
    }
}
