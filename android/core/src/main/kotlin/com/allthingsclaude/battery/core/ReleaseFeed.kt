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
     * Takes the full releases list rather than `/latest`, because this repository
     * publishes three tag namespaces into one feed and `/latest` would cheerfully
     * hand back a macOS release.
     */
    fun newestRelease(body: String, currentVersion: String): Release? = runCatching {
        val newest = Json.parseToJsonElement(body).jsonArray
            .map { it.jsonObject }
            .filter { it["draft"]?.jsonPrimitive?.content != "true" }
            .filter { it["prerelease"]?.jsonPrimitive?.content != "true" }
            .firstOrNull { it["tag_name"]?.jsonPrimitive?.content?.startsWith(TAG_PREFIX) == true }
            ?: return null

        val version = newest["tag_name"]!!.jsonPrimitive.content.removePrefix(TAG_PREFIX)
        if (compareVersions(version, currentVersion) <= 0) return null

        Release(version, newest["html_url"]!!.jsonPrimitive.content)
    }.getOrNull()

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
