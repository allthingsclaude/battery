import XCTest
@testable import Battery

/// Directory identity decides whether two accounts share a history, so the
/// resolution rules here are load-bearing: get one wrong and either two accounts
/// merge back into one set of numbers, or an account reads a directory that is
/// not its own.
final class ClaudeConfigDirTests: XCTestCase {

    private var tempDir: URL!
    private var savedMapping: URL!
    private var savedLiveMapping: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("battery-cfgdir-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        savedMapping = ClaudeConfigDir.mappingFile
        savedLiveMapping = LiveCredentials.mappingFile
        ClaudeConfigDir.mappingFile = tempDir.appendingPathComponent("account-dirs.json")
        LiveCredentials.mappingFile = tempDir.appendingPathComponent("live-creds.json")
    }

    override func tearDown() {
        ClaudeConfigDir.mappingFile = savedMapping
        LiveCredentials.mappingFile = savedLiveMapping
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Normalization

    /// Two spellings of one directory must compare equal, or accounts sharing a
    /// folder would wrongly read as separated.
    func testNormalizeCollapsesEquivalentSpellings() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(ClaudeConfigDir.normalize("~/.claude"), ClaudeConfigDir.normalize("\(home)/.claude"))
        XCTAssertEqual(ClaudeConfigDir.normalize("~/.claude/"), ClaudeConfigDir.normalize("~/.claude"))
        XCTAssertEqual(ClaudeConfigDir.normalize("~/.claude"), ClaudeConfigDir.defaultDir)
    }

    func testNormalizeKeepsDistinctDirectoriesDistinct() {
        XCTAssertNotEqual(ClaudeConfigDir.normalize("~/.claude"), ClaudeConfigDir.normalize("~/.claude-work"))
    }

    // MARK: - Resolution

    func testUnmappedAccountFallsBackToTheDefaultDirectory() {
        XCTAssertEqual(ClaudeConfigDir.resolve(for: UUID()), ClaudeConfigDir.defaultDir)
    }

    func testExplicitMappingWins() throws {
        let account = UUID()
        try ClaudeConfigDir.setDir("~/.claude-work", for: account)
        XCTAssertEqual(ClaudeConfigDir.resolve(for: account), ClaudeConfigDir.normalize("~/.claude-work"))
    }

    /// An account already bridged to Claude Code for credentials has stated its
    /// directory once; it should not have to state it again.
    func testFallsBackToTheLiveCredentialsMapping() throws {
        let account = UUID()
        let json = #"{"\#(account.uuidString)":"~/.claude-live"}"#
        try Data(json.utf8).write(to: LiveCredentials.mappingFile)
        XCTAssertEqual(ClaudeConfigDir.resolve(for: account), ClaudeConfigDir.normalize("~/.claude-live"))
    }

    func testExplicitMappingOverridesTheLiveCredentialsMapping() throws {
        let account = UUID()
        let json = #"{"\#(account.uuidString)":"~/.claude-live"}"#
        try Data(json.utf8).write(to: LiveCredentials.mappingFile)
        try ClaudeConfigDir.setDir("~/.claude-chosen", for: account)
        XCTAssertEqual(ClaudeConfigDir.resolve(for: account), ClaudeConfigDir.normalize("~/.claude-chosen"))
    }

    func testClearingReturnsAnAccountToTheDefault() throws {
        let account = UUID()
        try ClaudeConfigDir.setDir("~/.claude-work", for: account)
        try ClaudeConfigDir.setDir(nil, for: account)
        XCTAssertEqual(ClaudeConfigDir.resolve(for: account), ClaudeConfigDir.defaultDir)
    }

    /// Choosing the default directory explicitly is the same as choosing
    /// nothing — storing it would leave a redundant entry behind.
    func testMappingToTheDefaultDirectoryStoresNothing() throws {
        let account = UUID()
        try ClaudeConfigDir.setDir("~/.claude", for: account)
        XCTAssertNil(ClaudeConfigDir.mapping()[account.uuidString])
        XCTAssertEqual(ClaudeConfigDir.resolve(for: account), ClaudeConfigDir.defaultDir)
    }

    /// A hand-edited file with a typo must not lock every account out of its
    /// history.
    func testMalformedMappingReadsAsUnmapped() {
        XCTAssertTrue(ClaudeConfigDir.mapping(from: Data("not json".utf8)).isEmpty)
    }

    // MARK: - The untouched setup

    /// One account, nothing configured — by far the common case. It must land on
    /// exactly the paths the service used before any of this existed, and keep
    /// using the local Claude Code history rather than Battery's snapshots.
    func testSingleUnconfiguredAccountKeepsTheOriginalBehaviour() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let account = UUID()
        let dir = ClaudeConfigDir.resolve(for: account)

