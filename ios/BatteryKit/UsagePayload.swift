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
    /// False for an account with no five-hour limit at all — a verified Ultra
    /// account, whose usage response carries `"five_hour": null`. The session
    /// fields below are then 0 / nil, and every glanceable surface leads with
    /// the weekly window instead (see `primaryWindow`). A payload written before
    /// this field existed decodes it as `true`, which is what it described.
    var hasSessionLimit: Bool = true
    var sessionUtilization: Double
    var sessionResetsAt: Date?

    // Weekly (7-day) window
    var weeklyUtilization: Double
    var weeklyResetsAt: Date?

    // Opus 7-day window (nil when the plan has no Opus access)
    var opusUtilization: Double?

    // Fable 7-day window (nil until the account has Fable usage this week)
    var fableUtilization: Double?

    // Precomputed burn-rate projection for the *primary* window (see
    // BurnRateCalculator): the session when there is one, otherwise the weekly.
    var burnRatePerHour: Double        // percentage points / hour, 0 when unknown
    var projectedLimitAt: Date?        // when 100% is reached, nil when not projected

    // Context
    var isSessionActive: Bool          // a coding session is actively burning tokens
    var planTier: String               // "Pro" / "Max" / "Ultra", or "" when unknown
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

    // MARK: - Primary window
    //
    // What every glanceable surface leads with — the ring, the Lock Screen
    // number, the Live Activity, its start threshold and reset detection, and
    // the burn-rate regression. The session window when the account has one;
    // the weekly window when it doesn't. Route through these rather than the
    // `session…` fields, or an Ultra account renders a permanent 0% ring.

    var primaryWindow: FocusWindow { hasSessionLimit ? .session : .weekly }
    var primaryUtilization: Double { hasSessionLimit ? sessionUtilization : weeklyUtilization }
    var primaryResetsAt: Date? { hasSessionLimit ? sessionResetsAt : weeklyResetsAt }
    var primaryLevel: UsageLevel { .from(utilization: primaryUtilization) }

    /// Convenience: the more urgent of the two windows drives most glanceable UI.
    var focusUtilization: Double { max(sessionUtilization, weeklyUtilization) }

    var sessionLevel: UsageLevel { .from(utilization: sessionUtilization) }
    var weeklyLevel: UsageLevel { .from(utilization: weeklyUtilization) }

    /// Whichever window is closer to its ceiling — what a "smart" surface leads
    /// with. Always the weekly window when there is no session window to weigh
    /// it against.
    var focusWindow: FocusWindow {
        guard hasSessionLimit else { return .weekly }
        return weeklyUtilization > sessionUtilization ? .weekly : .session
    }

    enum FocusWindow: String, Codable { case session, weekly }

    var sessionTimeRemaining: TimeInterval {
        guard let r = sessionResetsAt else { return 0 }
        return max(0, r.timeIntervalSinceNow)
    }

    /// A neutral "empty" payload for placeholders and signed-out state.
    static let placeholder = UsagePayload(
        hasSessionLimit: true,
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

    /// The same, shaped like an account with no five-hour limit (verified
    /// Ultra): weekly-led, no session window. Widget placeholders and gallery
    /// snapshots pick this when the signed-in account is weekly-only, so the
    /// skeleton has the layout the real data is about to fill.
    static let placeholderWeeklyOnly = UsagePayload(
        hasSessionLimit: false,
        sessionUtilization: 0,
        sessionResetsAt: nil,
        weeklyUtilization: 38,
        weeklyResetsAt: Date().addingTimeInterval(4 * 86400 + 6 * 3600),
        opusUtilization: nil,
        fableUtilization: nil,
        burnRatePerHour: 0,
        projectedLimitAt: nil,
        isSessionActive: false,
        planTier: "Ultra",
        accountName: "Account 1",
        isConnected: true,
        updatedAt: Date()
    )

    /// The sample payload matching a (possibly absent) real one's shape.
    static func placeholder(like payload: UsagePayload?) -> UsagePayload {
        payload?.hasSessionLimit == false ? .placeholderWeeklyOnly : .placeholder
    }

    // Spelled out so `init(from:)` below can supply defaults. Encoding is still
    // synthesised from these keys.
    enum CodingKeys: String, CodingKey {
        case hasSessionLimit, sessionUtilization, sessionResetsAt
        case weeklyUtilization, weeklyResetsAt, opusUtilization, fableUtilization
        case burnRatePerHour, projectedLimitAt
        case isSessionActive, planTier, accountName, isConnected, updatedAt
    }
}

// Declared in an extension so the memberwise initializer survives.
extension UsagePayload {
    /// Tolerates payloads written by the previous app version: a missing
    /// `hasSessionLimit` means the account had a session window, and a plan
    /// label from before the 2026-10-30 rename is brought up to date.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasSessionLimit = try c.decodeIfPresent(Bool.self, forKey: .hasSessionLimit) ?? true
        sessionUtilization = try c.decode(Double.self, forKey: .sessionUtilization)
        sessionResetsAt = try c.decodeIfPresent(Date.self, forKey: .sessionResetsAt)
        weeklyUtilization = try c.decode(Double.self, forKey: .weeklyUtilization)
        weeklyResetsAt = try c.decodeIfPresent(Date.self, forKey: .weeklyResetsAt)
        opusUtilization = try c.decodeIfPresent(Double.self, forKey: .opusUtilization)
        fableUtilization = try c.decodeIfPresent(Double.self, forKey: .fableUtilization)
        burnRatePerHour = try c.decode(Double.self, forKey: .burnRatePerHour)
        projectedLimitAt = try c.decodeIfPresent(Date.self, forKey: .projectedLimitAt)
        isSessionActive = try c.decode(Bool.self, forKey: .isSessionActive)
        planTier = PlanLabel.migrated(try c.decode(String.self, forKey: .planTier))
        accountName = try c.decode(String.self, forKey: .accountName)
        isConnected = try c.decode(Bool.self, forKey: .isConnected)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}
