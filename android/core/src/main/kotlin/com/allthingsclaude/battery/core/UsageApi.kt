package com.allthingsclaude.battery.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeParseException

/**
 * OAuth tokens for one account. Port of `StoredTokens` in
 * `ios/BatteryKit/UsageAPIShared.swift`.
 *
 * [expiresAt] is epoch **milliseconds**, matching the iOS field exactly, so a
 * future cross-platform pairing step wouldn't have to reconcile two encodings.
 */
data class StoredTokens(
    val accessToken: String,
    val refreshToken: String?,
    val expiresAt: Long,
) {
    val expiryInstant: Instant get() = Instant.ofEpochMilli(expiresAt)

    fun isExpiringSoon(now: Instant = Instant.now()): Boolean =
        expiryInstant.epochSecond - now.epochSecond < AppConfig.TOKEN_REFRESH_LEEWAY_SECONDS

    companion object {
        fun fromExpiresIn(accessToken: String, refreshToken: String?, expiresInSeconds: Long) =
            StoredTokens(
                accessToken = accessToken,
                refreshToken = refreshToken,
                expiresAt = System.currentTimeMillis() + expiresInSeconds * 1000,
            )
    }
}

/** One rate-limit window as the API reports it. */
data class UsageBucket(val utilization: Double, val resetsAt: Instant?)

/**
 * The weekly limit that applies to one model rather than to everything.
 *
 * [label] comes from the response — `scope.model.display_name` — instead of
 * being hardcoded, which is the whole point of this type. The app shipped a
 * literal "Opus" heading; the API has since moved this into a `limits` array and
 * now reports the model by name, and on a live account that name is "Fable".
 * Any label baked into the client is a guess with an expiry date.
 */
data class ScopedWeekly(val label: String, val utilization: Double, val resetsAt: Instant?)

/**
 * Pay-as-you-go credits, when the account has them enabled.
 *
 * **The amounts are minor units.** The live response carries
 * `used_credits: 2080.0` against `monthly_limit: 4000` with
 * `decimal_places: 2` — that is $20.80 of $40.00, not $2080 of $4000. macOS
 * calls the same two fields "cents" and divides by 100
 * (`Views/Components/ExtraUsageView.swift`). Getting this wrong renders a
 * hundred-fold overcharge on a lock screen, so the scale is read from
 * `decimal_places` rather than assumed.
 */
data class ExtraUsage(
    val isEnabled: Boolean,
    val usedMinor: Double?,
    val limitMinor: Double?,
    val utilization: Double?,
    val currency: String,
    val decimalPlaces: Int,
) {
    private fun major(minor: Double?): Double? {
        if (minor == null) return null
        var scale = 1.0
        repeat(decimalPlaces.coerceIn(0, 6)) { scale *= 10 }
        return minor / scale
    }

    val used: Double? get() = major(usedMinor)
    val limit: Double? get() = major(limitMinor)
    val remaining: Double? get() {
        val u = used ?: return null
        val l = limit ?: return null
        return (l - u).coerceAtLeast(0.0)
    }

    /** `$20.80`, or `20.80 CHF` when there is no symbol worth guessing. */
    fun format(amount: Double?): String? {
        if (amount == null) return null
        val text = String.format(java.util.Locale.US, "%.${decimalPlaces.coerceIn(0, 6)}f", amount)
        val symbol = when (currency.uppercase()) {
            "USD" -> "$"
            "EUR" -> "€"
            "GBP" -> "£"
            else -> null
        }
        return symbol?.let { it + text } ?: "$text ${currency.uppercase()}"
    }

    /** Worth showing only when it is on and has a limit to measure against. */
    val isPresentable: Boolean get() = isEnabled && (limit ?: 0.0) > 0.0 && used != null
}

