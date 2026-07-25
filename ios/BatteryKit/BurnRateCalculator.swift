import Foundation

/// A burn-rate projection derived from recent snapshots. Mirrors the macOS type
/// so any code that reasons about "will I hit the limit" behaves identically.
struct BurnRateProjection {
    let currentRate: Double           // percentage points per hour
    let projectedLimitTime: Date?     // when 100% is hit (nil if flat / already maxed)
    let projectedAtReset: Double      // projected utilization at reset time
    let trend: Trend
    let hasEnoughData: Bool

    enum Trend: String { case increasing, stable, decreasing }

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

/// Linear-regression burn rate. Ported from the macOS `BurnRateCalculator`; the
/// only difference is the iOS snapshot has fewer fields, but the math is the same.
enum BurnRateCalculator {

    static let minimumSnapshots = 3
    static let minimumTimeSpan: TimeInterval = 120 // 2 minutes

    static func calculate(
        snapshots: [UsageSnapshot],
        currentUtilization: Double,
        resetsAt: Date
    ) -> BurnRateProjection {
        // Only keep samples belonging to the current session window; a reset
        // changes `sessionResetsAt` and would otherwise poison the regression.
        let currentSession = snapshots.filter {
            abs($0.sessionResetsAt.timeIntervalSince(resetsAt)) < 1.0
        }

        guard currentSession.count >= minimumSnapshots else {
            return .insufficientData(at: currentUtilization)
        }

        let sorted = currentSession.sorted { $0.timestamp < $1.timestamp }
        let timeSpan = sorted.last!.timestamp.timeIntervalSince(sorted.first!.timestamp)
        guard timeSpan >= minimumTimeSpan else {
            return .insufficientData(at: currentUtilization)
        }

        let origin = sorted.first!.timestamp.timeIntervalSince1970
        let n = Double(sorted.count)
        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumX2 = 0.0
        for s in sorted {
            let x = (s.timestamp.timeIntervalSince1970 - origin) / 3600.0 // hours
            let y = s.sessionUtilization
            sumX += x; sumY += y; sumXY += x * y; sumX2 += x * x
        }

        let denominator = n * sumX2 - sumX * sumX
        guard abs(denominator) > 1e-10 else {
            return .insufficientData(at: currentUtilization)
        }

        // Within a session, utilization only rises — clamp noise to non-negative.
        let slope = max(0, (n * sumXY - sumX * sumY) / denominator)
        let trend: BurnRateProjection.Trend = slope > 1.0 ? .increasing : .stable

        var projectedLimitTime: Date?
        if slope > 0.01 && currentUtilization < 100 {
            let hoursToLimit = (100.0 - currentUtilization) / slope
            projectedLimitTime = Date().addingTimeInterval(hoursToLimit * 3600)
        }

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
