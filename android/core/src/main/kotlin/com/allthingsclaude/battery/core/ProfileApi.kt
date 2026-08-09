package com.allthingsclaude.battery.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Who the signed-in account belongs to.
 *
 * `/api/oauth/profile` is what the `user:profile` scope both apps already
 * request is *for*, and nothing in this repository has ever called it — macOS
 * declares an `Account.email` field that is never populated, iOS names accounts
 * "Account 1", "Account 2". Verified to exist by an unauthenticated probe: it
 * answers 401 where `/api/oauth/me`, `/v1/me` and `/api/oauth/organizations`
 * answer 404.
 *
 * **The response shape is not documented and was not observed before this was
 * written**, so the parser hunts for an email rather than asserting a schema,
 * and every failure degrades to null. An account label is a nicety; failing a
 * sign-in over it would not be.
 */
class ProfileApi(
    private val userAgent: String,
    private val transport: UsageApi.HttpTransport = UrlConnectionTransport(),
) {

    data class Profile(
        val email: String?,
        val displayName: String?,
        /** `organization.rate_limit_tier`, e.g. `default_claude_max_20x`. */
        val rateLimitTier: String? = null,
    ) {
        /** The best human label available, or null to fall back to "Account N". */
        val label: String? get() = email ?: displayName

        /**
         * The plan, as a badge, or "" when it cannot be said.
         *
         * This lives here and not on the usage response because that is where
         * the answer actually is. `/api/oauth/usage` carries no
         * `rate_limit_tier` at all — measured on a live account — so the badge
         * was permanently blank and looked like a rendering bug. macOS reads the
         * tier from the Keychain, where the Claude Code CLI happens to have left
         * it, which is not a source an Android app has.
         *
         * **Order matters and is the whole reason this is not a `when` on the
         * raw string.** The live value is `default_claude_max_20x`, which
         * contains "max" — so a naive contains-check labels a 20x plan as plain
         * "Max". The narrower tiers have to be tested first.
         */
        val planLabel: String
            get() {
                val t = rateLimitTier?.lowercase() ?: return ""
                return when {
                    t.contains("max_20x") || t.contains("max20x") -> "Max 20x"
                    t.contains("max_5x") || t.contains("max5x") -> "Max 5x"
                    t.contains("max") -> "Max"
                    t.contains("pro") -> "Pro"
                    t.contains("team") -> "Team"
                    t.contains("enterprise") -> "Enterprise"
                    else -> ""
                }
            }
    }

    fun fetch(accessToken: String): Profile? {
        val response = runCatching {
            transport.request(
                url = AppConfig.API_BASE_URL + AppConfig.PROFILE_PATH,
                method = "GET",
                headers = mapOf(
                    "Authorization" to "Bearer $accessToken",
                    "anthropic-beta" to AppConfig.BETA_HEADER,
                    "User-Agent" to userAgent,
                ),
                body = null,
            )
        }.getOrNull() ?: return null

        if (response.code != 200) return null
        return parse(response.body)
    }

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        /**
         * Pull an email out of whatever shape comes back.
         *
         * Searched recursively rather than read from a fixed path: the response
         * is undocumented, and an email nested under `account` or `organization`
         * is at least as likely as one at the top level. A wrong guess about the
         * path would silently produce "Account 1" forever with no clue why.
         */
        fun parse(body: String): Profile? = runCatching {
            val root = json.parseToJsonElement(body).jsonObject
            Profile(
                email = findString(root, setOf("email", "email_address")),
                displayName = findString(root, setOf("display_name", "name", "full_name")),
                // Read from the exact path rather than by the recursive search
                // the label uses. The search exists because the shape was
                // unknown; this key has now been seen, it sits under
                // `organization`, and a stray match elsewhere would put a wrong
                // plan on a lock screen.
                rateLimitTier = (root["organization"] as? JsonObject)
                    ?.get("rate_limit_tier")
                    ?.let { runCatching { it.jsonPrimitive.content }.getOrNull() }
                    ?.takeIf { it.isNotBlank() && it != "null" },
            ).takeIf { it.email != null || it.displayName != null }
        }.getOrNull()

        private fun findString(obj: JsonObject, keys: Set<String>, depth: Int = 0): String? {
            if (depth > 4) return null // undocumented shape; don't walk forever
            for ((key, value) in obj) {
                if (key in keys) {
                    val text = runCatching { value.jsonPrimitive.content }.getOrNull()
                    if (!text.isNullOrBlank() && text != "null") return text
                }
            }
            // Breadth first: a top-level `email` should win over one nested
            // inside an organization the user merely belongs to.
            for ((_, value) in obj) {
                val nested = runCatching { value.jsonObject }.getOrNull() ?: continue
                findString(nested, keys, depth + 1)?.let { return it }
            }
            return null
        }
    }
}
