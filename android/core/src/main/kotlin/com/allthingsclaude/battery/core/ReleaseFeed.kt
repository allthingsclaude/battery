package com.allthingsclaude.battery.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Reading the GitHub releases feed for the in-app updater.
 *
 * Lives here rather than beside the Android `UpdateChecker` so it can be tested
 * without a `Context` — this is the half that can actually be wrong, and the
 * alternative was a test that re-implemented the comparison it was checking.
 * The HTTP arrives through an injected [UsageApi.HttpTransport] for the same
 * reason, which leaves `UpdateChecker` holding only what genuinely needs Android:
 * the installed version and the intent that opens a browser.
 */
object ReleaseFeed {

    data class Release(val version: String, val url: String)

    /**
     * The outcome of one update check.
     *
     * Four answers rather than a nullable [Release], because the automatic check
     * and the manual one report them differently: "up to date" is worth saying
     * only when the user asked, and a failure is worth saying *only* when the
     * user asked. A null cannot carry that distinction — and collapsing separate
     * answers into one null is precisely the bug that made this updater go quiet
     * a layer down, where "no Android release on this page" and "no newer release"
     * were the same value.
     */
    sealed interface Check {
        data class Available(val release: Release) : Check

        /** A newer release was looked for and does not exist. */
        data object UpToDate : Check

        /**
         * The feed ran out — or ran to [MAX_PAGES] — without one Android release
         * on it.
         *
         * Distinct from [UpToDate], which claims the installed build is current.
         * This claims nothing: it is the answer when the feed cannot say. It was
         * the real state of this repository until `android-v0.1.0`, and reporting
         * it as "up to date" would have been a lie that looked like good news.
         */
        data object NoRelease : Check

        data class Failed(val reason: Reason) : Check

        enum class Reason {
            /** The request never completed — no network, DNS, timeout. */
            OFFLINE,

            /** GitHub's unauthenticated quota is spent. Sixty requests an hour, per IP. */
            RATE_LIMITED,

            /** Any other non-200. */
            SERVER,
        }
    }

    /** Tags this app publishes under, distinct from `v*` (Mac) and `ios-v*`. */
    const val TAG_PREFIX = "android-v"

    /**
     * Walk the feed for a release newer than [currentVersion].
     *
     * Pages rather than reading one page and giving up. Three tag namespaces
     * share this feed and the other two ship far more often — at the time of
     * writing there were forty `v*` and `ios-v*` releases and one `android-v*`.
     * A single page would go blind the moment that many newer releases stacked
     * on top of the current Android one, and the symptom is silence: every
     * install says it is up to date, which is exactly what it says when it
     * genuinely is.
     *
     * Blocking. Up to [MAX_PAGES] sequential requests, so callers run it off the
     * main thread.
     */
    fun findNewer(
        transport: UsageApi.HttpTransport,
        currentVersion: String,
        repo: String = DEFAULT_REPO,
    ): Check {
        for (page in 1..MAX_PAGES) {
            val response = runCatching {
                transport.request(releasesUrl(repo, page), "GET", REQUEST_HEADERS, null)
            }.getOrNull() ?: return Check.Failed(Check.Reason.OFFLINE)

            if (response.code != 200) return Check.Failed(reasonFor(response))

            newestOnPage(response.body)?.let { newest ->
                // The first Android release found is the newest one, because the
                // feed is ordered newest-first. Whether it is an *update* is a
                // separate question, and either way there is no reason to page on.
                return if (compareVersions(newest.version, currentVersion) > 0) {
                    Check.Available(newest)
                } else {
                    Check.UpToDate
                }
            }

            // A short page is the end of the feed, so there is nothing further back.
            if (itemCount(response.body) < PER_PAGE) return Check.NoRelease
        }
        // Five hundred releases deep with no Android tag. Something is wrong with
        // the feed or the prefix, and the one thing this must not do is shrug and
        // call it up to date.
        return Check.NoRelease
    }

    /**
     * Whether [release] is worth interrupting the user about, given the version
     * they last dismissed.
     *
     * Compares rather than testing inequality against [skippedVersion]. Skipping
     * 0.2.0 has to keep 0.2.0 quiet *and* let 0.3.0 through — an `!=` does the
     * first, and would also re-announce 0.1.0 to someone who had skipped ahead.
     */
    fun shouldAnnounce(release: Release, skippedVersion: String?): Boolean =
        skippedVersion == null || compareVersions(release.version, skippedVersion) > 0

    /**
     * The newest Android release strictly newer than [currentVersion], or null.
     *
     * Takes the releases list rather than `/latest`, because this repository
     * publishes three tag namespaces into one feed and `/latest` would cheerfully
     * hand back a macOS release.
     *
     * Single-page. [newestOnPage] plus [itemCount] are what the caller uses to
     * walk past a page with no Android release on it at all — see the note there.
     */
    fun newestRelease(body: String, currentVersion: String): Release? =
        newestOnPage(body)?.takeIf { compareVersions(it.version, currentVersion) > 0 }

