package com.plaud.template.ui.settings

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.appcompat.app.AlertDialog
import androidx.fragment.app.Fragment
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.plaud.template.PlaudTemplateApp
import com.plaud.template.R
import com.plaud.template.databinding.FragmentSettingsBinding
import com.plaud.template.storage.RecordingStore
import com.plaud.template.ui.onboarding.WelcomeActivity
import kotlinx.coroutines.launch

/**
 * Settings Tab — Auto Sync toggle + Firmware version + Sign Out
 */
class SettingsFragment : Fragment() {

    private var _binding: FragmentSettingsBinding? = null
    private val binding get() = _binding!!

    private val app get() = requireActivity().application as PlaudTemplateApp
    private val deviceManager get() = app.deviceManager
    private val recordingManager get() = app.recordingManager

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
        _binding = FragmentSettingsBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        // Re-check firmware on open (mirrors iOS setupBindings), covering late/failed on-connect checks
        deviceManager.refreshFirmwareCheck()

        // Auto Sync toggle
        binding.autoSyncToggle.isChecked = RecordingStore.isAutoSyncEnabled
        binding.autoSyncToggle.onToggleChanged = { isChecked ->
            RecordingStore.isAutoSyncEnabled = isChecked
            deviceManager.setAutoSync(isChecked)
        }

        // Sign Out
        binding.signOutButton.setOnClickListener {
            showSignOutConfirmation()
        }

        // SDK Logs export: encrypted .plaud package → share sheet → clear logs (mirrors iOS)
        binding.exportLogsButton.setOnClickListener { exportSdkLogs() }

        // User Access Token: renewal (same user) applies live; account switch takes effect on restart
        renderTokenCard()
        binding.replaceTokenButton.setOnClickListener { showReplaceTokenDialog() }

        // API Key (transcription): replacement applies immediately (read per-request)
        renderApiKeyCard()
        binding.replaceApiKeyButton.setOnClickListener { showReplaceApiKeyDialog() }

        // App version (read-only) so QA can report the exact build in bug reports
        binding.appVersionLabel.text =
            "${com.plaud.template.BuildConfig.VERSION_NAME} (${com.plaud.template.BuildConfig.VERSION_CODE})"

        // Server Environment: production / test domain switch, takes effect on restart
        renderEnvCard()
        binding.switchEnvButton.setOnClickListener { showSwitchEnvDialog() }

