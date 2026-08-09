package com.allthingsclaude.battery.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * The paging walk in [ReleaseFeed.findNewer].
 *
 * The walk had no coverage at all while it lived in `UpdateChecker`, because
 * `app` has no test source set and the class needed a `Context` to name its own
 * version. Moving it here was most of the point: this is the half with a loop, a
 * page boundary and four distinct failure modes, and the one whose bugs are
 * invisible — an updater that wrongly reports "up to date" looks exactly like an
 * updater that works.
 */
class ReleaseWalkTest {

    private class FakeTransport(
        val respond: (page: Int) -> UsageApi.HttpTransport.Response,
    ) : UsageApi.HttpTransport {
        val requested = mutableListOf<String>()
        val userAgents = mutableListOf<String?>()

        override fun request(
            url: String,
            method: String,
            headers: Map<String, String>,
            body: String?,
        ): UsageApi.HttpTransport.Response {
            requested += url
            userAgents += headers["User-Agent"]
            // substringAfterLast, because `per_page=` contains `page=` and the
            // first match would read "100&page=1".
            return respond(url.substringAfterLast("page=").toInt())
        }
    }

    private fun release(tag: String) =
        """{"tag_name":"$tag","html_url":"https://x/$tag","draft":false,"prerelease":false}"""

    private fun feed(entries: List<String>) = entries.joinToString(",", "[", "]")

    private fun ok(entries: List<String>) =
        UsageApi.HttpTransport.Response(200, feed(entries))

    /** A page with nothing Android on it, long enough that the walk continues. */
    private fun fullPageOfOtherPlatforms(page: Int) =
        ok(List(ReleaseFeed.PER_PAGE) { release("v$page.$it.0") })

    // ── Finding ─────────────────────────────────────────────────────────────

    @Test
    fun `a newer android release on the first page is offered`() {
        val transport = FakeTransport { ok(listOf(release("v9.0.0"), release("android-v0.2.0"))) }
        val result = ReleaseFeed.findNewer(transport, currentVersion = "0.1.0")

        assertEquals(ReleaseFeed.Check.Available(ReleaseFeed.Release("0.2.0", "https://x/android-v0.2.0")), result)
        assertEquals(1, transport.requested.size)
    }

    @Test
    fun `the walk pages past a full page carrying no android release`() {
        // The bug the paging exists for. Two other tag namespaces share this feed
        // and ship far more often, so the newest Android release sinks out of the
        // first page and a single-page check goes permanently quiet.
        val transport = FakeTransport { page ->
            if (page < 3) fullPageOfOtherPlatforms(page) else ok(listOf(release("android-v0.2.0")))
        }
        val result = ReleaseFeed.findNewer(transport, currentVersion = "0.1.0")

        assertIs<ReleaseFeed.Check.Available>(result)
        assertEquals("0.2.0", result.release.version)
        assertEquals(3, transport.requested.size)
    }

    @Test
    fun `a short page with no android release ends the walk as NoRelease`() {
        // Not UpToDate. The feed reached its end without saying anything about
        // this build, and claiming it is current would be a guess dressed as an
        // answer — which is the shape of the failure this whole type prevents.
        val transport = FakeTransport { ok(listOf(release("v1.0.0"), release("ios-v1.0.0"))) }

        assertEquals(ReleaseFeed.Check.NoRelease, ReleaseFeed.findNewer(transport, "0.1.0"))
        assertEquals(1, transport.requested.size)
    }

    @Test
    fun `the walk stops at the page limit rather than running forever`() {
        val transport = FakeTransport { page -> fullPageOfOtherPlatforms(page) }

        assertEquals(ReleaseFeed.Check.NoRelease, ReleaseFeed.findNewer(transport, "0.1.0"))
        assertEquals(ReleaseFeed.MAX_PAGES, transport.requested.size)
    }

    @Test
    fun `the current version is up to date, and does not page on`() {
        val transport = FakeTransport { page ->
            if (page == 1) ok(listOf(release("android-v0.1.0"))) else fullPageOfOtherPlatforms(page)
        }

        assertEquals(ReleaseFeed.Check.UpToDate, ReleaseFeed.findNewer(transport, "0.1.0"))
        // The first Android release found is the newest one — the feed is ordered
        // newest-first, so there is nothing better deeper in and no reason to look.
        assertEquals(1, transport.requested.size)
    }

    @Test
    fun `an older android release is up to date, not an update`() {
        val transport = FakeTransport { ok(listOf(release("android-v0.1.0"))) }
        assertEquals(ReleaseFeed.Check.UpToDate, ReleaseFeed.findNewer(transport, "0.9.0"))
    }

    // ── Failing ─────────────────────────────────────────────────────────────

    @Test
    fun `a transport that throws is offline, not up to date`() {
        val transport = object : UsageApi.HttpTransport {
            override fun request(
                url: String,
                method: String,
                headers: Map<String, String>,
                body: String?,
            ): UsageApi.HttpTransport.Response = throw java.io.IOException("no network")
        }

        assertEquals(
            ReleaseFeed.Check.Failed(ReleaseFeed.Check.Reason.OFFLINE),
            ReleaseFeed.findNewer(transport, "0.1.0"),
        )
    }

