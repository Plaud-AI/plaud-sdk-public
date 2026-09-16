package com.plaud.template.ui.onboarding

import android.Manifest
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.animation.LinearInterpolator
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.plaud.template.PlaudTemplateApp
import com.plaud.template.R
import com.plaud.template.databinding.ActivityScanningBinding
import com.plaud.template.models.DeviceConnectionState
import kotlinx.coroutines.launch

/**
 * Onboarding second page — BLE scanning
 * Scanning animation + shows DeviceConnectBottomSheet once a device is found
 */
class ScanningActivity : AppCompatActivity() {

    private lateinit var binding: ActivityScanningBinding
    private val deviceManager get() = (application as PlaudTemplateApp).deviceManager

    /** Add-device mode: launched from Home to pair an additional device. */
    private val isAddingDevice: Boolean get() = intent.getBooleanExtra(EXTRA_ADDING_DEVICE, false)

    // Animations
    private var pulseAnimator: ObjectAnimator? = null
    private var rotationAnimator: ObjectAnimator? = null

    /** BLE runtime permissions to request (Android 12+ needs BLUETOOTH_SCAN/CONNECT; below 12 needs location permission) */
    private val blePermissions: Array<String> get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    } else {
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { grants ->
        if (grants.values.all { it }) {
            deviceManager.startScan()
        } else {
            binding.statusLabel.text = getString(R.string.bluetooth_permission_denied)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityScanningBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.backButton.setOnClickListener {
            deviceManager.stopScan()
            finish()
        }

        // Add-device mode: disconnect the current device first so we can scan/pair a new one
        // (also suppresses auto-reconnect of the old device while scanning).
        if (isAddingDevice) {
            deviceManager.disconnect()
            awaitingDisconnectSettle = true
        }

        setupScanAnimation()
        observeState()
    }

    override fun onDestroy() {
        super.onDestroy()
        // Leaving Add-Device without connecting must not permanently suppress auto-reconnect
        // (mirrors iOS viewWillDisappear reset).
        if (isAddingDevice) deviceManager.suppressAutoReconnect = false
    }

    /**
     * Add-device mode disconnects the current device in onCreate. The BLE stack needs a moment to
     * actually drop the link, and scanning inside that window finds nothing — which looked like the
     * connect sheet never opening until the user backed out and tried again (PLA2-331).
     * switchDevice() waits for the same reason.
     */
    private var awaitingDisconnectSettle = false

    override fun onResume() {
        super.onResume()
        startAnimations()
        if (!hasBlePermissions()) {
            permissionLauncher.launch(blePermissions)
            return
        }
        if (awaitingDisconnectSettle) {
            awaitingDisconnectSettle = false
            lifecycleScope.launch {
                kotlinx.coroutines.delay(DISCONNECT_SETTLE_MS)
                if (!isFinishing) deviceManager.startScan()
            }
        } else {
            deviceManager.startScan()
        }
    }

    private fun hasBlePermissions(): Boolean =
        blePermissions.all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }

    override fun onPause() {
        super.onPause()
        stopAnimations()
    }

    // MARK: - Scanning animation

    private fun setupScanAnimation() {
        // Replace the static Ring and rotating Arc with custom-drawn Views
        val ringView = object : View(this) {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = ContextCompat.getColor(this@ScanningActivity, R.color.scan_ring_light)
                style = Paint.Style.STROKE
                strokeWidth = 1.5f * resources.displayMetrics.density
            }
            override fun onDraw(canvas: Canvas) {
                val cx = width / 2f
                val cy = height / 2f
                val r = (minOf(width, height) / 2f) - paint.strokeWidth
                canvas.drawCircle(cx, cy, r, paint)
            }
        }
        binding.staticRing.visibility = View.GONE
        binding.scanAnimationContainer.addView(ringView, 1,
            android.widget.FrameLayout.LayoutParams(
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT
            ))

        val arcView = object : View(this) {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = ContextCompat.getColor(this@ScanningActivity, R.color.scan_arc_dark)
                style = Paint.Style.STROKE
                strokeWidth = 2f * resources.displayMetrics.density
                strokeCap = Paint.Cap.ROUND
            }
            private val rect = RectF()
            override fun onDraw(canvas: Canvas) {
                val inset = paint.strokeWidth
                rect.set(inset, inset, width - inset, height - inset)
                // 28% of 360 = ~100 degrees
                canvas.drawArc(rect, 0f, 100f, false, paint)
            }
        }
        binding.spinningArc.visibility = View.GONE
        binding.scanAnimationContainer.addView(arcView, 2,
            android.widget.FrameLayout.LayoutParams(
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT
            ))

        // Pulse animation
        pulseAnimator = ObjectAnimator.ofFloat(binding.glowView, View.SCALE_X, 0.95f, 1.05f).apply {
            duration = 2000
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
        }
        val pulseY = ObjectAnimator.ofFloat(binding.glowView, View.SCALE_Y, 0.95f, 1.05f).apply {
            duration = 2000
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
        }

        // Rotation animation
        rotationAnimator = ObjectAnimator.ofFloat(arcView, View.ROTATION, 0f, 360f).apply {
            duration = 1800
            interpolator = LinearInterpolator()
            repeatCount = ValueAnimator.INFINITE
        }

        pulseAnimator?.start()
        pulseY.start()
        rotationAnimator?.start()
    }

    private fun startAnimations() {
        pulseAnimator?.resume()
        rotationAnimator?.resume()
    }

    private fun stopAnimations() {
        pulseAnimator?.pause()
        rotationAnimator?.pause()
    }

    // MARK: - State observation

    private fun observeState() {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    // Show the BottomSheet when a device is found
                    deviceManager.scannedDevices.collect { devices ->
                        if (devices.isEmpty()) return@collect
                        binding.statusLabel.text = getString(R.string.device_found)
                        // Nothing the user hasn't already dismissed → leave them alone.
                        val sns = devices.map { it.serialNumber }.toSet()
                        if (sns.all { it in dismissedDeviceSNs }) return@collect
                        showDeviceConnectSheet()
                    }
                }

                launch {
                    // Navigate once the connection succeeds
                    deviceManager.connectionState.collect { state ->
                        when (state) {
                            is DeviceConnectionState.Connected -> {
                                // Add-device flow returns to Home; first-time onboarding goes to Success
                                if (isAddingDevice) finish() else navigateToSuccess()
                            }
                            is DeviceConnectionState.Failed -> {
                                binding.statusLabel.text = state.message
                                // Bluetooth off is the one failure the user can fix right now, and
                                // an inline label is easy to miss while the animation keeps
                                // spinning — offer the system toggle directly (PLA2-321).
                                if (state.message == com.plaud.template.managers.DeviceManager.BLUETOOTH_OFF_MESSAGE) {
                                    stopAnimations()
                                    promptEnableBluetooth(state.message)
                                }
                            }
                            is DeviceConnectionState.Disconnected -> {
                                // Scan timed out (or dropped) — restart after 2s so the page never
                                // dies silently (mirrors iOS ScanningViewController).
                                binding.statusLabel.text = getString(R.string.searching)
                                kotlinx.coroutines.delay(2_000)
                                if (deviceManager.connectionState.value is DeviceConnectionState.Disconnected) {
                                    deviceManager.startScan()
                                }
                            }
                            else -> {}
                        }
                    }
                }
            }
        }
    }

    private var sheetShown = false

    /**
     * SNs the user had in front of them when they dismissed the sheet. Scanning keeps emitting the
     * same devices, so re-presenting on every emission made Back and the sheet's close button look
     * broken — the sheet reappeared instantly and it took two Backs to leave the page (PLA2-330).
     * A device outside this set is genuinely new information, so it may present again.
     */
    private var dismissedDeviceSNs = emptySet<String>()

    private fun showDeviceConnectSheet() {
        if (sheetShown) return
        sheetShown = true
        val sheet = DeviceConnectBottomSheet()
        supportFragmentManager.setFragmentResultListener(
            DeviceConnectBottomSheet.RESULT_DISMISSED, this
        ) { _, _ ->
            sheetShown = false
            dismissedDeviceSNs = deviceManager.scannedDevices.value.map { it.serialNumber }.toSet()
        }
        sheet.show(supportFragmentManager, "DeviceConnectBottomSheet")
    }

    /**
     * Bluetooth is off: tell the user plainly and hand them the system toggle. Retry re-runs the
     * scan (the user may have flipped it from the notification shade), Cancel leaves the page.
     */
    private var bluetoothPromptShown = false

    private fun promptEnableBluetooth(message: String) {
        if (bluetoothPromptShown) return
        bluetoothPromptShown = true
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle(R.string.bluetooth_off_title)
            .setMessage(message)
            .setPositiveButton(R.string.bluetooth_open_settings) { _, _ ->
                bluetoothPromptShown = false
                startActivity(Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS))
            }
            .setNegativeButton(R.string.cancel) { _, _ -> finish() }
            .setOnDismissListener { bluetoothPromptShown = false }
            .show()
    }

    private fun navigateToSuccess() {
        startActivity(Intent(this, OnboardingSuccessActivity::class.java))
        finish()
    }

    companion object {
        const val EXTRA_ADDING_DEVICE = "extra_adding_device"

        /** Grace period for the BLE stack to finish dropping the previous link before scanning. */
        private const val DISCONNECT_SETTLE_MS = 1_200L
    }
}
