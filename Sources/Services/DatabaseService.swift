import Foundation
import SQLite

/// SQLite-backed persistence for usage history snapshots.
actor DatabaseService {

    private var db: Connection?

    // Table definition
    private let snapshots = Table("usage_snapshots")
    private let colId = SQLite.Expression<String>("id")
    private let colTimestamp = SQLite.Expression<Double>("timestamp")
    private let colSessionUtil = SQLite.Expression<Double>("session_utilization")
    private let colSessionResets = SQLite.Expression<Double>("session_resets_at")
    private let colWeeklyUtil = SQLite.Expression<Double>("weekly_utilization")
    private let colWeeklyResets = SQLite.Expression<Double>("weekly_resets_at")
    private let colSonnetUtil = SQLite.Expression<Double?>("sonnet_utilization")
    private let colOpusUtil = SQLite.Expression<Double?>("opus_utilization")
    private let colFableUtil = SQLite.Expression<Double?>("fable_utilization")
    private let colPlanTier = SQLite.Expression<String>("plan_tier")
    private let colAccountId = SQLite.Expression<String?>("account_id")
    /// Nullable: rows written before weekly-only plans existed read as NULL,
    /// which means "had a session window" — every account did then.
    private let colHasSessionLimit = SQLite.Expression<Bool?>("has_session_limit")

    /// - Parameter directory: Override for the database directory. Defaults to
    ///   the app's Application Support folder; tests pass a temp directory.
    func initialize(directory: URL? = nil) throws {
        let batteryDir: URL
        if let directory {
            batteryDir = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            batteryDir = appSupport.appendingPathComponent("Battery", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: batteryDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let dbPath = batteryDir.appendingPathComponent("battery.db").path
        db = try Connection(dbPath)

        // Restrict database file permissions to owner-only
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbPath)

        try db?.run(snapshots.create(ifNotExists: true) { t in
            t.column(colId, primaryKey: true)
            t.column(colTimestamp)
            t.column(colSessionUtil)
            t.column(colSessionResets)
            t.column(colWeeklyUtil)
            t.column(colWeeklyResets)
            t.column(colSonnetUtil)
            t.column(colOpusUtil)
            t.column(colFableUtil)
            t.column(colPlanTier)
            t.column(colAccountId)
            t.column(colHasSessionLimit)
        })

        // Create index on timestamp for efficient range queries
        try db?.run(snapshots.createIndex(colTimestamp, ifNotExists: true))

        // Migrations: add columns missing from databases created by older builds
        migrateAddAccountId()
        migrateAddFableUtilization()
        migrateAddHasSessionLimit()
    }

    func saveSnapshot(_ snapshot: UsageSnapshot) throws {
        guard let db = db else { return }
        try db.run(snapshots.insert(
            colId <- snapshot.id.uuidString,
            colTimestamp <- snapshot.timestamp.timeIntervalSince1970,
            colSessionUtil <- snapshot.sessionUtilization,
            colSessionResets <- snapshot.sessionResetsAt.timeIntervalSince1970,
            colWeeklyUtil <- snapshot.weeklyUtilization,
            colWeeklyResets <- snapshot.weeklyResetsAt.timeIntervalSince1970,
            colSonnetUtil <- snapshot.sonnetUtilization,
            colOpusUtil <- snapshot.opusUtilization,
            colFableUtil <- snapshot.fableUtilization,
            colPlanTier <- snapshot.planTier,
            colAccountId <- snapshot.accountId?.uuidString,
            colHasSessionLimit <- snapshot.hasSessionLimit
        ))
    }

    func getSnapshots(from startDate: Date, to endDate: Date, accountId: UUID? = nil) throws -> [UsageSnapshot] {
        guard let db = db else { return [] }
        var query = snapshots
            .filter(colTimestamp >= startDate.timeIntervalSince1970 && colTimestamp <= endDate.timeIntervalSince1970)
            .order(colTimestamp.asc)

        if let accountId = accountId {
            query = query.filter(colAccountId == accountId.uuidString)
        }

        return try db.prepare(query).map { snapshotFromRow($0) }
    }

    func getLatestSnapshots(count: Int, accountId: UUID? = nil) throws -> [UsageSnapshot] {
        guard let db = db else { return [] }
        var query = snapshots
            .order(colTimestamp.desc)
            .limit(count)

        if let accountId = accountId {
            query = query.filter(colAccountId == accountId.uuidString)
        }

        return try db.prepare(query).map { snapshotFromRow($0) }.reversed()  // Return in chronological order
    }

    /// One activity value per local day for one account, keyed by the start of
    /// that day. Only days the account was used appear.
    ///
    /// This is what makes streaks and history per-account: the local Claude Code
    /// transcripts under `~/.claude` carry no marker saying which account ran a
    /// session, so several accounts sharing that directory can only be told
    /// apart by what Battery itself recorded against each `account_id`.
    ///
    /// What a day's value means depends on how the account was metered:
    ///
    /// - **With a five-hour window**, the value is the day's peak session
    ///   utilization, and any row at all marks the day active — those rows are
    ///   only written while a window is open.
    /// - **Weekly only** (verified Ultra), rows are written on every poll, idle
    ///   or not, so presence says nothing. The value is instead how many points
    ///   of the weekly allowance the day consumed — the rise in weekly
    ///   utilization, summed across a weekly reset if one fell that day — and
    ///   only a day with a rise counts as active.
    ///
    /// A day with both kinds of row (the account was verified mid-day) takes
    /// whichever value is larger.
    ///
    /// Aggregated in SQL rather than by loading rows — a 35-day window is on the
    /// order of ten thousand snapshots at the one-minute poll rate.
    ///
    /// - Parameter accountId: nil aggregates across every account.
    func dailyPeakUtilization(from startDate: Date, to endDate: Date, accountId: UUID?) throws -> [Date: Double] {
        guard let db = db else { return [:] }

        // The inner query splits each day by metering kind and by weekly window.
        // `resets_at` carries request-time microseconds, so windows are matched
        // to the minute rather than exactly.
        var sql = """
        SELECT day,
               MAX(CASE WHEN session_window = 1 THEN session_peak END),
               SUM(CASE WHEN session_window = 0 THEN weekly_used END)
        FROM (
            SELECT date(timestamp, 'unixepoch', 'localtime') AS day,
                   COALESCE(has_session_limit, 1) AS session_window,
                   MAX(session_utilization) AS session_peak,
                   MAX(weekly_utilization) - MIN(weekly_utilization) AS weekly_used
            FROM usage_snapshots
            WHERE timestamp >= ? AND timestamp <= ?
        """
        var bindings: [SQLite.Binding?] = [
            startDate.timeIntervalSince1970,
            endDate.timeIntervalSince1970,
        ]
        if let accountId = accountId {
            sql += "\n      AND account_id = ?"
            bindings.append(accountId.uuidString)
        }
        sql += """

            GROUP BY day, session_window, CAST(weekly_resets_at / 60 AS INTEGER)
        )
        GROUP BY day
        """

        // SQLite's 'localtime' resolves against the OS zone, so the parser has to
        // read the day strings back in that same zone or every key lands a day off.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let calendar = Calendar.current

        var peaks: [Date: Double] = [:]
        for row in try db.prepare(sql, bindings) {
            guard let day = row[0] as? String, let date = formatter.date(from: day) else { continue }
            let sessionPeak = Self.number(row[1])
            let weeklyUsed = Self.number(row[2]).flatMap { $0 > 0 ? $0 : nil }
            // Neither a session window nor any weekly movement: an idle day on a
            // weekly-only account.
            guard sessionPeak != nil || weeklyUsed != nil else { continue }
            peaks[calendar.startOfDay(for: date)] = max(sessionPeak ?? 0, weeklyUsed ?? 0)
        }
        return peaks
    }

    /// A numeric SQLite result, or nil for NULL.
    private static func number(_ value: SQLite.Binding?) -> Double? {
        switch value {
        case let value as Double: return value
        case let value as Int64: return Double(value)
        default: return nil
        }
    }

    private func snapshotFromRow(_ row: Row) -> UsageSnapshot {
        UsageSnapshot(
            id: UUID(uuidString: row[colId]) ?? UUID(),
            timestamp: Date(timeIntervalSince1970: row[colTimestamp]),
            sessionUtilization: row[colSessionUtil],
            sessionResetsAt: Date(timeIntervalSince1970: row[colSessionResets]),
            weeklyUtilization: row[colWeeklyUtil],
            weeklyResetsAt: Date(timeIntervalSince1970: row[colWeeklyResets]),
            sonnetUtilization: row[colSonnetUtil],
            opusUtilization: row[colOpusUtil],
            fableUtilization: row[colFableUtil],
            planTier: row[colPlanTier],
            accountId: row[colAccountId].flatMap { UUID(uuidString: $0) },
            hasSessionLimit: row[colHasSessionLimit] ?? true
        )
    }

    func pruneOldData(olderThan date: Date) throws {
        guard let db = db else { return }
        let old = snapshots.filter(colTimestamp < date.timeIntervalSince1970)
        try db.run(old.delete())
    }

    // MARK: - Migration

    private func migrateAddAccountId() {
        guard let db = db else { return }
        // Detect the column via PRAGMA. A SELECT-based probe is unreliable here:
        // SQLite.swift's `scalar` swallows the prepare-time "no such column"
        // error on an empty table and returns nil instead of throwing, so the
        // column would never be added and every insert that references it would
        // fail silently (breaking snapshot persistence and projections).
        do {
            let columns = try db.prepare("PRAGMA table_info(usage_snapshots)")
                .compactMap { $0[1] as? String }
            guard !columns.contains("account_id") else { return }
            try db.run(snapshots.addColumn(colAccountId))
        } catch {
            print("Migration: failed to add account_id column: \(error.localizedDescription)")
        }
    }

    /// `create(ifNotExists:)` leaves an existing table alone, so a database from
    /// a build that predates Fable tracking needs the column added explicitly —
    /// otherwise every `saveSnapshot` insert references a column that isn't
    /// there and history stops accumulating. Detected via PRAGMA for the same
    /// reason as `account_id` above.
    private func migrateAddFableUtilization() {
        guard let db = db else { return }
        do {
            let columns = try db.prepare("PRAGMA table_info(usage_snapshots)")
                .compactMap { $0[1] as? String }
            guard !columns.contains("fable_utilization") else { return }
            try db.run(snapshots.addColumn(colFableUtil))
        } catch {
            print("Migration: failed to add fable_utilization column: \(error.localizedDescription)")
        }
    }

    /// Weekly-only plans arrived after the table did. Existing rows keep NULL,
    /// which reads as "had a session window" — true of every row written
    /// before. Detected via PRAGMA for the same reason as `account_id` above.
    private func migrateAddHasSessionLimit() {
        guard let db = db else { return }
        do {
            let columns = try db.prepare("PRAGMA table_info(usage_snapshots)")
                .compactMap { $0[1] as? String }
            guard !columns.contains("has_session_limit") else { return }
            try db.run(snapshots.addColumn(colHasSessionLimit))
        } catch {
            print("Migration: failed to add has_session_limit column: \(error.localizedDescription)")
        }
    }
}
