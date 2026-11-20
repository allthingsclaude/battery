import XCTest
@testable import Battery

/// The service used to hard-code `~/.claude`, which is why every account showed
/// one machine-wide history. These cover the part that makes separation real:
/// an instance reads the directory it was handed and nothing else.
final class StatsCacheServiceScopingTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("battery-scope-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Builds a config directory holding one session's worth of transcript.
    @discardableResult
    private func makeConfigDir(named name: String, project: String, messages: Int) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let projectDir = dir.appendingPathComponent("projects/-tmp-\(project)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        for index in 0..<messages {
            lines.append("""
            {"type":"assistant","timestamp":"\(stamp)","cwd":"/tmp/\(project)",\
            "message":{"usage":{"input_tokens":\(100 + index),"output_tokens":50,\
            "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
            """)
        }
        try lines.joined(separator: "\n").write(
            to: projectDir.appendingPathComponent("\(UUID().uuidString).jsonl"),
            atomically: true,
            encoding: .utf8
        )
        return dir
    }

    /// The whole point: two directories, two different project breakdowns.
    func testProjectBreakdownComesFromTheDirectoryItWasGiven() throws {
        let dirA = try makeConfigDir(named: ".claude-a", project: "alpha", messages: 3)
        let dirB = try makeConfigDir(named: ".claude-b", project: "beta", messages: 3)

        let window = Date().addingTimeInterval(-3600)...Date().addingTimeInterval(3600)
        let serviceA = StatsCacheService(configDir: dirA.path)
        let serviceB = StatsCacheService(configDir: dirB.path)

        let usageA = serviceA.scanProjectTokenUsage(from: window.lowerBound, to: window.upperBound)
        let usageB = serviceB.scanProjectTokenUsage(from: window.lowerBound, to: window.upperBound)

        XCTAssertEqual(usageA.map(\.name), ["alpha"])
        XCTAssertEqual(usageB.map(\.name), ["beta"])
        XCTAssertFalse(usageA.contains { $0.name == "beta" }, "A must not see B's projects")
    }

    /// The popover shows five projects and expands to ten, so the scan keeps
    /// ten by name and rolls everything past them into one "Other projects" row.
    func testBreakdownKeepsTenProjectsAndRollsUpTheRest() throws {
        var dir: URL!
        // Project pN gets N+1 messages, so the order by tokens is p11 ... p0.
        for index in 0..<12 {
            dir = try makeConfigDir(named: "cfg-many", project: "p\(index)", messages: index + 1)
        }

        let usage = StatsCacheService(configDir: dir.path).scanProjectTokenUsage(
            from: Date().addingTimeInterval(-3600),
            to: Date().addingTimeInterval(3600)
        )

        XCTAssertEqual(usage.count, 11)
        XCTAssertEqual(usage.prefix(10).map(\.name), (2..<12).reversed().map { "p\($0)" })
        XCTAssertEqual(usage.last?.isOtherProjects, true)
        // p0: one message of 100 + 50 tokens; p1: 150 + 151.
        XCTAssertEqual(usage.last?.tokens, 451)
        XCTAssertEqual(usage.reduce(0) { $0 + $1.percentage }, 100, accuracy: 0.001)
    }

    /// Writes one assistant line per working directory into a config dir.
    private func makeConfigDir(named name: String, cwds: [String]) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        for (index, cwd) in cwds.enumerated() {
            let projectDir = dir.appendingPathComponent("projects/p\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let line = """
            {"type":"assistant","timestamp":"\(stamp)","cwd":"\(cwd)",\
            "message":{"usage":{"input_tokens":100,"output_tokens":0,\
            "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
            """
            try line.write(
                to: projectDir.appendingPathComponent("\(UUID().uuidString).jsonl"),
                atomically: true,
                encoding: .utf8
            )
        }
        return dir
    }

    private func mkdir(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Sessions in a repo, a folder inside it, and one of its linked worktrees
    /// are one project; a submodule and an unrelated folder stay separate.
    func testWorkingDirectoriesFoldIntoTheirGitProject() throws {
        let repo = try mkdir("code/shopnosis-platform")
        _ = try mkdir("code/shopnosis-platform/.git/worktrees/feature")
        try "../..\n".write(
            to: repo.appendingPathComponent(".git/worktrees/feature/commondir"),
            atomically: true,
            encoding: .utf8
        )
        let web = try mkdir("code/shopnosis-platform/web")
        let worktree = try mkdir("trees/feature")
        try "gitdir: \(repo.path)/.git/worktrees/feature\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        let worktreeSub = try mkdir("trees/feature/db")
        _ = try mkdir("code/shopnosis-platform/.git/modules/vendor")
        let submodule = try mkdir("code/shopnosis-platform/vendor")
        try "gitdir: ../.git/modules/vendor\n".write(
            to: submodule.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        let loose = try mkdir("code/scratch")

        let dir = try makeConfigDir(
            named: "cfg-fold",
            cwds: [repo.path, web.path, worktree.path, worktreeSub.path, submodule.path, loose.path]
        )
        let usage = StatsCacheService(configDir: dir.path).scanProjectTokenUsage(
            from: Date().addingTimeInterval(-3600),
            to: Date().addingTimeInterval(3600)
        )

        XCTAssertEqual(usage.map(\.name), ["shopnosis-platform", "scratch", "vendor"])
        XCTAssertEqual(usage.first?.tokens, 400)
        XCTAssertEqual(usage.first?.path, repo.standardizedFileURL.path)
    }

    /// A repository at home must not absorb every folder that isn't its own repo.
    func testHomeRepositoryDoesNotAbsorbNestedFolders() throws {
        let home = try mkdir("home")
        _ = try mkdir("home/.git")
        let folder = try mkdir("home/Downloads/thing")
        XCTAssertEqual(StatsCacheService.projectRoot(for: folder.path, home: home.path), folder.path)
        XCTAssertEqual(StatsCacheService.projectRoot(for: home.path, home: home.path), home.path)
    }

    func testConfigDirIsNormalizedOnTheInstance() throws {
        let dir = try makeConfigDir(named: ".claude-n", project: "gamma", messages: 1)
        let service = StatsCacheService(configDir: dir.path + "/")
        XCTAssertEqual(service.configDir, ClaudeConfigDir.normalize(dir.path))
    }

    /// A directory with no transcripts yields nothing rather than falling back
    /// to the machine-wide `~/.claude`, which would resurrect the shared numbers.
    func testEmptyDirectoryDoesNotFallBackToTheDefault() throws {
        let empty = root.appendingPathComponent(".claude-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let service = StatsCacheService(configDir: empty.path)
        let usage = service.scanProjectTokenUsage(
            from: Date().addingTimeInterval(-86_400),
            to: Date().addingTimeInterval(3600)
        )
        XCTAssertTrue(usage.isEmpty)
    }
}
