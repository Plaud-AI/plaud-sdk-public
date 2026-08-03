package com.plaud.template.common

import android.util.Log
import timber.log.Timber

/**
 * App-side logger that mirrors iOS AppLog: every message goes to Logcat AND into the SDK's
 * on-disk log files (the SDK plants a Timber FileLoggingTree in its Logger), so exported
 * .plaud log packages contain app-layer context alongside SDK logs.
 */
object AppLog {

    fun i(tag: String, message: String) {
        Log.i(tag, message)
        safeTimber { Timber.tag(tag).i(message) }
    }

    fun w(tag: String, message: String, tr: Throwable? = null) {
        Log.w(tag, message, tr)
        safeTimber { Timber.tag(tag).w(tr, message) }
    }

    fun e(tag: String, message: String, tr: Throwable? = null) {
        Log.e(tag, message, tr)
        safeTimber { Timber.tag(tag).e(tr, message) }
    }

    /** Timber is only planted after SDK init; never let logging itself crash the app. */
    private inline fun safeTimber(block: () -> Unit) {
        try { block() } catch (_: Exception) { }
    }
}
