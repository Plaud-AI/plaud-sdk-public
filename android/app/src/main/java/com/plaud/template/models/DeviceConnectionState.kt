package com.plaud.template.models

sealed class DeviceConnectionState {
    object Disconnected : DeviceConnectionState()
    object Scanning : DeviceConnectionState()
    data class Connecting(val device: ScannedDevice) : DeviceConnectionState()
    object Connected : DeviceConnectionState()
    data class Failed(val message: String) : DeviceConnectionState()
}
