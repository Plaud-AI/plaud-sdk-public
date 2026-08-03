package com.plaud.template.ui.home

import android.content.Intent
import android.os.Bundle
import android.view.View
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import com.plaud.template.PlaudTemplateApp
import com.plaud.template.R
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.plaud.template.databinding.ActivityDevicePanelBinding
import com.plaud.template.ui.onboarding.WelcomeActivity
import kotlinx.coroutines.launch

/**
 * Device management page — Device info + Disconnect/Unpair actions
 */
class DevicePanelActivity : AppCompatActivity() {

    private lateinit var binding: ActivityDevicePanelBinding
    private val deviceManager get() = (application as PlaudTemplateApp).deviceManager
    private val recordingManager get() = (application as PlaudTemplateApp).recordingManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityDevicePanelBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.backButton.setOnClickListener { finish() }

        // Intent extras are just the initial snapshot; live updates below keep the page fresh.
        bindDevice(
            intent.getStringExtra("device_name") ?: "",
            intent.getStringExtra("device_sn") ?: "",
            intent.getStringExtra("firmware_version") ?: "",
            intent.getStringExtra("latest_firmware")
        )

        // Live-update from connectedDevice (mirrors iOS connectedDevicePublisher subscription):
        // name / firmware / Update visibility refresh when the delayed firmware check lands.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                deviceManager.connectedDevice.collect { device ->
                    device ?: return@collect
                    bindDevice(device.name, device.serialNumber, device.firmwareVersion, device.latestFirmwareVersion)
                }
            }
        }

        // Disconnect (row and trailing pill button share the action)
        binding.disconnectButton.setOnClickListener { binding.disconnectRow.performClick() }
        binding.disconnectRow.setOnClickListener {
            AlertDialog.Builder(this)
                .setTitle(R.string.disconnect)
                .setMessage(R.string.confirm_disconnect)
                .setPositiveButton(R.string.confirm) { _, _ ->
                    deviceManager.disconnect()
                    finish()
                }
                .setNegativeButton(R.string.cancel, null)
                .show()
        }

        // Unpair (multi-device aware): removes only this device, keeps the others.
        binding.unpairButton.setOnClickListener { binding.unpairRow.performClick() }
        binding.unpairRow.setOnClickListener {
            // Unpairing mid-recording strands the in-progress file: the device keeps writing it but
            // we lose the right to download it, so the recording is silently lost (PLA2-401).
            if (recordingManager.state.value.isActive) {
                showRecordingInProgressDialog()
                return@setOnClickListener
            }
            AlertDialog.Builder(this)
                .setTitle(R.string.unpair_device)
                .setMessage(R.string.confirm_unpair)
                .setPositiveButton(R.string.confirm) { _, _ ->
                    deviceManager.unpair()
                    // If other paired devices remain, return to Home (which reconnects the new
                    // active device); otherwise go back to onboarding Welcome.
                    if (deviceManager.getPairedDevices().isEmpty()) {
                        navigateToWelcome()
                    } else {
                        finish()
                    }
                }
                .setNegativeButton(R.string.cancel, null)
                .show()
        }
    }

    private fun bindDevice(name: String, sn: String, firmware: String, latest: String?) {
        // Nav title = device name (mirrors iOS)
        binding.panelTitle?.text = name.ifBlank { getString(R.string.device) }
        binding.deviceNameValue.text = name
        binding.deviceSnValue.text = sn
        binding.firmwareValue.text = firmware
        if (latest != null && latest != firmware) {
            binding.firmwareUpdateButton.visibility = View.VISIBLE
            binding.firmwareUpdateButton.setOnClickListener {
                com.plaud.template.ui.settings.FirmwareUpdateSheet
                    .newInstance(name)
                    .show(supportFragmentManager, "FirmwareUpdateSheet")
            }
        } else {
            binding.firmwareUpdateButton.visibility = View.GONE
        }
    }

    /** Refusal shown when a destructive action would strand an unfinished recording. */
    private fun showRecordingInProgressDialog() {
        AlertDialog.Builder(this)
            .setTitle(R.string.device_recording_title)
            .setMessage(R.string.device_recording_blocks_unpair)
            .setPositiveButton(android.R.string.ok, null)
            .show()
    }

    private fun navigateToWelcome() {
        val intent = Intent(this, WelcomeActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        startActivity(intent)
        finish()
    }
}
