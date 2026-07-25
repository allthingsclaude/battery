import Foundation
import Security

// `StoredTokens` now lives in BatteryKit/UsageAPIShared.swift (shared with the widget).

/// Keychain-backed token storage, keyed **per account** (the account's UUID is the
/// Keychain `account` attribute). iOS Keychain is the right home for secrets —
/// unlike the macOS app, which avoids it to dodge repeated unlock prompts.
enum TokenStore {
    private static var service: String { AppConfig.keychainService }

    // MARK: Per-account

    /// Returns false when the Keychain write failed — callers must not treat the
    /// account as usable in that case (a silent failure would leave the user
    /// "signed in" with no credential and every poll returning early).
    @discardableResult
    static func save(_ tokens: StoredTokens, for id: UUID) -> Bool {
        setItem(account: id.uuidString, tokens: tokens)
    }
    static func load(for id: UUID) -> StoredTokens? { getItem(account: id.uuidString) }
    static func delete(for id: UUID) { deleteItem(account: id.uuidString) }

    // MARK: Legacy single-account (pre multi-account) — for one-time migration.

    private static let legacyAccount = "oauth-tokens"
    static func legacyLoad() -> StoredTokens? { getItem(account: legacyAccount) }
    static func legacyClear() { deleteItem(account: legacyAccount) }

    // MARK: Keychain primitives

    private static func setItem(account: String, tokens: StoredTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // `…ThisDeviceOnly` keeps these device-bound OAuth grants out of backups
        // that could be restored onto another device.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func getItem(account: String) -> StoredTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data)
        else { return nil }
        return tokens
    }

    private static func deleteItem(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
