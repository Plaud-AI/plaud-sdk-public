package com.plaud.template.ui.home

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.google.android.material.bottomsheet.BottomSheetDialogFragment
import com.plaud.template.PlaudTemplateApp
import com.plaud.template.R
import com.plaud.template.databinding.SheetFastTransferBinding
import com.plaud.template.models.SyncState
import com.plaud.template.storage.RecordingStore
import kotlinx.coroutines.launch

/**
 * WiFi fast transfer confirmation sheet (mirrors iOS FastTransferSheetViewController):
 * 10x copy, "Never show again" + persistence, Turn on / Cancel, and a connecting state.
 * On transfer start the sheet dismisses and the sync banner takes over.
 */
class FastTransferSheet : BottomSheetDialogFragment() {

    private var _binding: SheetFastTransferBinding? = null
    private val binding get() = _binding!!

    private val syncManager get() = (requireActivity().application as PlaudTemplateApp).syncManager

    private var transferStarted = false

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
        _binding = SheetFastTransferBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        binding.closeButton.setOnClickListener { dismiss() }
        binding.cancelButton.setOnClickListener { dismiss() }
        binding.neverShowCheckbox.setOnCheckedChangeListener { _, checked ->
            RecordingStore.fastTransferNeverShowAgain = checked
        }
        binding.turnOnButton.setOnClickListener {
            transferStarted = true
            showConnectingState()
            syncManager.startWiFiTransfer()
        }

        observeState()
    }

    private fun observeState() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                syncManager.state.collect { state ->
                    if (!transferStarted) return@collect
                    when (state) {
                        is SyncState.WiFiConnecting -> showPhase(state.phase)
                        is SyncState.WiFiTransferring -> dismissAllowingStateLoss() // banner takes over
                        is SyncState.Failed -> {
                            // Only surface WiFi-related failures here (mirrors iOS filter)
                            if (state.message.contains("WiFi", ignoreCase = true) ||
                                state.message.contains("handshake", ignoreCase = true) ||
                                state.message.contains("hotspot", ignoreCase = true)
                            ) showError(state.message)
                        }
                        else -> {}
                    }
                }
            }
        }
    }

    private fun showConnectingState() {
        // Stay swipe-dismissable during connect (mirrors iOS)
        binding.confirmContainer.visibility = View.GONE
        binding.connectingContainer.visibility = View.VISIBLE
        showPhase(SyncState.WiFiConnectPhase.OPENING_HOTSPOT)
    }

    /** Three-phase connect copy: hotspot → join WiFi (system dialog) → starting transfer. */
    private fun showPhase(phase: SyncState.WiFiConnectPhase) {
        binding.connectStatusLabel.text = when (phase) {
            SyncState.WiFiConnectPhase.OPENING_HOTSPOT -> getString(R.string.wifi_opening_hotspot)
            SyncState.WiFiConnectPhase.CONNECTING_WIFI -> getString(R.string.wifi_connecting)
            SyncState.WiFiConnectPhase.HANDSHAKING -> getString(R.string.wifi_starting_transfer)
        }
    }

    private fun showError(message: String) {
        binding.spinner.visibility = View.GONE
        binding.connectStatusLabel.text = getString(R.string.connection_failed_fmt, message)
        binding.root.postDelayed({ if (isAdded) dismissAllowingStateLoss() }, 3000)
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }
}
