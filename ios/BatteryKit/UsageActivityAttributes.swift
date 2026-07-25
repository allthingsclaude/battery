#if os(iOS)
import ActivityKit
#endif
import Foundation

/// ActivityKit attributes for the "session in progress" Live Activity.
///
/// This type must be compiled into BOTH the app target (which starts / updates /
/// ends the activity) and the widget extension target (which draws it). The
/// `ContentState` is the mutable part pushed on every update; the top-level
/// fields are fixed for the lifetime of one activity.
#if os(iOS)
struct UsageActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        /// Session (5-hour) utilization, 0–100.
        var sessionUtilization: Double
        /// When the session window resets (drives the live countdown).
        var sessionResetsAt: Date?
        /// Weekly utilization, shown as secondary context.
        var weeklyUtilization: Double
        /// Burn rate in percentage points per hour (0 when unknown).
        var burnRatePerHour: Double
        /// Projected time the session hits 100% (nil when not projected).
        var projectedLimitAt: Date?
        /// Whether a coding session is actively burning tokens right now.
        var isSessionActive: Bool
        /// Terminal state: the session just reset — show a brief "reset" card
        /// before the activity dismisses itself.
        var didReset: Bool
        /// When the app last refreshed this data. Drives a live "Updated Xm ago"
        /// label so a stale activity is honest about it (the system ticks it up
        /// on its own, no app update needed).
        var updatedAt: Date

        var level: UsageLevel { .from(utilization: sessionUtilization) }

        init(
            sessionUtilization: Double,
            sessionResetsAt: Date?,
            weeklyUtilization: Double,
            burnRatePerHour: Double,
            projectedLimitAt: Date?,
            isSessionActive: Bool,
            didReset: Bool,
            updatedAt: Date
        ) {
            self.sessionUtilization = sessionUtilization
            self.sessionResetsAt = sessionResetsAt
            self.weeklyUtilization = weeklyUtilization
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

        private enum CodingKeys: String, CodingKey {
            case sessionUtilization, sessionResetsAt, weeklyUtilization
            case burnRatePerHour, projectedLimitAt, isSessionActive, didReset, updatedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionUtilization = try c.decode(Double.self, forKey: .sessionUtilization)
            weeklyUtilization = try c.decode(Double.self, forKey: .weeklyUtilization)
            burnRatePerHour = try c.decodeIfPresent(Double.self, forKey: .burnRatePerHour) ?? 0
            isSessionActive = try c.decodeIfPresent(Bool.self, forKey: .isSessionActive) ?? false
            didReset = try c.decodeIfPresent(Bool.self, forKey: .didReset) ?? false
            sessionResetsAt = Self.date(try c.decodeIfPresent(Double.self, forKey: .sessionResetsAt))
            projectedLimitAt = Self.date(try c.decodeIfPresent(Double.self, forKey: .projectedLimitAt))
            updatedAt = Self.date(try c.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? Date()
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(sessionUtilization, forKey: .sessionUtilization)
            try c.encode(weeklyUtilization, forKey: .weeklyUtilization)
            try c.encode(burnRatePerHour, forKey: .burnRatePerHour)
            try c.encode(isSessionActive, forKey: .isSessionActive)
            try c.encode(didReset, forKey: .didReset)
            try c.encodeIfPresent(sessionResetsAt?.timeIntervalSince1970, forKey: .sessionResetsAt)
            try c.encodeIfPresent(projectedLimitAt?.timeIntervalSince1970, forKey: .projectedLimitAt)
            try c.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
        }

        private static func date(_ epochSeconds: Double?) -> Date? {
            guard let epochSeconds else { return nil }
            return Date(timeIntervalSince1970: epochSeconds)
        }
    }

    /// Plan tier at the time the activity started ("Max", "Pro", …).
    var planTier: String
    /// Account label, e.g. "Account 1".
    var accountName: String
}
#endif
