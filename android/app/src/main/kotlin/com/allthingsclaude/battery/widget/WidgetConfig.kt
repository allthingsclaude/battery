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
    /**
     * Which account this widget shows, or null to follow whichever is selected.
     *
     * Null is the default and stays the sensible one for a single-account user —
     * and for anyone who wants a widget that tracks the switcher. Binding is for
     * the case that makes switching unnecessary: one widget per account, both on
     * the home screen, neither of them ever needing to be told which is which.
     *
     * This is the pattern Google's own widget guidance names for exactly this
     * situation, with the multi-account email widget as the worked example.
     */
    val accountId: String? = null,
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
            val accountId = prefs.getString(key(appWidgetId, "account"), null)
            return WidgetConfig(opacity, colors, accountId)
        }

        fun save(context: Context, appWidgetId: Int, config: WidgetConfig) {
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putFloat(key(appWidgetId, "opacity"), config.opacity)
                .putString(key(appWidgetId, "colors"), config.colors.name)
                .putString(key(appWidgetId, "account"), config.accountId)
                .apply()
        }

        /**
         * Forget a removed widget's settings.
         *
         * Not because ids get reused — they do not. `AppWidgetServiceImpl`
         * allocates from a per-user monotonic counter and says so outright:
         * "appWidgetId is a monotonic increasing number, so the appWidgetId
         * cannot be reclaimed by a new widget." An earlier comment here claimed
         * the opposite and would have justified far more defensive machinery
         * than the problem deserves.
         *
         * It earns its place anyway. The one real collision vector is a
         * cross-device restore, where the system's id counter starts fresh at 1
         * while backed-up preferences still hold keys from the old device — and
         * that is already closed by `allowBackup="false"`. What remains is
         * ordinary hygiene: `onDeleted` is not guaranteed to fire (clearing One
         * UI Home's data destroys the host's records without telling us), so
         * settings for a departed widget would otherwise accumulate forever.
         */
        fun delete(context: Context, appWidgetId: Int) {
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .remove(key(appWidgetId, "opacity"))
                .remove(key(appWidgetId, "colors"))
                .remove(key(appWidgetId, "account"))
                .apply()
        }

        private fun key(id: Int, field: String) = "w${id}_$field"

        /**
         * Drop settings for widgets that are no longer placed.
         *
         * `onDeleted` covers the ordinary case, but it is not guaranteed to
         * fire: clearing One UI Home's data destroys the host's widget records
         * without telling the provider, and that is a fix Samsung's own support
         * threads tell people to perform. Without a sweep the bindings left
         * behind would accumulate for the life of the install.
         */
        fun reconcile(context: Context, liveIds: Set<Int>) {
            val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val stale = prefs.all.keys
                .mapNotNull { it.removePrefix("w").substringBefore('_').toIntOrNull() }
                .toSet()
                .minus(liveIds)
            if (stale.isEmpty()) return
            prefs.edit().apply { stale.forEach { id ->
                remove(key(id, "opacity"))
                remove(key(id, "colors"))
                remove(key(id, "account"))
            } }.apply()
        }

        /**
         * Every account any placed widget is bound to, plus the selected one.
         *
         * What the refresh worker fans out over. Distinct, so four widgets on
         * one account cost one poll rather than four.
         */
        fun boundAccountIds(context: Context, appWidgetIds: List<Int>, activeId: String?): Set<String> =
            (appWidgetIds.mapNotNull { load(context, it).accountId } + listOfNotNull(activeId)).toSet()

        val INVALID_ID = AppWidgetManager.INVALID_APPWIDGET_ID
    }
}
