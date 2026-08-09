package com.allthingsclaude.battery.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.allthingsclaude.battery.core.ReleaseFeed
import com.allthingsclaude.battery.core.UsageApi
import com.allthingsclaude.battery.core.UrlConnectionTransport

/**
 * Checks GitHub Releases for a newer APK.
 *
 * This has no iOS or macOS counterpart, which is why it is real scope rather
 * than polish: the Mac app has Sparkle, the iPhone app has TestFlight, and a
 * sideloaded APK has neither. Without it a shipped build is frozen forever on
 * whatever device installed it.
 *
 * Deliberately **check-and-hand-off**, not download-and-install. Downloading the
 * APK ourselves would mean requesting `REQUEST_INSTALL_PACKAGES` — a permission
 * that lets an app install arbitrary software and is one of the most abused on
 * the platform. Opening the release page in a browser gets the user the same
 * APK, through the download flow they already understand, with the system's own
 * install confirmation. The cost is two extra taps; the saving is a permission
 * this app has no business holding.
 */
class UpdateChecker(private val context: Context) {

    private val currentVersion: String
        get() = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull() ?: "0"

    /**
     * @return the newer release, or null when up to date or the check fails.
     *
     * Pages until it finds an Android release rather than reading one page and
     * giving up. Three tag namespaces share this feed and the other two ship far
     * more often — at the time of writing there were forty `v*` and `ios-v*`
     * releases and no `android-v*` at all. A single page of thirty would have
     * gone blind the moment that many newer releases stacked on top of the
     * current Android one, and the symptom is silence: every install says it is
     * up to date, which is exactly what it says when it genuinely is.
     */
    fun check(transport: UsageApi.HttpTransport = UrlConnectionTransport()): ReleaseFeed.Release? {
        for (page in 1..MAX_PAGES) {
            val response = runCatching {
                transport.request(
                    url = releasesUrl(page),
                    method = "GET",
                    headers = mapOf(
                        "Accept" to "application/vnd.github+json",
                        "User-Agent" to "Battery-Android",
                    ),
                    body = null,
                )
            }.getOrNull() ?: return null

            if (response.code != 200) return null

            ReleaseFeed.newestOnPage(response.body)?.let { newest ->
                // The first Android release found is the newest one, because the
                // feed is ordered newest-first. Whether it is an *update* is a
                // separate question, and either way there is no reason to page on.
                return newest.takeIf {
                    ReleaseFeed.compareVersions(it.version, currentVersion) > 0
                }
            }

            // A short page is the end of the feed, so there is nothing further back.
            if (ReleaseFeed.itemCount(response.body) < PER_PAGE) return null
        }
        return null
    }

    fun openRelease(available: ReleaseFeed.Release) {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(available.url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    private companion object {
        /** 100 is the GitHub API's maximum; asking for less only costs more requests. */
        const val PER_PAGE = 100

        /**
         * 500 releases back. Far enough that reaching the limit means something
         * else is wrong, and bounded so a malformed feed cannot loop the check.
         */
        const val MAX_PAGES = 5

        fun releasesUrl(page: Int) =
            "https://api.github.com/repos/allthingsclaude/battery/releases" +
                "?per_page=$PER_PAGE&page=$page"
    }
}
