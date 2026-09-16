package com.plaud.template.models

data class PlaudDevice(
    val serialNumber: String,
    val name: String,
    var batteryLevel: Int,
    var isCharging: Boolean,
    var storageUsed: Long,
    var storageTotal: Long,
    var firmwareVersion: String,
    var latestFirmwareVersion: String? = null,
    var supportWiFi: Boolean = false,
    var isConnected: Boolean = true
) {
    val storageUsageRatio: Float
        get() = if (storageTotal > 0) storageUsed.toFloat() / storageTotal else 0f
}

/**
 * Display name for the UI: the SDK's BLE name when present, otherwise a model name derived from
 * the SN prefix. SDK 1.0.9 can report an empty name, which left the device card title blank.
 */
val PlaudDevice.displayName: String
    get() = when {
        name.isNotEmpty() -> name
        serialNumber.startsWith("881") -> "Plaud NotePro"
        serialNumber.startsWith("882") -> "Plaud NotePin S"
        serialNumber.startsWith("883") -> "Plaud NotePin"
        serialNumber.isNotEmpty() -> serialNumber
        else -> "Plaud Device"
    }
