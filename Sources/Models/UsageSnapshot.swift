import Foundation

/// A point-in-time record of usage data, stored in SQLite for historical tracking.
struct UsageSnapshot: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let sessionUtilization: Double
    let sessionResetsAt: Date
    let weeklyUtilization: Double
    let weeklyResetsAt: Date
    let sonnetUtilization: Double?
    let opusUtilization: Double?
    let fableUtilization: Double?
    let planTier: String
    let accountId: UUID?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionUtilization: Double,
        sessionResetsAt: Date,
        weeklyUtilization: Double,
        weeklyResetsAt: Date,
        sonnetUtilization: Double? = nil,
        opusUtilization: Double? = nil,
        fableUtilization: Double? = nil,
        planTier: String = "unknown",
        accountId: UUID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionUtilization = sessionUtilization
        self.sessionResetsAt = sessionResetsAt
        self.weeklyUtilization = weeklyUtilization
        self.weeklyResetsAt = weeklyResetsAt
        self.sonnetUtilization = sonnetUtilization
        self.opusUtilization = opusUtilization
        self.fableUtilization = fableUtilization
        self.planTier = planTier
        self.accountId = accountId
    }
}
