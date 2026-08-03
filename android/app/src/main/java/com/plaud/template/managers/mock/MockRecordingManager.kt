package com.plaud.template.managers.mock

import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import com.plaud.template.managers.RecordingManagerProtocol
import com.plaud.template.models.RecordingState

/**
 * Mock recording manager for use during UI development
 */
class MockRecordingManager : RecordingManagerProtocol {

    companion object {
        private const val TAG = "MockRecordingManager"
    }

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private val _state = MutableStateFlow<RecordingState>(RecordingState.Idle)
    override val state: StateFlow<RecordingState> = _state.asStateFlow()

    private val _waveformLevel = MutableStateFlow(0f)
    override val waveformLevel: StateFlow<Float> = _waveformLevel.asStateFlow()

    /** Coroutine job that drives the simulated waveform */
    private var waveformJob: Job? = null

    override fun startRecord() {
        Log.d(TAG, "startRecord (mock)")
        _state.value = RecordingState.Recording(
            sessionId = 9001L,
            startedAt = System.currentTimeMillis()
        )

        // Simulate a live waveform: generate a random volume every 50ms
        waveformJob?.cancel()
        waveformJob = scope.launch {
            while (isActive) {
                _waveformLevel.value = (0.1f + Math.random().toFloat() * 0.8f) // 0.1 - 0.9
                delay(50)
            }
        }
    }

    override fun stopRecord() {
        Log.d(TAG, "stopRecord (mock)")
        waveformJob?.cancel()
        waveformJob = null
        _waveformLevel.value = 0f
        _state.value = RecordingState.Idle
    }

    override fun pauseRecord() {
        Log.d(TAG, "pauseRecord (mock)")
        waveformJob?.cancel()
        _state.value = RecordingState.Paused(sessionId = 9001L)
    }

    override fun resumeRecord() {
        Log.d(TAG, "resumeRecord (mock)")
        _state.value = RecordingState.Recording(
            sessionId = 9001L,
            startedAt = System.currentTimeMillis()
        )

        waveformJob?.cancel()
        waveformJob = scope.launch {
            while (isActive) {
                _waveformLevel.value = (0.1f + Math.random().toFloat() * 0.8f)
                delay(50)
            }
        }
    }
}
