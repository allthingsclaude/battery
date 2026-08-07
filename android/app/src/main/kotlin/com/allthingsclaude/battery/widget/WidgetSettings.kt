package com.allthingsclaude.battery.widget

import android.content.Context

/**
 * How widgets paint their background.
 *
 * A transparent widget can't ask the system what colour the wallpaper behind it
 * is, and the launcher's own light/dark setting is not the wallpaper — a black
 * wallpaper in light mode is exactly the case where "follow the system" produces
 * dark text on black. So the text colour is chosen explicitly rather than
 * inferred, which is also what every launcher-customisation tool ends up doing.
 */
enum class WidgetBackground(val title: String, val subtitle: String) {
    SURFACE("Surface", "Solid card, follows light/dark"),
    TRANSPARENT_LIGHT_TEXT("Transparent · light text", "For dark wallpapers"),
    TRANSPARENT_DARK_TEXT("Transparent · dark text", "For light wallpapers");

    val isTransparent: Boolean get() = this != SURFACE

    companion object {
        private const val PREFS = "widget_settings"
        private const val KEY = "background"

        fun current(context: Context): WidgetBackground {
            val raw = context.applicationContext
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY, null) ?: return SURFACE
            return entries.firstOrNull { it.name == raw } ?: SURFACE
        }

        fun set(context: Context, value: WidgetBackground) {
            context.applicationContext
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString(KEY, value.name).apply()
        }
    }
}
