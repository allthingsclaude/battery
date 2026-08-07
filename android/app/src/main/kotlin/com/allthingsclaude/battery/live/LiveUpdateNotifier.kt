package com.allthingsclaude.battery.live

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.allthingsclaude.battery.R
import com.allthingsclaude.battery.core.USAGE_RAMP_SEGMENTS
import com.allthingsclaude.battery.core.UsageLevel
import com.allthingsclaude.battery.core.UsagePayload
import kotlin.math.roundToInt

/**
 * Builds and posts the Live Update — the prominent lock-screen card, and the
 * top-of-shade ranking that comes with it.
 *
 * **What this reaches, measured on a Galaxy S24 Ultra / One UI 8.5:** the
 * lock-screen card and the shade. **What it does not:** the status-bar chip
 * (One UI draws the small icon instead) or Samsung's bottom Now Bar pill.
 *
 * One UI appears to run two pipelines. AOSP's promoted notifications — which
 * this satisfies completely, verified by `FLAG_PROMOTED_ONGOING` on a live post
 * — drive the lock-screen card. Samsung's own apps reach the Now Bar and the
 * chip through a *private* ongoing-activity path instead, using
 * `android.ongoingActivityNoti.*` extras and a `com.samsung.android.support.ongoing_activity`
 * manifest entry, and use none of the AOSP promoted APIs at all. Evidence
 * suggests that path is package-whitelisted.
 *
 * So [samsungExtrasEnabled] and the manifest meta-data are live experiments, not
 * dependencies. Everything the app promises works on the AOSP path alone.
 *
 * The failure mode worth knowing: if *any* qualification clause is missed, the
 * notification still posts and still looks correct in the shade — it simply
 * never gets promoted, and nothing is logged to say why. That silence is why
 * [diagnose] exists.
 */
object LiveUpdateNotifier {

    private const val CHANNEL_ID = "session"
    const val NOTIFICATION_ID = 1