        XCTAssertEqual(dir, "\(home)/.claude")
        XCTAssertEqual(ClaudeConfigDir.statsCacheFile(in: dir), "\(home)/.claude/stats-cache.json")
        XCTAssertEqual(ClaudeConfigDir.projectsDir(in: dir), "\(home)/.claude/projects")
        XCTAssertEqual(
            ClaudeConfigDir.statsSupplementFile(for: dir).path,
            "\(home)/.battery/stats-supplement.json"
        )
        XCTAssertTrue(
            ClaudeConfigDir.hasSoleClaim(account, among: [account: dir]),
            "a lone account owns its directory, so local history still applies"
        )
    }

    /// Nothing is written until a folder is actually picked — an untouched
    /// install gains no new files.
    func testNoMappingFileIsCreatedUntilAFolderIsPicked() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClaudeConfigDir.mappingFile.path))
        XCTAssertTrue(ClaudeConfigDir.mapping().isEmpty)
    }

    // MARK: - Sole claim

    /// The rule that picks the history source. Two accounts in one directory is
    /// exactly the case that produced identical streaks and charts.
    func testSoleClaimRequiresADirectoryToItself() {
        let alice = UUID()
        let bob = UUID()

        let shared: [UUID: String] = [alice: "~/.claude", bob: "~/.claude"]
        XCTAssertFalse(ClaudeConfigDir.hasSoleClaim(alice, among: shared))
        XCTAssertFalse(ClaudeConfigDir.hasSoleClaim(bob, among: shared))

        let split: [UUID: String] = [alice: "~/.claude", bob: "~/.claude-work"]
        XCTAssertTrue(ClaudeConfigDir.hasSoleClaim(alice, among: split))
        XCTAssertTrue(ClaudeConfigDir.hasSoleClaim(bob, among: split))

        XCTAssertTrue(ClaudeConfigDir.hasSoleClaim(alice, among: [alice: "~/.claude"]))
    }

    /// Sharing must be detected through a difference in spelling, not just a
    /// difference in string.
    func testSoleClaimComparesNormalizedPaths() {
        let alice = UUID()
        let bob = UUID()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs: [UUID: String] = [alice: "~/.claude", bob: "\(home)/.claude/"]
        XCTAssertFalse(ClaudeConfigDir.hasSoleClaim(alice, among: dirs))
    }

    func testUnknownAccountHasNoClaim() {
        XCTAssertFalse(ClaudeConfigDir.hasSoleClaim(UUID(), among: [:]))
    }

    // MARK: - Config file location

    /// The location is inconsistent in Claude Code and was verified against
    /// 2.1.232: beside the directory for a default install, inside it for one
    /// named by CLAUDE_CONFIG_DIR. Guessing here returns no identity at all.
    func testConfigFileSitsBesideTheDefaultDirectoryButInsideOthers() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(ClaudeConfigDir.configFile(in: ClaudeConfigDir.defaultDir), "\(home)/.claude.json")
        XCTAssertEqual(ClaudeConfigDir.configFile(in: "\(home)/.claude-work"), "\(home)/.claude-work/.claude.json")
    }

    // MARK: - Identity

    func testParsesTheRealOAuthAccountShape() {
        let json = """
        {"numStartups": 4, "oauthAccount": {
          "accountUuid": "178667ab-ac56-4791-af90-062fa92c6c24",
          "emailAddress": "someone@example.com",
          "organizationName": "someone@example.com's Organization",
          "organizationType": "claude_max"}}
        """
        let identity = ClaudeConfigDir.identity(fromConfig: Data(json.utf8))
        XCTAssertEqual(identity?.accountUuid, "178667ab-ac56-4791-af90-062fa92c6c24")
        XCTAssertEqual(identity?.email, "someone@example.com")
        XCTAssertEqual(identity?.organizationName, "someone@example.com's Organization")
    }

    /// A config from a directory that has never been signed in has no
    /// `oauthAccount` at all — that is "unknown", not a crash.
    func testConfigWithoutAnAccountYieldsNoIdentity() {
        XCTAssertNil(ClaudeConfigDir.identity(fromConfig: Data(#"{"numStartups": 1}"#.utf8)))
        XCTAssertNil(ClaudeConfigDir.identity(fromConfig: Data("not json".utf8)))
    }

    // MARK: - Derived files

    /// One shared supplement file would let two directories overwrite each
    /// other's sealed days, quietly corrupting both histories.
    func testEachDirectoryGetsItsOwnSupplementFile() {
        let a = ClaudeConfigDir.statsSupplementFile(for: "~/.claude-a")
        let b = ClaudeConfigDir.statsSupplementFile(for: "~/.claude-b")
        XCTAssertNotEqual(a, b)
    }

    /// Existing installs must not throw away a cache they already computed.
    func testDefaultDirectoryKeepsTheOriginalSupplementFilename() {
        XCTAssertEqual(
            ClaudeConfigDir.statsSupplementFile(for: ClaudeConfigDir.defaultDir).lastPathComponent,
            "stats-supplement.json"
        )
    }
}
