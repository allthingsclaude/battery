import Foundation
import Combine
import Security

/// Manages multiple accounts and their token storage.
///
/// Tokens are stored as JSON files in `~/.battery/tokens/` (0600 perms).
/// Account metadata lives at `~/.battery/accounts.json` (0600 perms).
/// Migrates from legacy keychain/disk storage on first access.
@MainActor
class AccountManager: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var selectedAccountId: UUID?

    private let fileManager = FileManager.default
    private static let keychainService = "com.allthingsclaude.battery"

    private var batteryDir: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".battery")
    }

    private var accountsFile: URL {
        batteryDir.appendingPathComponent("accounts.json")
    }

    private var accountsDir: URL {
        batteryDir.appendingPathComponent("accounts")
    }

    var selectedAccount: Account? {
        guard let id = selectedAccountId else { return accounts.first }
        return accounts.first(where: { $0.id == id })
    }

    var hasAccounts: Bool {
        !accounts.isEmpty
    }

    // MARK: - Load / Save

    func load() {
        guard fileManager.fileExists(atPath: accountsFile.path) else { return }
        do {
            let data = try Data(contentsOf: accountsFile)
            accounts = try JSONDecoder().decode([Account].self, from: data)
        } catch {
            print("Failed to load accounts: \(error.localizedDescription)")
        }

        if let savedId = UserDefaults.standard.string(forKey: "selectedAccountId"),
           let uuid = UUID(uuidString: savedId),
           accounts.contains(where: { $0.id == uuid }) {
            selectedAccountId = uuid
        } else {
            selectedAccountId = accounts.first?.id
        }
    }

    func save() {
        do {
            try fileManager.createDirectory(at: batteryDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(accounts)
            try data.write(to: accountsFile, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountsFile.path)
        } catch {
            print("Failed to save accounts: \(error.localizedDescription)")
        }
    }

    // MARK: - Account Management

    func addAccount(_ account: Account, tokens: StoredTokens) {
        accounts.append(account)
        saveTokens(tokens, for: account.id)
        save()
        selectAccount(id: account.id)
    }

    func removeAccount(id: UUID) {
        accounts.removeAll(where: { $0.id == id })

        // Remove tokens from all storage backends
        deleteTokens(for: id)

        // Clean up any leftover legacy tokens
        let tokenDir = accountsDir.appendingPathComponent(id.uuidString)
        try? fileManager.removeItem(at: tokenDir)

        // Select next account if the removed one was selected
        if selectedAccountId == id {
            selectedAccountId = accounts.first?.id
            persistSelectedAccountId()
        }

        save()
    }

    func removeAllAccounts() {
        let ids = accounts.map(\.id)
        for id in ids {
            deleteTokens(for: id)
            let tokenDir = accountsDir.appendingPathComponent(id.uuidString)
            try? fileManager.removeItem(at: tokenDir)
        }
        accounts.removeAll()
        selectedAccountId = nil
        persistSelectedAccountId()
        save()
    }

    func selectAccount(id: UUID) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        selectedAccountId = id
        persistSelectedAccountId()
    }

    func updateAccount(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        save()
    }

    // MARK: - Token Storage

    private var tokensDir: URL {
        batteryDir.appendingPathComponent("tokens")
    }

    private func tokenFile(for accountId: UUID) -> URL {
        tokensDir.appendingPathComponent("\(accountId.uuidString).json")
    }

    func getTokens(for accountId: UUID) -> StoredTokens? {
        // 0. Live Claude Code credentials (accounts mapped in ~/.battery/live-creds.json)
        if let live = LiveCredentials.tokens(for: accountId) {
            return live
        }

        // 1. File-based storage (primary)
        let file = tokenFile(for: accountId)
        if fileManager.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                return try JSONDecoder().decode(StoredTokens.self, from: data)
            } catch {
                print("Failed to read tokens for \(accountId): \(error.localizedDescription)")
            }
        }

        // 2. Migrate from keychain (one-time, for existing installs)
        if let tokens = migrateFromKeychain(accountId: accountId) {
            return tokens
        }

        // 3. Legacy: old per-account directory structure
        let legacyFile = accountsDir
            .appendingPathComponent(accountId.uuidString)
            .appendingPathComponent("tokens.json")
        guard fileManager.fileExists(atPath: legacyFile.path) else { return nil }
        do {
            let data = try Data(contentsOf: legacyFile)
            let tokens = try JSONDecoder().decode(StoredTokens.self, from: data)
            saveTokens(tokens, for: accountId)
            try? fileManager.removeItem(at: legacyFile)
            return tokens
        } catch {
            print("Failed to read legacy tokens for \(accountId): \(error.localizedDescription)")
            return nil
        }
    }

    func saveTokens(_ tokens: StoredTokens, for accountId: UUID) {
        do {
            try fileManager.createDirectory(at: tokensDir, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tokensDir.path)
            let data = try JSONEncoder().encode(tokens)
            try data.write(to: tokenFile(for: accountId), options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile(for: accountId).path)
        } catch {
            print("Failed to save tokens for \(accountId): \(error.localizedDescription)")
        }
    }

    func deleteTokens(for accountId: UUID) {
        try? fileManager.removeItem(at: tokenFile(for: accountId))
        // Also clean up any leftover keychain entry
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: accountId.uuidString,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }

    // MARK: - Keychain Migration

    /// One-time: read from the old keychain, save to file, delete keychain entry.
    private func migrateFromKeychain(accountId: UUID) -> StoredTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: accountId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data) else {
            return nil
        }

        // Save to file and remove keychain entry
        saveTokens(tokens, for: accountId)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: accountId.uuidString,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        return tokens
    }

    // MARK: - Private

    private func persistSelectedAccountId() {
        if let id = selectedAccountId {
            UserDefaults.standard.set(id.uuidString, forKey: "selectedAccountId")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedAccountId")
        }
    }
}