    @Test
    fun `a server error is reported as one`() {
        val transport = FakeTransport { UsageApi.HttpTransport.Response(500, "") }
        assertEquals(
            ReleaseFeed.Check.Failed(ReleaseFeed.Check.Reason.SERVER),
            ReleaseFeed.findNewer(transport, "0.1.0"),
        )
    }

    @Test
    fun `an exhausted quota is told apart from a refusal`() {
        // GitHub answers a spent unauthenticated quota with 403 (classic) or 429,
        // both carrying x-ratelimit-remaining: 0. Worth separating: "rate limited"
        // tells the user to wait, "GitHub said no" tells them nothing actionable.
        listOf(403, 429).forEach { code ->
            val limited = FakeTransport {
                UsageApi.HttpTransport.Response(code, "", mapOf("x-ratelimit-remaining" to "0"))
            }
            assertEquals(
                ReleaseFeed.Check.Failed(ReleaseFeed.Check.Reason.RATE_LIMITED),
                ReleaseFeed.findNewer(limited, "0.1.0"),
                "$code with a spent quota",
            )
        }

        val forbidden = FakeTransport {
            UsageApi.HttpTransport.Response(403, "", mapOf("x-ratelimit-remaining" to "57"))
        }
        assertEquals(
            ReleaseFeed.Check.Failed(ReleaseFeed.Check.Reason.SERVER),
            ReleaseFeed.findNewer(forbidden, "0.1.0"),
        )
    }

    @Test
    fun `the rate-limit header is matched whatever its casing`() {
        // HTTP/2 mandates lowercase field names on the wire, but the real
        // transport hands back a case-insensitive map precisely because callers
        // should not have to care. This pins that the lookup relies on it.
        val transport = FakeTransport {
            UsageApi.HttpTransport.Response(
                403,
                "",
                java.util.TreeMap<String, String>(String.CASE_INSENSITIVE_ORDER)
                    .apply { put("X-RateLimit-Remaining", "0") },
            )
        }
        assertEquals(
            ReleaseFeed.Check.Failed(ReleaseFeed.Check.Reason.RATE_LIMITED),
            ReleaseFeed.findNewer(transport, "0.1.0"),
        )
    }

    @Test
    fun `malformed json is not mistaken for an empty page`() {
        // itemCount reads 0 for garbage, which ends the walk. The answer must be
        // NoRelease rather than UpToDate: nothing was learned about this build.
        val transport = FakeTransport { UsageApi.HttpTransport.Response(200, "not json") }
        assertEquals(ReleaseFeed.Check.NoRelease, ReleaseFeed.findNewer(transport, "0.1.0"))
    }

    // ── Requests ────────────────────────────────────────────────────────────

    @Test
    fun `every request carries a User-Agent and walks the pages in order`() {
        // GitHub rejects requests without a User-Agent outright, which would turn
        // every check into a 403 the user can do nothing about.
        val transport = FakeTransport { page -> fullPageOfOtherPlatforms(page) }
        ReleaseFeed.findNewer(transport, "0.1.0")

        assertTrue(transport.userAgents.all { !it.isNullOrBlank() })
        assertEquals(
            (1..ReleaseFeed.MAX_PAGES).map { "page=$it" },
            transport.requested.map { "page=" + it.substringAfterLast("page=") },
        )
        assertTrue(transport.requested.all { "per_page=${ReleaseFeed.PER_PAGE}" in it })
    }

    @Test
    fun `the feed is read from the repository the build was published from`() {
        // A fork's APK has to find the fork's releases. Hardcoded to upstream, a
        // fork build polls a feed that will never carry them, compares upstream's
        // newest tag against its own version and reports "up to date" — a failure
        // shaped exactly like success, which is this updater's recurring one.
        val fork = FakeTransport { ok(listOf(release("android-v0.2.0"))) }
        ReleaseFeed.findNewer(fork, "0.1.0", repo = "ivanprtljaga/battery")
        assertTrue(fork.requested.all { "/repos/ivanprtljaga/battery/releases" in it })

        val stock = FakeTransport { ok(listOf(release("android-v0.2.0"))) }
        ReleaseFeed.findNewer(stock, "0.1.0")
        assertTrue(stock.requested.all { "/repos/${ReleaseFeed.DEFAULT_REPO}/releases" in it })
    }

    // ── Announcing ──────────────────────────────────────────────────────────

    @Test
    fun `a skipped version stays skipped and a newer one still gets through`() {
        val release = { v: String -> ReleaseFeed.Release(v, "https://x/$v") }

        assertTrue(ReleaseFeed.shouldAnnounce(release("0.2.0"), skippedVersion = null))
        assertFalse(ReleaseFeed.shouldAnnounce(release("0.2.0"), skippedVersion = "0.2.0"))
        assertTrue(ReleaseFeed.shouldAnnounce(release("0.3.0"), skippedVersion = "0.2.0"))
        // Compared, not merely != — skipping ahead must not resurrect an older
        // release, which a plain inequality would happily announce.
        assertFalse(ReleaseFeed.shouldAnnounce(release("0.1.0"), skippedVersion = "0.2.0"))
        // And double digits sort numerically here too, or the notice dies at 0.10.
        assertTrue(ReleaseFeed.shouldAnnounce(release("0.10.0"), skippedVersion = "0.9.0"))
    }
}
