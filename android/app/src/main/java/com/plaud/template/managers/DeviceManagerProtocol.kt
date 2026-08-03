package com.plaud.template.managers

import com.plaud.template.models.DeviceConnectionState
import com.plaud.template.models.FirmwareUpdateUiState
import com.plaud.template.models.PairedDeviceInfo
import com.plaud.template.models.PlaudDevice
import com.plaud.template.models.ScannedDevice
import kotlinx.coroutines.flow.StateFlow

interface DeviceManagerProtocol {
    val connectionState: StateFlow<DeviceConnectionState>
    val connectedDevice: StateFlow<PlaudDevice?>
    val scannedDevices: StateFlow<List<ScannedDevice>>
    val firmwareProgress: StateFlow<Float?>
    /** Rich firmware update state for the update sheet (null when no update is in progress). */
    val firmwareUpdateState: StateFlow<FirmwareUpdateUiState?>
    /** User-facing alerts from cloud binding (e.g. device bound to another account). */
    val cloudAlerts: kotlinx.coroutines.flow.SharedFlow<String>

    /** Set to true while adding a device / during a user-initiated disconnect, to suppress auto-reconnect to the last device */
    var suppressAutoReconnect: Boolean

    fun configure(userId: String)
    fun startScan()
    fun stopScan()
    /** If there is a previously bound device and nothing is currently connected, start a background scan and auto-reconnect */
    fun attemptReconnect()
    fun connect(device: ScannedDevice, userId: String)
    fun disconnect()
    fun unpair()
    /** All paired devices (read from local storage, no BLE needed). */
    fun getPairedDevices(): List<PairedDeviceInfo>
    /** Disconnect the current device and connect the given paired device. */
    fun switchDevice(sn: String)
    /** Actively query the device's current recording state and align it with the app state (called after connecting / when opening the recording screen) */
    fun refreshRecordState()
    fun refreshDeviceInfo()
    /** Re-run the firmware update check (Settings calls this on open, mirrors iOS). */
    fun refreshFirmwareCheck()
    fun startFirmwareUpdate()
    fun setAutoSync(enabled: Boolean)
}