/** The `/api/oauth/usage` response. */
data class UsageResponse(
    val fiveHour: UsageBucket?,
    val sevenDay: UsageBucket,
    val sevenDayOpus: UsageBucket?,
    /** The model-scoped weekly window, whatever model it is scoped to. */
    val scopedWeekly: ScopedWeekly?,
    /** Pay-as-you-go credits, null when the account has none. */
    val extraUsage: ExtraUsage?,
)

/*
 * No `rateLimitTier`/`planDisplayName`, though `ios/BatteryKit/UsageAPIShared.swift`
 * has both: this endpoint sends no `rate_limit_tier`, measured on a live account,
 * so the badge was permanently blank. `ProfileApi.planLabel` is the real source
 * and can tell Max 20x from Max, which this mapping could not.
 */

/** Everything that can go wrong talking to the usage API. */
sealed class UsageApiError(message: String, cause: Throwable? = null) : Exception(message, cause) {
    /** The grant is dead — the account must be re-added. */
    object Unauthorized : UsageApiError("Session expired — please sign in again.")
    class RateLimited(val retryAfterSeconds: Long?) : UsageApiError("Rate limited by the API.")
    class Server(val code: Int) : UsageApiError("Server error ($code).")
    class Network(cause: Throwable) : UsageApiError(cause.message ?: "Network error", cause)
    class Decoding(cause: Throwable) : UsageApiError("Bad response: ${cause.message}", cause)
}

/**
 * The usage API client. A merge of the iOS `UsageAPI` actor and `UsageFetcher`.
 *
 * Deliberately built on `HttpURLConnection` and hand-parsed JSON rather than
 * OkHttp + a serialization plugin: this module is plain JVM by design (see
 * `core/build.gradle.kts`), the whole surface is one GET and one POST, and four
 * fields do not justify a compiler plugin. `parseToJsonElement` is a runtime-only
 * API, so no `@Serializable` types and no plugin are involved.
 *
 * [transport] exists so tests can drive the parsing and the refresh logic without
 * a network — the iOS original has no such seam and is correspondingly untested.
 */
