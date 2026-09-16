package com.plaud.template.common

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import android.view.animation.DecelerateInterpolator

class PlaudToggle @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    var isChecked: Boolean = false
        set(value) {
            if (field != value) {
                field = value
                animateToggle(value)
            }
        }

    var onToggleChanged: ((Boolean) -> Unit)? = null

    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val knobPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
    }

    private val trackRect = RectF()
    private val knobRect = RectF()

    private val trackCornerRadius = dpToPx(6f)
    private val knobCornerRadius = dpToPx(4f)
    private val knobPadding = dpToPx(2f)
    private val knobSize = dpToPx(22f)

    private val trackColorOn = Color.BLACK
    private val trackColorOff = Color.parseColor("#D6D6D6")

    // Animation progress: 0 = off, 1 = on
    private var animProgress = 0f
    private var animator: ValueAnimator? = null

    init {
        isClickable = true
        setOnClickListener {
            // Callback fires ONLY on user taps (mirrors iOS PlaudToggle.onToggle) — programmatic
            // sets via isChecked/setCheckedSilently never re-enter the listener (no feedback loop).
            isChecked = !isChecked
            onToggleChanged?.invoke(isChecked)
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = dpToPx(48f).toInt()
        val h = dpToPx(26f).toInt()
        setMeasuredDimension(
            resolveSize(w, widthMeasureSpec),
            resolveSize(h, heightMeasureSpec)
        )
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val w = width.toFloat()
        val h = height.toFloat()

        // Draw the track
        trackRect.set(0f, 0f, w, h)
        val trackColor = blendColors(trackColorOff, trackColorOn, animProgress)
        trackPaint.color = trackColor
        canvas.drawRoundRect(trackRect, trackCornerRadius, trackCornerRadius, trackPaint)

        // Draw the knob
        val knobLeft = knobPadding + (w - knobSize - knobPadding * 2) * animProgress
        val knobTop = (h - knobSize) / 2f
        knobRect.set(knobLeft, knobTop, knobLeft + knobSize, knobTop + knobSize)
        canvas.drawRoundRect(knobRect, knobCornerRadius, knobCornerRadius, knobPaint)
    }

    private fun animateToggle(checked: Boolean) {
        animator?.cancel()
        val target = if (checked) 1f else 0f
        animator = ValueAnimator.ofFloat(animProgress, target).apply {
            duration = 200L
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                animProgress = it.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    /**
     * Set the checked state without triggering the animation
     */
    fun setCheckedSilently(checked: Boolean) {
        if (isChecked != checked) {
            isChecked = checked
        }
        animProgress = if (checked) 1f else 0f
        invalidate()
    }

    private fun blendColors(from: Int, to: Int, ratio: Float): Int {
        val inverseRatio = 1f - ratio
        val a = (Color.alpha(from) * inverseRatio + Color.alpha(to) * ratio).toInt()
        val r = (Color.red(from) * inverseRatio + Color.red(to) * ratio).toInt()
        val g = (Color.green(from) * inverseRatio + Color.green(to) * ratio).toInt()
        val b = (Color.blue(from) * inverseRatio + Color.blue(to) * ratio).toInt()
        return Color.argb(a, r, g, b)
    }

    private fun dpToPx(dp: Float): Float {
        return dp * resources.displayMetrics.density
    }
}
