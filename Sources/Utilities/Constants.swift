import Foundation

/// App-wide constants.
enum Constants {
    static let apiBaseURL = "https://api.anthropic.com"
    static let betaHeader = "oauth-2025-04-20"

    // OAuth PKCE
    static let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let oauthAuthorizeURL = "https://claude.ai/oauth/authorize"
    static let oauthTokenURL = "https://platform.claude.com/v1/oauth/token"
    static let oauthScopes = "user:profile user:inference"
    static let oauthRedirectPath = "/callback"
    // Kept in step with Info.plist by Scripts/release.sh.
    static let userAgent = "Battery/0.8.3"

    // Push relay — the Cloudflare Worker that forwards Live Activity updates to
    // the iPhone app (see worker/).
    //
    // Ships EMPTY on purpose, which hides the whole feature. A relay's APNs key
    // is bound to one Apple team, so a shared URL can only ever work for that
    // team's builds — anyone else pairing would register push tokens against a
    // relay that can't reach their app. Self-hosters point this at their own
    // Worker without rebuilding:
    //   defaults write com.allthingsclaude.battery pushRelayURL https://…workers.dev
    static let pushRelayURL = ""

    // Polling intervals (seconds)
    static let defaultPollInterval: TimeInterval = 60
    static let activePollInterval: TimeInterval = 60
    static let idlePollInterval: TimeInterval = 300

    // Notification thresholds
    static let defaultThresholds: [Int] = [80, 90, 95]

    // Database
    static let dataRetentionDays: Int = 90

    // Stats — how far back the heat map reaches. Five weeks so the grid in
    // StatsView (5 rows × 7 days, week-aligned) is always fully covered.
    static let heatMapDays: Int = 35

    // Stats — how far back Battery keeps its own copy of local daily activity.
    //
    // Neither source it reads is durable: Claude Code's `stats-cache.json` is a
    // rolling 30-day window, and the session transcripts the gaps are rebuilt
    // from are deleted after `cleanupPeriodDays` (30 by default). A day older
    // than that survives only because Battery wrote it down while it was still
    // visible, so the archive has to outlive both. A year bounds the file at a
    // few tens of kilobytes while reaching well past any streak worth showing.
    static let localHistoryRetentionDays: Int = 365

    // UI — Tahoe-style corner radius for the menu bar panel
    static let panelCornerRadius: CGFloat = 24
}
