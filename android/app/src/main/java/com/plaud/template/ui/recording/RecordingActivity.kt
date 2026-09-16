package com.plaud.template.ui.recording

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.AttributeSet
import android.view.View
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.plaud.template.PlaudTemplateApp
import com.plaud.template.R
import com.plaud.template.databinding.ActivityRecordingBinding
import com.plaud.template.models.RecordingState
import kotlinx.coroutines.launch

/**
 * Full-screen recording page — Dark theme
 * Waveform bars + Record button + State switching
 */
class RecordingActivity : AppCompatActivity() {

    private lateinit var binding: ActivityRecordingBinding
    private val recordingManager get() = (application as PlaudTemplateApp).recordingManager
    private val deviceManager get() = (application as PlaudTemplateApp).deviceManager

    private var waveformView: WaveformView? = null
    private var timerHandler: Handler? = null
    private var timerRunnable: Runnable? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityRecordingBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.closeButton.setOnClickListener { finish() }
        binding.recordButton.setOnClickListener { onRecordButtonTapped() }
        binding.pauseButton.setOnClickListener { onPauseButtonTapped() }

        // Replace the placeholder View with the custom WaveformView
        setupWaveformView()
        observeState()
    }

    override fun onResume() {
        super.onResume()
        // When opening the recording page, proactively sync the recording state with the device to correct any possible drift
        deviceManager.refreshRecordState()
    }

    private fun setupWaveformView() {
        waveformView = WaveformView(this).apply {
            visibility = View.INVISIBLE
        }
        val placeholder = binding.waveformView
        val parent = placeholder.parent as? android.view.ViewGroup ?: return
        val index = parent.indexOfChild(placeholder)
        val params = placeholder.layoutParams
        parent.removeViewAt(index)
        parent.addView(waveformView, index, params)
    }

    private fun observeState() {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    recordingManager.state.collect { state ->
                        updateUI(state)
                    }
                }

                launch {
                    recordingManager.waveformLevel.collect { level ->
                        waveformView?.addLevel(level)
                    }
                }
            }
        }
    }

    /**
     * Transitional "waiting for the device" state after the user taps record. Cleared by updateUI
     * on the next real state, or by the timeout below if the device never answers.
     */
    private var startingJob: kotlinx.coroutines.Job? = null

    private fun showStartingFeedback() {
        binding.recordingSubtitle.text = getString(R.string.starting_recording)
        binding.recordButton.isEnabled = false
        binding.recordButton.alpha = 0.5f
        startingJob?.cancel()
        startingJob = lifecycleScope.launch {
            kotlinx.coroutines.delay(START_ACK_TIMEOUT_MS)
            // Still idle → the device never acknowledged; give the button back so the user can retry.
            if (recordingManager.state.value is RecordingState.Idle) updateUI(RecordingState.Idle)
        }
    }

    private fun updateUI(state: RecordingState) {
        startingJob?.cancel()
        binding.recordButton.isEnabled = true
        binding.recordButton.alpha = 1f
        when (state) {
            is RecordingState.Idle -> {
                binding.recordingTitle.text = getString(R.string.start_recording)
                binding.recordingSubtitle.text = getString(R.string.record_via_device)
                binding.recordingSubtitle.textSize = 13f
                binding.stopIcon.visibility = View.GONE
                binding.pauseButton.visibility = View.GONE
                waveformView?.visibility = View.INVISIBLE
                waveformView?.reset()
                setRecordButtonSize(72)
                stopTimer()
            }
            is RecordingState.Recording -> {
                binding.recordingTitle.text = getString(R.string.recording)
                binding.recordingSubtitle.textSize = 14f
                binding.stopIcon.visibility = View.VISIBLE
                binding.pauseButton.visibility = View.VISIBLE
                binding.pauseButton.text = getString(R.string.pause)
                waveformView?.visibility = View.VISIBLE
                setRecordButtonSize(64)
                startTimer(state.startedAt)
            }
            is RecordingState.Paused -> {
                // Title shows "Paused", subtitle keeps the last timer text; main button = stop,
                // the side button resumes.
                stopTimer()
                binding.recordingTitle.text = getString(R.string.paused)
                binding.stopIcon.visibility = View.VISIBLE
                binding.pauseButton.visibility = View.VISIBLE
                binding.pauseButton.text = getString(R.string.resume)
            }
        }
    }

    private fun onPauseButtonTapped() {
        when (recordingManager.state.value) {
            is RecordingState.Recording -> recordingManager.pauseRecord()
            is RecordingState.Paused -> recordingManager.resumeRecord()
            else -> {}
        }
    }

    private fun setRecordButtonSize(dp: Int) {
        val px = (dp * resources.displayMetrics.density).toInt()
        binding.recordButtonBg.layoutParams = binding.recordButtonBg.layoutParams.apply {
            width = px; height = px
        }
    }

    private fun onRecordButtonTapped() {
        when (recordingManager.state.value) {
            is RecordingState.Idle -> {
                // The device takes about a second to acknowledge, and the UI only moves when its
                // callback lands — so the tap looked ignored (PLA2-317). Acknowledge immediately;
                // updateUI() overwrites this the moment the real state arrives.
                showStartingFeedback()
                recordingManager.startRecord()
            }
            is RecordingState.Recording, is RecordingState.Paused -> {
                // Main button = stop (pause/resume live on the side button). After stopping,
                // close the recording page and return to Home (the sync banner is shown there).
                recordingManager.stopRecord()
                finish()
            }
        }
    }

    private companion object {
        /** How long to wait for the device's record-start ack before restoring the button. */
        const val START_ACK_TIMEOUT_MS = 4_000L
    }

    private fun startTimer(startedAt: Long) {
        stopTimer()
        timerHandler = Handler(Looper.getMainLooper())
        timerRunnable = object : Runnable {
            override fun run() {
                val elapsed = ((System.currentTimeMillis() - startedAt) / 1000).toInt()
                val h = elapsed / 3600
                val m = (elapsed % 3600) / 60
                val s = elapsed % 60
                binding.recordingSubtitle.text = String.format("%02d:%02d:%02d", h, m, s)
                timerHandler?.postDelayed(this, 500)
            }
        }
        timerHandler?.post(timerRunnable!!)
    }

    private fun stopTimer() {
        timerRunnable?.let { timerHandler?.removeCallbacks(it) }
        timerHandler = null
        timerRunnable = null
    }

    override fun onDestroy() {
        super.onDestroy()
        stopTimer()
    }
}

