import Foundation

/// Cached per-account usage state for fast account switching.
struct AccountUsageState {
    var sessionUtilization: Double = 0
    var sessionResetsAt: Date?
    var weeklyUtilization: Double = 0
    var weeklyResetsAt: Date?
    var sonnetUtilization: Double?
    var opusUtilization: Double?
    var fableUtilization: Double?
    var fableResetsAt: Date?
    var extraUsageEnabled: Bool = false
    var extraUsageCost: Double?
    var extraUsageLimit: Double?
    var extraUsageUtilization: Double?
    var isConnected: Bool = false
    var lastUpdated: Date?
    var error: String?
    var planTier: PlanTier = .unknown
    var projection: BurnRateProjection?
    var dailyPeaks: [(date: Date, peak: Double)] = []
    var currentStreak: Int = 0
    var activeDays: [Date: Double] = [:]
    var todaySessionCount: Int = 0
    var sessionProjectTokenUsage: [ProjectTokenUsage] = []
    var weeklyProjectTokenUsage: [ProjectTokenUsage] = []
}
