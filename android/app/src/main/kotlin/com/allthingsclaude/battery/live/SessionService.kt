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
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

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

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (loop?.isActive == true) return START_STICKY

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
        // is in flight; the placeholder would be an invented number on a lock
        // screen.
        val initial = repo.lastKnownPayload ?: UsagePayload.PLACEHOLDER

        // startForeground is unavoidable — a service started with
        // startForegroundService MUST promote or the system kills it — so an
        // already-dismissed window is handled by promoting and immediately
        // standing down rather than by skipping the call.
        promote(LiveUpdateNotifier.build(this, initial))
        if (dismissal.isDismissed(initial.sessionResetsAt)) {
            stopWithoutCard()
            return START_NOT_STICKY
        }

        loop = scope.launch { pollLoop(repo) }
        return START_STICKY
    }

    private suspend fun pollLoop(repo: UsageRepository) {
        while (scope.isActive) {
            val result = repo.poll()

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
                    delay(SessionPolicy.pollIntervalSeconds(SessionPolicy.Decision.Hide) * 1000)
                    continue
                }
                is UsageRepository.PollResult.Failed -> {
                    // Keep the card at its last known value rather than dropping
                    // it: a transient network blip should not clear the user's
                    // lock screen. `updatedAt` is untouched, so the card ages
                    // visibly instead of pretending to be current.
                    val wait = backoff.recordFailure(result.retryAfterSeconds)
                    Log.w(TAG, "poll failed (${backoff.failureCount}x): ${result.message}; waiting ${wait}s")
                    delay(wait * 1000)
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
                    delay(SessionPolicy.pollIntervalSeconds(decision) * 1000)
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
