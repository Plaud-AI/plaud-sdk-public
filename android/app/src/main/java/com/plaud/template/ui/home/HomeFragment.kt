package com.plaud.template.ui.home

import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.fragment.app.Fragment
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.plaud.template.PlaudTemplateApp
import com.plaud.template.R
import com.plaud.template.databinding.FragmentHomeBinding
import com.plaud.template.models.*
import com.plaud.template.ui.filedetail.FileDetailActivity
import com.plaud.template.ui.onboarding.ScanningActivity
import com.plaud.template.ui.recording.RecordingActivity
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*

/**
 * Home Tab — Device card + Recording entry + Banners + Recent Files
 */
class HomeFragment : Fragment() {

    private var _binding: FragmentHomeBinding? = null
    private val binding get() = _binding!!

    private val app get() = requireActivity().application as PlaudTemplateApp
    private val deviceManager get() = app.deviceManager
    private val recordingManager get() = app.recordingManager
    private val syncManager get() = app.syncManager

    private var isDeviceCardExpanded = false
    private var currentDevice: PlaudDevice? = null
    private var recordingTimerHandler: Handler? = null
    private var recordingTimerRunnable: Runnable? = null

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
        _binding = FragmentHomeBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        setupClickListeners()
        observeManagers()
    }

    override fun onResume() {
        super.onResume()
        // Re-read the paired-device list on every return to Home (mirrors iOS viewWillAppear),
        // so unpair/add-device done on other screens is reflected immediately.
        renderOtherDevices(currentDevice?.serialNumber)
    }

    private fun setupClickListeners() {
        // Expand/collapse the device card
        binding.deviceCardHeader.setOnClickListener { toggleDeviceCard() }

        // Manage device
        binding.manageButton.setOnClickListener {
            currentDevice?.let { device ->
                val intent = Intent(requireContext(), DevicePanelActivity::class.java)
                intent.putExtra("device_sn", device.serialNumber)
                intent.putExtra("device_name", device.displayName)
                intent.putExtra("firmware_version", device.firmwareVersion)
                intent.putExtra("latest_firmware", device.latestFirmwareVersion)
                startActivity(intent)
            }
        }

        // Recording entry
        binding.recordCard.setOnClickListener { openRecording() }

        // Fast Transfer button (inside the syncBanner include)
        binding.syncBanner.fastTransferButton.setOnClickListener {
            showFastTransferDialog()
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun selectableBackgroundRes(): Int {
        val tv = android.util.TypedValue()
        requireContext().theme.resolveAttribute(android.R.attr.selectableItemBackground, tv, true)
        return tv.resourceId
    }

    private fun makeSeparator(): View = View(requireContext()).apply {
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(1))
        setBackgroundColor(resources.getColor(R.color.light_gray, null))
    }

    /**
     * Render the other paired devices (excluding the active one) plus the "+ Add device" entry,
     * mirroring iOS: separator + 48dp icon-and-label rows, then a leading-aligned add-device row.
     */
    private fun renderOtherDevices(activeSN: String?) {
        val container = binding.otherDevicesList
        container.removeAllViews()
        val others = deviceManager.getPairedDevices().filter { it.serialNumber != activeSN }

        if (others.isNotEmpty()) container.addView(makeSeparator())
        for (info in others) {
            container.addView(makeDeviceRow(info))
            container.addView(makeSeparator())
        }
        container.addView(makeAddDeviceRow())
    }

    private fun makeDeviceRow(info: com.plaud.template.models.PairedDeviceInfo): View {
        val row = LinearLayout(requireContext()).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(48))
            setPaddingRelative(dp(16), 0, dp(16), 0)
            isClickable = true
            setBackgroundResource(selectableBackgroundRes())
            setOnClickListener { deviceManager.switchDevice(info.serialNumber) }
        }
        val icon = android.widget.ImageView(requireContext()).apply {
            setImageResource(R.drawable.ic_device)
            layoutParams = LinearLayout.LayoutParams(dp(32), dp(32))
        }
        val label = TextView(requireContext()).apply {
            text = info.name
            textSize = 14f
            setTextColor(resources.getColor(R.color.black, null))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { marginStart = dp(12) }
        }
        row.addView(icon)
        row.addView(label)
        return row
    }

    private fun makeAddDeviceRow(): View = TextView(requireContext()).apply {
        text = getString(R.string.add_device)
        textSize = 14f
        setTextColor(resources.getColor(R.color.black, null))
        gravity = android.view.Gravity.CENTER_VERTICAL
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(48))
        setPaddingRelative(dp(16), 0, dp(16), 0)
        isClickable = true
        setBackgroundResource(selectableBackgroundRes())
        setOnClickListener {
            val intent = Intent(requireContext(), ScanningActivity::class.java)
            intent.putExtra(ScanningActivity.EXTRA_ADDING_DEVICE, true)
            startActivity(intent)
        }
    }

    // MARK: - Data binding

    private fun observeManagers() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                // Device state
                launch {
                    deviceManager.connectedDevice.collect { device ->
                        currentDevice = device
                        updateDeviceCard(device)
                    }
                }

                // Recording state (updates the record card only; matches iOS — iOS does not show a separate recording banner)
                launch {
                    recordingManager.state.collect { state ->
                        updateRecordCard(state)
                    }
                }

                // Sync state
                launch {
                    syncManager.state.collect { state ->
                        updateSyncBanner(state)
                    }
                }

                // File list
                launch {
                    syncManager.files.collect { files ->
                        val synced = files.filter { it.isSynced }.take(5)
                        updateRecentFiles(synced)
                    }
                }

                // Auto-reconnect rejected by a locked device — offer recovery (lifecycle guide §3.3)
                launch {
                    deviceManager.recoveryOffers.collect { device ->
                        offerRecovery(device)
                    }
                }
            }
        }
    }

    /**
     * Auto-reconnect was rejected before the handshake completed — the device is likely
     * still locked by a previous account. Mirrors iOS MainTabBarController's offer.
     */
    private fun offerRecovery(device: ScannedDevice) {
        if (!isAdded) return
        androidx.appcompat.app.AlertDialog.Builder(requireContext())
            .setTitle("Device Locked")
            .setMessage("${device.name} may still be locked by a previous account. Try to recover it?")
            .setPositiveButton("Recover") { _, _ ->
                deviceManager.startDeviceRecovery(device)
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    // MARK: - Device card

    private fun updateDeviceCard(device: PlaudDevice?) {
        renderOtherDevices(device?.serialNumber)
        if (device == null) {
            binding.deviceNameLabel.text = getString(R.string.no_device)
            binding.statusDot.setBackgroundResource(R.drawable.bg_status_dot_gray)
            binding.statusLabel.text = getString(R.string.disconnected)
            return
        }
        binding.deviceNameLabel.text = device.displayName
        binding.statusLabel.text = getString(R.string.connected)

        // Battery level. A negative level means "not reported yet" (the SDK hands us -1 until the
        // device sends it, which showed up as "-1%" on NotePin S \u2014 PLA2-312): show a placeholder
        // and a neutral, empty bar instead of a nonsense number.
        val chargingPrefix = if (device.isCharging) "\u26A1 " else ""
        val hasBattery = device.batteryLevel >= 0
        binding.batteryValueLabel.text =
            if (hasBattery) "$chargingPrefix${device.batteryLevel}%" else "$chargingPrefix--"

        // Battery bar color
        val batteryColor = when {
            !hasBattery -> R.color.text_secondary
            device.batteryLevel <= 10 -> R.color.red
            device.batteryLevel <= 20 -> R.color.orange
            else -> R.color.green
        }
        binding.batteryFill.setBackgroundColor(ContextCompat.getColor(requireContext(), batteryColor))

        // Battery bar width
        binding.batteryFill.post {
            val parent = binding.batteryFill.parent as? View ?: return@post
            val parentWidth = parent.width
            val level = device.batteryLevel.coerceAtLeast(0)
            val fillWidth = (parentWidth * level / 100f).toInt().coerceAtLeast(2)
            binding.batteryFill.layoutParams = binding.batteryFill.layoutParams.apply { width = fillWidth }
        }

        // Storage
        val usedGB = String.format("%.1f", device.storageUsed / 1_073_741_824.0)
        val totalGB = String.format("%.1f", device.storageTotal / 1_073_741_824.0)
        binding.storageValueLabel.text = "$usedGB GB / $totalGB GB"

        // Storage bar width
        binding.storageFill.post {
            val parent = binding.storageFill.parent as? View ?: return@post
            val parentWidth = parent.width
            val ratio = device.storageUsageRatio
            val fillWidth = (parentWidth * ratio).toInt().coerceAtLeast(2)
            binding.storageFill.layoutParams = binding.storageFill.layoutParams.apply { width = fillWidth }
        }
    }

    private fun toggleDeviceCard() {
        isDeviceCardExpanded = !isDeviceCardExpanded
        // Animate the height change (mirrors iOS 0.25s constraint animation)
        android.transition.TransitionManager.beginDelayedTransition(
            binding.root as ViewGroup,
            android.transition.AutoTransition().setDuration(250)
        )
        binding.deviceExpandedContent.visibility = if (isDeviceCardExpanded) View.VISIBLE else View.GONE

        // Chevron rotation
        val rotation = if (isDeviceCardExpanded) 90f else 0f
        ObjectAnimator.ofFloat(binding.deviceChevron, View.ROTATION, rotation).apply {
            duration = 250
            start()
        }
    }

    // MARK: - Recording entry card

    private fun updateRecordCard(state: RecordingState) {
        when (state) {
            is RecordingState.Recording -> {
                binding.recordTitleLabel.text = getString(R.string.recording_ellipsis)
                startRecordCardTimer(state.startedAt)
            }
            else -> {
                binding.recordTitleLabel.text = getString(R.string.capture_moments)
                binding.recordSubtitleLabel.text = getString(R.string.record_via_device)
                stopRecordCardTimer()
            }
        }
    }

    private fun startRecordCardTimer(startedAt: Long) {
        stopRecordCardTimer()
        recordingTimerHandler = Handler(Looper.getMainLooper())
        recordingTimerRunnable = object : Runnable {
            override fun run() {
                val elapsed = ((System.currentTimeMillis() - startedAt) / 1000).toInt()
                val h = elapsed / 3600
                val m = (elapsed % 3600) / 60
                val s = elapsed % 60
                binding.recordSubtitleLabel.text = String.format("%02d:%02d:%02d", h, m, s)
                recordingTimerHandler?.postDelayed(this, 1000)
            }
        }
        recordingTimerHandler?.post(recordingTimerRunnable!!)
    }

    private fun stopRecordCardTimer() {
        recordingTimerRunnable?.let { recordingTimerHandler?.removeCallbacks(it) }
        recordingTimerHandler = null
        recordingTimerRunnable = null
    }

    // MARK: - Sync Banner

    private fun updateSyncBanner(state: SyncState) {
        val bannerRoot = binding.syncBanner.root
        when (state) {
            is SyncState.Syncing -> {
                fadeInBanner(bannerRoot)
                updateSyncBannerContent(state.progress, isWiFi = false)
            }
            is SyncState.WiFiTransferring -> {
                fadeInBanner(bannerRoot)
                updateSyncBannerContent(state.progress, isWiFi = true)
            }
            // Keep the banner untouched during the WiFi connect window (mirrors iOS —
            // the FastTransferSheet owns that phase; hiding here would make it flash)
            is SyncState.WiFiConnecting -> {}
            is SyncState.Completed -> {
                bannerRoot.postDelayed({ fadeOutBanner(bannerRoot) }, 2000)
            }
            else -> fadeOutBanner(bannerRoot)
        }
    }

    /** 0.25s fade in/out (mirrors iOS banner animations). */
    private fun fadeInBanner(v: View) {
        if (v.visibility == View.VISIBLE && v.alpha == 1f) return
        v.alpha = if (v.visibility == View.VISIBLE) v.alpha else 0f
        v.visibility = View.VISIBLE
        v.animate().alpha(1f).setDuration(250).start()
    }

    private fun fadeOutBanner(v: View) {
        if (v.visibility != View.VISIBLE) return
        v.animate().alpha(0f).setDuration(250)
            .withEndAction { v.visibility = View.GONE; v.alpha = 1f }
            .start()
    }

    private fun updateSyncBannerContent(progress: SyncProgress, isWiFi: Boolean) {
        val banner = binding.syncBanner
        banner.syncTitleLabel.text =
            if (isWiFi) getString(R.string.fast_transfer) else getString(R.string.syncing_recordings)
        banner.syncCountLabel.text =
            if (progress.totalFiles > 0) "${progress.syncedFiles}/${progress.totalFiles}" else ""

        // Progress bar
        val fill = banner.syncProgressFill
        fill.post {
            val parent = fill.parent as? View ?: return@post
            val fraction = progress.progressFraction.coerceIn(0f, 1f)
            fill.layoutParams = fill.layoutParams.apply {
                width = (parent.width * fraction).toInt().coerceAtLeast(1)
            }
        }

        // Always show progress as a percentage so the readout never flickers between a speed and
        // a (usually "Untitled") file name; append the real transfer speed when one is reported.
        val percent = (progress.progressFraction.coerceIn(0f, 1f) * 100).toInt()
        banner.syncSpeedLabel.text = when {
            progress.totalFiles == 0 -> getString(R.string.retrieving_file_list)
            progress.bytesPerSecond > 0 -> "$percent% · ${progress.speedText}"
            else -> "$percent%"
        }

        banner.fastTransferButton.visibility =
            if (isWiFi) View.GONE else View.VISIBLE
    }

    // MARK: - Recent Files

    private fun updateRecentFiles(files: List<RecordingFile>) {
        binding.recentFilesList.removeAllViews()
        binding.emptyFilesLabel.visibility = if (files.isEmpty()) View.VISIBLE else View.GONE
        binding.recentFilesList.visibility = if (files.isEmpty()) View.GONE else View.VISIBLE

        for (file in files) {
            val row = createFileRow(file)
            binding.recentFilesList.addView(row)
        }
    }

    private fun createFileRow(file: RecordingFile): View {
        val row = LayoutInflater.from(requireContext())
            .inflate(R.layout.item_file_row, binding.recentFilesList, false)
        row.findViewById<TextView>(R.id.fileNameLabel).text = file.name
        row.findViewById<TextView>(R.id.fileMetaLabel).text = formatMeta(file)
        row.setOnClickListener {
            val intent = Intent(requireContext(), FileDetailActivity::class.java)
            intent.putExtra("file_id", file.id)
            startActivity(intent)
        }
        return row
    }

    private fun formatMeta(file: RecordingFile): String {
        val dateFormat = SimpleDateFormat("MMM d", Locale.getDefault())
        val timeFormat = SimpleDateFormat("HH:mm", Locale.getDefault())
        val date = Date(file.createdAt)
        val dur = formatDuration(file.duration)
        return "${dateFormat.format(date)}  \u00B7  ${timeFormat.format(date)}  \u00B7  $dur"
    }

    private fun formatDuration(seconds: Long): String {
        if (seconds <= 0) return "--"
        val total = seconds.toInt()
        return if (total >= 3600) {
            String.format("%dh %dm", total / 3600, (total % 3600) / 60)
        } else {
            String.format("%dm %ds", total / 60, total % 60)
        }
    }

    // MARK: - Navigation

    private fun openRecording() {
        startActivity(Intent(requireContext(), RecordingActivity::class.java))
    }

    private fun showFastTransferDialog() {
        // Honor "Never show again": skip the sheet and start directly.
        if (com.plaud.template.storage.RecordingStore.fastTransferNeverShowAgain) {
            syncManager.startWiFiTransfer()
            return
        }
        FastTransferSheet().show(childFragmentManager, "FastTransferSheet")
    }

    override fun onDestroyView() {
        super.onDestroyView()
        stopRecordCardTimer()
        _binding = null
    }
}
