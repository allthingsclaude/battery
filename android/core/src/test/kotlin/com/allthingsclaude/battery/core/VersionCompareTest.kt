package com.allthingsclaude.battery.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Version ordering and release-feed parsing for the in-app updater.
 *
 * An earlier revision of this file re-implemented `compareVersions` locally so
 * it could be tested without a Context — a test that duplicates the code it
 * checks passes even when the real implementation is wrong. The logic moved to
 * [ReleaseFeed] instead, and this exercises it directly.
 */
class VersionCompareTest {

    @Test
    fun `double-digit components sort numerically, not lexically`() {
        // The bug this exists for: a string compare ranks "0.10.0" below
        // "0.9.0", so the updater would silently stop offering updates at
        // exactly the version where a project has shipped ten times.
        assertTrue(ReleaseFeed.compareVersions("0.10.0", "0.9.0") > 0)
        assertTrue(ReleaseFeed.compareVersions("1.0.0", "0.99.99") > 0)
        assertTrue(ReleaseFeed.compareVersions("0.2.10", "0.2.9") > 0)
    }

    @Test
    fun `equal versions do not offer an update`() {
        assertTrue(ReleaseFeed.compareVersions("1.2.3", "1.2.3") == 0)
        // Trailing zeros are the same version, not a newer one — otherwise the
        // updater would prompt forever after a release tagged without a patch.
        assertTrue(ReleaseFeed.compareVersions("1.2", "1.2.0") == 0)
    }

    @Test
    fun `older versions are older`() {
        assertTrue(ReleaseFeed.compareVersions("0.1.0", "0.2.0") < 0)
        assertTrue(ReleaseFeed.compareVersions("1.0.0", "2.0.0") < 0)
    }

    @Test
    fun `a suffixed component still compares`() {
        // Tags like "0.3.0-beta1" shouldn't parse to 0 and rank below everything.
        assertTrue(ReleaseFeed.compareVersions("0.3.0-beta1", "0.2.0") > 0)
    }

    @Test
    fun `garbage sorts as zero rather than throwing`() {
        // versionName can be absent on an oddly-built APK. Returning "no update"
        // is the safe failure; an exception in the update check would surface as
        // a crash on launch.
        assertTrue(ReleaseFeed.compareVersions("", "0.0.0") == 0)
        assertTrue(ReleaseFeed.compareVersions("unknown", "0.1.0") < 0)
    }

    // ── Release feed ────────────────────────────────────────────────────────

    private fun release(tag: String, draft: Boolean = false, prerelease: Boolean = false) =
        """{"tag_name":"$tag","html_url":"https://x/$tag","draft":$draft,"prerelease":$prerelease}"""

    private fun feed(vararg entries: String) = entries.joinToString(",", "[", "]")

    @Test
    fun `only android tags are considered`() {
        // This repository publishes three tag namespaces into ONE release feed,
        // which is why the updater reads the list rather than /latest — /latest
        // would cheerfully hand back a macOS release and offer it as an APK.
        val body = feed(
            release("v0.9.0"),        // macOS, newest overall
            release("ios-v0.5.0"),    // iPhone
            release("android-v0.2.0"),
        )
        val found = ReleaseFeed.newestRelease(body, currentVersion = "0.1.0")
        assertEquals("0.2.0", found?.version)
    }

    @Test
    fun `drafts and prereleases are skipped`() {
        val body = feed(
            release("android-v0.9.0", draft = true),
            release("android-v0.8.0", prerelease = true),
            release("android-v0.3.0"),
        )
        assertEquals("0.3.0", ReleaseFeed.newestRelease(body, "0.1.0")?.version)
    }

    @Test
    fun `the current version is not offered to itself`() {
        val body = feed(release("android-v0.4.0"))
        assertNull(ReleaseFeed.newestRelease(body, currentVersion = "0.4.0"))
        assertNull(ReleaseFeed.newestRelease(body, currentVersion = "0.5.0"))
        assertEquals("0.4.0", ReleaseFeed.newestRelease(body, currentVersion = "0.3.9")?.version)
    }

    @Test
    fun `a feed with no android release yields nothing`() {
        assertNull(ReleaseFeed.newestRelease(feed(release("v1.0.0")), "0.1.0"))
        assertNull(ReleaseFeed.newestRelease("[]", "0.1.0"))
    }

    @Test
    fun `malformed json returns null rather than throwing`() {
        // The update check runs on launch. An exception here would be a crash on
        // startup caused by a bad response from a third-party API.
        assertNull(ReleaseFeed.newestRelease("not json", "0.1.0"))
        assertNull(ReleaseFeed.newestRelease("""[{"no_tag":1}]""", "0.1.0"))
    }

    // ── Paging ──────────────────────────────────────────────────────────────

    @Test
    fun `a page of only other-platform releases is not the same as no update`() {
        // The distinction the paging caller turns on. Both of these return null
        // from newestRelease, but they mean opposite things: the first says keep
        // looking, the second says stop. Collapsing them is what let the newest
        // Android release fall off the end of the window unnoticed.
        val otherPlatformsOnly = feed(release("v0.9.0"), release("ios-v0.5.0"))
        assertNull(ReleaseFeed.newestOnPage(otherPlatformsOnly))

        val androidButOlder = feed(release("android-v0.1.0"))
        assertEquals("0.1.0", ReleaseFeed.newestOnPage(androidButOlder)?.version)
        assertNull(ReleaseFeed.newestRelease(androidButOlder, currentVersion = "0.1.0"))
    }

    @Test
    fun `itemCount reports the page size so a short page ends the walk`() {
        assertEquals(2, ReleaseFeed.itemCount(feed(release("v1.0.0"), release("v0.9.0"))))
        assertEquals(0, ReleaseFeed.itemCount("[]"))
        // Unreadable counts as empty, which stops the walk rather than looping
        // to the page limit against an endpoint that is clearly not helping.
        assertEquals(0, ReleaseFeed.itemCount("not json"))
    }

    @Test
    fun `newestOnPage ignores drafts and prereleases like newestRelease does`() {
        val body = feed(
            release("android-v0.9.0", draft = true),
            release("android-v0.8.0", prerelease = true),
            release("android-v0.3.0"),
        )
        assertEquals("0.3.0", ReleaseFeed.newestOnPage(body)?.version)
    }
}
