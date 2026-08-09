package com.allthingsclaude.battery.live

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.allthingsclaude.battery.core.PollBackoff
import com.allthingsclaude.battery.core.SessionPolicy
import com.allthingsclaude.battery.core.UsagePayload
import com.allthingsclaude.battery.data.UsageRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The foreground service whose notification **is** the lock-screen card.
 *
 * This is the architectural centrepiece, and the reason Android needs less code
 * here than iOS: on iOS the poll loop and the Live Activity are separate
 * concerns, reconciled by `LiveActivityController.sync()`. Here they collapse
 * into one:
 *
 *     card exists  ⟺  service running  ⟺  fast polling
 *
 * That also makes the foreground service self-justifying in the way Google's
 * guidelines want. It is not a background poller wearing a notification as a
 * disguise — the notification is the product, and the service exists exactly as
 * long as there is something for the user to watch.
 *
 * **Type is `specialUse`, not `dataSync`.** `dataSync` is capped at six hours per
 * twenty-four (Android 15+), which a back-to-back coding day would blow through;
 * `specialUse` carries no timeout. Distribution is off-Play, so the Play Console
 * justification `specialUse` would otherwise need doesn't apply.
 */
class SessionService : Service() {

    private val scope = CoroutineScope(SupervisorJob())
    private val dismissal by lazy { CardDismissal(this) }
    private val settings by lazy { com.allthingsclaude.battery.data.Settings(this) }
    private var loop: Job? = null
    private var policyState = SessionPolicy.State()
    private val backoff = PollBackoff()

    /**
     * Cuts a poll delay short. Conflated because the signal is "something
     * changed, look again" — two of them pending mean the same as one, and
     * dropping the duplicate is the point rather than a compromise.
     */
    private val wake = Channel<Unit>(Channel.CONFLATED)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // MUST precede startForeground. build() does not create the channel —
        // only post() did — so a fresh install that starts the service without
        // ever posting a card hit `IllegalArgumentException: No Channel found`,
        // which the system converts into "Bad notification for startForeground"
        // and kills the process. Same crash on every START_STICKY restart.
        LiveUpdateNotifier.ensureChannel(this)

        val repo = UsageRepository(this)

        // startForeground must happen within a few seconds of the start request
        // or the system kills us with a ForegroundServiceDidNotStartInTimeException.
        // The last-known payload is the honest thing to show while the first poll
        // is in flight. With no last-known payload the obligation is still to
        // post — but to post that we have nothing, not to invent a number.
        val initial = repo.lastKnownPayload

        // Promote on EVERY start, including one that arrives while the loop is
        // already running, for two independent reasons.
        //
        // The contract one: each startForegroundService call carries its own
        // "you must promote" timer, and already being foreground does not
        // discharge it.
        //
        // The bug one: this is what repaints a stale card. The loop spends
        // nearly all of its life parked in a delay — three minutes normally, up
        // to ten after a failure — and the dashboard polls independently on
        // resume. A poll landing there wrote a fresh payload and refreshed the
        // widgets, but nothing rebuilt the notification, so the app read 10%
        // while the pill, the chip and the lock-screen card all sat at 9% until
        // the loop happened to wake. `lastKnownPayload` is that fresh number.
        promote(
            if (initial != null) LiveUpdateNotifier.build(this, initial)
            else LiveUpdateNotifier.buildWaiting(this)
        )

        if (loop?.isActive == true) {
            // Re-evaluate now rather than whenever the current delay expires —
            // otherwise mode changes and fresh payloads take effect up to ten
            // minutes late. Cheap: the repository's own freshness gate serves
            // this from cache, so waking costs no request.
            wake.trySend(Unit)
            return START_STICKY
        }

        // An already-dismissed window is handled by promoting and immediately
        // standing down rather than by skipping the promote call above.
        if (initial != null && dismissal.isDismissed(initial.sessionResetsAt)) {
            stopWithoutCard()
            return START_NOT_STICKY
        }

