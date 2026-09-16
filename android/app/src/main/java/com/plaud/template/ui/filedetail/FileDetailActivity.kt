package com.plaud.template.ui.filedetail

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.EditText
import android.widget.PopupMenu
import android.widget.SeekBar
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch
import com.plaud.template.PlaudTemplateApp
import com.plaud.template.R
import com.plaud.template.databinding.ActivityFileDetailBinding
import com.plaud.template.models.RecordingFile
import java.io.File
import java.text.SimpleDateFormat
import java.util.*

/**
 * File detail page
 * Header (name/date/duration/status) + Summary + Transcript + More Menu
 */
class FileDetailActivity : AppCompatActivity() {

    private lateinit var binding: ActivityFileDetailBinding
    private val syncManager get() = (application as PlaudTemplateApp).syncManager

    private var currentFile: RecordingFile? = null

    // Audio player (media3 ExoPlayer)
    private var preparedPath: String? = null
    private val progressHandler = Handler(Looper.getMainLooper())
    private var progressRunnable: Runnable? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityFileDetailBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.backButton.setOnClickListener { finish() }
        binding.moreButton.setOnClickListener { showMoreMenu(it) }
        setupAudioPlayerControls()

        val fileId = intent.getStringExtra("file_id") ?: run { finish(); return }
        loadFile(fileId)
    }

    override fun onResume() {
        super.onResume()
        // Refresh data (after returning from a rename)
        currentFile?.let { loadFile(it.id) }
    }

    private fun loadFile(fileId: String) {
        // Read from the persistent store FIRST: updateTranscript/updateDuration write to disk,
        // while syncManager.files is an in-memory snapshot that may still hold stale objects
        // (e.g. transcriptJSON = null right after a transcription completes).
        val file = com.plaud.template.storage.RecordingStore.allFiles.find { it.id == fileId }
            ?: syncManager.files.value.find { it.id == fileId }
            ?: run { finish(); return }
        currentFile = file
        bindFile(file)
    }

    /** Plain-text transcript for the "Copy Transcript" menu action (set when parsing succeeds). */
    private var transcriptPlainText: String? = null

    private fun bindFile(file: RecordingFile) {
        binding.fileNameLabel.text = file.name

        // Meta line "MMM d, yyyy \u00B7 HH:mm \u00B7 Xm Ys" (mirrors iOS)
        val dateFormat = SimpleDateFormat("MMM d, yyyy \u00B7 HH:mm", Locale.getDefault())
        binding.fileDateLabel.text =
            "${dateFormat.format(Date(file.createdAt))} \u00B7 ${formatMetaDuration(file.duration)}"

        // Self-heal: entries synced before the duration fix have duration 0 stored \u2014 recompute
        // from the local audio and backfill so old files show the real length too.
        val localPath = file.localPath
        if (file.duration <= 0 && localPath != null && File(localPath).exists()) {
            lifecycleScope.launch(kotlinx.coroutines.Dispatchers.IO) {
                val d = com.plaud.template.managers.SyncManager.shared.audioDurationSec(localPath)
                if (d > 0) {
                    com.plaud.template.storage.RecordingStore.updateDuration(file.id, d)
                    runOnUiThread {
                        binding.fileDateLabel.text =
                            "${dateFormat.format(Date(file.createdAt))} \u00B7 ${formatMetaDuration(d)}"
                    }
                }
            }
        }

        // Status badge (Android extra, kept by product decision)
        if (file.isSynced) {
            binding.statusBadge.text = getString(R.string.synced)
            binding.statusBadge.setTextColor(ContextCompat.getColor(this, R.color.green))
            binding.statusBadge.setBackgroundResource(R.drawable.bg_status_synced)
        } else {
            binding.statusBadge.text = getString(R.string.pending)
            binding.statusBadge.setTextColor(ContextCompat.getColor(this, R.color.orange))
            binding.statusBadge.setBackgroundResource(R.drawable.bg_status_pending)
        }

        // Summary block (flat, only when a summary exists)
        val hasSummary = !file.summaryText.isNullOrBlank()
        binding.summaryHeader.visibility = if (hasSummary) View.VISIBLE else View.GONE
        binding.summaryText.visibility = if (hasSummary) View.VISIBLE else View.GONE
        if (hasSummary) binding.summaryText.text = file.summaryText

        // Transcript: parsed segments, or the centered empty state
        transcriptPlainText = file.transcriptJSON?.let { parseTranscript(it) }
        if (transcriptPlainText != null) {
            binding.transcriptText.text = transcriptPlainText
            binding.transcriptText.visibility = View.VISIBLE
            binding.emptyState.visibility = View.GONE
        } else {
            binding.transcriptText.visibility = View.GONE
            binding.emptyState.visibility = View.VISIBLE
            if (file.isSynced) {
                binding.emptyTitle.text = "Generate recording insights"
                binding.emptySubtitle.text = "Transcribe and summarize this recording."
                binding.generateButton.visibility = View.VISIBLE
                binding.generateButton.setOnClickListener { startTranscription(file) }
            } else {
                binding.emptyTitle.text = "No transcript available"
                binding.emptySubtitle.text = "Sync this recording first to generate insights."
                binding.generateButton.visibility = View.GONE
            }
        }

        // Audio player: only available once the file has a local audio file
        bindAudioPlayer(file)
    }

    // MARK: - Transcription (upload \u2192 submit \u2192 poll, mirrors iOS)

    private fun startTranscription(file: RecordingFile) {
        val path = file.localPath
        if (path == null || !File(path).exists()) {
            AlertDialog.Builder(this)
                .setTitle(getString(R.string.generate_ai_insights))
                .setMessage("Local audio file not found. Sync the recording first.")
                .setPositiveButton(android.R.string.ok, null)
                .show()
            return
        }
        binding.generateButton.isEnabled = false
        observeTranscription(file)
        com.plaud.template.managers.TranscriptionManager.shared.transcribe(path)
    }

    private var transcriptionObserved = false

    private fun observeTranscription(file: RecordingFile) {
        if (transcriptionObserved) return
        transcriptionObserved = true
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                com.plaud.template.managers.TranscriptionManager.shared.state.collect { st ->
                    when (st) {
                        is com.plaud.template.managers.TranscriptionState.Uploading -> {
                            binding.emptySubtitle.text = "Uploading\u2026 ${(st.progress * 100).toInt()}%"
                        }
                        is com.plaud.template.managers.TranscriptionState.Submitting ->
                            binding.emptySubtitle.text = "Submitting transcription\u2026"
                        is com.plaud.template.managers.TranscriptionState.Processing ->
                            binding.emptySubtitle.text = "Transcribing\u2026 (${st.status})"
                        is com.plaud.template.managers.TranscriptionState.Completed -> {
                            binding.generateButton.isEnabled = true
                            com.plaud.template.managers.TranscriptionManager.shared.reset()
                            if (st.resultsJson == "[]" || st.resultsJson.isBlank()) {
                                // Backend finished but found no speech (VAD dropped everything) —
                                // tell the user instead of silently showing the empty state again.
                                binding.emptySubtitle.text = "Transcribe and summarize this recording."
                                AlertDialog.Builder(this@FileDetailActivity)
                                    .setTitle(getString(R.string.generate_ai_insights))
                                    .setMessage("Transcription finished, but no speech was detected in this recording.")
                                    .setPositiveButton(android.R.string.ok, null)
                                    .show()
                            } else {
                                com.plaud.template.storage.RecordingStore.updateTranscript(file.id, st.resultsJson)
                                loadFile(file.id) // re-render with the parsed transcript
                            }
                        }
                        is com.plaud.template.managers.TranscriptionState.Failed -> {
                            binding.generateButton.isEnabled = true
                            binding.emptySubtitle.text = "Transcribe and summarize this recording."
                            com.plaud.template.managers.TranscriptionManager.shared.reset()
                            AlertDialog.Builder(this@FileDetailActivity)
                                .setTitle("Transcription Failed")
                                .setMessage(st.message)
                                .setPositiveButton(android.R.string.ok, null)
                                .show()
                        }
                        else -> {}
                    }
                }
            }
        }
    }

    /**
     * Parse the cached transcript JSON into "Speaker N \u00B7 HH:MM:SS" paragraphs (mirrors iOS).
     * Tolerant of both a bare segment array and an object wrapping one; returns null if nothing
     * parseable so the caller can fall back to the empty state.
     */
    private fun parseTranscript(json: String): String? {
        val segments = try {
            val arr = when {
                json.trimStart().startsWith("[") -> org.json.JSONArray(json)
                else -> {
                    val obj = org.json.JSONObject(json)
                    obj.optJSONArray("segments")
                        ?: obj.optJSONArray("transaction")
                        ?: obj.optJSONArray("list")
                        ?: obj.optJSONArray("data")
                        ?: return null
                }
            }
            (0 until arr.length()).mapNotNull { i ->
                val seg = arr.optJSONObject(i) ?: return@mapNotNull null
                if (i == 0) com.plaud.template.common.AppLog.i("Transcript", "first segment shape: ${seg.toString().take(220)}")
                val text = seg.optString("content", seg.optString("text", seg.optString("sentence")))
                if (text.isBlank()) return@mapNotNull null
                // speaker_id is a string like "SPEAKER_00" (Plaud result shape, mirrors iOS);
                // device-cache shapes may use a numeric "speaker".
                val speakerLabel = when {
                    seg.has("speaker_id") ->
                        seg.optString("speaker_id").replace("SPEAKER_", "Speaker ").ifBlank { "Speaker" }
                    else -> "Speaker ${seg.optInt("speaker", 0) + 1}"
                }
                // start_time/startTime are milliseconds (device cache shape); "start" is SECONDS
                // (Double, possibly a numeric string) in the Plaud transcription-result shape.
                val startMs = when {
                    seg.has("start_time") -> seg.optLong("start_time")
                    seg.has("startTime") -> seg.optLong("startTime")
                    else -> (seg.optDouble("start", 0.0).takeIf { !it.isNaN() }?.times(1000))?.toLong() ?: 0L
                }
                Triple(speakerLabel, startMs, text)
            }
        } catch (e: Exception) {
            null
        } ?: return null
        if (segments.isEmpty()) return null

        return segments.joinToString("\n\n") { (speakerLabel, startMs, text) ->
            "$speakerLabel \u00B7 ${formatClock(startMs)}\n$text"
        }
    }

    /** "Xm Ys" / "Xh Ym Zs" duration for the meta line. */
    private fun formatMetaDuration(seconds: Long): String {
        if (seconds <= 0) return "0s"
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        val s = seconds % 60
        return buildString {
            if (h > 0) append("${h}h ")
            if (m > 0 || h > 0) append("${m}m ")
            append("${s}s")
        }.trim()
    }

    // MARK: - Audio Player

    // Media3 ExoPlayer: OEM MediaPlayerNative frequently fails on Ogg/Opus (the sync/export
    // format); ExoPlayer's own extractor + platform decoder handles it reliably.
    private var exoPlayer: androidx.media3.exoplayer.ExoPlayer? = null

    private fun setupAudioPlayerControls() {
        binding.playPauseButton.setOnClickListener { togglePlayPause() }
        binding.rewindButton.setOnClickListener { seekBy(-5_000) }
        binding.forwardButton.setOnClickListener { seekBy(5_000) }
        binding.progressSlider.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(sb: SeekBar?, progress: Int, fromUser: Boolean) {
                if (fromUser) {
                    val p = exoPlayer ?: return
                    val target = (progress / 1000f * p.duration).toLong().coerceAtLeast(0)
                    p.seekTo(target)
                    binding.currentTimeLabel.text = formatClock(target)
                }
            }
            override fun onStartTrackingTouch(sb: SeekBar?) {}
            override fun onStopTrackingTouch(sb: SeekBar?) {}
        })
    }

    private fun bindAudioPlayer(file: RecordingFile) {
        val path = file.localPath
        val exists = path != null && File(path).exists()
        if (!exists) {
            binding.audioPlayer.visibility = View.GONE
            releasePlayer()
            return
        }
        binding.audioPlayer.visibility = View.VISIBLE
        // Avoid re-preparing the same file on every onResume
        if (preparedPath == path && exoPlayer != null) return

        // Self-heal legacy files exported with the SDK's corrupt OpusTags header
        if (path!!.endsWith(".opus", ignoreCase = true)) {
            com.plaud.template.common.OpusRepair.repairIfNeeded(path)
        }

        releasePlayer()
        val player = androidx.media3.exoplayer.ExoPlayer.Builder(this).build()
        exoPlayer = player
        player.addListener(object : androidx.media3.common.Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                when (state) {
                    androidx.media3.common.Player.STATE_READY -> {
                        preparedPath = path
                        binding.totalTimeLabel.text = formatClock(player.duration.coerceAtLeast(0))
                    }
                    androidx.media3.common.Player.STATE_ENDED -> {
                        stopProgressUpdates()
                        binding.playPauseButton.setImageResource(R.drawable.ic_play_arrow)
                        player.pause()
                        player.seekTo(0)
                        binding.progressSlider.progress = 0
                        binding.currentTimeLabel.text = formatClock(0)
                    }
                    else -> {}
                }
            }
            override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                com.plaud.template.common.AppLog.w("FileDetail", "ExoPlayer error: ${error.errorCodeName}")
                binding.audioPlayer.visibility = View.GONE
                releasePlayer()
            }
        })
        player.setMediaItem(androidx.media3.common.MediaItem.fromUri(android.net.Uri.fromFile(File(path!!))))
        player.prepare()
        binding.currentTimeLabel.text = formatClock(0)
        binding.progressSlider.progress = 0
    }

    private fun togglePlayPause() {
        val p = exoPlayer ?: return
        if (p.isPlaying) {
            p.pause()
            stopProgressUpdates()
            binding.playPauseButton.setImageResource(R.drawable.ic_play_arrow)
        } else {
            p.play()
            startProgressUpdates()
            binding.playPauseButton.setImageResource(R.drawable.ic_pause)
        }
    }

    private fun seekBy(deltaMs: Int) {
        val p = exoPlayer ?: return
        val duration = p.duration.coerceAtLeast(0)
        val target = (p.currentPosition + deltaMs).coerceIn(0, duration)
        p.seekTo(target)
        binding.currentTimeLabel.text = formatClock(target)
        binding.progressSlider.progress = if (duration > 0) (target * 1000 / duration).toInt() else 0
    }

    private fun startProgressUpdates() {
        stopProgressUpdates()
        progressRunnable = object : Runnable {
            override fun run() {
                val p = exoPlayer ?: return
                if (p.isPlaying) {
                    val duration = p.duration.coerceAtLeast(0)
                    binding.currentTimeLabel.text = formatClock(p.currentPosition)
                    binding.progressSlider.progress =
                        if (duration > 0) (p.currentPosition * 1000 / duration).toInt() else 0
                }
                progressHandler.postDelayed(this, 200)
            }
        }
        progressHandler.post(progressRunnable!!)
    }

    private fun stopProgressUpdates() {
        progressRunnable?.let { progressHandler.removeCallbacks(it) }
        progressRunnable = null
    }

    private fun releasePlayer() {
        stopProgressUpdates()
        exoPlayer?.release()
        exoPlayer = null
        preparedPath = null
    }

    private fun formatClock(ms: Long): String {
        val total = (ms / 1000).toInt().coerceAtLeast(0)
        return String.format("%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    override fun onPause() {
        super.onPause()
        // Pause playback when leaving the screen
        exoPlayer?.takeIf { it.isPlaying }?.let {
            it.pause()
            stopProgressUpdates()
            binding.playPauseButton.setImageResource(R.drawable.ic_play_arrow)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        releasePlayer()
    }

    private fun formatDuration(seconds: Long): String {
        if (seconds <= 0) return "--:--"
        val total = seconds.toInt()
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) String.format("%d:%02d:%02d", h, m, s)
        else String.format("%d:%02d", m, s)
    }

    // MARK: - More Menu

    private fun showMoreMenu(anchor: View) {
        val popup = PopupMenu(this, anchor)
        popup.menuInflater.inflate(R.menu.menu_file_detail, popup.menu)

        val file = currentFile ?: return

        // Hide options that do not apply (Export Audio stays visible like iOS; failure alerts)
        popup.menu.findItem(R.id.action_copy_summary)?.isVisible = file.summaryText != null
        popup.menu.findItem(R.id.action_copy_transcript)?.isVisible = transcriptPlainText != null

        popup.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                R.id.action_export -> {
                    exportAudio(file)
                    true
                }
                R.id.action_rename -> {
                    showRenameDialog(file)
                    true
                }
                R.id.action_copy_summary -> {
                    copySummary(file)
                    true
                }
                R.id.action_copy_transcript -> {
                    copyTranscript()
                    true
                }
                R.id.action_delete -> {
                    showDeleteConfirmation(file)
                    true
                }
                else -> false
            }
        }
        popup.show()
    }

    private fun exportAudio(file: RecordingFile) {
        syncManager.exportAudio(file) { result ->
            runOnUiThread {
                result.onSuccess { outputFile ->
                    val uri = FileProvider.getUriForFile(
                        this,
                        "$packageName.fileprovider",
                        outputFile
                    )
                    val shareIntent = Intent(Intent.ACTION_SEND).apply {
                        type = "audio/*"
                        putExtra(Intent.EXTRA_STREAM, uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(Intent.createChooser(shareIntent, getString(R.string.export_audio)))
                }
                result.onFailure {
                    // Alert instead of toast (mirrors iOS "Export Failed")
                    AlertDialog.Builder(this)
                        .setTitle("Export Failed")
                        .setMessage(it.message ?: "Could not export this recording.")
                        .setPositiveButton(android.R.string.ok, null)
                        .show()
                }
            }
        }
    }

    private fun showRenameDialog(file: RecordingFile) {
        val editText = EditText(this).apply {
            setText(file.name)
            selectAll()
            setPadding(48, 32, 48, 32)
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.rename)
            .setView(editText)
            .setPositiveButton(R.string.confirm) { _, _ ->
                val newName = editText.text.toString().trim()
                if (newName.isNotEmpty()) {
                    syncManager.renameFile(file, newName)
                    loadFile(file.id)
                }
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun copySummary(file: RecordingFile) {
        // Silent copy (no toast, mirrors iOS / template-app convention)
        val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Summary", file.summaryText))
    }

    private fun copyTranscript() {
        val text = transcriptPlainText ?: return
        val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Transcript", text))
    }

    private fun showDeleteConfirmation(file: RecordingFile) {
        AlertDialog.Builder(this)
            .setTitle(getString(R.string.delete_recording))
            .setMessage("This will permanently delete \"${file.name}\".")
            .setPositiveButton(R.string.delete) { _, _ ->
                syncManager.deleteFile(file)
                finish()
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }
}
