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
import com.allthingsclaude.battery.core.UsageForecast
import com.allthingsclaude.battery.core.UsageLevel
import com.allthingsclaude.battery.core.BatteryPalette
import com.allthingsclaude.battery.core.TimeFormatting
import com.allthingsclaude.battery.core.UsagePayload
import com.allthingsclaude.battery.ui.UsageRingRenderer
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Builds and posts the Live Update — the prominent lock-screen card, and the
 * top-of-shade ranking that comes with it.
 *
 * **Measured on a Galaxy S24 Ultra / One UI 8.5, this reaches all of it:**
 * Samsung's Now Bar pill, the status-bar chip, the lock screen, and the top of
 * the shade — on plain AOSP APIs, with no Samsung-specific code whatsoever.
 *
 * The catch is a gate, not an API. One UI 8.5 ships **Developer options ▸ "Live
 * notifications for all apps" turned OFF**, and with it off a promoted
 * notification still gets `FLAG_PROMOTED_ONGOING` and still renders as a
 * lock-screen card — it simply never reaches the Now Bar or the chip. That
 * partial success is what made it look like a missing capability rather than a
 * switch. See android/NOW_BAR.md.
 *
 * An earlier revision carried decompiled `android.ongoingActivityNoti.*` extras
 * on the theory that Samsung's own apps use a private pipeline. They do — the
 * Clock's stopwatch has `mIsPromotion=false` and those extras — but it is not
 * the only way in. Verified by posting with the extras provably absent
 * (`ongoingActivityNoti keys: 0`) and watching the pill appear anyway, so the
 * experiment is deleted rather than shipped.
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
            // One segment spanning the whole bar, coloured by the current level.
            //
            // There used to be three, painting the severity ramp at 75 and 90,
            // and measuring them killed the idea: One UI draws the *unfilled*
            // track at heavy transparency, which flattened BRAND, BRAND_DARK and
            // BRAND_DEEP to within two units of each other (#E1CDC6, #E1CFC7,
            // #DBCBC4), and it paints the *filled* track from the first segment
            // alone — so at 95% the run past 75 was still segment one's colour.
            // All three thresholds ever produced was a gap. The bar read as
            // broken rather than as informative.
            //
            // Dropping segments entirely turns the fill black, because the
            // colour does come from here and nowhere else — `setColor` tints the
            // pill and the chip, not the bar. So: one segment, and it carries
            // the level. The escalation the ramp was for now shows as the whole
            // bar darkening, which is visible where three near-identical washed
            // pastels were not.
            .setProgressSegments(
                listOf(NotificationCompat.ProgressStyle.Segment(100).setColor(level.color))
            )

        style.setProgressPoints(points(payload, percent))

        // The bar has three icon slots — tracker, start and end — and only the
        // tracker moves, because it is pinned to setProgress(). Points and
        // Segments take no icon at all, so a custom marker cannot be placed at
        // an arbitrary position; that is the whole of what the API offers.
        //
        // There is deliberately no start icon. Fixed at zero, it would say the
        // same thing on every card ever posted, and both bookends are drawn
        // *outside* the bar, so it costs width the segments could use.
        //
        // The end icon is conditional for the same reason: at a fixed 100 it is
        // decoration unless its *presence* is the information. So it appears
        // only when the burn rate says this window will actually hit the
        // ceiling — which is also exactly when `points` stops drawing the
        // projection mark, because the projection has left the bar.
        if (willBreachCeiling(payload)) {
            style.setProgressEndIcon(IconCompat.createWithResource(context, R.drawable.ic_bar_end))
        }

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_battery)
            .setContentTitle(if (didReset) "Session reset" else title(payload))
            // Renders as a circular badge at the top right of the expanded card
            // and the shade entry. Ignored by the collapsed Now Bar pill, which
            // draws the small icon on a coloured disc instead — so this is the
            // only place the ring reaches a lock screen.
            .setLargeIcon(UsageRingRenderer.renderBadge(payload.sessionUtilization))
            .setContentText(
                if (didReset) "A fresh 5-hour window just opened." else headline(payload)
            )
            // An alerting update makes a sound and shows a banner. Only ever set
            // on a level crossing — SessionPolicy guarantees at most one per
            // level, because re-alerting on every poll at 91% is how a user
            // learns to swipe the card away. (And if they do, CardDismissal
            // stops it coming back.)
            .setOnlyAlertOnce(alertLevel == null)
            .setStyle(style)
            // ── The four clauses that make this a Live Update ───────────────
            .setOngoing(true)
            .setRequestPromotedOngoing(true)
            // …plus: contentTitle set above, no custom RemoteViews, not a group
            // summary, not colorized, channel not IMPORTANCE_MIN.
            // ───────────────────────────────────────────────────────────────
            // Drives TWO surfaces: the status-bar chip, and the second line of
            // the Now Bar pill. See criticalText for why that matters.
            .setShortCriticalText(criticalText(payload))
            // AOSP does not require a category. Samsung might switch on one, and
            // a burning-down quota is a progress journey by any reading, so this
            // is a free shot at the Now Bar gate.
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            // Tints the status-bar chip and the Now Bar pill. Without it the
            // system default (blue) is used — Samsung's own Clock sets
            // color=0xff5f57d9 and its chip is that purple, which is what
            // identified this as the mechanism.
            //
            // NOT setColorized(true): that fills the whole notification
            // background and is one of the clauses that disqualifies a
            // notification from being promoted at all.
            .setColor(level.color)
            .setContentIntent(openAppIntent(context))

        if (payload.planTier.isNotEmpty()) builder.setSubText(payload.planTier)

        // Dismissal detection. Reposting a card the user swiped away is what
        // drives people to revoke an app's promotion permission, and that
        // revocation is effectively permanent — so the service has to be able to
        // find out. On Android 14+ a foreground service's notification can be
        // dismissed even while the service runs, so this genuinely fires.
        builder.setDeleteIntent(dismissIntent(context, payload))

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

    /**
     * Tapping the card opens the app.
     *
     * Points at MainActivity rather than a trampoline: Android 12+ blocks a
     * notification from launching an activity via a broadcast or service
     * receiver, so the target has to be the activity itself.
     */
    private fun openAppIntent(context: Context): android.app.PendingIntent {
        val intent = Intent()
            .setClassName(context, "com.allthingsclaude.battery.MainActivity")
            .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return android.app.PendingIntent.getActivity(
            context,
            0,
            intent,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                android.app.PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * The card for "signed in, nothing fetched yet".
     *
     * A foreground service has seconds to call `startForeground` or the system
     * kills it, so on a fresh install whose first poll has not returned it must
     * post *something*. That obligation is to post, not to post numbers — and
     * the previous fallback was [UsagePayload.PLACEHOLDER], demo data reading
     * 87% with a plan badge and a live countdown, indistinguishable on a lock
     * screen from a real reading for an account that had used nothing. If that
     * first poll then failed, the backoff held it there for as long as the
     * failures lasted.
     *
     * No ProgressStyle: a bar at zero is still a claim about usage.
     */
    fun buildWaiting(context: Context): Notification =
        NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_battery)
            .setContentTitle("Battery")
            .setContentText("Waiting for the first update…")
            .setOngoing(true)
            .setRequestPromotedOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setColor(UsageLevel.LOW.color)
            .setContentIntent(openAppIntent(context))
            .build()

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
     * Carries the window that was on screen, so the dismissal can be scoped to
     * it rather than suppressing the card forever.
     *
     * FLAG_UPDATE_CURRENT because the window changes across posts and a cached
     * PendingIntent would keep delivering the first window we ever showed.
     */
    private fun dismissIntent(context: Context, payload: UsagePayload): android.app.PendingIntent {
        val intent = Intent(context, CardDismissedReceiver::class.java)
            .setAction(CardDismissedReceiver.ACTION)
            .putExtra(
                CardDismissedReceiver.EXTRA_WINDOW,
                payload.sessionResetsAt?.toEpochMilli() ?: -1L,
            )
        return android.app.PendingIntent.getBroadcast(
            context,
            0,
            intent,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                android.app.PendingIntent.FLAG_IMMUTABLE,
        )
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

    /**
     * The one string One UI shows in both the status-bar chip and the second
     * line of the Now Bar pill.
     *
     * Those two want different things, which is the whole difficulty. The chip
     * is a tiny always-on glance and wants the number that matters most; the
     * pill's second line sits under a title that already says the session
     * percentage, so repeating it there is wasted space — the card read
     * "Claude · 9%" over "9%", which is what prompted this.
     *
     * Resolved with [UsagePayload.focusWindow], which already exists for exactly
     * this judgement: lead with whichever window is closer to its ceiling. Early
     * in a session the weekly is the tighter constraint, so the line reads
     * "wk 28%" and adds something; late in a session the session leads and the
     * chip shows the number that actually matters, at the cost of agreeing with
     * the title.
     *
     * Budget is ~7 characters — the chip is capped at 96dp and drops to
     * icon-only if the text doesn't fit whole. "wk 28%" is six.
     */
    /**
     * The pill's first line, and the shade title.
     *
     * Carries **both** windows, which the measurement says it can afford: the
     * collapsed pill ellipsises at roughly 23 characters and this is nineteen at
     * its longest. Leading with the time is not decoration — `setWhen` plus
     * `setChronometerCountDown` gives a free ticking countdown in the *shade*
     * header, and it does not render on the lock screen at all, so without it
     * here the one number the pill can't otherwise show is missing from the
     * surface it matters most on.
     *
     * The cost of spelling it out is that it only moves when we repost, so it
     * steps in three-minute jumps and is stale in between, where the shade's
     * chronometer ticks every second for free. Minutes-scale staleness on a
     * five-hour window reads as fine; seconds-scale would not.
     */
    private fun title(payload: UsagePayload): String {
        val weekly = payload.weeklyUtilization.roundToInt()
        return listOfNotNull(glance(payload), "wk $weekly%").joinToString(" · ")
    }

    /**
     * `11% · 1h17m` — percentage first, then time left in the window.
     *
     * The same order the macOS menu bar uses, deliberately: this is the string
     * the eye lands on in three different places (the chip, the pill's second
     * line, the front of the title) and someone running both apps should not
     * have to read them differently.
     */
    private fun glance(payload: UsagePayload, separator: String = " · "): String =
        listOfNotNull("${payload.sessionUtilization.roundToInt()}%", remaining(payload))
            .joinToString(separator)

    /** Time left in the session window, compact: `1h17m`, `47m`. Null once past. */
    private fun remaining(payload: UsagePayload): String? = payload.sessionResetsAt
        ?.let { (it.toEpochMilli() - System.currentTimeMillis()) / 1000.0 }
        ?.takeIf { it > 0 }
        ?.let { TimeFormatting.shortDuration(it).replace(" ", "") }

    /**
     * The status-bar chip, and the pill's second line — one string, two
     * surfaces, and they do not have the same room. At 22 characters the pill
     * rendered all of it while the chip marqueed, scrolling text beside the
     * clock. So this is sized for the chip, and the pill's second line is left
     * short rather than the chip left moving.
     *
     * Session only, not [UsagePayload.focusWindow]. Both windows already appear
     * in [title]; what the chip wants is the fast-moving one a reader can still
     * act on.
     */
    private fun criticalText(payload: UsagePayload): String =
        "${payload.sessionUtilization.roundToInt()}%"

    /**
     * The marks on the bar. At most two, and they answer different questions.
     *
     * **The pace mark** sits where the clock is — [UsagePayload.elapsedPercent].
     * It is the only thing on the card that says whether you are ahead of or
     * behind budget right now; the tracker says how much is gone and the body
     * text says where it will land, and neither of those is the same question.
     *
     * **The projection mark** sits where the burn rate says the window will
     * finish. It duplicates the body text in words, so it earns its place only
     * when it is visibly clear of the tracker.
     *
     * Both are suppressed when they would land within [MARK_CLEARANCE] of
     * something else. A point renders as a chunky rounded block, not a hairline,
     * and two of them touching read as one wide smear rather than as two marks.
     *
     * The block is not stylable. `setSemanticStyle` takes
     * `NotificationCompat.SEMANTIC_STYLE_*` — UNSPECIFIED/INFO/SAFE/CAUTION/
     * DANGER — and those pick a *colour*, never a shape. They are also API 37
     * and this ships to 36, so on the test device all five render identically;
     * see android/NOW_BAR.md.
     */
    private fun points(
        payload: UsagePayload,
        percent: Int,
    ): List<NotificationCompat.ProgressStyle.Point> {
        val marks = mutableListOf<NotificationCompat.ProgressStyle.Point>()

        val pace = payload.elapsedPercent()
        if (pace != null && abs(pace - percent) > MARK_CLEARANCE) {
            marks += NotificationCompat.ProgressStyle.Point(pace)
                .setColor(BatteryPalette.SECONDARY)
        }

        val projected = projectedAtReset(payload)
        if (projected != null &&
            projected - percent > MARK_CLEARANCE &&
            marks.none { abs(it.position - projected) <= MARK_CLEARANCE }
        ) {
            marks += NotificationCompat.ProgressStyle.Point(projected)
                .setColor(UsageLevel.from(projected.toDouble()).color)
        }

        return marks
    }

    /**
     * How far apart two marks must be, in percentage points, to be worth drawing
     * separately. Sized from the rendered block, not from the data.
     */
    private const val MARK_CLEARANCE = 2

    // ── Forecast ────────────────────────────────────────────────────────────
    //
    // Both of these come from UsageForecast, which exists so that every surface
    // talking about a projection agrees on the numbers, the outlook AND the
    // wording. An earlier revision inlined its own approximations here, and the
    // in-app card and the lock-screen card promptly disagreed for the same
    // payload — "Hits 100% in 125m" against "Hits 100% in 2h 5m", and a bare
    // "58% left in this window" where the forecast knew the window was idle.
    // That contradiction is the exact failure the type was designed to prevent.

    private fun headline(payload: UsagePayload): String = UsageForecast(payload).headline

    /**
     * The projected landing point, as a mark on the bar — but only when it means
     * something. A projection that clamps to 100 puts the Point on the bar's end
     * cap, where it is invisible and indistinguishable from decoration.
     */
    private fun projectedAtReset(payload: UsagePayload): Int? {
        val forecast = UsageForecast(payload)
        if (forecast.pace == UsageForecast.Pace.NONE) return null
        val projected = forecast.projectedAtReset.roundToInt()
        return projected.takeIf { it < 100 }
    }

    /**
     * Whether this window is forecast to run out before it resets.
     *
     * The complement of [projectedAtReset]'s `< 100` guard: where that stops
     * drawing a mark because the projection has left the bar, this notices the
     * same thing and puts the icon where the projection went.
     */
    private fun willBreachCeiling(payload: UsagePayload): Boolean {
        val forecast = UsageForecast(payload)
        return forecast.pace != UsageForecast.Pace.NONE &&
            forecast.projectedAtReset.roundToInt() >= 100
    }
}
