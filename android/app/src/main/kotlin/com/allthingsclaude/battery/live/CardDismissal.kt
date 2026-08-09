package com.allthingsclaude.battery.live

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import java.time.Instant

/**
 * Remembers that the user swiped the card away, so nothing reposts it.
 *
 * Google is explicit that reposting a dismissed Live Update is what drives users
 * to revoke an app's promotion permission — and that revocation is effectively
 * permanent, recoverable only through a settings deep link the user has no
 * reason to find. Since [SessionService] reposts on every poll, without this the
 * app would fight the user roughly every three minutes.
 *
 * Worth knowing: on Android 14+ a foreground service's notification **can** be
 * dismissed even while the service runs, so `setOngoing(true)` does not make
 * this unreachable. It is a normal thing for a user to do.
 *
 * **Scoped to the window, not forever.** The dismissal records which session
 * window was on screen; when that window resets, a genuinely new thing is
 * happening and the card is allowed back. Suppressing permanently would mean one
 * swipe silently disables the product, and re-arming on the next poll would mean
 * the swipe did nothing.
 */
class CardDismissal(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("card_dismissal", Context.MODE_PRIVATE)

    /** Record a dismissal against the window that was showing. */
    fun record(windowResetsAt: Instant?) {
        prefs.edit()
            .putLong(KEY_WINDOW, windowResetsAt?.toEpochMilli() ?: NO_WINDOW)
            .apply()
    }

    /**
     * Whether the card should stay hidden for this window.
     *
     * A payload with no open window can't match a recorded one, so it never
     * suppresses — otherwise the gap between sessions would inherit the previous
     * window's dismissal and swallow the start of the next.
     */
    fun isDismissed(windowResetsAt: Instant?): Boolean {
        val dismissed = prefs.getLong(KEY_WINDOW, NO_WINDOW)
        if (dismissed == NO_WINDOW) return false
        val current = windowResetsAt?.toEpochMilli() ?: return false
        // Same 1-second tolerance the regression uses: a reset time round-trips
        // through JSON and can come back a hair off.
        return kotlin.math.abs(dismissed - current) < 1000
    }

    fun clear() = prefs.edit().remove(KEY_WINDOW).apply()

    private companion object {
        const val KEY_WINDOW = "dismissed_window"
        const val NO_WINDOW = -1L
    }
}

/**
 * Fired by the system when the card is swiped away. Registered as the
 * notification's `deleteIntent`.
 */
class CardDismissedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val resetsAt = intent.getLongExtra(EXTRA_WINDOW, -1L)
            .takeIf { it > 0 }
            ?.let(Instant::ofEpochMilli)
        CardDismissal(context).record(resetsAt)
        // Stop the poll loop too. Leaving it running would burn the battery
        // maintaining a card nobody can see, and its next post would be the
        // repost this whole mechanism exists to prevent.
        SessionService.stop(context)
    }

    companion object {
        const val ACTION = "com.allthingsclaude.battery.CARD_DISMISSED"
        const val EXTRA_WINDOW = "window_resets_at"
    }
}
