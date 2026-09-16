package com.plaud.template

import android.app.Application
import com.plaud.template.managers.DeviceManager
import com.plaud.template.managers.DeviceManagerProtocol
import com.plaud.template.managers.RecordingManager
import com.plaud.template.managers.RecordingManagerProtocol
import com.plaud.template.managers.SyncManager
import com.plaud.template.managers.SyncManagerProtocol
import com.plaud.template.managers.mock.MockDeviceManager
import com.plaud.template.managers.mock.MockRecordingManager
import com.plaud.template.managers.mock.MockSyncManager
import com.plaud.template.storage.RecordingStore

/**
 * Application entry point
 * Initializes RecordingStore and the manager singletons
 */
class PlaudTemplateApp : Application() {

    companion object {
        /** Set to true to use the mock managers, enabling UI development without a real device */
        const val USE_MOCK = false

        lateinit var instance: PlaudTemplateApp
            private set
    }

    // Manager instances (switch between real / mock based on USE_MOCK)
    val deviceManager: DeviceManagerProtocol by lazy {
        if (USE_MOCK) MockDeviceManager() else DeviceManager.shared.also { it.setContext(this) }
    }
    val recordingManager: RecordingManagerProtocol by lazy {
        if (USE_MOCK) MockRecordingManager() else RecordingManager.shared
    }
    val syncManager: SyncManagerProtocol by lazy {
        if (USE_MOCK) MockSyncManager() else SyncManager.shared
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        RecordingStore.init(this)
        registerForegroundReconnect()
    }

    /**
     * App-wide foreground reconnect trigger (mirrors iOS sceneDidBecomeActive): whenever the app
     * returns to the foreground from ANY activity — not just MainActivity — try to reconnect the
     * last device after 2s, guarded by connected/OTA/paired checks inside attemptReconnect().
     */
    private fun registerForegroundReconnect() {
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacksAdapter() {
            private var startedCount = 0
            override fun onActivityStarted(activity: android.app.Activity) {
                val wasBackground = startedCount == 0
                startedCount++
                if (!wasBackground || USE_MOCK) return
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    if (RecordingStore.lastConnectedDeviceSN != null &&
                        RecordingStore.userId != null
                    ) {
                        deviceManager.attemptReconnect()
                    }
                }, 2_000)
            }
            override fun onActivityStopped(activity: android.app.Activity) {
                startedCount = (startedCount - 1).coerceAtLeast(0)
            }
        })
    }
}

/** No-op base so callers override only the callbacks they need. */
open class ActivityLifecycleCallbacksAdapter : Application.ActivityLifecycleCallbacks {
    override fun onActivityCreated(activity: android.app.Activity, savedInstanceState: android.os.Bundle?) {}
    override fun onActivityStarted(activity: android.app.Activity) {}
    override fun onActivityResumed(activity: android.app.Activity) {}
    override fun onActivityPaused(activity: android.app.Activity) {}
    override fun onActivityStopped(activity: android.app.Activity) {}
    override fun onActivitySaveInstanceState(activity: android.app.Activity, outState: android.os.Bundle) {}
    override fun onActivityDestroyed(activity: android.app.Activity) {}
}
