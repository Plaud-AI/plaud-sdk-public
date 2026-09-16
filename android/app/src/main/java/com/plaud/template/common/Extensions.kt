package com.plaud.template.common

import android.animation.ObjectAnimator
import android.animation.PropertyValuesHolder
import android.content.Context
import android.util.Base64
import android.view.View
import android.view.animation.CycleInterpolator
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * JWT base64url -> standard base64, padding restored
 */
fun String.base64Padded(): String {
    var result = this
        .replace('-', '+')
        .replace('_', '/')
    val remainder = result.length % 4
    if (remainder > 0) {
        result += "=".repeat(4 - remainder)
    }
    return String(Base64.decode(result, Base64.DEFAULT), Charsets.UTF_8)
}

/**
 * Horizontal shake animation, ±10px, 400ms
 */
fun View.shake() {
    val pvh = PropertyValuesHolder.ofFloat(View.TRANSLATION_X, 0f, -10f, 10f, -10f, 10f, -5f, 5f, 0f)
    ObjectAnimator.ofPropertyValuesHolder(this, pvh).apply {
        duration = 400L
        interpolator = null
        start()
    }
}

/**
 * epoch millis -> "EEE, MMM d" format
 */
fun Long.toDateString(): String {
    val sdf = SimpleDateFormat("EEE, MMM d", Locale.US)
    return sdf.format(Date(this))
}

/**
 * epoch millis -> "h:mm a" format
 */
fun Long.toTimeString(): String {
    val sdf = SimpleDateFormat("h:mm a", Locale.US)
    return sdf.format(Date(this))
}

/**
 * seconds -> "Xh Xm" or "Xm" format
 */
fun Long.toDurationString(): String {
    val hours = this / 3600
    val minutes = (this % 3600) / 60
    return if (hours > 0) {
        "${hours}h ${minutes}m"
    } else {
        "${minutes}m"
    }
}

/**
 * dp to px (Int)
 */
fun Context.dpToPx(dp: Int): Int {
    return (dp * resources.displayMetrics.density + 0.5f).toInt()
}

/**
 * dp to px (Float)
 */
fun Context.dpToPx(dp: Float): Float {
    return dp * resources.displayMetrics.density
}
