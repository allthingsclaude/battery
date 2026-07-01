import Foundation

/// Token usage attributed to a local Claude Code project for a time window.
struct ProjectTokenUsage: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let tokens: Int
    let percentage: Double
}
