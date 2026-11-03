import Foundation

/// Codable model matching Claude Code's `~/.claude/stats-cache.json` structure.
struct StatsCache: Codable {
    let version: Int
    let lastComputedDate: String
    let dailyActivity: [DailyActivity]
    let totalSessions: Int
    let totalMessages: Int

    /// `Equatable` so an archive rewrite can be skipped when nothing about a
    /// day has changed.
    struct DailyActivity: Codable, Equatable {
        let date: String  // "YYYY-MM-DD"
        let messageCount: Int
        let sessionCount: Int
        let toolCallCount: Int
    }
}
