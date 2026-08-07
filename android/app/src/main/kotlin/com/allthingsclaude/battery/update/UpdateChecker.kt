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

    /** @return the newer release, or null when up to date or the check fails. */
    fun check(transport: UsageApi.HttpTransport = UrlConnectionTransport()): ReleaseFeed.Release? {
        val response = runCatching {
            transport.request(
                url = RELEASES_URL,
                method = "GET",
                headers = mapOf(
                    "Accept" to "application/vnd.github+json",
                    "User-Agent" to "Battery-Android",
                ),
                body = null,
            )
        }.getOrNull() ?: return null

        if (response.code != 200) return null
        return ReleaseFeed.newestRelease(response.body, currentVersion)
    }

    fun openRelease(available: ReleaseFeed.Release) {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(available.url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    private companion object {
        const val RELEASES_URL =
            "https://api.github.com/repos/allthingsclaude/battery/releases?per_page=30"
    }
}
