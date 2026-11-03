import Foundation

/// Token usage attributed to a local Claude Code project for a time window.
struct ProjectTokenUsage: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let tokens: Int
    let percentage: Double

    /// Id of the row that rolls up everything past the named projects.
    static let otherProjectsID = "__other_projects__"

    var isOtherProjects: Bool { id == Self.otherProjectsID }
}
