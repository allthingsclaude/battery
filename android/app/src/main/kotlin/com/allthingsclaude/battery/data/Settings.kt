package com.allthingsclaude.battery.data

import android.content.Context
import com.allthingsclaude.battery.core.ReleaseFeed
import com.allthingsclaude.battery.core.SessionPolicy

/**
 * User preferences. Mirrors `ios/BatteryApp/Settings.swift`.
 *
 * The app-icon choice is deliberately not here. It is not a preference the app
 * stores — it is which `activity-alias` is enabled, which PackageManager already
 * persists and which the launcher reads directly. A copy in these prefs could
 * only ever disagree with the icon actually on the home screen. See
 * [com.allthingsclaude.battery.launcher.AppIcon].
 *
 * This comment used to say a picker was impossible, because alias swapping
 * "drops the user's home-screen shortcut on One UI". That is not true. Measured
 * on One UI 8.5: a shortcut survives MainActivity giving up its LAUNCHER filter
 * to an alias, and survives repeated swaps between aliases afterwards.
 *
 * Why the original note said otherwise is unknown — an older One UI, or a
 * different swap order, or something else. `AppIcon.select` enables before it
 * disables, which would avoid the failure if ordering was the cause, but that is
 * a precaution rather than a diagnosis: nobody has reproduced the drop.
 */
class Settings(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("settings", Context.MODE_PRIVATE)

    /**
     * When the lock-screen card should exist. Defaults to [SessionPolicy.Mode.SMART]
     * — quietest — but [SessionPolicy.Mode.WHENEVER_OPEN] is the one for anyone
     * who wants the meter up for the whole window.
     */
    var cardMode: SessionPolicy.Mode
        get() = prefs.getString(KEY_CARD_MODE, null)
            ?.let { raw -> SessionPolicy.Mode.entries.firstOrNull { it.name == raw } }
            ?: SessionPolicy.Mode.SMART
        set(value) = prefs.edit().putString(KEY_CARD_MODE, value.name).apply()

    /** When the automatic update check last ran, epoch millis. 0 means never. */
    var lastUpdateCheckAt: Long
        get() = prefs.getLong(KEY_LAST_UPDATE_CHECK, 0L)
        set(value) = prefs.edit().putLong(KEY_LAST_UPDATE_CHECK, value).apply()

    /**
     * The release the last check found, remembered across launches.
     *
     * Without this the notice is a lottery. The check runs once a day, so whether
     * the user ever sees it depends on which launch they happen to make — open the
     * app on a resume where the throttle says "not due" and there is nothing to
     * show, with the next chance tomorrow. Storing it makes "an update exists" a
     * fact about the install rather than a fact about one particular resume.
     *
     * Cleared when a check comes back [ReleaseFeed.Check.UpToDate], which is how
     * the notice disappears after the user actually updates. Deliberately NOT
     * cleared on a failure — a GitHub outage is no reason to forget a release we
     * already know about.
     */
    var pendingUpdate: ReleaseFeed.Release?
        get() {
            val version = prefs.getString(KEY_PENDING_VERSION, null) ?: return null
            val url = prefs.getString(KEY_PENDING_URL, null) ?: return null
            return ReleaseFeed.Release(version, url)
        }
        set(value) = prefs.edit()
            .putString(KEY_PENDING_VERSION, value?.version)
            .putString(KEY_PENDING_URL, value?.url)
            .apply()

    /**
     * The newest version the user has dismissed from the status line, so the
     * notice stops nagging without also hiding the release after it.
     */
    var skippedVersion: String?
        get() = prefs.getString(KEY_SKIPPED_VERSION, null)
        set(value) = prefs.edit().putString(KEY_SKIPPED_VERSION, value).apply()

    /**
     * Once a day, not once a resume.
     *
     * The launch check hangs off `repeatOnLifecycle(RESUMED)`, which fires every
     * time the app comes back from the background — dozens of times a day for an
     * app whose whole job is a quick glance at a number. Unthrottled that is
     * dozens of GitHub requests against an unauthenticated quota of sixty an hour
     * per IP, spent on an answer that changes a few times a year.
     *
     * `abs`, for the reason `UsageRepository.pollLocked` uses it: a device whose
     * clock jumps backwards leaves a stored timestamp in the future, and a signed
     * comparison would then read as "checked recently" until real time caught up.
     */
    fun isUpdateCheckDue(now: Long = System.currentTimeMillis()): Boolean =
        kotlin.math.abs(now - lastUpdateCheckAt) >= UPDATE_CHECK_INTERVAL_MS

    private companion object {
        const val KEY_CARD_MODE = "card_mode"
        const val KEY_LAST_UPDATE_CHECK = "last_update_check_at"
        const val KEY_SKIPPED_VERSION = "skipped_version"
        const val KEY_PENDING_VERSION = "pending_update_version"
        const val KEY_PENDING_URL = "pending_update_url"

        const val UPDATE_CHECK_INTERVAL_MS = 24L * 60 * 60 * 1000
    }
}

/** Titles and one-line explanations, kept beside the enum they describe. */
val SessionPolicy.Mode.title: String
    get() = when (this) {
        SessionPolicy.Mode.OFF -> "Off"
        SessionPolicy.Mode.SMART -> "Smart"
        SessionPolicy.Mode.WHENEVER_OPEN -> "Whole session"
    }

val SessionPolicy.Mode.subtitle: String
    get() = when (this) {
        SessionPolicy.Mode.OFF -> "Never show a lock-screen card"
        SessionPolicy.Mode.SMART -> "While a session is open and in use"
        SessionPolicy.Mode.WHENEVER_OPEN -> "Any time a 5-hour window is open, at any percentage"
    }
