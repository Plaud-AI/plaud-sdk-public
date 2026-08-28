package com.plaud.template.managers.mock

import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import com.plaud.template.managers.DeviceManagerProtocol
import com.plaud.template.models.*

/**
 * Mock implementation that fully simulates the scan -> discover device -> connect sequence,
 * so the full flow can be exercised during UI development.
 */
class MockDeviceManager : DeviceManagerProtocol {

    companion object {
        private const val TAG = "MockDeviceManager"
        private val MOCK_DEVICE = ScannedDevice(
            name = "NotePin Mock",
            serialNumber = "MOCK-SN-001",
            rssi = -58
        )
        private val MOCK_CONNECTED_DEVICE = PlaudDevice(
            serialNumber = "MOCK-SN-001",
            name = "NotePin Mock",
            batteryLevel = 72,
            isCharging = false,
            storageUsed = 512L * 1024 * 1024,   // 512 MB
            storageTotal = 4096L * 1024 * 1024,  // 4 GB
            firmwareVersion = "V1.8.0",
            latestFirmwareVersion = "V1.9.0",
            supportWiFi = true
        )
    }

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private val _connectionState = MutableStateFlow<DeviceConnectionState>(DeviceConnectionState.Disconnected)
    override val connectionState: StateFlow<DeviceConnectionState> = _connectionState.asStateFlow()

    private val _connectedDevice = MutableStateFlow<PlaudDevice?>(null)
    override val connectedDevice: StateFlow<PlaudDevice?> = _connectedDevice.asStateFlow()

    private val _scannedDevices = MutableStateFlow<List<ScannedDevice>>(emptyList())
    override val scannedDevices: StateFlow<List<ScannedDevice>> = _scannedDevices.asStateFlow()

    private val _firmwareProgress = MutableStateFlow<Float?>(null)
    override val firmwareProgress: StateFlow<Float?> = _firmwareProgress.asStateFlow()

    private val _firmwareUpdateState = MutableStateFlow<com.plaud.template.models.FirmwareUpdateUiState?>(null)
    override val firmwareUpdateState: StateFlow<com.plaud.template.models.FirmwareUpdateUiState?> = _firmwareUpdateState.asStateFlow()

    override val cloudAlerts: kotlinx.coroutines.flow.SharedFlow<String> =
        kotlinx.coroutines.flow.MutableSharedFlow()

    override var suppressAutoReconnect: Boolean = false

    override fun configure(userId: String) {
        Log.d(TAG, "configure: userId=$userId (mock)")
    }

    override fun attemptReconnect() {
        Log.d(TAG, "attemptReconnect (mock)")
        if (_connectionState.value is DeviceConnectionState.Connected) return
        _connectionState.value = DeviceConnectionState.Connected
        _connectedDevice.value = MOCK_CONNECTED_DEVICE
    }

    /** Simulated scan: "discovers" the device after 1.5 seconds */
    override fun startScan() {
        Log.d(TAG, "startScan (mock)")
        _scannedDevices.value = emptyList()
        _connectionState.value = DeviceConnectionState.Scanning

        scope.launch {
            delay(1500)
            // Only emit the result while still in the Scanning state (avoid firing after cancellation)
            if (_connectionState.value is DeviceConnectionState.Scanning) {
                _scannedDevices.value = listOf(MOCK_DEVICE)
            }
        }
    }

    override fun stopScan() {
        Log.d(TAG, "stopScan (mock)")
        if (_connectionState.value is DeviceConnectionState.Scanning) {
            _connectionState.value = DeviceConnectionState.Disconnected
        }
    }

    /** Simulated connect: enters Connecting immediately, becomes Connected after 1 second */
    override val recoveryOffers = kotlinx.coroutines.flow.MutableSharedFlow<ScannedDevice>()

    override fun connect(device: ScannedDevice, userId: String, userInitiated: Boolean) {
        Log.d(TAG, "connect: ${device.serialNumber} (mock)")
        _connectionState.value = DeviceConnectionState.Connecting(device)

        scope.launch {
            delay(1000)
            _connectionState.value = DeviceConnectionState.Connected
            _connectedDevice.value = MOCK_CONNECTED_DEVICE
        }
    }

    override fun disconnect() {
        Log.d(TAG, "disconnect (mock)")
        _connectionState.value = DeviceConnectionState.Disconnected
        _connectedDevice.value = null
    }

    override fun unpair() {
        Log.d(TAG, "unpair (mock)")
        _connectionState.value = DeviceConnectionState.Disconnected
        _connectedDevice.value = null
        _scannedDevices.value = emptyList()
    }

    override fun refreshFirmwareCheck() {
        Log.d(TAG, "refreshFirmwareCheck (mock)")
    }

    override fun startDeviceRecovery(device: ScannedDevice) {
        Log.d(TAG, "startDeviceRecovery (mock)")
    }

    override fun refreshDeviceInfo() {
        Log.d(TAG, "refreshDeviceInfo (mock)")
    }

    override fun refreshRecordState() {
        Log.d(TAG, "refreshRecordState (mock)")
    }

    override fun getPairedDevices(): List<com.plaud.template.models.PairedDeviceInfo> = emptyList()

    override fun switchDevice(sn: String) {
        Log.d(TAG, "switchDevice: $sn (mock)")
    }

    override fun startFirmwareUpdate() {
        Log.d(TAG, "startFirmwareUpdate (mock)")
        scope.launch {
            for (i in 1..5) {
                delay(300)
                val p = i / 10f
                _firmwareProgress.value = p
                _firmwareUpdateState.value = com.plaud.template.models.FirmwareUpdateUiState(
                    p, com.plaud.template.models.FirmwareUpdateUiState.Phase.DOWNLOADING, "Downloading firmware..."
                )
            }
            for (i in 6..10) {
                delay(300)
                val p = i / 10f
                _firmwareProgress.value = p
                _firmwareUpdateState.value = com.plaud.template.models.FirmwareUpdateUiState(
                    p, com.plaud.template.models.FirmwareUpdateUiState.Phase.INSTALLING, "Installing on device..."
                )
            }
            _firmwareUpdateState.value = com.plaud.template.models.FirmwareUpdateUiState(
                1f, com.plaud.template.models.FirmwareUpdateUiState.Phase.COMPLETED, "Update complete!"
            )
            _firmwareProgress.value = null
        }
    }

    override fun setAutoSync(enabled: Boolean) {
        Log.d(TAG, "setAutoSync: $enabled (mock)")
    }
}
