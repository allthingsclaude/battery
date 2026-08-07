import Foundation

/// The single, fully-baked snapshot the app writes and every read-only surface
/// (widgets, Live Activity, complications) consumes.
///
/// Design rule: **the app computes, the surfaces present.** Everything a widget
/// or the Live Activity needs to render is precomputed here — including the burn
/// rate and the projected-limit time — so extensions never touch the network,
/// the regression, or a database. That keeps them fast, cheap, and always in
/// agreement with the phone's main screen.
struct UsagePayload: Codable, Equatable {
    // Session (5-hour) window
    var sessionUtilization: Double
    var sessionResetsAt: Date?

    // Weekly (7-day) window
    var weeklyUtilization: Double
    var weeklyResetsAt: Date?

    // Opus 7-day window (nil when the plan has no Opus access)
    var opusUtilization: Double?

    // Fable 7-day window (nil until the account has Fable usage this week)
    var fableUtilization: Double?

    // Precomputed burn-rate projection (see BurnRateCalculator)
    var burnRatePerHour: Double        // percentage points / hour, 0 when unknown
    var projectedLimitAt: Date?        // when 100% is reached, nil when not projected

    // Context
    var isSessionActive: Bool          // a coding session is actively burning tokens
    var planTier: String               // "Pro" / "Max" / "Max 5x" / "Unknown"
    var accountName: String
    var isConnected: Bool
    var updatedAt: Date

    /// A projection is only meaningful while it's still in the future and we have
    /// a burn rate. Carried-forward payloads (widget self-fetch, background
    /// refresh) can hold a `projectedLimitAt` that has since passed — surfacing it
    /// would render nonsense like "hits limit in 0s".
    var hasLiveProjection: Bool {
        guard burnRatePerHour > 0.05, let limit = projectedLimitAt else { return false }
        return limit > Date()
    }

    /// The projected-limit date, or nil once it's stale.
    var liveProjectedLimitAt: Date? { hasLiveProjection ? projectedLimitAt : nil }

    /// Convenience: the more urgent of the two windows drives most glanceable UI.
    var focusUtilization: Double { max(sessionUtilization, weeklyUtilization) }

    var sessionLevel: UsageLevel { .from(utilization: sessionUtilization) }
    var weeklyLevel: UsageLevel { .from(utilization: weeklyUtilization) }

    /// Whichever window is closer to its ceiling — what a "smart" surface leads with.
    var focusWindow: FocusWindow {
        weeklyUtilization > sessionUtilization ? .weekly : .session
    }

    enum FocusWindow: String, Codable { case session, weekly }

    var sessionTimeRemaining: TimeInterval {
        guard let r = sessionResetsAt else { return 0 }
        return max(0, r.timeIntervalSinceNow)
    }

    /// A neutral "empty" payload for placeholders and signed-out state.
    static let placeholder = UsagePayload(
        sessionUtilization: 42,
        sessionResetsAt: Date().addingTimeInterval(2 * 3600 + 13 * 60),
        weeklyUtilization: 63,
        weeklyResetsAt: Date().addingTimeInterval(3 * 86400),
        opusUtilization: nil,   // most accounts have no Opus bucket — don't imply one in previews
        fableUtilization: nil,
        burnRatePerHour: 0,
        projectedLimitAt: nil,
        isSessionActive: false,
        planTier: "",
        accountName: "Account 1",
        isConnected: true,
        updatedAt: Date()
    )
}
