package com.allthingsclaude.battery.launcher

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/**
 * Which launcher icon the app wears.
 *
 * An adaptive icon's layers are fixed, so the only way to change an icon at
 * runtime is to change *which component* carries MAIN/LAUNCHER. Each option is
 * an `activity-alias` in the manifest, all targeting MainActivity, exactly one
 * enabled.
 *
 * [AUTO] is not a third piece of artwork — it is the icon whose adaptive XML is
 * night-qualified, so the system theme picks the layers. [LIGHT] and [DARK]
 * point at fixed variants that do not move.
 *
 * There is no stored preference. The enabled component *is* the state: it
 * survives reinstalls, it is what the launcher reads, and a mirror in
 * SharedPreferences could only ever disagree with it.
 */
enum class AppIcon(private val className: String) {
    /** Follows the system theme. The manifest default. */
    AUTO("com.allthingsclaude.battery.IconAuto"),
    LIGHT("com.allthingsclaude.battery.IconLight"),
    DARK("com.allthingsclaude.battery.IconDark");

    /**
     * Fully qualified, not `packageName + ".IconAuto"`.
     *
     * `android:name=".IconAuto"` expands against the manifest namespace
     * (`com.allthingsclaude.battery`), while `packageName` returns the
     * applicationId (`…battery.android`, plus `.debug` on a debug build). The
     * two differ, and building the name from packageName would look right and
     * resolve to nothing. WidgetParts and LiveUpdateNotifier name MainActivity
     * the same way, for the same reason.
     */
    private fun component(context: Context) = ComponentName(context.packageName, className)

    companion object {

        /**
         * The icon in use, read from component state rather than remembered.
         *
         * Nothing is explicitly enabled until the user picks something, so the
         * manifest default — [AUTO] — is the answer when no component reports
         * ENABLED. That is why this cannot test for "not disabled": [AUTO]'s
         * state is DEFAULT, not ENABLED, on a fresh install.
         */
        fun current(context: Context): AppIcon {
            val pm = context.packageManager
            return entries.firstOrNull { icon ->
                runCatching {
                    pm.getComponentEnabledSetting(icon.component(context))
                }.getOrNull() == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } ?: AUTO
        }

        /**
         * Switch to [chosen].
         *
         * Enables the new alias **before** disabling the others, so there is
         * never an instant with no enabled launcher component — the state in
         * which a launcher would have grounds to prune the shortcut pointing at
         * the app. A precaution rather than a fix for anything observed: in this
         * order the shortcut survives on One UI 8.5, and the claim that swapping
         * drops it was never reproduced. The other order was never tried, so
         * whether it actually matters is unknown.
         *
         * `DONT_KILL_APP` because the alternative is the process dying under a
         * user who just tapped a radio button. Synchronous, and deliberately not
         * in a coroutine: these are three fast binder calls that must not be
         * interrupted half-applied, and a cancellable wrapper would trade a real
         * correctness risk for a theoretical jank one.
         */
        fun select(context: Context, chosen: AppIcon) {
            val pm = context.packageManager
            pm.setComponentEnabledSetting(
                chosen.component(context),
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP,
            )
            entries.filter { it != chosen }.forEach { other ->
                pm.setComponentEnabledSetting(
                    other.component(context),
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }
        }
    }
}
