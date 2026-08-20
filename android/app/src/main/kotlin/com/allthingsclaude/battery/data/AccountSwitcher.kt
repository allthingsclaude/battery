package com.allthingsclaude.battery.data

import android.content.Context
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
    suspend fun switchTo(id: String): UsageRepository.PollResult {
        repository.selectAccount(id)
        val result = repository.poll()
        repaint()
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
