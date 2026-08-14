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
