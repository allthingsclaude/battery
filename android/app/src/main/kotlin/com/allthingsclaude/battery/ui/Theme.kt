package com.allthingsclaude.battery.ui

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import androidx.compose.ui.graphics.Color
import com.allthingsclaude.battery.core.BatteryPalette

/** The terracotta palette as Compose colours. Values come from [BatteryPalette]. */
object BatteryColors {
    val brand = Color(BatteryPalette.BRAND)
    val brandDark = Color(BatteryPalette.BRAND_DARK)
    val brandDeep = Color(BatteryPalette.BRAND_DEEP)
    val surfaceLight = Color(BatteryPalette.SURFACE_LIGHT)
    val surfaceDark = Color(BatteryPalette.SURFACE_DARK)
    val secondary = Color(BatteryPalette.SECONDARY)
}

/**
 * Fixed terracotta, in both schemes.
 *
 * **No Material You dynamic colour**, and that is a decision rather than an
 * oversight. Battery is one product across three platforms, and the Live
 * Update's segment ramp *is* the brand ramp — brand → brandDark → brandDeep is
 * how severity is encoded, so recolouring it from the wallpaper would stop it
 * meaning anything. Dynamic colour would have split the app's chrome from its
 * own card.
 *
 * Light and dark backgrounds match the desktop app's `#FAF8F4` / `#191814`
 * exactly, so a screenshot of this next to the menu bar reads as one product.
 */
private val LightScheme = lightColorScheme(
    primary = BatteryColors.brand,
    onPrimary = Color.White,
    secondary = BatteryColors.brandDark,
    background = BatteryColors.surfaceLight,
    surface = BatteryColors.surfaceLight,
    surfaceVariant = Color(0xFFEFEAE2),
    onBackground = Color(0xFF1C1B18),
    onSurface = Color(0xFF1C1B18),
)

private val DarkScheme = darkColorScheme(
    primary = BatteryColors.brand,
    onPrimary = Color(0xFF1C1B18),
    secondary = BatteryColors.brandDark,
    background = BatteryColors.surfaceDark,
    surface = BatteryColors.surfaceDark,
    surfaceVariant = Color(0xFF262420),
    onBackground = Color(0xFFF2EFE9),
    onSurface = Color(0xFFF2EFE9),
)

/** System / Light / Dark, mirroring `AppearanceMode` in `ios/BatteryApp/Settings.swift`. */
enum class AppearanceMode(val title: String) {
    SYSTEM("System"),
    LIGHT("Light"),
    DARK("Dark");

    companion object {
        const val STORAGE_KEY = "appearance"
    }
}

@Composable
fun BatteryTheme(
    appearance: AppearanceMode = AppearanceMode.SYSTEM,
    content: @Composable () -> Unit,
) {
    val dark = when (appearance) {
        AppearanceMode.SYSTEM -> isSystemInDarkTheme()
        AppearanceMode.LIGHT -> false
        AppearanceMode.DARK -> true
    }

    // Tell the system which ink the status and navigation bars should use.
    //
    // Android does not infer this from the window background — an app has to
    // declare it, and the default is light (white) icons. On our light surface
    // that makes the clock, wifi and battery indicators invisible. The flag
    // reads backwards at first glance: `isAppearanceLightStatusBars = true`
    // means "the BARS sit on a light background", i.e. draw DARK icons.
    val view = LocalView.current
    if (!view.isInEditMode) {
        val activity = view.context as? Activity
        SideEffect {
            activity?.window?.let { window ->
                WindowCompat.getInsetsController(window, view).apply {
                    isAppearanceLightStatusBars = !dark
                    isAppearanceLightNavigationBars = !dark
                }
            }
        }
    }

    MaterialTheme(
        colorScheme = if (dark) DarkScheme else LightScheme,
        content = content,
    )
}
