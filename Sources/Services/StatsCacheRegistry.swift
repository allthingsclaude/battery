import Foundation

/// Owns one `StatsCacheService` per Claude Code configuration directory.
///
/// Accounts sharing a directory share the instance. That matters for more than
/// tidiness: each service holds a kqueue file watcher and scans multi-megabyte
/// JSONL transcripts, so handing every account its own copy of the same
/// directory would duplicate both for no new information.
@MainActor
final class StatsCacheRegistry {
    private var services: [String: StatsCacheService] = [:]

    /// The service for a directory, started on first use.
    func service(for configDir: String) -> StatsCacheService {
        let key = ClaudeConfigDir.normalize(configDir)
        if let existing = services[key] { return existing }

        let service = StatsCacheService(configDir: key)
        services[key] = service
        service.startWatching()
        return service
    }

    /// Stop watching directories no account points at any more — a removed
    /// account otherwise leaves a file watcher running for the rest of the
    /// session.
    func retainOnly(_ configDirs: Set<String>) {
        let keep = Set(configDirs.map { ClaudeConfigDir.normalize($0) })
        for (key, service) in services where !keep.contains(key) {
            service.stopWatching()
            services.removeValue(forKey: key)
        }
    }
}
