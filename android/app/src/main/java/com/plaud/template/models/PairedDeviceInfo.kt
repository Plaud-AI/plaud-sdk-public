package com.plaud.template.models

/**
 * Paired device summary read from local storage (no BLE connection required).
 * Mirrors iOS PairedDeviceInfo.
 */
data class PairedDeviceInfo(
    val serialNumber: String,
    val name: String,
    val type: String // notepro / notepin / notepins / note
) {
    companion object {
        /** Device type inferred from the SN prefix (aligned with DeviceManager.getDeviceType). */
        fun deviceType(sn: String): String = when (sn.take(3)) {
            "880" -> "notepin"
            "881" -> "notepro"
            "882" -> "notepins"
            else -> "note"
        }
    }
}
