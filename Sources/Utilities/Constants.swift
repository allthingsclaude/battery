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
    static let userAgent = "Battery/0.2.4"

    // Polling intervals (seconds)
    static let defaultPollInterval: TimeInterval = 60
    static let activePollInterval: TimeInterval = 60
    static let idlePollInterval: TimeInterval = 300

    // Notification thresholds
    static let defaultThresholds: [Int] = [80, 90, 95]

    // Database
    static let dataRetentionDays: Int = 90

    // UI — Tahoe-style corner radius for the menu bar panel
    static let panelCornerRadius: CGFloat = 24
}
