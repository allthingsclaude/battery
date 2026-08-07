package com.allthingsclaude.battery.widget

import android.appwidget.AppWidgetManager
import android.content.Context

/**
 * Per-widget appearance, stored against the `appWidgetId`.
 *
 * Per-widget rather than one app-wide preference, because that is what the
 * platform's own widgets do and what the affordance implies: a gear on *this*
 * widget should change *this* widget. Someone with the row widget on a dark home
 * screen and the ring on a light one needs two answers, not one.
 *
 * Reached through the widget's configuration activity — `android:configure` plus
 * `widgetFeatures="reconfigurable"`, which is what puts the gear there.
 * `configuration_optional` means placing a widget doesn't force a trip through
 * the config screen first; the defaults are sensible on their own.
 */
data class WidgetConfig(
    /** 0f = fully transparent, 1f = solid. */
    val opacity: Float = DEFAULT_OPACITY,
    val colors: Colors = Colors.AUTO,
) {
    /** Which ink to draw with, given the current system theme. */
    fun lightInk(systemIsDark: Boolean): Boolean = when (colors) {
        Colors.AUTO -> systemIsDark
        Colors.LIGHT -> false
        Colors.DARK -> true
    }

    enum class Colors(val title: String) {
        /** Follow the system's light/dark setting. */
        AUTO("Auto"),

        /**
         * Dark ink for a light background. Named for the *widget's* appearance,
         * matching how the platform's own widgets label this — not for the ink.
         */
        LIGHT("Light"),

        /** Light ink, for a dark wallpaper. The reason this can't be inferred: a
         * transparent widget cannot ask what colour the wallpaper behind it is,
         * and the launcher's light/dark setting is not the wallpaper. A black
         * wallpaper in light mode is exactly where AUTO gets it wrong. */
        DARK("Dark"),
    }

    companion object {
        const val DEFAULT_OPACITY = 1f

        private const val PREFS = "widget_config"

        fun load(context: Context, appWidgetId: Int): WidgetConfig {
            val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val opacity = prefs.getFloat(key(appWidgetId, "opacity"), DEFAULT_OPACITY)
            val colors = prefs.getString(key(appWidgetId, "colors"), null)
                ?.let { raw -> Colors.entries.firstOrNull { it.name == raw } }
                ?: Colors.AUTO
            return WidgetConfig(opacity, colors)
        }

        fun save(context: Context, appWidgetId: Int, config: WidgetConfig) {
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putFloat(key(appWidgetId, "opacity"), config.opacity)
                .putString(key(appWidgetId, "colors"), config.colors.name)
                .apply()
        }

        /**
         * Forget a removed widget's settings.
         *
         * Android reuses `appWidgetId`s, so without this a newly placed widget
         * would silently inherit the opacity of a deleted one.
         */
        fun delete(context: Context, appWidgetId: Int) {
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .remove(key(appWidgetId, "opacity"))
                .remove(key(appWidgetId, "colors"))
                .apply()
        }

        private fun key(id: Int, field: String) = "w${id}_$field"

        val INVALID_ID = AppWidgetManager.INVALID_APPWIDGET_ID
    }
}
