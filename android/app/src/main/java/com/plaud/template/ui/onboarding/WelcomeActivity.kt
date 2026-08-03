package com.plaud.template.ui.onboarding

import android.content.Intent
import android.os.Bundle
import android.util.Base64
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import com.plaud.template.PlaudTemplateApp
import com.plaud.template.databinding.ActivityWelcomeBinding
import com.plaud.template.storage.RecordingStore
import com.plaud.template.ui.main.MainActivity
import org.json.JSONObject

/**
 * Onboarding first page — Welcome
 * Ready to use once B2B customers replace the logo and brand name
 */
class WelcomeActivity : AppCompatActivity() {

    private lateinit var binding: ActivityWelcomeBinding

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Route BEFORE inflating so returning users never see a Welcome flash (mirrors iOS
        // deciding the root VC before the window is shown).
        // Route on ANY paired device (mirrors iOS pairedDeviceSNs check), not just the last-connected one.
        val hasPairedDevice = RecordingStore.pairedDeviceSNs.isNotEmpty()
        val savedUserId = RecordingStore.userId
        if ((hasPairedDevice || RecordingStore.hasSkippedOnboarding) && savedUserId != null) {
            (application as PlaudTemplateApp).deviceManager.configure(savedUserId)
            navigateToMain()
            return
        }

        binding = ActivityWelcomeBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // Apply system bar insets (status bar top + navigation bar bottom)
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.updatePadding(top = bars.top, bottom = bars.bottom)
            insets
        }

        binding.getStartedButton.setOnClickListener {
            onGetStartedTapped()
        }

        // Enter Home without pairing (e.g. the built-in token expired after a reinstall and
        // scanning/connect can't proceed — the user needs Settings to replace the token first).
        binding.skipButton.setOnClickListener {
            val userId = extractUserId()
            RecordingStore.userId = userId
            RecordingStore.hasSkippedOnboarding = true
            (application as PlaudTemplateApp).deviceManager.configure(userId)
            navigateToMain()
        }
    }

    private fun onGetStartedTapped() {
        // Extract sub from the partnerToken JWT payload to use as the userId
        val userId = extractUserId()
        RecordingStore.userId = userId

        val app = application as PlaudTemplateApp
        app.deviceManager.configure(userId)

        startActivity(Intent(this, ScanningActivity::class.java))
    }

    /**
     * Parse the sub field from the partnerToken JWT payload to use as the userId
     */
    private fun extractUserId(): String {
        return try {
            val token = PARTNER_TOKEN
            val parts = token.split(".")
            if (parts.size < 2) return java.util.UUID.randomUUID().toString()

            // Base64-decode the payload (padding is added automatically)
            val payload = parts[1]
            val decoded = Base64.decode(payload, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
            val json = JSONObject(String(decoded, Charsets.UTF_8))
            json.optString("sub", java.util.UUID.randomUUID().toString())
        } catch (e: Exception) {
            java.util.UUID.randomUUID().toString()
        }
    }

    private fun navigateToMain() {
        startActivity(Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        })
        finish()
    }

    companion object {
        /** User Access Token, injected via local.properties → BuildConfig (mirrors iOS xcconfig).
         *  B2B customers put their own token in local.properties: PLAUD_USER_ACCESS_TOKEN=... */
        private val PARTNER_TOKEN get() = com.plaud.template.storage.RecordingStore.activeUserAccessToken
    }
}
