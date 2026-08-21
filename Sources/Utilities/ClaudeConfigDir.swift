import CryptoKit
import Foundation

/// Who a Claude Code configuration directory is currently signed in as, read
/// from the `oauthAccount` block Claude Code maintains in its config file.
///
/// This is the only place Battery can learn a real identity for an account: the
/// usage endpoint returns figures and nothing else, and OAuth sign-in yields
/// tokens, not a name.
struct ClaudeAccountIdentity: Equatable {
    let accountUuid: String
    let email: String?
    let organizationName: String?
}

/// Which Claude Code configuration directory an account's local data lives in.
///
/// Claude Code keeps everything a session produces — `projects/` transcripts,
/// `stats-cache.json`, credentials — under one directory: `~/.claude`, unless
/// `CLAUDE_CONFIG_DIR` points elsewhere. Giving each account its own directory
/// is the only thing that makes local history per-account, because sessions
/// carry no marker naming the account that ran them. A directory shared by two
/// accounts describes both at once, which is why they used to show identical
/// streaks, charts and project breakdowns.
enum ClaudeConfigDir {
    /// Account id (UUID string) → configuration directory. Written by the
    /// folder picker in Settings.
    ///
    /// Deliberately separate from `LiveCredentials.mappingFile`, which answers a
    /// different question — "read this account's *credentials* from Claude Code"
    /// — and carries consequences the stats mapping must not drag along: being
    /// listed there routes an account away from Battery's own token store for
    /// good reason, and picking a folder to sort out heat maps should never
    /// silently change how an account authenticates.
    static var mappingFile: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".battery/account-dirs.json")

    private static var batteryDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".battery")
    }

    /// Where Claude Code stores everything when `CLAUDE_CONFIG_DIR` is unset.
    static var defaultDir: String {
        normalize(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)
    }

    // MARK: - Resolution

    /// The directory this account's local history comes from.
    ///
    /// An explicit choice wins; failing that an account bridged to Claude Code
    /// for credentials already names its directory, so that mapping is reused
    /// rather than asking the user to state the same fact twice.
    static func resolve(for accountId: UUID) -> String {
        if let explicit = mapping()[accountId.uuidString], !explicit.isEmpty {
            return normalize(explicit)
        }
        if let live = LiveCredentials.configDir(for: accountId), !live.isEmpty {
            return normalize(live)
        }
        return defaultDir
    }

    /// Whether an account has its directory to itself — the condition that makes
    /// that directory's local history attributable to it.
    ///
    /// Taking a resolved snapshot rather than reading the mapping per call is
    /// deliberate: this is consulted on every publish from the file watcher.
    static func hasSoleClaim(_ accountId: UUID, among dirs: [UUID: String]) -> Bool {
        guard let dir = dirs[accountId].map(normalize) else { return false }
        return dirs.values.filter { normalize($0) == dir }.count <= 1
    }

    static func mapping() -> [String: String] {
        guard let data = try? Data(contentsOf: mappingFile) else { return [:] }
        return mapping(from: data)
    }

    /// Split from the file read so the format is testable. A malformed file
    /// reads as "nothing mapped", which falls back to the default directory
    /// rather than locking every account out of its history.
    static func mapping(from data: Data) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Point an account at a directory, or pass nil to return it to the default.
    static func setDir(_ dir: String?, for accountId: UUID) throws {
        var map = mapping()
        if let dir = dir, !dir.isEmpty, normalize(dir) != defaultDir {
            map[accountId.uuidString] = normalize(dir)
        } else {
            map.removeValue(forKey: accountId.uuidString)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: batteryDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(map)
        try data.write(to: mappingFile, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mappingFile.path)
    }

    /// Forget an account's mapping — used when the account itself goes away, so
    /// a later sign-in cannot inherit a stranger's folder.
    static func clearDir(for accountId: UUID) {
        try? setDir(nil, for: accountId)
    }

    // MARK: - Paths inside a directory

    static func statsCacheFile(in dir: String) -> String {
        normalize(dir) + "/stats-cache.json"
    }

    static func projectsDir(in dir: String) -> String {
        normalize(dir) + "/projects"
    }

    /// Claude Code's prompt history — one JSON line per prompt, appended and
    /// never pruned.
    ///
    /// It sits inside the directory alongside `projects/`; the odd one out is
    /// `.claude.json`, see `configFile(in:)`. Worth having a path to because it
    /// is the only record here that outlives `cleanupPeriodDays`, and so the
    /// only thing that can still place a day whose transcript has been deleted.
    static func historyFile(in dir: String) -> String {
        normalize(dir) + "/history.jsonl"
    }

    /// Claude Code's config file, which holds the `oauthAccount` block.
    ///
    /// The location is inconsistent and has to be special-cased: a default
    /// install keeps it at `~/.claude.json`, *beside* `~/.claude/`, while a
    /// directory named by `CLAUDE_CONFIG_DIR` keeps it *inside*, at
    /// `<dir>/.claude.json`. Verified against Claude Code 2.1.232 rather than
    /// assumed — guessing here would silently return no identity at all.
    static func configFile(in dir: String) -> String {
        let normalized = normalize(dir)
        if normalized == defaultDir {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude.json").path
        }
        return normalized + "/.claude.json"
    }

    /// Who this directory is signed in as, or nil if it has never been used or
    /// its config cannot be read.
    static func identity(in dir: String) -> ClaudeAccountIdentity? {
        guard let data = FileManager.default.contents(atPath: configFile(in: dir)) else { return nil }
        return identity(fromConfig: data)
    }

    /// Split from the file read so the shape — which belongs to another program
    /// and is undocumented — is pinned by a test rather than trusted.
    static func identity(fromConfig data: Data) -> ClaudeAccountIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["oauthAccount"] as? [String: Any],
              let uuid = oauth["accountUuid"] as? String,
              !uuid.isEmpty
        else { return nil }
        return ClaudeAccountIdentity(
            accountUuid: uuid,
            email: oauth["emailAddress"] as? String,
            organizationName: oauth["organizationName"] as? String
        )
    }

    /// Whether a directory looks like a Claude Code configuration directory at
    /// all, so the picker can reject a wrong folder before it is saved.
    static func looksValid(_ dir: String) -> Bool {
        let normalized = normalize(dir)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: normalized, isDirectory: &isDir), isDir.boolValue else { return false }
        return fm.fileExists(atPath: projectsDir(in: normalized))
            || fm.fileExists(atPath: statsCacheFile(in: normalized))
            || fm.fileExists(atPath: configFile(in: normalized))
    }

    // MARK: - Derived files Battery keeps per directory

    /// Where the sealed-days supplement for a directory is cached.
    ///
    /// The default directory keeps the original filename so existing installs
    /// do not throw away a cache they already computed; any other directory
    /// gets a digest-suffixed sibling, because one shared file would let two
    /// directories overwrite each other's sealed days.
    static func statsSupplementFile(for dir: String) -> URL {
        let normalized = normalize(dir)
        if normalized == defaultDir {
            return batteryDir.appendingPathComponent("stats-supplement.json")
        }
        return batteryDir.appendingPathComponent("stats-supplement-\(digest(normalized)).json")
    }

    // MARK: - Helpers

    /// Expand and standardize so `~/.claude`, `/Users/me/.claude` and
    /// `/Users/me/.claude/` compare equal — directory identity decides whether
    /// two accounts share a history, so a spelling difference would wrongly
    /// read as separation.
    static func normalize(_ dir: String) -> String {
        let expanded = NSString(string: dir).expandingTildeInPath
        let standardized = NSString(string: expanded).standardizingPath
        if standardized.count > 1 && standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }

    private static func digest(_ value: String) -> String {
        let hash = SHA256.hash(data: Data(value.utf8))
        return String(hash.map { String(format: "%02x", $0) }.joined().prefix(8))
    }
}
