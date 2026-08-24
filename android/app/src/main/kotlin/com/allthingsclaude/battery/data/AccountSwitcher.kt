package com.allthingsclaude.battery.data

import android.content.Context
import com.allthingsclaude.battery.core.ActiveAccount
import java.time.Duration
import java.time.Instant
import com.allthingsclaude.battery.core.SessionPolicy
import com.allthingsclaude.battery.live.SessionService
import com.allthingsclaude.battery.quicksettings.AccountTileService

/**
 * Switching accounts, as one operation.
 *
 * [UsageRepository.selectAccount] only moves the pointer and drops the previous
 * account's inference. Everything that makes the switch *visible* — re-polling,
 * and asking the service to repaint the card — was the caller's job, and three
 * handlers in `MainActivity` assembled it by hand.
 *
 * That was survivable while the app had exactly one switcher, all of it inside a
 * composable that already held the context and the card mode. It stops being
 * survivable the moment a Quick Settings tile, a card action or a widget button
 * can switch too (PLAN_02 Phases 4–6): each of those runs outside the Activity,
 * and each one that forgot the repaint would leave the lock-screen card
 * describing the account you just switched *away* from. On a convenience feature
 * that is the failure that costs trust — you tap switch, the home screen agrees,
 * and the lock screen quietly disagrees.
 *
 * Widgets need no help here: [UsageRepository.poll] refreshes them itself on
 * success.
 *
 * Takes a repository rather than building one only to avoid a redundant object
 * where the caller already holds it. It is safe for a caller that has none — a
 * Quick Settings tile, a broadcast receiver — to construct its own: the state
 * `resetInference` clears is not held in the instance. `SessionHistory`
 * delegates to `SnapshotPrefs` and the payload cache is a store, so both are
 * SharedPreferences-backed and shared by every instance in the process. An
 * earlier version of this comment claimed the opposite, which would have ruled
 * out the tile entirely.
 */
class AccountSwitcher(context: Context, private val repository: UsageRepository) {

    private val appContext = context.applicationContext
    private val accounts = AccountStore(appContext)
    private val settings = Settings(appContext)

    /**
     * Select [id], then make every surface agree about it.
     *
     * The card mode is read here rather than passed in, so that no caller can
     * switch without it. Reading it is safe: `SettingsSheet` writes the choice
     * straight through to [Settings], which is the persisted source of truth —
     * the copy `MainActivity` holds is a mirror of it, not the other way round.
     */
    suspend fun switchTo(
        id: String,
        /**
         * Set false from a background caller. [repaint] starts a foreground
         * service, and an app in the background may not do that on Android 12+ —
         * `WidgetRefreshWorker` learned this by throwing
         * `ForegroundServiceStartNotAllowedException` on its first real run, and
         * posts the card itself instead.
         *
         * A notification action *is* allowed: the tap grants a short FGS
         * allowlist, which is why `AccountSwitchReceiver` leaves this true.
         */
        repaintCard: Boolean = true,
    ): UsageRepository.PollResult {
        repository.selectAccount(id)
        val result = repository.poll()
        if (repaintCard) repaint()
        // The tile is ACTIVE_TILE, so it is bound only for taps and panel opens.
        // Without this nudge it would keep naming the account we just left.
        AccountTileService.requestRefresh(appContext)
        return result
    }

    /**
     * Switch to the next account, wrapping past the end.
     *
     * This — not `switchTo` — is what the tile, the card action and any future
     * widget button call. They have no account picker to offer and no room for
     * one; "next" is the only instruction a single tap can carry.
     *
     * Returns null when there is nothing to switch to, which callers should
     * treat as "leave the surface exactly as it was" rather than as a failure:
     * one account is a perfectly ordinary state, and a tile that reported an
     * error for it would be wrong.
     */
    suspend fun cycle(): UsageRepository.PollResult? {
        val next = accounts.nextAccountId() ?: return null
        return switchTo(next)
    }

    /**
     * Move to whichever account is actually being used, if the user asked for
     * that and there is evidence to act on.
     *
     * Returns the account it moved to, or null for "left alone" — which covers
     * the mode being off, nothing having moved recently, and the pick already
     * being selected. Callers must treat null as *no change*, never as failure:
     * an idle hour is the ordinary case, and a switcher that lurched somewhere
     * on no evidence is exactly the behaviour this is designed not to have.
     */
    suspend fun applyAutoFollow(
        now: Instant = Instant.now(),
        repaintCard: Boolean = true,
    ): String? {
        if (!settings.followsActiveAccount) return null

        val rises = accounts.load().mapNotNull { account ->
            repository.lastActivityAt(account.id)?.let { account.id to it }
        }.toMap()

        val pick = ActiveAccount.pick(rises, now) ?: return null
        if (pick == accounts.activeId) return null

        switchTo(pick, repaintCard)
        return pick
    }

    /**
     * A one-line account of what the follow mode did, for the header to show.
     *
     * Never optional when the mode is on. The research this came from is blunt
     * about it: automatic selection is only safe when the user can see which
     * account was chosen and why, because otherwise a wrong pick is indetectable
     * until they have already believed the number.
     */
    fun followReason(now: Instant = Instant.now()): String? {
        if (!settings.followsActiveAccount) return null
        val id = accounts.activeId ?: return null
        val name = accounts.load().firstOrNull { it.id == id }?.name ?: return null
        val rise = repository.lastActivityAt(id)
            ?: return "following $name — no recent activity"
        val minutes = Duration.between(rise, now).toMinutes()
        val ago = when {
            minutes < 1L -> "just now"
            minutes < 60L -> "${minutes}m ago"
            else -> "${minutes / 60}h ago"
        }
        return "following $name — active $ago"
    }

    /**
     * Ask the service to repaint. Starting it is the whole mechanism — the
     * service's own notification *is* the card, so there is nothing else to
     * post, and nothing here may post one directly: doing that bypasses all
     * three gates that decide whether a card may exist (the mode, the session
     * policy, and the record of a card the user swiped away).
     */
    fun repaint() {
        if (settings.cardMode != SessionPolicy.Mode.OFF) SessionService.start(appContext)
    }
}