    /**
     * The newest Android release on one page of the feed, ignoring version.
     *
     * Separate from [newestRelease] because "this page has no Android release"
     * and "there is no newer Android release" are different answers and only the
     * caller can tell them apart — the first means keep paging, the second means
     * stop. Collapsing them is what made the updater go quiet: filtering happens
     * *after* the page boundary, so once enough macOS and iOS releases pile up on
     * top, the newest Android release is simply not in the window, and every
     * install reports "up to date" indefinitely.
     */
    fun newestOnPage(body: String): Release? = runCatching {
        val newest = Json.parseToJsonElement(body).jsonArray
            .map { it.jsonObject }
            .filter { it["draft"]?.jsonPrimitive?.content != "true" }
            .filter { it["prerelease"]?.jsonPrimitive?.content != "true" }
            .firstOrNull { it["tag_name"]?.jsonPrimitive?.content?.startsWith(TAG_PREFIX) == true }
            ?: return null

        Release(
            newest["tag_name"]!!.jsonPrimitive.content.removePrefix(TAG_PREFIX),
            newest["html_url"]!!.jsonPrimitive.content,
        )
    }.getOrNull()

    /**
     * How many releases a page carried, or 0 if it could not be read.
     *
     * A short page is the end of the feed. Without this the caller cannot tell
     * "no Android release here, try the next page" from "that was the last page",
     * and would keep requesting empty pages up to its own limit.
     */
    fun itemCount(body: String): Int =
        runCatching { Json.parseToJsonElement(body).jsonArray.size }.getOrDefault(0)

    /**
     * Numeric, component-wise comparison.
     *
     * A string compare ranks "0.10.0" below "0.9.0" — which is exactly the
     * version where a project that has shipped ten times would silently stop
     * offering updates, and it would look like the updater simply worked.
     */
    fun compareVersions(a: String, b: String): Int {
        val left = components(a)
        val right = components(b)
        for (i in 0 until maxOf(left.size, right.size)) {
            val l = left.getOrElse(i) { 0 }
            val r = right.getOrElse(i) { 0 }
            if (l != r) return l.compareTo(r)
        }
        return 0
    }

    /** "0.3.0-beta1" → [0, 3, 0]; anything unparseable contributes 0. */
    private fun components(version: String): List<Int> =
        version.split('.').map { it.takeWhile(Char::isDigit).toIntOrNull() ?: 0 }

    // ── Feed transport ──────────────────────────────────────────────────────

    /** 100 is the GitHub API's maximum; asking for less only costs more requests. */
    internal const val PER_PAGE = 100

    /**
     * 500 releases back. Far enough that reaching the limit means something else
     * is wrong, and bounded so a malformed feed cannot loop the check.
     */
    internal const val MAX_PAGES = 5

    /**
     * Where releases come from when the build does not say otherwise.
     *
     * A parameter rather than a constant because an APK should look for updates
     * in the repository it was *published from*, and a fork publishes its own.
     * Hardcoded, a fork's build polls upstream, compares upstream's newest tag
     * against its own version and reports "up to date" — the fork's releases are
     * invisible to it, and the failure looks exactly like a working updater. The
     * release workflow passes `-PreleaseRepo=$GITHUB_REPOSITORY`, so this default
     * only applies to a build made by hand.
     */
    const val DEFAULT_REPO = "allthingsclaude/battery"

    /** GitHub rejects requests without a User-Agent outright. */
    private val REQUEST_HEADERS = mapOf(
        "Accept" to "application/vnd.github+json",
        "User-Agent" to "Battery-Android",
    )

    internal fun releasesUrl(repo: String, page: Int) =
        "https://api.github.com/repos/$repo/releases?per_page=$PER_PAGE&page=$page"

    /**
     * An exhausted quota answers 403 (classic) or 429, and both carry
     * `x-ratelimit-remaining: 0`. The header is what separates a spent quota from
     * a genuine refusal, and it is worth the distinction: "rate limited" tells the
     * user to wait, while "GitHub said no" tells them nothing they can act on.
     * [UsageApi.HttpTransport.Response.headers] is case-insensitive, so the
     * lowercase HTTP/2 wire name matches whatever casing arrives.
     */
    private fun reasonFor(response: UsageApi.HttpTransport.Response): Check.Reason =
        if ((response.code == 403 || response.code == 429) &&
            response.headers["x-ratelimit-remaining"] == "0"
        ) {
            Check.Reason.RATE_LIMITED
        } else {
            Check.Reason.SERVER
        }
}
