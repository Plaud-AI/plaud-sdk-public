package com.plaud.template.models

sealed class RecordingState {
    object Idle : RecordingState()
    data class Recording(val sessionId: Long, val startedAt: Long) : RecordingState()
    data class Paused(val sessionId: Long) : RecordingState()

    val isActive: Boolean
        get() = this is Recording || this is Paused

    val currentSessionId: Long?
        get() = when (this) {
            is Recording -> sessionId
            is Paused -> sessionId
            is Idle -> null
        }
}
