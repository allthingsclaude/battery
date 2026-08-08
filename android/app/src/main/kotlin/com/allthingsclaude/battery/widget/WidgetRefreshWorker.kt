package com.allthingsclaude.battery.widget

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.allthingsclaude.battery.core.SessionPolicy
import com.allthingsclaude.battery.core.UsagePayload
import com.allthingsclaude.battery.data.Settings
import com.allthingsclaude.battery.data.UsageRepository
import com.allthingsclaude.battery.live.CardDismissal
import com.allthingsclaude.battery.live.LiveUpdateNotifier
import java.time.Instant
import kotlin.math.abs
import java.util.concurrent.TimeUnit

/**
 * Keeps home-screen widgets from lying.
 *
 * A Glance widget is a `RemoteViews` tree built once and then frozen. Everything
 * it says about time — "resets in 2h 13m" — is a string sampled at composition,
 * not a ticking clock, and the only thing that ever rebuilt it was a *successful
 * network poll* from an app that may not be running. So a widget could sit on
 * the home screen reading "resets in 2h 13m" for a day and a half. The countdown
 * did not merely go stale; it stated a falsehood with a straight face.
 *
 * There is no lighter fix. Glance has no ticking primitive, all four provider
 * XMLs set `updatePeriodMillis="0"` (the platform's own periodic update has a
 * thirty-minute floor and wakes the device), and wrapping an `AndroidRemoteViews`
 * `Chronometer` would tick the countdown while leaving every percentage frozen —
 * arguably worse, because a live-looking clock implies live-looking numbers.
 *
 * Two comments in the codebase (`SnapshotPrefs`, `SessionHistory`) already
 * described this class as though it existed. It did not.
 */
class WidgetRefreshWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val repository = UsageRepository(applicationContext)

        // A periodic worker is invisible by nature, so the only way to know it
        // fires at all is to say so. This line is what showed the worker sitting
        // out three consecutive windows while the app was frozen.
        Log.i(TAG, "refresh: payload age=${ageSeconds(repository)}s")

        val stored = repository.lastKnownPayload
        // abs for the same reason as the repository's freshness gate: a backward
        // clock jump makes a signed age negative, and a negative age reads as
        // "fresh" and skips the poll indefinitely.
        val age = stored?.let { abs(Instant.now().epochSecond - it.updatedAt.epochSecond) }
        val willPoll = repository.isSignedIn() && (age == null || age >= STALE_AFTER_SECONDS)

        val result = if (willPoll) repository.poll() else null
        val fresh = (result as? UsageRepository.PollResult.Success)?.payload

        // **Exactly one repaint per run, on every path.** `poll()` repaints
        // itself on success; every other path stored nothing, so the repaint has
        // to happen here. Two `updateAll` bursts cancel each other's Glance
        // sessions and *both* compositions are lost — see `refreshAllWidgets`.
        if (fresh == null) refreshWidgets()

        // The card is a render of whatever payload we have, so it needs no
        // network and must not be gated behind a successful poll. It used to be,
        // which left a wide-open window showing no card at all for as long as the
        // poll was skipped or failing.
        (fresh ?: stored)?.let {
            runCatching { postCardIfWarranted(it) }
                .onFailure { e -> Log.w(TAG, "card post skipped: $e") }
        }

        if (result is UsageRepository.PollResult.Failed) {
            // Exponential backoff is the right shape for a failed fetch, and it
            // costs only freshness now that the repaint and the card have both
            // already happened above.
            Log.w(TAG, "background poll failed: ${result.message}")
            return Result.retry()
        }
        return Result.success()
    }

    /**
     * Bring the card back when a window has opened since it went.
     *
     * Closes the hole left by `card ⟺ service ⟺ polling`: when SessionPolicy
     * says Hide the service stops, and with it the only thing that polls, so
     * nothing notices a new five-hour window and the card cannot return until
     * the app is opened by hand.
     *
     * **This posts the notification directly and must not start the service.**
     * The first version called `SessionService.start` and threw
     * `ForegroundServiceStartNotAllowedException` on the first real run — an app
     * in the background cannot start a foreground service on Android 12+, and a
     * WorkManager worker is background by definition. That was a design error,
     * not an oversight in the call.
     *
     * Posting directly is not a workaround for that; it is the correct shape.
     * A foreground service is required to justify *continuous polling*, never to
     * earn promotion — `setOngoing` plus `setRequestPromotedOngoing` is what
     * earns promotion, and an ordinary notification can carry both. The card and
     * the service share one notification id, so when the service does start
     * legitimately — the user opens the app, or taps the card — `startForeground`
     * adopts this very notification rather than replacing it.
     *
     * The real policy is applied rather than approximated. A fresh
     * [SessionPolicy.State] is deliberate: with no previous utilization there is
     * no rollover to detect, and with `isShowing = false` the escalation rule
     * cannot fire — so a background repost can never make a sound. Alerting is
     * for a service watching a session, not for a worker that woke up.
     */
    private fun postCardIfWarranted(payload: UsagePayload) {
        val context = applicationContext
        val mode = Settings(context).cardMode
        if (mode == SessionPolicy.Mode.OFF) return

        val decision = SessionPolicy.evaluate(SessionPolicy.State(), payload, mode).decision
        if (decision !is SessionPolicy.Decision.Show) return

        // The user swiped this window's card away. Reposting it is the single
        // action that costs an app its promotion permission, and the worker is
        // not exempt from that just because it is a background job.
        if (CardDismissal(context).isDismissed(payload.sessionResetsAt)) return

        Log.i(TAG, "posting card from the background; window open at ${payload.sessionUtilization.toInt()}%")
        LiveUpdateNotifier.post(context, payload)
    }

    private fun ageSeconds(repository: UsageRepository): Long? =
        repository.lastKnownPayload?.let { Instant.now().epochSecond - it.updatedAt.epochSecond }

    private suspend fun refreshWidgets() {
        runCatching { refreshAllWidgets(applicationContext) }
            .onFailure { Log.d(TAG, "widget repaint skipped: ${it.message}") }
    }

    companion object {
        private const val TAG = "WidgetRefreshWorker"

        /**
         * Versioned because the work's constraints changed, and `KEEP` would
         * otherwise leave every existing install on the old network-constrained
         * schedule forever. A new name enqueues fresh; [LEGACY_WORK_NAME] is
         * cancelled once so the old one does not linger.
         */
        private const val WORK_NAME = "widget-refresh-v2"
        private const val LEGACY_WORK_NAME = "widget-refresh"

        /**
         * Fifteen minutes is not a choice — it is `PeriodicWorkRequest`'s
         * floor. Anything smaller is silently clamped to it.
         *
         * It also matters less than it looks. On One UI the app is frozen with
         * the screen off and this worker does not run at all — measured at 44
         * minutes idle across three missed windows — so what actually schedules
         * a run is the screen coming on, which releases the overdue job
         * immediately. The period sets the floor on how *often* that can happen,
         * not when.
         */
        private const val INTERVAL_MINUTES = 15L

        /**
         * How old a payload must be before this worker spends a request on it.
         *
         * Three minutes, matching the service's own cadence, because this gate —
         * not the interval — is what decides whether waking the phone shows a
         * current number. At fourteen it routinely re-rendered a figure the Mac
         * had already moved past. The original worry was ninety-six requests a
         * day from an unattended worker, which does not apply to a worker that
         * only runs when someone turns the screen on.
         */
        private const val STALE_AFTER_SECONDS = 3L * 60

        /**
         * Schedule the refresh, or leave the existing schedule alone.
         *
         * `KEEP`, not `UPDATE`: `UPDATE` restarts the period, so calling this on
         * every widget placement would push the next run fifteen minutes out
         * each time and a user rearranging their home screen would see nothing
         * refresh at all.
         */
        fun schedule(context: Context) {
            val manager = WorkManager.getInstance(context)
            manager.cancelUniqueWork(LEGACY_WORK_NAME)

            // **No network constraint, deliberately.** It used to require
            // `NetworkType.CONNECTED` on the grounds that a worker which cannot
            // poll may as well not wake — which had it exactly backwards. A
            // frozen app's network is blocked (`blocked=APP_BACKGROUND`), so the
            // constraint could never be satisfied, so the job never became
            // runnable, so nothing ever thawed the app to run it. The repaint
            // and the card post need no network; the poll fails on its own and
            // retries.
            val request = PeriodicWorkRequestBuilder<WidgetRefreshWorker>(
                INTERVAL_MINUTES,
                TimeUnit.MINUTES,
            ).build()

            manager.enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request,
            )
        }

        /**
         * Bring the schedule in line with reality.
         *
         * **Signed in, not widget-placed.** This used to key off `hasAnyWidget`,
         * which was right while the worker only repainted widgets and wrong the
         * moment it also became the card's way back: someone who wants the
         * lock-screen card and no widgets would have had nothing scheduled at
         * all, so a window opening while the app was closed could never produce
         * a card. The widgets are optional; the card is the app.
         *
         * Called on every app resume, so it self-heals in both directions — a
         * schedule that outlived a sign-out, or an install that predates this.
         */
        fun syncSchedule(context: Context) {
            if (UsageRepository(context).isSignedIn()) schedule(context) else cancel(context)
        }

        /** Stop refreshing. Called when the last widget is removed. */
        fun cancel(context: Context) {
            val manager = WorkManager.getInstance(context)
            manager.cancelUniqueWork(WORK_NAME)
            // Upgrades that never call schedule() — no widget placed — would
            // otherwise leave the pre-v2 schedule running untouched.
            manager.cancelUniqueWork(LEGACY_WORK_NAME)
        }
    }
}
