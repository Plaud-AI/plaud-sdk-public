package com.plaud.template.ui.main

import android.content.Intent
import android.os.Bundle
import android.view.View
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.fragment.app.Fragment
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch
import com.plaud.template.PlaudTemplateApp
import com.plaud.template.R
import com.plaud.template.databinding.ActivityMainBinding
import com.plaud.template.models.DeviceConnectionState
import com.plaud.template.storage.RecordingStore
import com.plaud.template.ui.files.FilesFragment
import com.plaud.template.ui.home.HomeFragment
import com.plaud.template.ui.onboarding.WelcomeActivity
import com.plaud.template.ui.settings.SettingsFragment

/**
 * Main screen — bottom floating Tab Bar + 3 Fragments
 */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding

    private val homeFragment = HomeFragment()
    private val filesFragment = FilesFragment()
    private val settingsFragment = SettingsFragment()
    private var activeFragment: Fragment? = null

    private var selectedTab = 0

    private val deviceManager get() = (application as PlaudTemplateApp).deviceManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // If no device has been connected before, go back to Welcome — unless the user chose
        // "Connect device later" on Welcome (device can be added afterwards).
        if (RecordingStore.lastConnectedDeviceSN == null && !RecordingStore.hasSkippedOnboarding) {
            startActivity(Intent(this, WelcomeActivity::class.java))
            finish()
            return
        }

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        setupFragments()
        setupTabBar()
        selectTab(0)

        // Cloud binding alerts (e.g. device bound to another account)
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                deviceManager.cloudAlerts.collect { message ->
                    AlertDialog.Builder(this@MainActivity)
                        .setTitle("Device Binding")
                        .setMessage(message)
                        .setPositiveButton(android.R.string.ok, null)
                        .show()
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // Entering the foreground -> if not connected and there is a previously bound device, trigger background auto-reconnect after a delay
        // (the delay waits for the Bluetooth stack to power on, matching the 2s delay in iOS sceneDidBecomeActive)
        if (deviceManager.connectionState.value !is DeviceConnectionState.Connected &&
            RecordingStore.lastConnectedDeviceSN != null
        ) {
            binding.root.postDelayed({ deviceManager.attemptReconnect() }, 2_000)
        }
    }

    private fun setupFragments() {
        supportFragmentManager.beginTransaction()
            .add(R.id.fragmentContainer, settingsFragment, "settings").hide(settingsFragment)
            .add(R.id.fragmentContainer, filesFragment, "files").hide(filesFragment)
            .add(R.id.fragmentContainer, homeFragment, "home")
            .commit()
        activeFragment = homeFragment
    }

    private fun setupTabBar() {
        // Pin the floating bar to safe-area bottom + 8dp (mirrors iOS)
        androidx.core.view.ViewCompat.setOnApplyWindowInsetsListener(binding.tabBar) { v, insets ->
            val bottom = insets.getInsets(androidx.core.view.WindowInsetsCompat.Type.systemBars()).bottom
            (v.layoutParams as android.widget.FrameLayout.LayoutParams).bottomMargin =
                bottom + (8 * v.resources.displayMetrics.density).toInt()
            v.requestLayout()
            insets
        }

        binding.tabHome.setOnClickListener { selectTab(0) }
        binding.tabFiles.setOnClickListener { selectTab(1) }
        binding.tabSettings.setOnClickListener { selectTab(2) }
    }

    private fun selectTab(index: Int) {
        if (selectedTab == index && activeFragment != null) return
        selectedTab = index

        val target = when (index) {
            0 -> homeFragment
            1 -> filesFragment
            2 -> settingsFragment
            else -> homeFragment
        }

        activeFragment?.let { current ->
            supportFragmentManager.beginTransaction()
                .hide(current)
                .show(target)
                .commit()
        }
        activeFragment = target

        updateTabAppearance()
    }

    private fun updateTabAppearance() {
        val tabs = listOf(binding.tabHome, binding.tabFiles, binding.tabSettings)
        val icons = listOf(binding.tabHomeIcon, binding.tabFilesIcon, binding.tabSettingsIcon)
        val labels = listOf(binding.tabHomeLabel, binding.tabFilesLabel, binding.tabSettingsLabel)

        for (i in tabs.indices) {
            val isSelected = i == selectedTab
            tabs[i].background = if (isSelected) {
                ContextCompat.getDrawable(this, R.drawable.bg_tab_selected)
            } else {
                null
            }
            // Selected = black icon+label, unselected = #7A7A7A (mirrors iOS)
            val tint = ContextCompat.getColor(this, if (isSelected) R.color.black else R.color.tab_unselected)
            icons[i].setColorFilter(tint)
            labels[i].setTextColor(tint)
        }
    }
}
