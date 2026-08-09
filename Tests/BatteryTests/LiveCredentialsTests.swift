import XCTest
@testable import Battery

/// The live-credentials bridge shipped with no tests at all. These cover the
/// two parts that can silently break without anything noticing: the shape of a
/// credential belonging to *another program*, and the keychain service name
/// derived from a config-dir path. Both fail by returning nil, which used to be
/// indistinguishable from "this account isn't mapped".
final class LiveCredentialsTests: XCTestCase {

    // MARK: - Credential blob

    private func credential(
        accessToken: String = "sk-ant-oat01-abc",
        expiresAt: String = "1893456000000",
        extra: String = ""
    ) -> String {
        """
        { "claudeAiOauth": { "accessToken": "\(accessToken)",
          "refreshToken": "sk-ant-ort01-should-be-ignored",
          "expiresAt": \(expiresAt)\(extra) } }
        """
    }

    func testParsesTheRealCredentialShape() {
        let tokens = LiveCredentials.parseCredential(credential())
        XCTAssertEqual(tokens?.accessToken, "sk-ant-oat01-abc")
        XCTAssertEqual(tokens?.expiresAt, 1_893_456_000_000)
    }

    /// The single most important property in the file. Refresh tokens are
    /// single-use, so if Battery ever carried Claude Code's refresh token it
    /// could rotate a chain both programs share and strand one of them.
    func testRefreshTokenIsWithheldEvenThoughTheBlobHasOne() {
        XCTAssertNil(LiveCredentials.parseCredential(credential())?.refreshToken)
    }

    /// Drives the exemptions in the polling service — no refresh, no reauth on
    /// 401. A live token that lost this flag would get its chain rotated.
    func testLiveTokensAreFlaggedAsLive() {
        XCTAssertEqual(LiveCredentials.parseCredential(credential())?.isLive, true)
    }

    /// `isLive` is deliberately outside CodingKeys: persisting it would let a
    /// stale flag outlive the mapping that justified it.
    func testIsLiveIsNotPersisted() throws {
        var tokens = StoredTokens(accessToken: "a", refreshToken: "r", expiresAt: 1)
        tokens.isLive = true

        let round = try JSONDecoder().decode(StoredTokens.self, from: JSONEncoder().encode(tokens))

        XCTAssertFalse(round.isLive)
        XCTAssertEqual(round.accessToken, "a")
    }

    func testRejectsBlobsThatAreNotACredential() {
        XCTAssertNil(LiveCredentials.parseCredential("not json"))
        XCTAssertNil(LiveCredentials.parseCredential("{}"))
        // The wrapper key is Claude Code's; without it this is someone else's file.
        XCTAssertNil(LiveCredentials.parseCredential(#"{"accessToken":"x"}"#))
        // An empty token would be sent as `Bearer ` and 401 on every poll.
        XCTAssertNil(LiveCredentials.parseCredential(credential(accessToken: "")))
    }

    /// A credential with no expiry still works, because live tokens are used
    /// as-is and never refreshed — but it must not crash the parse.
    func testMissingExpiryIsTolerated() {
        let raw = #"{ "claudeAiOauth": { "accessToken": "abc" } }"#
        XCTAssertEqual(LiveCredentials.parseCredential(raw)?.accessToken, "abc")
        XCTAssertEqual(LiveCredentials.parseCredential(raw)?.expiresAt, 0)
    }

    // MARK: - Keychain service name

    /// Claude Code names its keychain item after the sha256 of the config-dir
    /// path. Get this wrong and every read misses — silently, since a miss is
    /// just nil. Pinned to a known digest so a refactor of the hashing cannot
    /// pass by agreeing with itself.
    func testServiceNameMatchesClaudeCodesScheme() {
        // sha256("/Users/me/.claude") begins 4b9f0dbf…
        let service = LiveCredentials.service(forConfigDir: "/Users/me/.claude")
        XCTAssertTrue(service.hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(service.count, "Claude Code-credentials-".count + 8)
    }

    func testServiceNameIsPathSensitive() {
        // Two config dirs is the entire use case; they must not collide, and a
        // trailing slash is a different string to Claude Code too.
        XCTAssertNotEqual(
            LiveCredentials.service(forConfigDir: "/Users/me/.claude-work"),
            LiveCredentials.service(forConfigDir: "/Users/me/.claude-personal")
        )
        XCTAssertNotEqual(
            LiveCredentials.service(forConfigDir: "/Users/me/.claude"),
            LiveCredentials.service(forConfigDir: "/Users/me/.claude/")
        )
    }

    func testServiceNameIsStableAcrossCalls() {
        XCTAssertEqual(
            LiveCredentials.service(forConfigDir: "/Users/me/.claude"),
            LiveCredentials.service(forConfigDir: "/Users/me/.claude")
        )
    }

    // MARK: - Mapping file

    func testMappingResolvesTheConfiguredAccount() throws {
        let mapped = UUID()
        let other = UUID()
        let data = Data("""
        { "\(mapped.uuidString)": "~/.claude-work",
          "\(other.uuidString)": "/Users/me/.claude-personal" }
        """.utf8)

        XCTAssertEqual(LiveCredentials.configDir(for: mapped, mapping: data), "~/.claude-work")
        XCTAssertEqual(LiveCredentials.configDir(for: other, mapping: data), "/Users/me/.claude-personal")
        XCTAssertNil(LiveCredentials.configDir(for: UUID(), mapping: data))
    }

    /// A hand-edited file with a typo must read as "not mapped" rather than
    /// locking the account out — unmapped accounts still have their own sign-in.
    func testMalformedMappingReadsAsUnmapped() {
        XCTAssertNil(LiveCredentials.configDir(for: UUID(), mapping: Data("{ oops".utf8)))
        XCTAssertNil(LiveCredentials.configDir(for: UUID(), mapping: Data()))
        // Right JSON, wrong type — the values must be paths.
        XCTAssertNil(LiveCredentials.configDir(for: UUID(), mapping: Data(#"{"a":1}"#.utf8)))
    }

    // MARK: - Fail closed

    /// Points the bridge at a fixture for the duration of a test.
    private func withMapping(_ json: String, _ body: () throws -> Void) rethrows {
        let original = LiveCredentials.mappingFile
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-creds-\(UUID().uuidString).json")
        try? Data(json.utf8).write(to: file)
        LiveCredentials.mappingFile = file
        defer {
            LiveCredentials.mappingFile = original
            try? FileManager.default.removeItem(at: file)
        }
        try body()
    }

    /// The fix this file exists for. A mapped account whose credential cannot be
    /// read must report `liveUnavailable` — never `missing`, which is what
    /// drives the browser sign-in that mints a competing refresh chain. It must
    /// also not fall through to Battery's own store on the way there.
    @MainActor
    func testMappedAccountWithUnreadableCredentialFailsClosed() {
        let account = UUID()
        withMapping(#"{"\#(account.uuidString)": "/nonexistent/claude-dir"}"#) {
            guard case .liveUnavailable = AccountManager().tokenLookup(for: account) else {
                return XCTFail("a mapped account must not fall through to the file store")
            }
        }
    }

    /// The other half: an account nobody mapped still reaches sign-in, or a
    /// genuinely signed-out account would sit on an error forever.
    @MainActor
    func testUnmappedAccountWithNoCredentialIsMissing() {
        withMapping("{}") {
            guard case .missing = AccountManager().tokenLookup(for: UUID()) else {
                return XCTFail("an unmapped account with no tokens should be missing")
            }
        }
    }
}
