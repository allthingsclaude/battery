package com.allthingsclaude.battery.core

/**
 * Endpoints and OAuth parameters, copied verbatim from `ios/BatteryApp/AppConfig.swift`
 * and `Sources/Utilities/Constants.swift` so the phone authenticates against
 * exactly the same client as Claude Code, the menu-bar app, and the iPhone app.
 *
 * None of these are secrets. The OAuth client is a **public** PKCE client — that
 * is the whole point of PKCE, and the same id is already committed in both other
 * apps in this repository.
 */
object AppConfig {
    const val API_BASE_URL = "https://api.anthropic.com"
    const val USAGE_PATH = "/api/oauth/usage"

    /**
     * Account identity. Confirmed to exist by an unauthenticated probe (401,
     * where /api/oauth/me and /v1/me answer 404) and covered by the
     * `user:profile` scope both apps already request. Response shape is
     * undocumented — see [ProfileApi].
     */
    const val PROFILE_PATH = "/api/oauth/profile"
    const val BETA_HEADER = "oauth-2025-04-20"

    // OAuth PKCE — the same public client as macOS and iOS.
    const val OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    const val OAUTH_AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
    const val OAUTH_TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
    const val OAUTH_SCOPES = "user:profile user:inference"
    const val OAUTH_REDIRECT_PATH = "/callback"

    /**
     * Poll cadence in seconds while a session is hot.
     *
     * Three minutes, not the 60s the desktop and iOS apps use. At a heavy
     * 20%/hr burn, 60 seconds of drift is 0.33 percentage points — sampling
     * noise, not information — while on Android the poll is what keeps a
     * foreground service alive, so the cost is real in a way it isn't on a Mac
     * that's already awake. Three minutes still clears
     * [BurnRateCalculator.MINIMUM_SNAPSHOTS] and [BurnRateCalculator.MINIMUM_TIME_SPAN]
     * with three samples across a 15-minute span, and the reset countdown ticks
     * for free via the notification's chronometer regardless of cadence.
     */
    const val ACTIVE_POLL_SECONDS = 180L

    /** Cadence when nothing is burning and no card is on screen. */
    const val IDLE_POLL_SECONDS = 900L

    /** Request timeout, seconds. */
    const val REQUEST_TIMEOUT_SECONDS = 15

    /** Refresh the access token this long before it expires. */
    const val TOKEN_REFRESH_LEEWAY_SECONDS = 300L

    fun userAgent(versionName: String): String = "Battery/$versionName"
}
