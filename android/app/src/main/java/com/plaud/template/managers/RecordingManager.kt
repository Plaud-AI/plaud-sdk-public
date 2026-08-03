package com.plaud.template.managers

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.plaud.template.common.AppLog
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import sdk.PlaudDeviceAgent
import com.plaud.template.models.RecordingState
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Recording state manager, built on the GA facade sdk.PlaudDeviceAgent.
 * Control commands go through the facade; state updates are driven by the facade's
 * bleRecordStart/Stop/Pause/Resume callbacks (forwarded by DeviceManager), with a
 * getState-based fallback in case a device response is missed.
 */
class RecordingManager private constructor() : RecordingManagerProtocol {

    companion object {
        private const val TAG = "RecordingManager"

        @Volatile
        private var instance: RecordingManager? = null

        val shared: RecordingManager
            get() = instance ?: synchronized(this) {
                instance ?: RecordingManager().also { instance = it }
            }
    }

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val handler = Handler(Looper.getMainLooper())

    // MARK: - StateFlow

    private val _state = MutableStateFlow<RecordingState>(RecordingState.Idle)
    override val state: StateFlow<RecordingState> = _state.asStateFlow()

    private val _waveformLevel = MutableStateFlow(0f)
    override val waveformLevel: StateFlow<Float> = _waveformLevel.asStateFlow()

    /** Current recording sessionId (needed to pass to pause/resume) */
    @Volatile
    private var currentSessionId = -1L

    @Volatile
    private var latestLevel: Float = 0f

    private var waveformRunnable: Runnable? = null

    // MARK: - Recording control commands

    /**
     * The facade routes device responses to bleRecordStart/Stop/Pause/Resume on the global
     * listener. If a response is missed (some firmware only answers the direct request), fall
     * back to a device state query so the UI never gets stuck.
     */
    private fun scheduleStateFallback(expectIdle: Boolean) {
        scope.launch {
            delay(1_500)
            val idle = _state.value is RecordingState.Idle
            if (idle != expectIdle) DeviceManager.shared.refreshRecordState()
        }
    }

    override fun startRecord() {
        try {
            PlaudDeviceAgent.startRecord(scene = 0)
            scheduleStateFallback(expectIdle = false)
        } catch (e: Exception) {
            AppLog.e(TAG, "startRecord failed", e)
        }
    }

    override fun stopRecord() {
        try {
            PlaudDeviceAgent.stopRecord(scene = 0)
            scheduleStateFallback(expectIdle = true)
        } catch (e: Exception) {
            AppLog.e(TAG, "stopRecord failed", e)
        }
    }

    override fun pauseRecord() {
        val sid = currentSessionId
        if (sid < 0) { AppLog.w(TAG, "pauseRecord: no active session"); return }
        try {
            PlaudDeviceAgent.pauseRecord(sid, scene = 0)
        } catch (e: Exception) {
            AppLog.e(TAG, "pauseRecord failed", e)
        }
    }

    override fun resumeRecord() {
        val sid = currentSessionId
        if (sid < 0) { AppLog.w(TAG, "resumeRecord: no active session"); return }
        try {
            PlaudDeviceAgent.resumeRecord(sid, scene = 0)
        } catch (e: Exception) {
            AppLog.e(TAG, "resumeRecord failed", e)
        }
    }

    // MARK: - Internal callbacks (forwarded by DeviceManager)

    fun handleRecordStart(sessionId: Int, startTime: Int) {
        // Idempotent: skip if the same session is already recording (both OnResponse and deviceOpRecordStart may fire)
        val cur = _state.value
        if (cur is RecordingState.Recording && cur.sessionId == sessionId.toLong()) return
        currentSessionId = sessionId.toLong()
        val startMillis: Long = when {
            sessionId > 0 -> sessionId.toLong() * 1000
            startTime > 0 -> startTime.toLong() * 1000
            else -> System.currentTimeMillis()
        }
        scope.launch {
            _state.value = RecordingState.Recording(
                sessionId = sessionId.toLong(),
                startedAt = startMillis
            )
            startWaveformTimer()
        }
    }

    fun handleRecordStop(sessionId: Int) {
        // Idempotent: skip if already Idle, to avoid triggering auto-sync repeatedly
        if (_state.value is RecordingState.Idle) return
        currentSessionId = -1L
        scope.launch {
            stopWaveformTimer()
            _state.value = RecordingState.Idle

            delay(1000)
            // Auto-sync when recording ends: download when Auto-Sync is on (showing the banner), otherwise just silently refresh the list
            // Mirrors iOS: trigger the sync flow after stopping recording
            if (com.plaud.template.storage.RecordingStore.isAutoSyncEnabled) {
                SyncManager.shared.startSync()
            } else {
                SyncManager.shared.fetchFileList()
            }
        }
    }

    fun handleRecordPause(sessionId: Int) {
        scope.launch {
            _state.value = RecordingState.Paused(sessionId = sessionId.toLong())
        }
    }

    fun handleRecordResume(sessionId: Int, startTime: Int) {
        val startMillis = startTime.toLong() * 1000
        scope.launch {
            _state.value = RecordingState.Recording(
                sessionId = sessionId.toLong(),
                startedAt = startMillis
            )
        }
    }

    fun handlePcmData(pcmData: ByteArray) {
        if (pcmData.size < 2) return
        var sumSquares = 0.0
        val sampleCount = pcmData.size / 2
        for (i in 0 until sampleCount) {
            val low = pcmData[i * 2].toInt() and 0xFF
            val high = pcmData[i * 2 + 1].toInt()
            val sample = (high shl 8) or low
            sumSquares += (sample * sample).toDouble()
        }
        val rms = sqrt(sumSquares / sampleCount)
        latestLevel = min(1f, max(0f, (rms / 32768.0).toFloat() * 3f))
    }

    // MARK: - Waveform timer

    private fun startWaveformTimer() {
        stopWaveformTimer()
        val runnable = object : Runnable {
            override fun run() {
                _waveformLevel.value = latestLevel
                handler.postDelayed(this, 100)
            }
        }
        waveformRunnable = runnable
        handler.postDelayed(runnable, 100)
    }

    private fun stopWaveformTimer() {
        waveformRunnable?.let { handler.removeCallbacks(it) }
        waveformRunnable = null
        latestLevel = 0f
        _waveformLevel.value = 0f
    }
}
