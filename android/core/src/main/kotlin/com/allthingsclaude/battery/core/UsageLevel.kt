package com.allthingsclaude.battery.core

/**
 * Maps a utilization percentage (0–100) to a colour-coded severity level.
 *
 * A direct port of `ios/BatteryKit/UsageLevel.swift`. Thresholds match the macOS
 * app exactly (50 / 75 / 90) and, like the desktop default theme, the ramp stays
 * **within the terracotta family** — escalating by darkening (brand → brandDark →
 * brandDeep) rather than turning red.
 *
 * Colours are plain ARGB [Int]s rather than a Compose `Color` on purpose: this
 * module is Android-free, and an `Int` is what both consumers actually want —
 * `NotificationCompat.ProgressStyle.Segment.setColor` takes one directly, and
 * Compose wraps it with `Color(argb)`.
 */
enum class UsageLevel(val label: String, val color: Int, val deeperColor: Int) {
    /** 0–50% */
    LOW("Good", BatteryPalette.BRAND, BatteryPalette.BRAND_DARK),

    /** 50–75% */
    MODERATE("Moderate", BatteryPalette.BRAND, BatteryPalette.BRAND_DARK),

    /** 75–90% */
    HIGH("High", BatteryPalette.BRAND_DARK, BatteryPalette.BRAND_DEEP),

    /** 90%+ */
    CRITICAL("Critical", BatteryPalette.BRAND_DEEP, BatteryPalette.BRAND_DEEP);

    /** True once usage warrants surfacing an alert / bringing the card forward. */
    val isAlarming: Boolean get() = this == HIGH || this == CRITICAL

    companion object {
        fun from(utilization: Double): UsageLevel = when {
            utilization < 50 -> LOW
            utilization < 75 -> MODERATE
            utilization < 90 -> HIGH
            else -> CRITICAL
        }
    }
}

/**
 * The terracotta palette, copied verbatim from the desktop and iOS apps
 * (`ios/BatteryKit/BatteryColors.swift`). Severity escalates by darkening within
 * the brand — multi-colour is the opt-in "classic" theme on desktop and we ship
 * the branded default.
 */
object BatteryPalette {
    const val BRAND = 0xFFD97757.toInt()
    const val BRAND_DARK = 0xFFB85A3A.toInt()
    const val BRAND_DEEP = 0xFF9A4A2C.toInt()

    /**
     * The system-grey equivalent of SwiftUI's `.secondary`, for the one place
     * the forecast deliberately leaves the brand: no open window at all.
     */
    const val SECONDARY = 0xFF8A8A8E.toInt()

    /** Desktop's `#FAF8F4` / `#191814` surfaces. */
    const val SURFACE_LIGHT = 0xFFFAF8F4.toInt()
    const val SURFACE_DARK = 0xFF191814.toInt()
}