    /**
     * IMPORTANCE_DEFAULT, not LOW or MIN. A channel at IMPORTANCE_MIN disqualifies
     * the notification from promotion outright — one of the eight clauses.
     */
    fun ensureChannel(context: Context) {
        val channel = NotificationChannelCompat
            .Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_DEFAULT)
            .setName("Session usage")
            .setDescription("Your live Claude Code 5-hour session window")
            .build()
        NotificationManagerCompat.from(context).createNotificationChannel(channel)
    }

    /**
     * Undocumented Samsung extras, recovered by decompiling Samsung Clock /
     * Health / Voice Recorder. Off by default — this is an experiment toggle so
     * the hypothesis can be A/B'd on device without a rebuild, not something the
     * app relies on. See [buildSamsungExtras].
     */
    @Volatile
    var samsungExtrasEnabled: Boolean = false

    fun build(
        context: Context,
        payload: UsagePayload,
        didReset: Boolean = false,
        alertLevel: UsageLevel? = null,
    ): Notification {
        val percent = payload.sessionUtilization.roundToInt().coerceIn(0, 100)
        val level = UsageLevel.from(payload.sessionUtilization)

        val style = NotificationCompat.ProgressStyle()
            // The tracker sits at the live value; segments below paint the ramp.
            .setProgress(percent)
            .setProgressTrackerIcon(IconCompat.createWithResource(context, R.drawable.ic_tracker))
            .setProgressSegments(
                USAGE_RAMP_SEGMENTS.map { (length, color) ->
                    NotificationCompat.ProgressStyle.Segment(length).setColor(color)
                }
            )

        // The projection as a mark on the bar. iOS hand-draws this tick in
        // ForecastBar; here the platform owns it. Only shown once it's visibly
        // ahead of the tracker — a point sitting under the tracker reads as a
        // rendering bug rather than as information.
        val projected = projectedAtReset(payload)
        if (projected != null && projected - percent > 2) {
            style.setProgressPoints(
                listOf(
                    NotificationCompat.ProgressStyle.Point(projected)
                        .setColor(UsageLevel.from(projected.toDouble()).color)
                )
            )
        }

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_battery)
            .setContentTitle(if (didReset) "Session reset" else "Claude · $percent%")
            .setContentText(
                if (didReset) "A fresh 5-hour window just opened." else headline(payload)
            )
            // An alerting update makes a sound and shows a banner. Only ever set
            // on a level crossing — SessionPolicy guarantees at most one per
            // level, because re-alerting on every poll at 91% is how a user
            // learns to swipe the card away, and a dismissed Live Update must
            // never be reposted.
            .setOnlyAlertOnce(alertLevel == null)
            .setStyle(style)
            // ── The four clauses that make this a Live Update ───────────────
            .setOngoing(true)
            .setRequestPromotedOngoing(true)
            // …plus: contentTitle set above, no custom RemoteViews, not a group
            // summary, not colorized, channel not IMPORTANCE_MIN.
            // ───────────────────────────────────────────────────────────────
            // The status-bar chip. Max width is 96dp and text only renders in
            // full under ~7 characters, so "87%" is the whole budget.
            //
            // Verified NOT rendered by One UI 8.5 (Phase 0) — Samsung draws the
            // small icon instead. Kept because it is the correct AOSP API, costs
            // one call, is inert when unrendered, and lights up for free if One
            // UI ever adopts the AOSP chip.
            .setShortCriticalText("$percent%")
            // AOSP does not require a category. Samsung might switch on one, and
            // a burning-down quota is a progress journey by any reading, so this
            // is a free shot at the Now Bar gate.
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)

        if (payload.planTier.isNotEmpty()) builder.setSubText(payload.planTier)

        if (samsungExtrasEnabled) builder.addExtras(buildSamsungExtras(percent, level))

        // The countdown to reset, ticked by the system with zero updates from us —
        // the direct analogue of iOS's `Text(resetsAt, style: .relative)`.
        payload.sessionResetsAt?.let { resetsAt ->
            builder.setWhen(resetsAt.toEpochMilli())
                .setShowWhen(true)
                .setUsesChronometer(true)
                .setChronometerCountDown(true)
        }

        return builder.build()
    }

    fun post(
        context: Context,
        payload: UsagePayload,
        didReset: Boolean = false,
        alertLevel: UsageLevel? = null,
    ) {
        ensureChannel(context)
        NotificationManagerCompat.from(context)
            .notify(NOTIFICATION_ID, build(context, payload, didReset, alertLevel))
    }

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
    }

    /**
     * Samsung's private ongoing-activity payload. `style = 1` asks for both the
     * notification and the Now Bar (0 = notification only, 2 = Now Bar only).
     *
     * Every key here is decompilation-derived from Samsung's own apps, not
     * documented anywhere, and the evidence says the pipeline is probably
     * package-whitelisted — so treat a success here as a discovery and a failure
     * as the expected outcome. Unrecognised extras are ignored by the platform,
     * so this cannot break the AOSP card we already have.
     */
    private fun buildSamsungExtras(percent: Int, level: UsageLevel): Bundle =
        Bundle().apply {
            putInt("android.ongoingActivityNoti.style", 1)
            putInt("android.ongoingActivityNoti.chipBgColor", level.color)
            putString("android.ongoingActivityNoti.chipExpandedText", "$percent%")
            putString("android.ongoingActivityNoti.primaryInfo", "Claude · $percent%")
            putString("android.ongoingActivityNoti.nowbarPrimaryInfo", "Claude · $percent%")
            putInt("android.ongoingActivityNoti.progress", percent)
            putInt("android.ongoingActivityNoti.progressMax", 100)
        }

    /**
     * Everything the system will tell us about whether this card was actually
     * promoted. Without it the only symptom of a failed clause is an absence.
     */
    fun diagnose(context: Context, payload: UsagePayload): String {
        val nm = context.getSystemService(NotificationManager::class.java)
        val notification = build(context, payload)

        val sb = StringBuilder()
        sb.appendLine("API level        ${Build.VERSION.SDK_INT} (need 36+)")
        sb.appendLine("notifications on ${NotificationManagerCompat.from(context).areNotificationsEnabled()}")

        if (Build.VERSION.SDK_INT >= 36) {
            sb.appendLine("canPostPromoted  ${nm.canPostPromotedNotifications()}")
            sb.appendLine("hasPromotable    ${notification.hasPromotableCharacteristics()}")
            val posted = nm.activeNotifications.firstOrNull { it.id == NOTIFICATION_ID }
            val promoted = posted?.notification?.flags?.and(Notification.FLAG_PROMOTED_ONGOING) ?: 0
            sb.appendLine("FLAG_PROMOTED    ${if (posted == null) "not posted yet" else (promoted != 0).toString()}")
        } else {
            sb.appendLine("Live Updates need API 36 — this device can't promote.")
        }

        // Does this device even advertise the Now Bar? Samsung's own apps gate
        // their ongoing-activity code on exactly this feature string.
        val pm = context.packageManager
        sb.appendLine("feature.nowbar    ${pm.hasSystemFeature("com.samsung.feature.nowbar")}")
        sb.appendLine("samsung extras    ${if (samsungExtrasEnabled) "ON (experiment)" else "off"}")
        return sb.toString().trim()
    }

    /**
     * Opens the system screen governing promoted notifications for this app.
     * Which screen One UI actually lands on is itself a finding: a dedicated
     * per-app Live-notifications toggle means AOSP's surface is wired up and
     * that toggle is the gate; the generic app-notification screen means it
     * isn't, which would corroborate the two-pipeline theory.
     */
    fun promotedNotificationSettingsIntent(context: Context): Intent? {
        if (Build.VERSION.SDK_INT < 36) return null
        // NOTE: the Android developer docs call this
        // `ACTION_MANAGE_APP_PROMOTED_NOTIFICATIONS`. That constant does not
        // exist in the SDK — the real one is below. Verified against
        // platforms/android-37.1/android.jar.
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        return intent.takeIf { it.resolveActivity(context.packageManager) != null }
    }

    // ── Placeholders until Phase 1 lands ────────────────────────────────────
    // Both of these belong to UsageForecast (ios/BatteryKit/UsageForecast.swift),
    // which is the Phase 1 port. They are inlined here only so the spike can post
    // a truthful-looking card; the moment core/ has UsageForecast, both go away
    // and this file calls it instead. Deliberately kept crude so nobody mistakes
    // them for the real thing.

    private fun headline(payload: UsagePayload): String {
        val limit = payload.liveProjectedLimitAt() ?: return "${(100 - payload.sessionUtilization).roundToInt()}% left in this window"
        val minutes = ((limit.epochSecond - java.time.Instant.now().epochSecond) / 60).coerceAtLeast(0)
        return "Hits 100% in ${minutes}m"
    }

    private fun projectedAtReset(payload: UsagePayload): Int? {
        if (payload.burnRatePerHour <= 0.05) return null
        val hoursLeft = payload.sessionSecondsRemaining() / 3600.0
        return (payload.sessionUtilization + payload.burnRatePerHour * hoursLeft)
            .coerceIn(0.0, 100.0).roundToInt()
    }
}