/**
 * Custom waveform view — 80 vertical bars
 * Bar width 2dp, spacing 2.5dp, white, height determined by the volume level
 */
class WaveformView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private val barCount = 80
    private val levels = FloatArray(barCount) { 0f }
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompat.getColor(context, R.color.white)
        strokeCap = Paint.Cap.ROUND
    }

    private val barWidthDp = 2f
    private val barSpacingDp = 2.5f
    private val density = resources.displayMetrics.density

    fun addLevel(level: Float) {
        // Shift left by one, append the new value at the end
        System.arraycopy(levels, 1, levels, 0, barCount - 1)
        levels[barCount - 1] = level.coerceIn(0f, 1f)
        invalidate()
    }

    /** Reset all waveform bars (matches iOS WaveformView.reset) */
    fun reset() {
        for (i in levels.indices) levels[i] = 0f
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val barWidth = barWidthDp * density
        val barSpacing = barSpacingDp * density
        val totalWidth = barCount * (barWidth + barSpacing) - barSpacing
        val startX = (width - totalWidth) / 2f
        val centerY = height / 2f
        // Matches iOS: max bar height = view height (iOS uses rect.height with no 0.8 discount)
        val maxBarHeight = height.toFloat()

        paint.strokeWidth = barWidth

        for (i in 0 until barCount) {
            val level = levels[i]
            val barHeight = maxOf(barWidth, maxBarHeight * level)
            val x = startX + i * (barWidth + barSpacing) + barWidth / 2f
            val alpha = (0.4f + level * 0.6f).coerceIn(0f, 1f)
            paint.alpha = (alpha * 255).toInt()
            canvas.drawLine(x, centerY - barHeight / 2f, x, centerY + barHeight / 2f, paint)
        }
    }
}
