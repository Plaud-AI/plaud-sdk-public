package com.plaud.template.common

import android.graphics.Color
import android.graphics.Typeface

object PlaudTheme {

    // --- Colors ---

    val background: Int = Color.parseColor("#F9F9F9")
    val primaryText: Int = Color.parseColor("#1F1F1F")
    val secondaryText: Int = Color.parseColor("#A3A3A3")
    val tertiaryText: Int = Color.parseColor("#858585")
    val separator: Int = Color.parseColor("#EBEBEB")
    val lightGray: Int = Color.parseColor("#D6D6D6")
    val darkGray: Int = Color.parseColor("#3D3D3D")
    /** Black @ 40% — modal scrim (mirrors iOS PlaudTheme.overlay). */
    val overlay: Int = Color.parseColor("#66000000")

    // Type scale (sp), mirrors iOS PlaudTheme font ladder
    const val fontDisplay = 36f
    const val fontTitle = 24f
    const val fontHeading = 20f
    const val fontBody = 16f
    const val fontLabel = 14f
    const val fontCaption = 13f
    val mediumGray: Int = Color.parseColor("#7A7A7A")
    val accentGreen: Int = Color.parseColor("#6CAE85")
    val accentRed: Int = Color.parseColor("#FF503F")
    val white: Int = Color.parseColor("#FFFFFF")
    val black: Int = Color.parseColor("#000000")
    val scanBlue: Int = Color.parseColor("#C1E8FE")
    val scanBlueDark: Int = Color.parseColor("#4B90B8")
    val cardBackground: Int = Color.parseColor("#FFFFFF")
    val syncBorderGray: Int = Color.parseColor("#CCCCCC")

    // --- Fonts ---

    fun light(): Typeface = Typeface.create(Typeface.DEFAULT, 300, false)

    fun regular(): Typeface = Typeface.create(Typeface.DEFAULT, 400, false)

    fun semiBold(): Typeface = Typeface.create(Typeface.DEFAULT, 600, false)

    // --- Dimensions (dp values, convert via Context.dpToPx) ---

    const val cornerRadius: Int = 12
    const val buttonHeight: Int = 48
    const val cardPadding: Int = 16
}
