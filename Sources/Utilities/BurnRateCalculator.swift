import Foundation

/// Calculates burn rate projections from historical snapshots.
struct BurnRateProjection {
    let currentRate: Double           // percentage points per hour
    let projectedLimitTime: Date?     // when 100% will be hit (nil if rate <= 0 or already at 100%)
    let projectedAtReset: Double      // projected utilization at reset time
    let trend: Trend
    let hasEnoughData: Bool           // true when regression had sufficient snapshots

    enum Trend: String {
        case increasing
        case stable
        case decreasing
    }

    static func insufficientData(at utilization: Double) -> BurnRateProjection {
        BurnRateProjection(
            currentRate: 0,
            projectedLimitTime: nil,
            projectedAtReset: utilization,
            trend: .stable,
            hasEnoughData: false
        )
    }
}

/// Which usage window a projection is about.
///
/// Normally the five-hour session window. Accounts with no session limit
/// (verified Ultra) are metered weekly only, so for them the weekly window is
/// the one worth projecting.
enum UsageWindow: String, Codable {
    case session
    case weekly

    /// Nominal length of the window, for "time since reset" displays.
    var duration: TimeInterval {
        switch self {
        case .session: return 5 * 3600
        case .weekly: return 7 * 86400
        }
    }

    func utilization(of snapshot: UsageSnapshot) -> Double {
        switch self {
        case .session: return snapshot.sessionUtilization
        case .weekly: return snapshot.weeklyUtilization
        }
    }

    func resetsAt(of snapshot: UsageSnapshot) -> Date {
        switch self {
        case .session: return snapshot.sessionResetsAt
        case .weekly: return snapshot.weeklyResetsAt
        }
    }
}

enum BurnRateCalculator {

    /// Minimum number of snapshots needed for a meaningful projection.
    static let minimumSnapshots = 3

    /// Minimum time span (seconds) between first and last snapshot for a valid regression.
    static let minimumTimeSpan: TimeInterval = 120 // 2 minutes

    /// Calculate projection from recent snapshots using linear regression.
    ///
    /// - Parameters:
    ///   - snapshots: Recent usage snapshots in chronological order
    ///   - currentUtilization: The most recent utilization percentage (0-100)
    ///   - resetsAt: When the current usage window resets
    ///   - window: Which window `currentUtilization` and `resetsAt` describe,
    ///     and so which of each snapshot's readings to regress over.
    /// - Returns: A projection with burn rate, estimated limit time, and trend
    static func calculate(
        snapshots: [UsageSnapshot],
        currentUtilization: Double,
        resetsAt: Date,
        window: UsageWindow = .session
    ) -> BurnRateProjection {
        // Filter to only snapshots from the current window. A reset changes the
        // window's reset time, so snapshots with a different one belong to a
        // previous window and would poison the regression. A snapshot taken
        // while the account was metered differently carries no reading for this
        // window at all — its session columns are placeholders when it had no
        // session limit. Use 1-second tolerance to account for floating-point
        // round-trips through SQLite.
        let currentSessionSnapshots = snapshots.filter {
            (window == .weekly || $0.hasSessionLimit)
                && abs(window.resetsAt(of: $0).timeIntervalSince(resetsAt)) < 1.0
        }

        guard currentSessionSnapshots.count >= minimumSnapshots else {
            return .insufficientData(at: currentUtilization)
        }

        let sorted = currentSessionSnapshots.sorted { $0.timestamp < $1.timestamp }
        let timeSpan = sorted.last!.timestamp.timeIntervalSince(sorted.first!.timestamp)

        guard timeSpan >= minimumTimeSpan else {
            return .insufficientData(at: currentUtilization)
        }

        // Linear regression: y = mx + b where x = time (hours), y = utilization (%)
        // Use the first snapshot's timestamp as the origin (t=0)
        let origin = sorted.first!.timestamp.timeIntervalSince1970

        let n = Double(sorted.count)
        var sumX: Double = 0
        var sumY: Double = 0
        var sumXY: Double = 0
        var sumX2: Double = 0

        for snapshot in sorted {
            let x = (snapshot.timestamp.timeIntervalSince1970 - origin) / 3600.0  // hours
            let y = window.utilization(of: snapshot)
            sumX += x
            sumY += y
            sumXY += x * y
            sumX2 += x * x
        }

        let denominator = n * sumX2 - sumX * sumX
        guard abs(denominator) > 1e-10 else {
            return .insufficientData(at: currentUtilization)
        }

        // Slope = percentage points per hour.
        // Clamp to non-negative: within a single window, utilization
        // can only increase (or stay flat). A negative slope would mean the
        // regression data is noisy, not that usage is actually decreasing.
        let rawSlope = (n * sumXY - sumX * sumY) / denominator
        let slope = max(0, rawSlope)

        // Classify trend
        let trend: BurnRateProjection.Trend
        if slope > 1.0 {
            trend = .increasing
        } else {
            trend = .stable
        }

        // Project when 100% will be hit
        var projectedLimitTime: Date? = nil
        if slope > 0.01 && currentUtilization < 100 {
            let hoursToLimit = (100.0 - currentUtilization) / slope
            projectedLimitTime = Date().addingTimeInterval(hoursToLimit * 3600)
        }

        // Project utilization at reset time
        let hoursToReset = max(0, resetsAt.timeIntervalSinceNow / 3600.0)
        let projectedAtReset = min(100, max(0, currentUtilization + slope * hoursToReset))

        return BurnRateProjection(
            currentRate: slope,
            projectedLimitTime: projectedLimitTime,
            projectedAtReset: projectedAtReset,
            trend: trend,
            hasEnoughData: true
        )
    }
}
