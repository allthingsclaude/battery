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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.time.Instant
import kotlin.math.abs

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
    suspend fun poll(force: Boolean = false): PollResult = pollLock.withLock {
        pollLocked(force)
    }

    private suspend fun pollLocked(force: Boolean): PollResult = withContext(Dispatchers.IO) {
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
        // abs, so the gate measures distance rather than direction. A signed
        // difference goes negative if the wall clock moves backwards — a manual
        // change, a timezone-less NTP correction — and every negative value is
        // below the threshold, so the cache would be served until real time
        // caught back up. Verification called that unreachable enough not to be
        // a defect; it is one character to stop it being a question.
        val cached = payloads.load()
        if (!force && cached != null &&
            abs(Instant.now().epochSecond - cached.updatedAt.epochSecond) < MIN_POLL_INTERVAL_SECONDS
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
                // Checked again here, not only after the GET: a rotated token
                // written back after sign-out recreates a credential file for an
                // account that no longer exists, and nothing ever cleans it up
                // because removeAccount is only called for ids still in the list.
                if (!stillCurrent(account.id)) {
                    Log.w(TAG, "discarding refreshed tokens for departed account ${account.id}")
                } else if (!tokens.save(account.id, refreshed)) {
                    // Same consequence as not saving at all, so it must not be
                    // swallowed: the old refresh token is already dead server-side.
                    Log.e(TAG, "failed to persist refreshed tokens for ${account.id}")
                }
            }

            // The selected account can change while a request is in flight. iOS
            // guards this twice, deliberately — a late response must never
            // overwrite the newly-selected account's data, poison its regression
            // buffer, or relabel its card.
            if (!stillCurrent(account.id)) {
                return@withContext PollResult.Stale
            }

            // Accounts created before the plan badge existed have no tier, and
            // the alternative to filling it in here is telling people to sign
            // out and back in for a cosmetic label. One request, once per
            // account, wrapped so it can never turn a good poll into a failure.
            val planTier = account.planTier.ifEmpty { backfillPlanTier(account, stored) }

            val payload = buildPayload(usage, account.name, planTier)
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
     * Resolve and store the plan for an account that has none.
     *
     * Returns "" on any failure, which simply means the badge stays hidden and
     * the next poll tries again — the same outcome as before this existed.
     */
    private fun backfillPlanTier(account: Account, tokens: StoredTokens): String {
        val label = runCatching {
            ProfileApi(userAgent).fetch(tokens.accessToken)?.planLabel
        }.getOrNull().orEmpty()
        if (label.isEmpty()) return ""

        // Re-read rather than reusing the list captured before the request: the
        // user may have renamed or removed accounts while it was in flight.
        val current = accounts.load()
        if (current.none { it.id == account.id }) return ""
        accounts.save(current.map { if (it.id == account.id) it.copy(planTier = label) else it })
        Log.i(TAG, "resolved plan tier for ${account.id}")
        return label
    }

    /**
     * Whether a poll that started against [id] may still write anything.
     *
     * The previous test was `selectedId != null && selectedId != id`, which was
     * written for account *switching* and is silently disabled by the two states
     * that need it most: `signOutAll` and removing the last account both set
     * `selectedId = null`, making the first clause false and the whole guard
     * pass. An in-flight poll finishing after sign-out would then rewrite the
     * payload that was just cleared and — via the refresh callback — recreate a
     * live credential file for an account that no longer exists.
     *
     * Membership is checked as well as selection, because "still selected" is
     * meaningless once the list is empty. `fetchUsage` is a blocking
     * `HttpURLConnection` call with no suspension point before the writes, so
     * cancellation cannot be relied on to do this.
     */
    private fun stillCurrent(id: String): Boolean {
        if (accounts.load().none { it.id == id }) return false
        val selected = accounts.selectedId ?: return true
        return selected == id
    }

    /**
     * `accountName` is passed in rather than read back from the selected account
     * so a response can only ever be labelled with the account it was fetched
     * for — the account can change while a request is in flight.
     */
    private fun buildPayload(
        usage: UsageResponse,
        accountName: String,
        accountPlanTier: String,
    ): UsagePayload {
        val session = usage.fiveHour
        val sessionUtil = session?.utilization ?: 0.0
        val sessionReset = session?.resetsAt

        val now = Instant.now()
        val projection = history.record(sessionUtil, sessionReset, now)

        // Activity inference, mirroring iOS: a session is "active" if
        // utilization climbed within the last ten minutes.
        //
        // Read from the shared snapshot buffer rather than from fields on this
        // object, because this object is not shared. The dashboard builds one
        // repository and the foreground service builds another, so an in-memory
        // "last utilization" meant each one had to observe two polls of its own
        // before it could see a rise — and the service is constructed exactly
        // when the card is meant to appear, so it was always the blind one.
        val lastRise = history.lastRiseAt(sessionReset)
        val isActive = session != null && lastRise != null &&
            now.epochSecond - lastRise.epochSecond < ACTIVE_WINDOW_SECONDS

        return UsagePayload(
            sessionUtilization = sessionUtil,
            sessionResetsAt = sessionReset,
            weeklyUtilization = usage.sevenDay.utilization,
            weeklyResetsAt = usage.sevenDay.resetsAt,
            opusUtilization = usage.scopedWeekly?.utilization,
            scopedLabel = usage.scopedWeekly?.label ?: "",
            extraUsage = usage.extraUsage?.takeIf { it.isPresentable },
            burnRatePerHour = projection.ratePerHour,
            projectedLimitAt = projection.limitAt,
            isSessionActive = isActive,
            // From the account, not the usage response: that response has no
            // rate_limit_tier at all, so this badge was permanently blank.
            planTier = accountPlanTier,
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
        val profile = runCatching {
            ProfileApi(userAgent).fetch(newTokens.accessToken)
        }.getOrNull()
        val account = Account.new(
            name = profile?.label ?: accounts.nextAccountName(existing),
            planTier = profile?.planLabel.orEmpty(),
        )
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
        resetInference()
    }

    fun signOutAll() {
        tokens.deleteAll()
        accounts.save(emptyList())
        accounts.selectedId = null
        resetInference()
    }

    fun listAccounts(): List<Account> = accounts.load()

    fun selectAccount(id: String) {
        accounts.selectedId = id
        // A different account's samples must never feed this account's
        // regression — the buffer is per-window, not per-account.
        resetInference()
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

    /**
     * Forget this account's samples.
     *
     * Now a single call, because the buffer is the only place session history
     * lives — activity inference reads it too, so clearing it clears both the
     * burn-rate regression and any lingering idea that a session is live.
     */
    private fun resetInference() {
        history.reset()
        // The payload cache is one global key, not one per account, so it
        // carries the outgoing account's name, percentages and burn rate. Left
        // in place, the freshness gate serves it as the *incoming* account's
        // data for the next sixty seconds — the dashboard header, the card and
        // all four widgets showing account A under account B's radio button.
        payloads.clear()
    }

    private companion object {
        /**
         * One poll at a time, process-wide.
         *
         * On the companion, not the instance, because the hazard *is* multiple
         * instances: the dashboard builds a repository and so does the
         * foreground service, and both poll. The freshness gate looks like it
         * serialises them and does not — it is a check-then-act over
         * SharedPreferences with an entire network round trip in between.
         *
         * The expensive collision is the refresh token. Two pollers inside the
         * 300s expiry leeway both load RT1 and both POST it; the server rotates,
         * the first gets RT2, the second gets a 400 that this code maps to
         * Unauthorized and reports as SignedOut — stranding the user on the
         * sign-in gate while a perfectly good RT2 sits on disk. Serialising
         * means the second caller arrives after the first has written, so it
         * either reads RT2 or is served from the cache.
         */
        val pollLock = Mutex()
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
