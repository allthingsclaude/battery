import XCTest
@testable import Battery

/// The query behind per-account history. Local Claude Code transcripts carry no
/// account marker, so this aggregate is the only thing that can tell two
/// accounts sharing `~/.claude` apart.
final class DailyPeakUtilizationTests: XCTestCase {

    private let calendar = Calendar.current

    private func makeService() async throws -> (DatabaseService, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("battery-peaks-\(UUID().uuidString)", isDirectory: true)
        let service = DatabaseService()
        try await service.initialize(directory: dir)
        return (service, dir)
    }

    private func snapshot(at timestamp: Date, utilization: Double, account: UUID) -> UsageSnapshot {
        UsageSnapshot(
            timestamp: timestamp,
            sessionUtilization: utilization,
            sessionResetsAt: timestamp.addingTimeInterval(3600),
            weeklyUtilization: 0,
            weeklyResetsAt: timestamp.addingTimeInterval(86_400),
            planTier: "max",
            accountId: account
        )
    }

    /// The bug this fixes: every account showed the same numbers.
    func testPeaksAreScopedToOneAccount() async throws {
        let (service, dir) = try await makeService()
        defer { try? FileManager.default.removeItem(at: dir) }

        let alice = UUID()
        let bob = UUID()
        let noon = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: Date()))!
        let yesterdayNoon = calendar.date(byAdding: .day, value: -1, to: noon)!

        try await service.saveSnapshot(snapshot(at: noon, utilization: 40, account: alice))
        try await service.saveSnapshot(snapshot(at: noon, utilization: 90, account: bob))
        try await service.saveSnapshot(snapshot(at: yesterdayNoon, utilization: 55, account: bob))

        let start = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: Date()))!
        let alicePeaks = try await service.dailyPeakUtilization(from: start, to: Date(), accountId: alice)
        let bobPeaks = try await service.dailyPeakUtilization(from: start, to: Date(), accountId: bob)

        XCTAssertEqual(alicePeaks.count, 1)
        XCTAssertEqual(alicePeaks[calendar.startOfDay(for: noon)], 40)
        XCTAssertEqual(bobPeaks.count, 2)
        XCTAssertEqual(bobPeaks[calendar.startOfDay(for: noon)], 90)
        XCTAssertEqual(bobPeaks[calendar.startOfDay(for: yesterdayNoon)], 55)
    }

    /// Days are grouped in local time on both sides — SQLite's `localtime` and
    /// the parser that reads the day strings back. A mismatch would shift every
    /// key by a day, which is invisible until a streak silently breaks.
    func testDaysAreGroupedInLocalTime() async throws {
        let (service, dir) = try await makeService()
        defer { try? FileManager.default.removeItem(at: dir) }

        let account = UUID()
        let startOfToday = calendar.startOfDay(for: Date())
        // Both sit inside today locally, but straddle midnight UTC in many zones.
        let earlyToday = calendar.date(byAdding: .minute, value: 30, to: startOfToday)!
        let lateToday = calendar.date(byAdding: .hour, value: 23, to: startOfToday)!

        try await service.saveSnapshot(snapshot(at: earlyToday, utilization: 20, account: account))
        try await service.saveSnapshot(snapshot(at: lateToday, utilization: 70, account: account))

        let start = calendar.date(byAdding: .day, value: -2, to: startOfToday)!
        let peaks = try await service.dailyPeakUtilization(
            from: start,
            to: lateToday.addingTimeInterval(60),
            accountId: account
        )

        XCTAssertEqual(peaks.count, 1)
        XCTAssertEqual(peaks[startOfToday], 70, "MAX over the day, keyed to local midnight")
    }

    func testRangeExcludesSnapshotsOutsideTheWindow() async throws {
        let (service, dir) = try await makeService()
        defer { try? FileManager.default.removeItem(at: dir) }

        let account = UUID()
        let noon = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: Date()))!
        let longAgo = calendar.date(byAdding: .day, value: -40, to: noon)!

        try await service.saveSnapshot(snapshot(at: noon, utilization: 33, account: account))
        try await service.saveSnapshot(snapshot(at: longAgo, utilization: 99, account: account))

        let start = calendar.date(byAdding: .day, value: -35, to: calendar.startOfDay(for: Date()))!
        let peaks = try await service.dailyPeakUtilization(from: start, to: Date(), accountId: account)

        XCTAssertEqual(peaks.count, 1)
        XCTAssertNil(peaks[calendar.startOfDay(for: longAgo)])
    }

    /// A snapshot recorded with no measurable usage must survive as 0 rather
    /// than disappearing — its presence is what keeps a streak alive.
    func testZeroUtilizationDaySurvives() async throws {
        let (service, dir) = try await makeService()
        defer { try? FileManager.default.removeItem(at: dir) }

        let account = UUID()
        let noon = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: Date()))!
        try await service.saveSnapshot(snapshot(at: noon, utilization: 0, account: account))

        let start = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: Date()))!
        let peaks = try await service.dailyPeakUtilization(from: start, to: Date(), accountId: account)

        XCTAssertEqual(peaks[calendar.startOfDay(for: noon)], 0)
    }
}
