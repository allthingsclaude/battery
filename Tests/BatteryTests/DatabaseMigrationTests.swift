import XCTest
import SQLite
@testable import Battery

final class DatabaseMigrationTests: XCTestCase {

    /// Regression for the silent snapshot-save failure that broke projections:
    /// a database whose `usage_snapshots` table predates the multi-account
    /// change lacks an `account_id` column. `initialize()` must add the column
    /// so that `saveSnapshot` (which writes `account_id`) succeeds. Before the
    /// fix the migration used a SELECT probe whose error SQLite.swift swallowed
    /// on an empty table, so the column was never added and every insert failed.
    func testInitializeAddsAccountIdToLegacyTable() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("battery-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed a legacy-schema DB: the table as it was created before account_id.
        let dbPath = dir.appendingPathComponent("battery.db").path
        let legacy = try Connection(dbPath)
        try legacy.execute("""
        CREATE TABLE "usage_snapshots" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "timestamp" REAL NOT NULL,
          "session_utilization" REAL NOT NULL,
          "session_resets_at" REAL NOT NULL,
          "weekly_utilization" REAL NOT NULL,
          "weekly_resets_at" REAL NOT NULL,
          "sonnet_utilization" REAL,
          "opus_utilization" REAL,
          "plan_tier" TEXT NOT NULL
        );
        """)

        let service = DatabaseService()
        try await service.initialize(directory: dir)

        // The migration must have added account_id, so a snapshot carrying an
        // accountId now persists and round-trips.
        let accountId = UUID()
        let snapshot = UsageSnapshot(
            sessionUtilization: 50,
            sessionResetsAt: Date(timeIntervalSince1970: 1_000_000),
            weeklyUtilization: 20,
            weeklyResetsAt: Date(timeIntervalSince1970: 2_000_000),
            planTier: "max",
            accountId: accountId
        )
        try await service.saveSnapshot(snapshot)

        let loaded = try await service.getLatestSnapshots(count: 10, accountId: accountId)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.accountId, accountId)
    }

    /// Same failure mode as `account_id`, one column later: a database created
    /// before Fable tracking has no `fable_utilization`, and `create(ifNotExists:)`
    /// won't add it to an existing table. Without the migration every insert
    /// references a missing column and history silently stops accumulating.
    func testInitializeAddsFableUtilizationToExistingTable() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("battery-fable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed the schema as it stood *after* account_id but before fable_utilization.
        let dbPath = dir.appendingPathComponent("battery.db").path
        let legacy = try Connection(dbPath)
        try legacy.execute("""
        CREATE TABLE "usage_snapshots" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "timestamp" REAL NOT NULL,
          "session_utilization" REAL NOT NULL,
          "session_resets_at" REAL NOT NULL,
          "weekly_utilization" REAL NOT NULL,
          "weekly_resets_at" REAL NOT NULL,
          "sonnet_utilization" REAL,
          "opus_utilization" REAL,
          "plan_tier" TEXT NOT NULL,
          "account_id" TEXT
        );
        """)

        let service = DatabaseService()
        try await service.initialize(directory: dir)

        let accountId = UUID()
        try await service.saveSnapshot(UsageSnapshot(
            sessionUtilization: 11,
            sessionResetsAt: Date(timeIntervalSince1970: 1_000_000),
            weeklyUtilization: 46,
            weeklyResetsAt: Date(timeIntervalSince1970: 2_000_000),
            fableUtilization: 63,
            planTier: "max",
            accountId: accountId
        ))

        let loaded = try await service.getLatestSnapshots(count: 10, accountId: accountId)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.fableUtilization, 63)
    }

    /// Rows written before Fable tracking read back as nil rather than 0 — a
    /// zero would render as a real "0%" gauge in history.
    func testPreExistingRowsReadBackWithNilFable() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("battery-fable-old-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = DatabaseService()
        try await service.initialize(directory: dir)

        let accountId = UUID()
        try await service.saveSnapshot(UsageSnapshot(
            sessionUtilization: 10,
            sessionResetsAt: Date(timeIntervalSince1970: 1_000_000),
            weeklyUtilization: 5,
            weeklyResetsAt: Date(timeIntervalSince1970: 2_000_000),
            planTier: "max",
            accountId: accountId
        ))

        let loaded = try await service.getLatestSnapshots(count: 10, accountId: accountId)
        XCTAssertNil(loaded.first?.fableUtilization)
    }

    /// A fresh database (no pre-existing table) must also end up with the
    /// account_id column so snapshots persist immediately.
    func testInitializeFreshDatabasePersistsSnapshot() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("battery-fresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = DatabaseService()
        try await service.initialize(directory: dir)

        let accountId = UUID()
        try await service.saveSnapshot(UsageSnapshot(
            sessionUtilization: 10,
            sessionResetsAt: Date(timeIntervalSince1970: 1_000_000),
            weeklyUtilization: 5,
            weeklyResetsAt: Date(timeIntervalSince1970: 2_000_000),
            planTier: "max",
            accountId: accountId
        ))

        let loaded = try await service.getLatestSnapshots(count: 10, accountId: accountId)
        XCTAssertEqual(loaded.count, 1)
    }
}
