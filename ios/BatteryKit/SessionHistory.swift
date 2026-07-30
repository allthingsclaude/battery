import Foundation

/// The one place a usage sample gets recorded and turned into a burn rate.
///
/// Three processes poll the same account — the app's foreground loop, its
/// background refresh task, and the widget extension's self-fetch — and each
/// used to keep its own idea of history (the app an in-memory array wiped on
/// every launch, the other two none at all). The result was that a *measured*
/// burn rate was the exception rather than the rule, so nearly every surface
/// fell through to "—".
///
/// Now all three funnel through here and share one buffer in the App Group, so
/// samples accumulate no matter which process happened to take them.
enum SessionHistory {

    /// Roughly 30–90 minutes of samples at the app's poll cadence. The
    /// regression wants recency, not depth — an older tail would drag the rate
    /// toward the window average, which `UsageForecast` already covers on its
    /// own terms.
    static let capacity = 30

    /// Result of recording one sample: the pace, and when the limit arrives.
    struct Projection {
        let ratePerHour: Double
        let limitAt: Date?

        static let none = Projection(ratePerHour: 0, limitAt: nil)
    }

    /// Record a sample for the current window and return the projection it
    /// implies. With no open window the buffer is dropped — samples from a
    /// closed window can only poison the next one's regression.
    @discardableResult
    static func record(utilization: Double, resetsAt: Date?, at now: Date = Date()) -> Projection {
        guard let reset = resetsAt else {
            SharedStore.clearSnapshots()
            return .none
        }

        // Same 1-second tolerance the calculator uses: a reset time round-trips
        // through JSON and can come back a hair off.
        var history = SharedStore.loadSnapshots()
            .filter { abs($0.sessionResetsAt.timeIntervalSince(reset)) < 1.0 }
        history.append(
            UsageSnapshot(timestamp: now, sessionUtilization: utilization, sessionResetsAt: reset)
        )
        history = Array(history.sorted { $0.timestamp < $1.timestamp }.suffix(capacity))
        SharedStore.saveSnapshots(history)

        let projection = BurnRateCalculator.calculate(
            snapshots: history,
            currentUtilization: utilization,
            resetsAt: reset
        )
        // A limit landing after the reset isn't reached — the window rolls over
        // first.
        let limit = projection.projectedLimitTime.flatMap { $0 < reset ? $0 : nil }
        return Projection(ratePerHour: projection.currentRate, limitAt: limit)
    }

    /// Forget everything — a different account's usage must never feed this
    /// account's regression.
    static func reset() {
        SharedStore.clearSnapshots()
    }
}
