package com.allthingsclaude.battery.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Parsing and version ordering for the in-app updater.
 *
 * Lives here rather than beside the Android `UpdateChecker` so it can be tested
 * without a `Context` — this is the half that can actually be wrong, and the
 * alternative was a test that re-implemented the comparison it was checking.
 */
object ReleaseFeed {

    data class Release(val version: String, val url: String)

    /** Tags this app publishes under, distinct from `v*` (Mac) and `ios-v*`. */
    const val TAG_PREFIX = "android-v"

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
}
