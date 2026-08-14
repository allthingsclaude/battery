import XCTest
@testable import Battery

@MainActor
final class StatsCacheRegistryTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("battery-registry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func dir(_ name: String) -> String {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// Accounts sharing a directory must share the instance — each one holds a
    /// file watcher and scans multi-megabyte transcripts, so a second copy of
    /// the same directory is pure waste.
    func testSameDirectoryYieldsTheSameInstance() {
        let registry = StatsCacheRegistry()
        let path = dir(".claude-shared")
        XCTAssertTrue(registry.service(for: path) === registry.service(for: path))
    }

    /// Spelling must not fork the instance, or two accounts on one directory
    /// would each get their own watcher.
    func testEquivalentPathsYieldTheSameInstance() {
        let registry = StatsCacheRegistry()
        let path = dir(".claude-norm")
        XCTAssertTrue(registry.service(for: path) === registry.service(for: path + "/"))
    }

    func testDifferentDirectoriesYieldDifferentInstances() {
        let registry = StatsCacheRegistry()
        XCTAssertFalse(registry.service(for: dir(".claude-x")) === registry.service(for: dir(".claude-y")))
    }

    /// A removed account otherwise leaves a watcher running for the rest of the
    /// session.
    func testRetainOnlyDropsUnusedDirectories() {
        let registry = StatsCacheRegistry()
        let kept = dir(".claude-kept")
        let dropped = dir(".claude-dropped")

        let keptService = registry.service(for: kept)
        let droppedService = registry.service(for: dropped)

        registry.retainOnly([kept])

        XCTAssertTrue(registry.service(for: kept) === keptService, "retained directory keeps its instance")
        XCTAssertFalse(registry.service(for: dropped) === droppedService, "dropped directory is rebuilt fresh")
    }
}
