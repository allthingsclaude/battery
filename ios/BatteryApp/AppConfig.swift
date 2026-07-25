import Foundation

/// iOS-side constants. The OAuth + API values are copied verbatim from the
/// macOS `Constants.swift` so the phone authenticates against exactly the same
/// endpoints and client as Claude Code and the menu bar app.
enum AppConfig {
    // API
    static let apiBaseURL = "https://api.anthropic.com"
    static let betaHeader = "oauth-2025-04-20"
    static let userAgent = BatteryVersion.userAgent

    // OAuth PKCE (same public client as the macOS app)
    static let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let oauthAuthorizeURL = "https://claude.ai/oauth/authorize"
    static let oauthTokenURL = "https://platform.claude.com/v1/oauth/token"
    static let oauthScopes = "user:profile user:inference"

    /// Scopes for the separate grant handed to the push relay for cloud polling.
    ///
    /// Verified against the live API: `user:profile` alone reads
    /// `/api/oauth/usage` in full, and the token server honours the narrowing
    /// rather than silently widening it. Critically it carries **no
    /// `user:inference`**, so a relay holding this credential cannot make calls
    /// billed to the account — which is what makes storing it defensible.
    static let cloudSyncScopes = "user:profile"
    static let oauthRedirectPath = "/callback"

    // Polling cadence (seconds). Foreground uses the active rate; the OS decides
    // when background-refresh tasks actually run, so `background` is only a hint.
    static let foregroundActiveInterval: TimeInterval = 60
    static let foregroundIdleInterval: TimeInterval = 180
    static let backgroundRefreshInterval: TimeInterval = 15 * 60

    // Background task identifier — must also be listed under
    // BGTaskSchedulerPermittedIdentifiers in the app's Info.plist.
    static let bgRefreshTaskID = "com.allthingsclaude.battery.ios.refresh"

    // Keychain access group — must match the entitlement on the app target.
    static let keychainService = "com.allthingsclaude.battery.ios"

    // MARK: - Push relay

    /// Base URL of the Cloudflare Worker that forwards Live Activity updates
    /// from the Mac app to APNs (see `worker/`). Leave empty to build without
    /// it: every relay call becomes a no-op and the app falls back to its own
    /// background refresh, exactly as it behaved before.
    ///
    /// Override at runtime with a `pushRelayURL` default, which is how you point
    /// a debug build at `wrangler dev`:
    ///   xcrun simctl spawn booted defaults write com.allthingsclaude.battery.ios \
    ///       pushRelayURL http://localhost:8787
    static let defaultPushRelayURL = "https://battery-push.allthingsclaude.workers.dev"

    static var pushRelayURL: URL? {
        let override = UserDefaults.standard.string(forKey: "pushRelayURL")
        let raw = (override?.isEmpty == false ? override! : defaultPushRelayURL)
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        // A trailing slash matters: URL(string:relativeTo:) drops the last path
        // component without it.
        return URL(string: raw.hasSuffix("/") ? raw : raw + "/")
    }
}
