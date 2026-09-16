package com.plaud.template.ui.settings

import android.graphics.Color
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.google.android.material.bottomsheet.BottomSheetDialogFragment
import com.plaud.template.PlaudTemplateApp
import com.plaud.template.R
import com.plaud.template.databinding.SheetFirmwareUpdateBinding
import com.plaud.template.models.FirmwareUpdateUiState
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Firmware update bottom sheet. Triggers the OTA on show and renders progress from
 * DeviceManager.firmwareUpdateState (mirrors iOS FirmwareUpdateSheetViewController).
 */
class FirmwareUpdateSheet : BottomSheetDialogFragment() {

    private var _binding: SheetFirmwareUpdateBinding? = null
    private val binding get() = _binding!!

    private val deviceManager get() = (requireActivity().application as PlaudTemplateApp).deviceManager

    private val totalSegments = 30
    private val segments = mutableListOf<View>()
    private var started = false
    /** Set once this run's OTA actually begins, so a stale terminal state from a previous run
     *  (kept in the StateFlow) isn't rendered/dismissed on reopen. */
    private var sawFreshState = false

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
        _binding = SheetFirmwareUpdateBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        // Fixed 380dp height (mirrors iOS detent)
        (dialog as? com.google.android.material.bottomsheet.BottomSheetDialog)?.setOnShowListener { d ->
            val sheet = (d as com.google.android.material.bottomsheet.BottomSheetDialog)
                .findViewById<android.widget.FrameLayout>(com.google.android.material.R.id.design_bottom_sheet)
            sheet?.let {
                val h = (380 * it.resources.displayMetrics.density).toInt()
                it.layoutParams.height = h
                com.google.android.material.bottomsheet.BottomSheetBehavior.from(it).peekHeight = h
            }
        }
        // Block dismissal while the update is running
        isCancelable = false
        // Survive rotation without re-triggering the OTA
        started = savedInstanceState?.getBoolean(KEY_STARTED, false) ?: false

        val deviceName = arguments?.getString(ARG_DEVICE_NAME) ?: "Plaud Device"
        binding.descriptionLabel.text = getString(R.string.firmware_updating_desc, deviceName)

        buildSegments()
        observeState()

        if (!started) {
            started = true
            deviceManager.startFirmwareUpdate()
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(KEY_STARTED, started)
    }

    private fun buildSegments() {
        val density = resources.displayMetrics.density
        for (i in 0 until totalSegments) {
            val seg = View(requireContext()).apply {
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f).apply {
                    if (i > 0) marginStart = (2 * density).toInt()
                }
                background = makeSegmentDrawable(EMPTY_COLOR)
            }
            binding.segmentContainer.addView(seg)
            segments.add(seg)
        }
    }

    /** Rounded segment (r1.5, mirrors iOS). */
    private fun makeSegmentDrawable(color: Int): android.graphics.drawable.GradientDrawable =
        android.graphics.drawable.GradientDrawable().apply {
            setColor(color)
            cornerRadius = 1.5f * resources.displayMetrics.density
        }

    private fun observeState() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                deviceManager.firmwareUpdateState.collect { state ->
                    state?.let { render(it) }
                }
            }
        }
    }

    private fun render(state: FirmwareUpdateUiState) {
        // Ignore a stale terminal state left over from a previous run until this run reports.
        val isActivePhase = state.phase == FirmwareUpdateUiState.Phase.DOWNLOADING ||
            state.phase == FirmwareUpdateUiState.Phase.INSTALLING ||
            state.phase == FirmwareUpdateUiState.Phase.RESTARTING
        if (!sawFreshState) {
            if (!isActivePhase) return
            sawFreshState = true
        }

        val pct = (state.progress * 100).toInt().coerceIn(0, 100)
        binding.percentLabel.text = "$pct%"
        binding.statusLabel.text = state.message

        val filled = (totalSegments * state.progress).toInt()
        segments.forEachIndexed { i, seg ->
            seg.background = makeSegmentDrawable(if (i < filled) Color.BLACK else EMPTY_COLOR)
        }

        when (state.phase) {
            FirmwareUpdateUiState.Phase.RESTARTING ->
                binding.descriptionLabel.text = getString(R.string.firmware_restarting_desc)
            FirmwareUpdateUiState.Phase.COMPLETED -> {
                // Don't dismiss yet — wait for the device to actually reconnect (mirrors iOS).
                awaitReconnectThenDismiss()
            }
            FirmwareUpdateUiState.Phase.FAILED -> {
                binding.descriptionLabel.text = state.errorMessage ?: getString(R.string.firmware_failed_desc)
                isCancelable = true
                showFailureAlertThenDismiss(state.errorMessage)
            }
            FirmwareUpdateUiState.Phase.NO_UPDATE -> {
                binding.descriptionLabel.text = getString(R.string.firmware_no_update_desc)
                isCancelable = true
                dismissAfterDelay()
            }
            else -> {}
        }
    }

    private var awaitingReconnect = false

    /**
     * After the firmware push completes the device reboots and drops BLE. Keep the sheet up with
     * "Restarting device..." until the connection actually comes back (60s cap), then show
     * "Update complete!" and dismiss — instead of dropping the user on a Disconnected UI.
     */
    private fun awaitReconnectThenDismiss() {
        if (awaitingReconnect) return
        awaitingReconnect = true
        binding.descriptionLabel.text = getString(R.string.firmware_restarting_desc)
        binding.statusLabel.text = "Restarting device..."
        viewLifecycleOwner.lifecycleScope.launch {
            val reconnected = kotlinx.coroutines.withTimeoutOrNull(60_000) {
                deviceManager.connectionState.first { it is com.plaud.template.models.DeviceConnectionState.Connected }
            } != null
            binding.statusLabel.text = if (reconnected) "Update complete!" else "Device is restarting..."
            binding.descriptionLabel.text = getString(R.string.firmware_success_desc)
            isCancelable = true
            dismissAfterDelay()
        }
    }

    private fun showFailureAlertThenDismiss(error: String?) {
        binding.root.postDelayed({
            if (!isAdded) return@postDelayed
            val ctx = requireActivity()
            dismissAllowingStateLoss()
            androidx.appcompat.app.AlertDialog.Builder(ctx)
                .setTitle("Update Failed")
                .setMessage(error ?: getString(R.string.firmware_failed_desc))
                .setPositiveButton(android.R.string.ok, null)
                .show()
        }, 800)
    }

    private fun dismissAfterDelay() {
        binding.root.postDelayed({ if (isAdded) dismissAllowingStateLoss() }, 2000)
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }

    companion object {
        private const val ARG_DEVICE_NAME = "device_name"
        private const val KEY_STARTED = "ota_started"
        private val EMPTY_COLOR = Color.parseColor("#E5E5E5")

        fun newInstance(deviceName: String): FirmwareUpdateSheet = FirmwareUpdateSheet().apply {
            arguments = Bundle().apply { putString(ARG_DEVICE_NAME, deviceName) }
        }
    }
}
