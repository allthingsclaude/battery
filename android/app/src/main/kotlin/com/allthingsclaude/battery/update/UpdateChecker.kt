package com.allthingsclaude.battery.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.allthingsclaude.battery.BuildConfig
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
 *
 * The walk itself lives in [ReleaseFeed] — `app` has no test source set, and the
 * paging loop is the part that can be wrong. What is left here is the two things
 * that genuinely need a `Context`.
 */
class UpdateChecker(private val context: Context) {

    /** What this build calls itself, as shown in Settings. */
    val currentVersion: String
        get() = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull() ?: "0"

    /**
     * Where this build looks for its updates — stamped in at build time by the
     * release workflow, so an APK checks the repository it was published from.
     * Blank on a hand-made build, which falls back to the canonical default.
     *
     * Public so the check can log it. Which feed answered is not a detail: "up to
     * date" is the same sentence whether the right repository said it or the wrong
     * one did, and telling those apart otherwise means pulling the APK and reading
     * its dex.
     */
    val repo: String
        get() = BuildConfig.RELEASE_REPO.ifBlank { ReleaseFeed.DEFAULT_REPO }

    /** Blocking — up to five sequential requests. Call it off the main thread. */
    fun check(transport: UsageApi.HttpTransport = UrlConnectionTransport()): ReleaseFeed.Check =
        ReleaseFeed.findNewer(transport, currentVersion, repo)

    fun openRelease(available: ReleaseFeed.Release) {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(available.url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }
}
