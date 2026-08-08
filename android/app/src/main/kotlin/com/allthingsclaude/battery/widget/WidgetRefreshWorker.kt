package com.allthingsclaude.battery.widget

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
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

        // Kept, not scaffolding. A periodic worker is invisible by nature —
        // WorkManager refuses to run one early even when JobScheduler is forced,
        // so the only way to know it fires at all is to say so. Verifying this
        // one took a sixteen-minute wait and an inference from a changed job id.
        Log.i(TAG, "refresh: payload age=${ageSeconds(repository)}s")

        // Repaint first and unconditionally. This is the part that fixes the
        // reported defect, it needs no network, and it must still happen when
        // the poll below is skipped or fails — recomposing against the stored
        // payload is what re-evaluates every "in 2h 13m" against the clock.
        refreshWidgets()

        if (!repository.isSignedIn()) return Result.success()

        // Polling is the *optional* half, and deliberately conditional. This
        // worker runs whether or not anyone is looking, so an unconditional
        // fetch every fifteen minutes would be ninety-six requests a day spent
        // largely on an idle account — and this account has already been
        // rate-limited by nothing worse than an app being reopened repeatedly.
        //
        // The service polls every three minutes while a card is up, so any
        // payload older than STALE_AFTER_SECONDS means the service is not
        // running: nothing else is going to refresh these numbers.
        val payload = repository.lastKnownPayload
        // abs for the same reason as the repository's freshness gate: a backward
        // clock jump makes a signed age negative, and a negative age reads as
        // "fresh" and skips the poll indefinitely.
        val age = payload?.let { abs(Instant.now().epochSecond - it.updatedAt.epochSecond) }
        if (age == null || age >= STALE_AFTER_SECONDS) {
            when (val result = repository.poll()) {
                // poll() repaints the widgets itself on success.
                is UsageRepository.PollResult.Success -> runCatching { postCardIfWarranted(result.payload) }
                    .onFailure { Log.w(TAG, "card post skipped: $it") }
                is UsageRepository.PollResult.Failed -> {
                    // Retry is WorkManager's exponential backoff, which is the
                    // right shape here — but the widgets are already repainted
                    // above, so a failure costs freshness and not correctness.
                    Log.w(TAG, "background poll failed: ${result.message}")
                    return Result.retry()
                }
                else -> Unit
            }
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
        private const val WORK_NAME = "widget-refresh"

        /**
         * Fifteen minutes is not a choice — it is `PeriodicWorkRequest`'s
         * floor. Anything smaller is silently clamped to it.
         */
        private const val INTERVAL_MINUTES = 15L

        /**
         * How old a payload must be before this worker spends a request on it.
         *
         * Just over the interval, so a worker that fires slightly early (Doze
         * batching moves these around by minutes) does not poll twice in a row
         * for the same window.
         */
        private const val STALE_AFTER_SECONDS = 14L * 60

        /**
         * Schedule the refresh, or leave the existing schedule alone.
         *
         * `KEEP`, not `UPDATE`: `UPDATE` restarts the period, so calling this on
         * every widget placement would push the next run fifteen minutes out
         * each time and a user rearranging their home screen would see nothing
         * refresh at all.
         */
        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<WidgetRefreshWorker>(
                INTERVAL_MINUTES,
                TimeUnit.MINUTES,
            )
                // Only the poll needs a network; the repaint does not, and it is
                // the repaint that matters. But a worker that runs offline can
                // only ever repaint, so requiring connectivity costs nothing a
                // reader would notice and saves the wakeup.
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build()
                )
                .build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request,
            )
        }

        /**
         * Bring the schedule in line with reality.
         *
         * `onEnabled` fires only for the *first* widget of a type, so it never
         * fires for anyone who already had widgets before this worker existed —
         * their countdowns would stay frozen forever. Called on every app
         * resume, this also picks up the reverse case, where a schedule outlived
         * the widgets because `onDisabled` was missed.
         */
        fun syncSchedule(context: Context) {
            if (hasAnyWidget(context)) schedule(context) else cancel(context)
        }

        /** Stop refreshing. Called when the last widget is removed. */
        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        }
    }
}
