package com.plaud.template.models

sealed class SyncState {
    object Idle : SyncState()
    data class Syncing(val progress: SyncProgress) : SyncState()
    /** WiFi fast-transfer connect phase (mirrors iOS WiFiConnectPhase). */
    enum class WiFiConnectPhase { OPENING_HOTSPOT, CONNECTING_WIFI, HANDSHAKING }
    data class WiFiConnecting(val phase: WiFiConnectPhase) : SyncState()
    data class WiFiTransferring(val progress: SyncProgress) : SyncState()
    object Completed : SyncState()
    data class Failed(val message: String) : SyncState()

    val isActive: Boolean
        get() = this is Syncing || this is WiFiConnecting || this is WiFiTransferring

    /** Current sync progress (non-null only when Syncing / WiFiTransferring) */
    val currentProgress: SyncProgress?
        get() = when (this) {
            is Syncing -> progress
            is WiFiTransferring -> progress
            else -> null
        }
}
