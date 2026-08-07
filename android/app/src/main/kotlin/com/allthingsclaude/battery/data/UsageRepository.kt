package com.allthingsclaude.battery.data

import android.content.Context
import android.util.Log
import com.allthingsclaude.battery.core.AppConfig
import com.allthingsclaude.battery.core.ProfileApi
import com.allthingsclaude.battery.core.SessionHistory
import com.allthingsclaude.battery.core.StoredTokens
import com.allthingsclaude.battery.core.UsageApi
import com.allthingsclaude.battery.core.UsageApiError
import com.allthingsclaude.battery.core.UsagePayload
import com.allthingsclaude.battery.core.UsageResponse
import com.allthingsclaude.battery.widget.refreshAllWidgets
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant

/**
 * One poll: fetch, persist any rotated tokens, fold the sample into the
 * regression, and produce the [UsagePayload] every surface renders.
 *
 * Port of the payload-building half of `ios/BatteryApp/UsageService.swift`. The
 * polling *loop* is deliberately not here — on Android the loop and the card are
 * the same decision (the foreground service's notification is the card), so it
 * belongs with the service in Phase 3.
 */
class UsageRepository(context: Context) {

    private val appContext = context.applicationContext
    private val accounts = AccountStore(appContext)
    private val tokens = TokenStore(appContext)
    private val payloads = PayloadStore(appContext)
    private val history = SessionHistory(payloads.snapshots)

    private val userAgent: String by lazy {
        val version = runCatching {
            appContext.packageManager.getPackageInfo(appContext.packageName, 0).versionName
        }.getOrNull() ?: "0"
        AppConfig.userAgent(version)
    }

    private val api by lazy { UsageApi(userAgent) }

    /**
     * Activity inference, mirroring iOS: a session is "active" if utilization
     * climbed within the last ten minutes. Held in memory only — a cold start
     * legitimately doesn't know yet, and persisting it would let a stale "active"
     * keep a foreground service alive across a reboot.
     */
    private var lastRiseAt: Instant? = null
    private var lastUtilization: Double? = null

    val lastKnownPayload: UsagePayload? get() = payloads.load()

    fun isSignedIn(): Boolean = accounts.load().isNotEmpty()

    sealed class PollResult {
        data class Success(val payload: UsagePayload) : PollResult()
        /** The grant is dead; the account needs re-adding. */
        object SignedOut : PollResult()
        data class Failed(val message: String, val retryAfterSeconds: Long?) : PollResult()
        object NoAccount : PollResult()

        /**
         * The account was switched while this poll was in flight, so its result
         * belongs to an account nobody is looking at. Discarded rather than
         * rendered.
         */
        object Stale : PollResult()
    }

    /**
     * @param force skip the freshness gate. Only for an explicit user action —
     *   never for a lifecycle event, which is what caused the problem below.
     */
    suspend fun poll(force: Boolean = false): PollResult = withContext(Dispatchers.IO) {
        // Rate-limit guard, at the single choke point every caller goes through.
        //
        // Learned the hard way: the app polls on every resume, the service polls
        // on its own cadence, and switching accounts or card modes polls too. A
        // day of relaunching the app while developing was enough to earn a 429
        // from the API — and the same shape of usage (open app, close, reopen)
        // is entirely normal for a real user.
        //
        // Anything inside this window gets the cached payload, which is what
        // every surface would have rendered anyway.
        val cached = payloads.load()
        if (!force && cached != null &&
            Instant.now().epochSecond - cached.updatedAt.epochSecond < MIN_POLL_INTERVAL_SECONDS
        ) {
            return@withContext PollResult.Success(cached)
        }

        val all = accounts.load()
        val account = all.firstOrNull { it.id == accounts.selectedId } ?: all.firstOrNull()
            ?: return@withContext PollResult.NoAccount
        val stored = tokens.load(account.id) ?: return@withContext PollResult.SignedOut

        try {
            // Persisted from inside fetchUsage, the instant the refresh returns —
            // see the comment there. Saving after the GET loses a rotated token
            // whenever the GET fails.
            val (usage, _) = api.fetchUsage(stored) { refreshed ->
                if (!tokens.save(account.id, refreshed)) {
                    // Same consequence as not saving at all, so it must not be
                    // swallowed: the old refresh token is already dead server-side.
                    Log.e(TAG, "failed to persist refreshed tokens for ${account.id}")
                }
            }

            // The selected account can change while a request is in flight. iOS
            // guards this twice, deliberately — a late response must never
            // overwrite the newly-selected account's data, poison its regression
            // buffer, or relabel its card.
            if (accounts.selectedId != null && accounts.selectedId != account.id) {
                return@withContext PollResult.Stale
            }

            val payload = buildPayload(usage, account.name)
            payloads.save(payload)
            // Repainted here rather than by the service, because this is the one
            // place a new payload lands — a manual refresh from the dashboard
            // has to move the widgets too, and routing it through the service
            // would mean the widgets only update while a card is up.
            refreshWidgets()
            PollResult.Success(payload)
        } catch (e: UsageApiError.Unauthorized) {
            PollResult.SignedOut
        } catch (e: UsageApiError.RateLimited) {
            PollResult.Failed("Rate limited by the API.", e.retryAfterSeconds)
        } catch (e: UsageApiError) {
            PollResult.Failed(e.message ?: "Couldn't refresh usage.", null)
        }
    }