        loop = scope.launch { pollLoop(repo) }
        return START_STICKY
    }

    private suspend fun pollLoop(repo: UsageRepository) {
        while (scope.isActive) {
            val result = repo.poll()

            // Drop any wake that arrived *during* the poll. The channel is
            // conflated, so a signal raised while the loop was busy sits in the
            // buffer and makes the next waitOrWake return instantly — including
            // the one that implements the backoff. A failed poll followed by an
            // app resume would therefore retry with no delay at all, which is
            // exactly how the rate limit was earned in the first place. A wake
            // means "look again", and this poll already is the looking.
            wake.tryReceive()

            val payload = when (result) {
                is UsageRepository.PollResult.Success -> result.payload
                UsageRepository.PollResult.SignedOut,
                UsageRepository.PollResult.NoAccount -> {
                    // Nothing to watch and nothing we can fix from here. Leaving
                    // the card up would freeze it at a number that is now a lie.
                    stopWithoutCard()
                    return
                }
                UsageRepository.PollResult.Stale -> {
                    // The account changed mid-poll; this result belongs to
                    // nobody. Skip it and let the next tick fetch the new one.
                    waitOrWake(SessionPolicy.pollIntervalSeconds(SessionPolicy.Decision.Hide))
                    continue
                }
                is UsageRepository.PollResult.Failed -> {
                    // Keep the card at its last known value rather than dropping
                    // it: a transient network blip should not clear the user's
                    // lock screen. `updatedAt` is untouched, so the card ages
                    // visibly instead of pretending to be current.
                    val wait = backoff.recordFailure(result.retryAfterSeconds)
                    Log.w(TAG, "poll failed (${backoff.failureCount}x): ${result.message}; waiting ${wait}s")
                    waitOrWake(wait)
                    continue
                }
            }

            // Re-read every poll rather than caching: changing the mode in
            // settings has to take effect on the next tick, not on a restart.
            backoff.recordSuccess()

            val outcome = SessionPolicy.evaluate(policyState, payload, settings.cardMode)
            policyState = outcome.state

            // The user swiped this window's card away. Reposting it is precisely
            // what costs an app its promotion permission, so stop instead. The
            // dismissal is scoped to the window, so the next one starts clean.
            if (dismissal.isDismissed(payload.sessionResetsAt)) {
                stopWithoutCard()
                return
            }

            when (val decision = outcome.decision) {
                is SessionPolicy.Decision.Show -> {
                    LiveUpdateNotifier.post(this, payload, alertLevel = decision.alertLevel)
                    waitOrWake(SessionPolicy.pollIntervalSeconds(decision))
                }

                SessionPolicy.Decision.ShowReset -> {
                    LiveUpdateNotifier.post(this, payload, didReset = true)
                    // Let the reset card sit briefly, then go. The service must
                    // outlive the card it posted, or stopping would take the
                    // notification with it and the user would never see it.
                    delay(RESET_CARD_LINGER_SECONDS * 1000)
                    stopWithoutCard()
                    return
                }

                SessionPolicy.Decision.Hide -> {
                    stopWithoutCard()
                    return
                }
            }
        }
    }

    /** Sleep for [seconds], or until someone signals [wake] — whichever is first. */
    private suspend fun waitOrWake(seconds: Long) {
        withTimeoutOrNull(seconds * 1000) { wake.receive() }
    }

    private fun promote(notification: android.app.Notification) {
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                LiveUpdateNotifier.NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(LiveUpdateNotifier.NOTIFICATION_ID, notification)
        }
    }

    /** Stop, taking the card with us. */
    private fun stopWithoutCard() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        loop?.cancel()
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "SessionService"

        /** How long the "session reset" card lingers before dismissing itself. */
        const val RESET_CARD_LINGER_SECONDS = 30L

        fun start(context: Context) {
            context.startForegroundService(Intent(context, SessionService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SessionService::class.java))
        }
    }
}