class UsageApi(
    private val userAgent: String,
    private val transport: HttpTransport = UrlConnectionTransport(),
) {

    /** The narrow HTTP surface this client needs. */
    interface HttpTransport {
        /** @return status code and body. Throws only for transport-level failures. */
        fun request(
            url: String,
            method: String,
            headers: Map<String, String>,
            body: String?,
        ): Response

        data class Response(val code: Int, val body: String, val headers: Map<String, String> = emptyMap())
    }

    /**
     * Fetch usage, refreshing the access token first if it's close to expiry.
     *
     * @return the usage plus, when a refresh happened, the tokens to persist.
     * The caller must store them: a rotated refresh token that isn't saved
     * invalidates the grant on the next call.
     */
    fun fetchUsage(
        tokens: StoredTokens,
        onTokensRefreshed: (StoredTokens) -> Unit = {},
    ): Pair<UsageResponse, StoredTokens?> {
        var updated: StoredTokens? = null
        var accessToken = tokens.accessToken

        if (tokens.isExpiringSoon()) {
            val refresh = tokens.refreshToken ?: throw UsageApiError.Unauthorized
            val refreshed = refreshTokens(refresh, tokens)
            accessToken = refreshed.accessToken
            updated = refreshed
            // Persist NOW, not after the GET. The server may have rotated the
            // refresh token, in which case the old one is already dead — so if
            // the usage request then fails (a 500, or a dropped connection on a
            // flaky phone) and we only saved on the success path, storage would
            // keep a token the server has invalidated. The next poll would fail
            // with 400 → Unauthorized → signed out, with no visible cause.
            onTokensRefreshed(refreshed)
        }

        return requestUsage(accessToken) to updated
    }

    /** A plain GET with an already-valid access token. Never refreshes. */
    fun requestUsage(accessToken: String): UsageResponse {
        val response = try {
            transport.request(
                url = AppConfig.API_BASE_URL + AppConfig.USAGE_PATH,
                method = "GET",
                headers = mapOf(
                    "Authorization" to "Bearer $accessToken",
                    "anthropic-beta" to AppConfig.BETA_HEADER,
                    "User-Agent" to userAgent,
                ),
                body = null,
            )
        } catch (e: Exception) {
            throw UsageApiError.Network(e)
        }

        when (response.code) {
            200 -> Unit
            401 -> throw UsageApiError.Unauthorized
            429 -> throw UsageApiError.RateLimited(
                response.headers["Retry-After"]?.toLongOrNull()
            )
            else -> throw UsageApiError.Server(response.code)
        }

        return try {
            parseUsage(response.body)
        } catch (e: Exception) {
            throw UsageApiError.Decoding(e)
        }
    }

    /**
     * Exchange a refresh token for a fresh access token.
     *
     * `refresh_token` may be absent from the response, in which case the old one
     * is still valid and must be carried forward — dropping it here would sign
     * the account out on the next refresh.
     */
    fun refreshTokens(refreshToken: String, previous: StoredTokens): StoredTokens {
        val body = buildString {
            append("{\"grant_type\":\"refresh_token\",")
            append("\"refresh_token\":${quote(refreshToken)},")
            append("\"client_id\":${quote(AppConfig.OAUTH_CLIENT_ID)},")
            append("\"scope\":${quote(AppConfig.OAUTH_SCOPES)}}")
        }

        val response = try {
            transport.request(
                url = AppConfig.OAUTH_TOKEN_URL,
                method = "POST",
                headers = mapOf(
                    "Content-Type" to "application/json",
                    "User-Agent" to userAgent,
                ),
                body = body,
            )
        } catch (e: Exception) {
            throw UsageApiError.Network(e)
        }

        if (response.code != 200) {
            // 400/401/403 mean the grant itself is dead, not that the request
            // was malformed — the only cure is a new sign-in.
            if (response.code in listOf(400, 401, 403)) throw UsageApiError.Unauthorized
            throw UsageApiError.Server(response.code)
        }

        // Wrapped exactly as the usage GET wraps parseUsage, and for a reason
        // that is worse here: nothing above catches a raw SerializationException.
        // A token endpoint answering 200 with a body that is empty, truncated,
        // or missing access_token slips past the code check and throws through
        // UsageRepository.poll — whose catch list is UsageApiError only — out of
        // the service's poll loop, which has no CoroutineExceptionHandler. The
        // process dies, START_STICKY restarts it, and it dies again.
        return try {
            parseTokens(response.body, previous)
        } catch (e: Exception) {
            throw UsageApiError.Decoding(e)
        }
    }

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun parseUsage(body: String): UsageResponse {
            val root = json.parseToJsonElement(body).jsonObject
            return UsageResponse(
                fiveHour = bucket(root, "five_hour"),
                sevenDay = bucket(root, "seven_day")
                    ?: throw IllegalArgumentException("response has no seven_day bucket"),
                sevenDayOpus = bucket(root, "seven_day_opus"),
                scopedWeekly = scopedWeekly(root),
                extraUsage = extraUsage(root),
            )
        }

        fun parseTokens(body: String, previous: StoredTokens?): StoredTokens {
            val root = json.parseToJsonElement(body).jsonObject
            val access = root["access_token"]?.jsonPrimitive?.contentOrNullSafe()
                ?: throw IllegalArgumentException("token response has no access_token")
            val refresh = root["refresh_token"]?.jsonPrimitive?.contentOrNullSafe()
                ?: previous?.refreshToken
            val expiresIn = root["expires_in"]?.jsonPrimitive?.contentOrNullSafe()?.toLongOrNull()
                ?: 3600L
            return StoredTokens.fromExpiresIn(access, refresh, expiresIn)
        }

        private fun extraUsage(root: kotlinx.serialization.json.JsonObject): ExtraUsage? {
            val obj = root["extra_usage"] as? kotlinx.serialization.json.JsonObject ?: return null
            fun num(key: String) =
                obj[key]?.jsonPrimitive?.contentOrNullSafe()?.toDoubleOrNull()
            fun text(key: String) = obj[key]?.jsonPrimitive?.contentOrNullSafe()
            return ExtraUsage(
                isEnabled = text("is_enabled")?.toBooleanStrictOrNull() ?: false,
                usedMinor = num("used_credits"),
                limitMinor = num("monthly_limit"),
                utilization = num("utilization"),
                currency = text("currency") ?: "USD",
                decimalPlaces = num("decimal_places")?.toInt() ?: 2,
            )
        }

        private fun bucket(root: kotlinx.serialization.json.JsonObject, key: String): UsageBucket? {
            val obj = root[key]?.takeIf { it is kotlinx.serialization.json.JsonObject }
                ?.jsonObject ?: return null
            val utilization = obj["utilization"]?.jsonPrimitive?.contentOrNullSafe()?.toDoubleOrNull()
                ?: return null
            return UsageBucket(
                utilization = utilization,
                resetsAt = obj["resets_at"]?.jsonPrimitive?.contentOrNullSafe()?.let(::parseInstant),
            )
        }

        /**
         * The model-scoped weekly limit, read from the `limits` array.
         *
         * The response carries the same numbers twice: flat keys like
         * `seven_day_opus`, and a `limits` array of
         * `{kind, percent, resets_at, scope}` entries. The array is the one that
         * says *which* model a scoped limit belongs to, via
         * `scope.model.display_name`, and on a live account today that reads
         * "Fable" while `seven_day_opus` is null. A client that only knows the
         * flat keys shows an empty Opus row forever and never mentions Fable.
         *
         * Falls back to `seven_day_opus` labelled "Opus" so an older response —
         * or an account still on that shape — keeps working.
         */
        private fun scopedWeekly(root: kotlinx.serialization.json.JsonObject): ScopedWeekly? {
            val entry = (root["limits"] as? kotlinx.serialization.json.JsonArray)
                ?.mapNotNull { it as? kotlinx.serialization.json.JsonObject }
                ?.firstOrNull { it["kind"]?.jsonPrimitive?.contentOrNullSafe() == "weekly_scoped" }

            if (entry != null) {
                val label = entry["scope"]?.let { it as? kotlinx.serialization.json.JsonObject }
                    ?.get("model")?.let { it as? kotlinx.serialization.json.JsonObject }
                    ?.get("display_name")?.jsonPrimitive?.contentOrNullSafe()
                val percent = entry["percent"]?.jsonPrimitive?.contentOrNullSafe()?.toDoubleOrNull()
                // No label means nothing can be said about *what* is limited, and
                // a bare percentage under no heading is worse than no row.
                if (label != null && percent != null) {
                    return ScopedWeekly(
                        label = label,
                        utilization = percent,
                        resetsAt = entry["resets_at"]?.jsonPrimitive?.contentOrNullSafe()
                            ?.let(::parseInstant),
                    )
                }
            }

            return bucket(root, "seven_day_opus")
                ?.let { ScopedWeekly("Opus", it.utilization, it.resetsAt) }
        }

        /**
         * The API sends ISO-8601 with or without fractional seconds; iOS tries
         * both formats for the same reason.
         */
        fun parseInstant(text: String): Instant? = try {
            OffsetDateTime.parse(text).toInstant()
        } catch (_: DateTimeParseException) {
            try {
                Instant.parse(text)
            } catch (_: DateTimeParseException) {
                null
            }
        }

        private fun quote(s: String): String =
            "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

        /** `jsonPrimitive.content` on a JSON null yields the string "null". */
        private fun kotlinx.serialization.json.JsonPrimitive.contentOrNullSafe(): String? =
            if (this is kotlinx.serialization.json.JsonNull) null else content
    }
}