    /**
     * `accountName` is passed in rather than read back from the selected account
     * so a response can only ever be labelled with the account it was fetched
     * for — the account can change while a request is in flight.
     */
    private fun buildPayload(usage: UsageResponse, accountName: String): UsagePayload {
        val session = usage.fiveHour
        val sessionUtil = session?.utilization ?: 0.0
        val sessionReset = session?.resetsAt

        val projection = history.record(sessionUtil, sessionReset)

        val now = Instant.now()
        lastUtilization?.let { if (sessionUtil > it + 0.01) lastRiseAt = now }
        lastUtilization = sessionUtil
        val isActive = session != null &&
            (lastRiseAt?.let { now.epochSecond - it.epochSecond < ACTIVE_WINDOW_SECONDS } ?: false)

        return UsagePayload(
            sessionUtilization = sessionUtil,
            sessionResetsAt = sessionReset,
            weeklyUtilization = usage.sevenDay.utilization,
            weeklyResetsAt = usage.sevenDay.resetsAt,
            opusUtilization = usage.sevenDayOpus?.utilization,
            burnRatePerHour = projection.ratePerHour,
            projectedLimitAt = projection.limitAt,
            isSessionActive = isActive,
            planTier = usage.planDisplayName,
            accountName = accountName,
            isConnected = true,
            updatedAt = now,
        )
    }

    // ── Account management ──────────────────────────────────────────────────

    /**
     * Adds a freshly-authenticated account and selects it.
     *
     * Labelled with the account's own email when `/api/oauth/profile` yields
     * one, falling back to "Account N". The fallback is not a formality — the
     * response shape is undocumented, and a sign-in must not fail because a
     * cosmetic label could not be resolved.
     */
    suspend fun addAccount(newTokens: StoredTokens): Boolean = withContext(Dispatchers.IO) {
        val existing = accounts.load()
        val label = runCatching {
            ProfileApi(userAgent).fetch(newTokens.accessToken)?.label
        }.getOrNull()
        val account = Account.new(label ?: accounts.nextAccountName(existing))
        // If the credential can't be stored, don't pretend the account exists —
        // it would look signed in while every poll returned SignedOut.
        if (!tokens.save(account.id, newTokens)) return@withContext false
        accounts.save(existing + account)
        accounts.selectedId = account.id
        resetInference()
        true
    }

    /** Rename an account by hand, for when the profile lookup came back empty. */
    fun renameAccount(id: String, name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        accounts.save(accounts.load().map { if (it.id == id) it.copy(name = trimmed) else it })
    }

    val selectedAccountId: String?
        get() = accounts.selectedId ?: accounts.load().firstOrNull()?.id

    fun removeAccount(id: String) {
        tokens.delete(id)
        val remaining = accounts.load().filterNot { it.id == id }
        accounts.save(remaining)
        if (accounts.selectedId == id) accounts.selectedId = remaining.firstOrNull()?.id
        if (remaining.isEmpty()) payloads.clear()
        resetInference()
    }

    fun signOutAll() {
        tokens.deleteAll()
        accounts.save(emptyList())
        accounts.selectedId = null
        payloads.clear()
        resetInference()
    }

    fun listAccounts(): List<Account> = accounts.load()

    fun selectAccount(id: String) {
        accounts.selectedId = id
        resetInference()
        // A different account's samples must never feed this account's
        // regression — the buffer is per-window, not per-account.
        history.reset()
    }

    private suspend fun refreshWidgets() {
        runCatching {
            refreshAllWidgets(appContext)
        }.onFailure {
            // A widget that isn't on any home screen throws here. That's the
            // common case, not an error worth surfacing.
            Log.d(TAG, "widget update skipped: ${it.message}")
        }
    }

    private fun resetInference() {
        lastRiseAt = null
        lastUtilization = null
    }

    private companion object {
        const val TAG = "UsageRepository"
        const val ACTIVE_WINDOW_SECONDS = 10 * 60

        /**
         * Floor between network polls. Comfortably under the service's own
         * three-minute cadence, so it never delays a scheduled refresh — it only
         * absorbs the bursts that come from lifecycle events.
         */
        const val MIN_POLL_INTERVAL_SECONDS = 60
    }
}
