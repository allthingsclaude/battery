import Foundation

/// A point-in-time usage sample. On macOS these are persisted to SQLite; on iOS
/// the app keeps a small in-memory ring buffer of them purely to feed the burn
/// rate regression, so no database is required on the phone.
///
/// Field set is a subset of the macOS `UsageSnapshot` — only what
/// `BurnRateCalculator` reads (`timestamp`, `sessionUtilization`, `sessionResetsAt`).
struct UsageSnapshot: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let sessionUtilization: Double
    let sessionResetsAt: Date

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionUtilization: Double,
        sessionResetsAt: Date
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionUtilization = sessionUtilization
        self.sessionResetsAt = sessionResetsAt
    }
}
