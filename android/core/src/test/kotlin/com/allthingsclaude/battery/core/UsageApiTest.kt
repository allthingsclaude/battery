package com.allthingsclaude.battery.core

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The API client's parsing and refresh behaviour, driven through a fake
 * transport. The iOS original has no such seam, so none of this is covered
 * there — several of these cases are bugs that would only ever show up as a
 * blank widget on someone's phone.
 */
class UsageApiTest {

    private class FakeTransport(
        var respond: (url: String, method: String, body: String?) -> UsageApi.HttpTransport.Response,
    ) : UsageApi.HttpTransport {
        val calls = mutableListOf<Triple<String, String, String?>>()
        override fun request(
            url: String,
            method: String,
            headers: Map<String, String>,
            body: String?,
        ): UsageApi.HttpTransport.Response {
            calls += Triple(url, method, body)
            return respond(url, method, body)
        }
    }

    private fun ok(body: String) = UsageApi.HttpTransport.Response(200, body)

    private val fullUsage = """
        {
          "five_hour":      { "utilization": 87.5, "resets_at": "2026-01-01T14:13:00.000Z" },
          "seven_day":      { "utilization": 63.0, "resets_at": "2026-01-04T00:00:00Z" },
          "seven_day_opus": { "utilization": 21.0, "resets_at": "2026-01-04T00:00:00Z" }
        }
    """.trimIndent()

    // ── Parsing ─────────────────────────────────────────────────────────────

    @Test
    fun `parses a full usage response`() {
        val usage = UsageApi.parseUsage(fullUsage)
        assertEquals(87.5, usage.fiveHour?.utilization)
        assertEquals(63.0, usage.sevenDay.utilization)
        assertEquals(21.0, usage.sevenDayOpus?.utilization)
        assertNotNull(usage.fiveHour?.resetsAt)
    }

    @Test
    fun `parses both ISO-8601 shapes the API sends`() {
        // With fractional seconds and without. iOS tries two formatters for the
        // same reason; getting this wrong silently nulls every reset time, which
        // kills the countdown and the whole forecast.
        assertNotNull(UsageApi.parseInstant("2026-01-01T14:13:00.000Z"))
        assertNotNull(UsageApi.parseInstant("2026-01-01T14:13:00Z"))
        assertNotNull(UsageApi.parseInstant("2026-01-01T14:13:00+02:00"))
        assertNull(UsageApi.parseInstant("not a date"))
    }

    @Test
    fun `tolerates a missing five_hour window`() {
        // Real and common: between sessions there is no open 5-hour window. The
        // app must render "no session" rather than fail the whole poll.
        val usage = UsageApi.parseUsage(
            """{ "seven_day": { "utilization": 12.0, "resets_at": null } }"""
        )
        assertNull(usage.fiveHour)
        assertNull(usage.sevenDayOpus)
        assertNull(usage.sevenDay.resetsAt)
    }

    @Test
    fun `ignores unknown fields`() {
        val usage = UsageApi.parseUsage(
            """{ "seven_day": { "utilization": 5.0 }, "brand_new_field": { "x": 1 } }"""
        )
        assertEquals(5.0, usage.sevenDay.utilization)
    }

    @Test
    fun `a response with no seven_day bucket is a decoding failure`() {
        assertFailsWith<IllegalArgumentException> { UsageApi.parseUsage("""{ "five_hour": {} }""") }
    }

    @Test
    fun `a rate_limit_tier, if one ever appears, is ignored rather than parsed`() {
        // The plan comes from ProfileApi. This endpoint sends no tier at all,
        // and a second mapping of the same thing is how the two disagree — see
        // `every tier maps to something a reader recognises` in SessionHistoryTest.
        val usage = UsageApi.parseUsage(
            """{ "seven_day": { "utilization": 1.0 }, "rate_limit_tier": "claude_max_5x" }"""
        )
        assertEquals(1.0, usage.sevenDay.utilization)
    }

    // ── Token refresh ───────────────────────────────────────────────────────

    @Test
    fun `a refresh response without a refresh_token carries the old one forward`() {
        // The token server does not always rotate. Dropping the existing refresh
        // token here would sign the account out on the *next* poll, an hour
        // later, with no obvious cause.
        val previous = StoredTokens("old-access", "keep-me", System.currentTimeMillis())
        val tokens = UsageApi.parseTokens(
            """{ "access_token": "new-access", "expires_in": 3600 }""",
            previous,
        )
        assertEquals("new-access", tokens.accessToken)
        assertEquals("keep-me", tokens.refreshToken)
    }

    @Test
    fun `a rotated refresh token replaces the old one`() {
        val previous = StoredTokens("old", "old-refresh", System.currentTimeMillis())
        val tokens = UsageApi.parseTokens(
            """{ "access_token": "a", "refresh_token": "rotated", "expires_in": 60 }""",
            previous,
        )
        assertEquals("rotated", tokens.refreshToken)
    }

    @Test
    fun `an expiring token triggers a refresh before the usage call`() {
        val expiring = StoredTokens("stale", "refresh-me", System.currentTimeMillis() + 10_000)
        assertTrue(expiring.isExpiringSoon())

        val transport = FakeTransport { url, _, _ ->
            if (url == AppConfig.OAUTH_TOKEN_URL) {
                ok("""{ "access_token": "fresh", "refresh_token": "r2", "expires_in": 3600 }""")
            } else {
                ok(fullUsage)
            }
        }

        val (usage, updated) = UsageApi("Battery/test", transport).fetchUsage(expiring)

        assertEquals(87.5, usage.fiveHour?.utilization)
        assertEquals("fresh", assertNotNull(updated).accessToken)
        assertEquals(AppConfig.OAUTH_TOKEN_URL, transport.calls.first().first)
        assertEquals(2, transport.calls.size)
    }

