package com.plaud.template.managers

import com.plaud.template.models.RecordingState
import kotlinx.coroutines.flow.StateFlow

interface RecordingManagerProtocol {
    val state: StateFlow<RecordingState>
    val waveformLevel: StateFlow<Float>

    fun startRecord()
    fun stopRecord()
    fun pauseRecord()
    fun resumeRecord()
}
