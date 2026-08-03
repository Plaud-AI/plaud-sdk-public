package com.plaud.template.models

/**
 * UI-facing firmware update state, surfaced by DeviceManager and observed by the
 * firmware update sheet. Mirrors the phases of iOS startFirmwareUpdate(progress:completion:).
 */
data class FirmwareUpdateUiState(
    /** Overall progress, 0f..1f (download counts as the first half, install the second). */
    val progress: Float,
    val phase: Phase,
    val message: String,
    val errorMessage: String? = null
) {
    enum class Phase { CHECKING, DOWNLOADING, INSTALLING, RESTARTING, COMPLETED, FAILED, NO_UPDATE }
}