    @Test
    fun `a rotated token is persisted even when the usage request then fails`() {
        // The bug this pins: refresh succeeds and the server ROTATES the refresh
        // token, then the usage GET fails. If persistence only happened on the
        // success path, storage would keep a token the server has already
        // invalidated — and the next poll would 400 into a silent sign-out with
        // no visible cause. A flaky phone connection makes this routine.
        val expiring = StoredTokens("stale", "old-refresh", System.currentTimeMillis())
        val transport = FakeTransport { url, _, _ ->
            if (url == AppConfig.OAUTH_TOKEN_URL) {
                ok("""{ "access_token": "fresh", "refresh_token": "ROTATED", "expires_in": 3600 }""")
            } else {
                UsageApi.HttpTransport.Response(500, "")
            }
        }

        var persisted: StoredTokens? = null
        assertFailsWith<UsageApiError.Server> {
            UsageApi("Battery/test", transport).fetchUsage(expiring) { persisted = it }
        }

        assertEquals(
            "ROTATED",
            assertNotNull(persisted, "rotated token must be handed over before the GET").refreshToken,
        )
    }

    @Test
    fun `a valid token skips the refresh entirely`() {
        val valid = StoredTokens("good", "r", System.currentTimeMillis() + 3_600_000)
        val transport = FakeTransport { _, _, _ -> ok(fullUsage) }

        val (_, updated) = UsageApi("Battery/test", transport).fetchUsage(valid)

        assertNull(updated, "no refresh happened, so nothing to persist")
        assertEquals(1, transport.calls.size)
    }

    @Test
    fun `an expiring token with no refresh token is unauthorized`() {
        val doomed = StoredTokens("stale", null, System.currentTimeMillis())
        val transport = FakeTransport { _, _, _ -> ok(fullUsage) }
        assertFailsWith<UsageApiError.Unauthorized> {
            UsageApi("Battery/test", transport).fetchUsage(doomed)
        }
        assertTrue(transport.calls.isEmpty(), "must not hit the network at all")
    }

    // ── HTTP status mapping ─────────────────────────────────────────────────

    @Test
    fun `401 is unauthorized and 500 is a server error`() {
        val api = { code: Int ->
            UsageApi("Battery/test", FakeTransport { _, _, _ ->
                UsageApi.HttpTransport.Response(code, "")
            })
        }
        assertFailsWith<UsageApiError.Unauthorized> { api(401).requestUsage("t") }
        assertFailsWith<UsageApiError.Server> { api(500).requestUsage("t") }
    }

    @Test
    fun `429 carries Retry-After through so backoff can honour it`() {
        val api = UsageApi("Battery/test", FakeTransport { _, _, _ ->
            UsageApi.HttpTransport.Response(429, "", mapOf("Retry-After" to "120"))
        })
        val error = assertFailsWith<UsageApiError.RateLimited> { api.requestUsage("t") }
        assertEquals(120L, error.retryAfterSeconds)
    }

    @Test
    fun `a refresh rejection is unauthorized, not a server error`() {
        // 400 from the token endpoint means the grant is dead, not that we sent a
        // bad request. Treating it as retryable would spin forever.
        for (code in listOf(400, 401, 403)) {
            val api = UsageApi("Battery/test", FakeTransport { _, _, _ ->
                UsageApi.HttpTransport.Response(code, """{"error":"invalid_grant"}""")
            })
            assertFailsWith<UsageApiError.Unauthorized> {
                api.refreshTokens("r", StoredTokens("a", "r", 0))
            }
        }
    }

    @Test
    fun `a transport exception becomes a network error, not a crash`() {
        val api = UsageApi("Battery/test", FakeTransport { _, _, _ -> throw java.io.IOException("offline") })
        assertFailsWith<UsageApiError.Network> { api.requestUsage("t") }
    }

    @Test
    fun `malformed JSON becomes a decoding error`() {
        val api = UsageApi("Battery/test", FakeTransport { _, _, _ -> ok("not json at all") })
        assertFailsWith<UsageApiError.Decoding> { api.requestUsage("t") }
    }

    // ── Payload construction ────────────────────────────────────────────────

    @Test
    fun `payload carries the forecast the surfaces will render`() {
        val now = Instant.parse("2026-01-01T12:00:00Z")
        val history = SessionHistory(InMemorySnapshotStore())
        val reset = now.plusSeconds(3600)

        // Three samples, 60% per hour, spanning more than MINIMUM_TIME_SPAN.
        history.record(10.0, reset, now.minusSeconds(1200))
        history.record(20.0, reset, now.minusSeconds(600))
        val projection = history.record(30.0, reset, now)

        assertTrue(projection.ratePerHour > 50, "expected ~60%/hr, got ${projection.ratePerHour}")

        val forecast = UsageForecast(
            utilization = 30.0,
            resetsAt = reset,
            burnRatePerHour = projection.ratePerHour,
            projectedLimitAt = projection.limitAt,
            isSessionActive = true,
            now = now,
        )
        // 30% now, ~60%/hr, one hour left → lands at ~90%, under the limit.
        assertEquals(UsageForecast.Outlook.ON_PACE, forecast.outlook)
        assertEquals(UsageForecast.Pace.MEASURED, forecast.pace)
        assertTrue(forecast.headline.startsWith("On pace for"), forecast.headline)
    }
}
