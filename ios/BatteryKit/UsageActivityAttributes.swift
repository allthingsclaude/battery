#if os(iOS)
import ActivityKit
#endif
import Foundation

/// ActivityKit attributes for the "session in progress" Live Activity — or, for
/// an account with no five-hour limit, the "week in progress" one.
///
/// This type must be compiled into BOTH the app target (which starts / updates /
/// ends the activity) and the widget extension target (which draws it). The
/// `ContentState` is the mutable part pushed on every update; the top-level
/// fields are fixed for the lifetime of one activity.
#if os(iOS)
struct UsageActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        /// False when the account has no five-hour limit (verified Ultra). The
        /// session fields are then 0 / absent and the card leads with the
        /// weekly window. A Mac or relay that predates this field only ever
        /// described accounts that had one, so absent decodes as `true`.
        var hasSessionLimit: Bool
        /// Session (5-hour) utilization, 0–100. Always 0 without a session limit.
        var sessionUtilization: Double
        /// When the session window resets (drives the live countdown). Always
        /// nil without a session limit.
        var sessionResetsAt: Date?
        /// Weekly utilization — secondary context, or the lead number when
        /// there is no session limit.
        var weeklyUtilization: Double
        /// When the weekly window resets. Optional on the wire: older senders
        /// never sent it, and newer ones only when the API reported it.
        var weeklyResetsAt: Date?
        /// Burn rate in percentage points per hour (0 when unknown), for the
        /// primary window — the session, or the weekly window without one.
        var burnRatePerHour: Double
        /// Projected time the primary window hits 100% (nil when not projected).
        var projectedLimitAt: Date?
        /// Whether a coding session is actively burning tokens right now.
        var isSessionActive: Bool
        /// Terminal state: the primary window just reset — show a brief "reset"
        /// card before the activity dismisses itself.
        var didReset: Bool
        /// When the app last refreshed this data. Drives a live "Updated Xm ago"
        /// label so a stale activity is honest about it (the system ticks it up
        /// on its own, no app update needed).
        var updatedAt: Date

        /// The window this card leads with. Mirrors `UsagePayload.primaryWindow`.
        var primaryUtilization: Double { hasSessionLimit ? sessionUtilization : weeklyUtilization }
        var primaryResetsAt: Date? { hasSessionLimit ? sessionResetsAt : weeklyResetsAt }

        var level: UsageLevel { .from(utilization: primaryUtilization) }

        /// Without a session limit the session fields are forced to 0 / nil, so
        /// no sender — this app, a Mac, or the relay — can make the card
        /// fabricate a window the account doesn't have.
        init(
            hasSessionLimit: Bool,
            sessionUtilization: Double,
            sessionResetsAt: Date?,
            weeklyUtilization: Double,
            weeklyResetsAt: Date?,
            burnRatePerHour: Double,
            projectedLimitAt: Date?,
            isSessionActive: Bool,
            didReset: Bool,
            updatedAt: Date
        ) {
            self.hasSessionLimit = hasSessionLimit
            self.sessionUtilization = hasSessionLimit ? sessionUtilization : 0
            self.sessionResetsAt = hasSessionLimit ? sessionResetsAt : nil
            self.weeklyUtilization = weeklyUtilization
            self.weeklyResetsAt = weeklyResetsAt
            self.burnRatePerHour = burnRatePerHour
            self.projectedLimitAt = projectedLimitAt
            self.isSessionActive = isSessionActive
            self.didReset = didReset
            self.updatedAt = updatedAt
        }

        // MARK: - Wire format
        //
        // This state now arrives over the network as well as from the app
        // process: the push relay forwards a JSON `content-state` built on the
        // Mac straight into ActivityKit. Swift's synthesised `Codable` encodes
        // `Date` as seconds since the *2001* reference date — a silent 31-year
        // offset for anything writing this JSON by hand. Spelling out Unix epoch
        // seconds makes the contract legible from both sides of the wire.
        //
        // `hasSessionLimit` is always encoded; `weeklyResetsAt` when known; and
        // `sessionResetsAt` is omitted for an account without a session limit.

        private enum CodingKeys: String, CodingKey {
            case hasSessionLimit, sessionUtilization, sessionResetsAt
            case weeklyUtilization, weeklyResetsAt
            case burnRatePerHour, projectedLimitAt, isSessionActive, didReset, updatedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                hasSessionLimit: try c.decodeIfPresent(Bool.self, forKey: .hasSessionLimit) ?? true,
                sessionUtilization: try c.decode(Double.self, forKey: .sessionUtilization),
                sessionResetsAt: Self.date(try c.decodeIfPresent(Double.self, forKey: .sessionResetsAt)),
                weeklyUtilization: try c.decode(Double.self, forKey: .weeklyUtilization),
                weeklyResetsAt: Self.date(try c.decodeIfPresent(Double.self, forKey: .weeklyResetsAt)),
                burnRatePerHour: try c.decodeIfPresent(Double.self, forKey: .burnRatePerHour) ?? 0,
                projectedLimitAt: Self.date(try c.decodeIfPresent(Double.self, forKey: .projectedLimitAt)),
                isSessionActive: try c.decodeIfPresent(Bool.self, forKey: .isSessionActive) ?? false,
                didReset: try c.decodeIfPresent(Bool.self, forKey: .didReset) ?? false,
                updatedAt: Self.date(try c.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? Date()
            )
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(hasSessionLimit, forKey: .hasSessionLimit)
            try c.encode(sessionUtilization, forKey: .sessionUtilization)
            try c.encode(weeklyUtilization, forKey: .weeklyUtilization)
            try c.encode(burnRatePerHour, forKey: .burnRatePerHour)
            try c.encode(isSessionActive, forKey: .isSessionActive)
            try c.encode(didReset, forKey: .didReset)
            try c.encodeIfPresent(sessionResetsAt?.timeIntervalSince1970, forKey: .sessionResetsAt)
            try c.encodeIfPresent(weeklyResetsAt?.timeIntervalSince1970, forKey: .weeklyResetsAt)
            try c.encodeIfPresent(projectedLimitAt?.timeIntervalSince1970, forKey: .projectedLimitAt)
            try c.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
        }

        private static func date(_ epochSeconds: Double?) -> Date? {
            guard let epochSeconds else { return nil }
            return Date(timeIntervalSince1970: epochSeconds)
        }
    }

    /// Plan tier at the time the activity started ("Pro", "Max", "Ultra", …).
    /// Set by whoever started the activity — possibly a Mac running an older
    /// build — so read it through `planLabel`, which applies the rename.
    var planTier: String
    /// Account label, e.g. "Account 1".
    var accountName: String

    /// `planTier` under the current plan names ("Max 20x" reads "Ultra").
    var planLabel: String { PlanLabel.migrated(planTier) }
}
#endif
