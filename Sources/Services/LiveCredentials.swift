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
enum LiveCredentials {
    static var mappingFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".battery/live-creds.json")
    }

    static func configDir(for accountId: UUID) -> String? {
        guard let data = try? Data(contentsOf: mappingFile),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return map[accountId.uuidString]
    }

    static func tokens(for accountId: UUID) -> StoredTokens? {
        guard let dir = configDir(for: accountId) else { return nil }
        let expanded = NSString(string: dir).expandingTildeInPath
        let raw = keychainRead(service: service(forConfigDir: expanded))
            ?? (try? String(contentsOfFile: expanded + "/.credentials.json", encoding: .utf8))
        guard let raw,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String
        else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber)?.int64Value ?? 0
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
