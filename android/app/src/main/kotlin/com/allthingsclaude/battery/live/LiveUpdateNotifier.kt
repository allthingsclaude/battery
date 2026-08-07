package com.allthingsclaude.battery.live

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.os.Build
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
 * Builds and posts the Live Update — the notification that reaches Samsung's Now
 * Bar, the lock screen, the AOD and the status-bar chip.
 *
 * The Now Bar is not a Samsung API. One UI 8 wired it to Android 16's Live
 * Updates, so this is plain AOSP: satisfy every clause in
 * [hasPromotableCharacteristics] and the card appears on all four surfaces at
 * once. Nothing here is Galaxy-specific.
 *
 * The failure mode worth knowing: if *any* qualification clause is missed, the
 * notification still posts and still looks correct in the shade — it simply never
 * reaches the Now Bar, and nothing is logged to say why. That silence is why
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

    fun build(context: Context, payload: UsagePayload): Notification {
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
            .setContentTitle("Claude · $percent%")
            .setContentText(headline(payload))
            .setStyle(style)
            // ── The four clauses that make this a Live Update ───────────────
            .setOngoing(true)
            .setRequestPromotedOngoing(true)
            // …plus: contentTitle set above, no custom RemoteViews, not a group
            // summary, not colorized, channel not IMPORTANCE_MIN.
            // ───────────────────────────────────────────────────────────────
            // The status-bar chip. Max width is 96dp and text only renders in
            // full under ~7 characters, so "87%" is the whole budget.
            .setShortCriticalText("$percent%")

        if (payload.planTier.isNotEmpty()) builder.setSubText(payload.planTier)

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

    fun post(context: Context, payload: UsagePayload) {
        ensureChannel(context)
        NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, build(context, payload))
    }

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
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
        return sb.toString().trim()
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
