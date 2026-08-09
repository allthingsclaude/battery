import CryptoKit
import Foundation
import Security

/// Optional bridge to Claude Code's own credentials.
///
/// When `~/.battery/live-creds.json` maps an account id (UUID string) to a
/// Claude Code config dir (e.g. `~/.claude-akson`), tokens for that account
/// are read fresh from the credential Claude Code itself maintains — macOS
/// keychain entry "Claude Code-credentials-<sha256[:8] of dir>", with a
/// plaintext `<dir>/.credentials.json` fallback — instead of Battery's own
/// token store.
///
/// The refresh token is deliberately withheld: OAuth refresh tokens are
/// single-use, so if Battery rotated a chain shared with Claude Code, one of
/// the two would be stranded ("OAuth session expired"). Claude Code and its
/// companion tooling keep these credentials fresh; Battery just reads them.
/// A mapped account whose Claude Code credential could not be read.
///
/// Deliberately not a `requiresReauth` case: Battery cannot fix this by signing
/// in, and doing so would create the duplicate refresh chain the bridge exists
/// to prevent. The user fixes it in Claude Code, or by correcting the mapping.
enum LiveCredentialError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "Claude Code credential unreadable — check ~/.battery/live-creds.json, "
            + "or allow Battery access to the keychain item when prompted."
    }
}

enum LiveCredentials {
    /// Settable purely so tests can point the bridge at a fixture rather than
    /// the real home directory. Nothing in the app reassigns it.
    static var mappingFile: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".battery/live-creds.json")

    static func configDir(for accountId: UUID) -> String? {
        guard let data = try? Data(contentsOf: mappingFile) else { return nil }
        return configDir(for: accountId, mapping: data)
    }

    /// Split from the file read so the mapping format is testable. A malformed
    /// file yields nil for every account, which reads as "not mapped" — the
    /// account falls back to Battery's own sign-in rather than being locked out
    /// by a typo in a hand-edited JSON file.
    static func configDir(for accountId: UUID, mapping data: Data) -> String? {
        guard let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return map[accountId.uuidString]
    }

    /// Whether this account is bridged to Claude Code at all.
    ///
    /// Distinct from whether its credential can currently be *read*: a mapped
    /// account whose keychain read fails must not fall through to Battery's own
    /// store, which is what [AccountManager.tokenLookup] uses this for.
    static func isMapped(_ accountId: UUID) -> Bool {
        configDir(for: accountId) != nil
    }

    static func tokens(for accountId: UUID) -> StoredTokens? {
        guard let dir = configDir(for: accountId) else { return nil }
        let expanded = NSString(string: dir).expandingTildeInPath
        let raw = keychainRead(service: service(forConfigDir: expanded))
            ?? (try? String(contentsOfFile: expanded + "/.credentials.json", encoding: .utf8))
        guard let raw else { return nil }
        return parseCredential(raw)
    }

    /// Claude Code's credential blob → tokens, or nil if it isn't one.
    ///
    /// Split out because this is the part that silently breaks: the shape is
    /// undocumented and belongs to another program, so a change there turns
    /// every mapped account into a nil that used to be indistinguishable from
    /// "not mapped". Tested against the real shape rather than assumed.
    static func parseCredential(_ raw: String) -> StoredTokens? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              !access.isEmpty
        else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber)?.int64Value ?? 0
        // Refresh token deliberately withheld — see the type doc.
        var tokens = StoredTokens(accessToken: access, refreshToken: nil, expiresAt: expiresAt)
        tokens.isLive = true
        return tokens
    }

    /// Keychain service name Claude Code uses for a given config dir.
    static func service(forConfigDir dir: String) -> String {
        let digest = SHA256.hash(data: Data(dir.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + String(hex.prefix(8))
    }

    private static func keychainRead(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