        observeDevice()
    }

    private fun observeDevice() {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                deviceManager.connectedDevice.collect { device ->
                    binding.firmwareVersionLabel.text = device?.firmwareVersion?.let { "Version $it" } ?: "--"

                    // Show the firmware update button
                    val hasUpdate = device?.latestFirmwareVersion != null &&
                            device.latestFirmwareVersion != device.firmwareVersion
                    binding.firmwareUpdateButton.visibility = if (hasUpdate) View.VISIBLE else View.GONE
                    binding.firmwareUpdateButton.setOnClickListener {
                        FirmwareUpdateSheet
                            .newInstance(device?.name ?: "Plaud Device")
                            .show(childFragmentManager, "FirmwareUpdateSheet")
                    }
                }
            }
        }
    }

    /**
     * Export the encrypted SDK log package (.plaud) and hand it to the system share sheet, then
     * clear the on-device logs so each export contains only fresh content (mirrors iOS
     * PlaudLogEncryption.exportEncryptedLogFile + deleteAllLogFiles).
     */
    private fun exportSdkLogs() {
        viewLifecycleOwner.lifecycleScope.launch {
            val ctx = requireContext().applicationContext
            val file = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                try { sdk.NiceBuildSdk.exportLog(ctx) } catch (e: Exception) { null }
            }
            if (file == null || !file.exists()) {
                AlertDialog.Builder(requireContext())
                    .setMessage(R.string.export_failed)
                    .setPositiveButton(android.R.string.ok, null)
                    .show()
                return@launch
            }
            val uri = androidx.core.content.FileProvider.getUriForFile(
                requireContext(), "${requireContext().packageName}.fileprovider", file
            )
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "application/octet-stream"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, getString(R.string.sdk_logs)))
            // Clear logs after export so the next package starts fresh (mirrors iOS)
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                try { sdk.NiceBuildSdk.cleanupLogs(ctx) } catch (_: Exception) { }
            }
        }
    }

    // MARK: - User Access Token (account switch / renewal)

    private fun renderTokenCard() {
        val info = com.plaud.template.common.JwtUtils.parse(RecordingStore.activeUserAccessToken)
        binding.tokenInfoLabel.text = if (info == null) "Invalid token" else {
            val exp = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm", java.util.Locale.getDefault())
                .format(java.util.Date(info.expSeconds * 1000))
            "${info.userId} · expires $exp"
        }
    }

    /**
     * Paste-in a new userAccessToken. Same user (JWT sub unchanged) → applied LIVE via
     * NiceBuildSdk.setPartnerToken (SDK refreshes RSA keys; handshake token derives from the
     * current token at connect time). Different user (account switch) → persisted only, takes
     * effect on the next cold start to avoid a half-switched runtime.
     * TODO(SDK): expose setUserAccessToken on the PlaudDeviceAgent facade (parity with iOS).
     */
    private fun showReplaceTokenDialog() {
        val input = android.widget.EditText(requireContext()).apply {
            hint = "Paste new userAccessToken (JWT)"
            setPadding(48, 32, 48, 32)
            maxLines = 4
        }
        AlertDialog.Builder(requireContext())
            .setTitle(R.string.user_access_token)
            .setView(input)
            .setPositiveButton(R.string.confirm) { _, _ ->
                applyNewToken(input.text.toString().trim())
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun applyNewToken(newToken: String) {
        val newInfo = com.plaud.template.common.JwtUtils.parse(newToken)
        if (newInfo == null) {
            AlertDialog.Builder(requireContext())
                .setTitle(R.string.user_access_token)
                .setMessage("Invalid token: not a parseable JWT.")
                .setPositiveButton(android.R.string.ok, null)
                .show()
            return
        }
        val oldInfo = com.plaud.template.common.JwtUtils.parse(RecordingStore.activeUserAccessToken)
        RecordingStore.userAccessTokenOverride = newToken

        if (oldInfo != null && oldInfo.sub == newInfo.sub) {
            // Renewal: same account — apply live, no reconnect needed.
            try { sdk.NiceBuildSdk.setPartnerToken(newToken) } catch (e: Exception) {
                com.plaud.template.common.AppLog.w("SettingsFragment", "setPartnerToken failed", e)
            }
            renderTokenCard()
            AlertDialog.Builder(requireContext())
                .setTitle(R.string.user_access_token)
                .setMessage("Token renewed for ${newInfo.userId}. Applied immediately.")
                .setPositiveButton(android.R.string.ok, null)
                .show()
        } else {
            // Account switch: persist the new identity, take effect on restart (no live rewiring).
            RecordingStore.userId = newInfo.userId
            renderTokenCard()
            AlertDialog.Builder(requireContext())
                .setTitle("Switch Account")
                .setMessage("Token saved for ${newInfo.userId}. Restart the app to switch accounts.\n\nNote: a device bound to the previous account must be unpaired there before the new account can bind it.")
                .setCancelable(false)
                .setPositiveButton("Exit Now") { _, _ ->
                    requireActivity().finishAffinity()
                    kotlin.system.exitProcess(0)
                }
                .setNegativeButton("Later", null)
                .show()
        }
    }

    // MARK: - API Key (transcription X-Client-Api-Key)

    private fun renderApiKeyCard() {
        val key = RecordingStore.activeApiKey
        binding.apiKeyInfoLabel.text = when {
            key.isBlank() -> "Not configured"
            key.length <= 12 -> key
            else -> "${key.take(8)}…${key.takeLast(4)}"
        }
    }

    /** Paste-in a new transcription API key. Applied immediately — it is read on every request. */
    private fun showReplaceApiKeyDialog() {
        val input = android.widget.EditText(requireContext()).apply {
            hint = "Paste new API key (ak_...)"
            setPadding(48, 32, 48, 32)
            maxLines = 3
        }
        AlertDialog.Builder(requireContext())
            .setTitle(R.string.api_key)
            .setView(input)
            .setPositiveButton(R.string.confirm) { _, _ ->
                val newKey = input.text.toString().trim()
                if (newKey.isBlank()) return@setPositiveButton
                RecordingStore.apiKeyOverride = newKey
                renderApiKeyCard()
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    // MARK: - Server Environment (production / test domain)

    private fun renderEnvCard() {
        val domain = RecordingStore.activeServerDomain
        binding.envInfoLabel.text = "${RecordingStore.serverEnvironmentLabel(domain)} · $domain"
    }

    /**
     * Switch the server domain (SDK customDomain, Partner API and transcription API all derive
     * from it). Persisted only — the SDK is initialized once at app start, so the new domain
     * takes effect on the next cold start.
     */
    private fun showSwitchEnvDialog() {
        val domains = RecordingStore.serverEnvironments.map { it.second }.toTypedArray()
        val labels = RecordingStore.serverEnvironments
            .map { (label, domain) -> "$label ($domain)" }
            .toTypedArray()
        val current = domains.indexOf(RecordingStore.activeServerDomain).coerceAtLeast(0)
        AlertDialog.Builder(requireContext())
            .setTitle(R.string.server_environment)
            .setSingleChoiceItems(labels, current) { dialog, which ->
                dialog.dismiss()
                val selected = domains[which]
                if (selected == RecordingStore.activeServerDomain) return@setSingleChoiceItems
                RecordingStore.serverDomainOverride = selected
                renderEnvCard()
                AlertDialog.Builder(requireContext())
                    .setTitle(R.string.server_environment)
                    .setMessage("Server switched to $selected. Restart the app to apply.")
                    .setCancelable(false)
                    .setPositiveButton("Exit Now") { _, _ ->
                        requireActivity().finishAffinity()
                        kotlin.system.exitProcess(0)
                    }
                    .setNegativeButton("Later", null)
                    .show()
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun showSignOutConfirmation() {
        // Sign-out unpairs, so it strands an in-progress recording exactly like Unpair does
        // (PLA2-401) — same refusal here, otherwise the guard is trivially bypassed.
        if (recordingManager.state.value.isActive) {
            AlertDialog.Builder(requireContext())
                .setTitle(R.string.device_recording_title)
                .setMessage(R.string.device_recording_blocks_unpair)
                .setPositiveButton(android.R.string.ok, null)
                .show()
            return
        }
        AlertDialog.Builder(requireContext())
            .setTitle(R.string.sign_out)
            .setMessage(R.string.confirm_sign_out)
            .setPositiveButton(R.string.confirm) { _, _ ->
                // Unpair the CURRENT device only (mirrors iOS): other paired devices and synced
                // recordings survive. unpair() falls the active SN back to the next device.
                deviceManager.unpair()
                if (RecordingStore.pairedDeviceSNs.isEmpty()) {
                    navigateToWelcome()
                } else {
                    requireActivity().recreate()
                }
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun navigateToWelcome() {
        // Sign-out returns to onboarding for real — drop the "connect later" shortcut too.
        RecordingStore.hasSkippedOnboarding = false
        val intent = Intent(requireContext(), WelcomeActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        startActivity(intent)
        activity?.finish()
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }
}
