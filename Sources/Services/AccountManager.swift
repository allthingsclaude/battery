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

    /// What a token lookup found, so callers can tell a missing credential from
    /// one that is merely unreadable right now.
    enum TokenLookup {
        case tokens(StoredTokens)
        /// No credential anywhere. Signing in is the only cure.
        case missing
        /// The account is mapped to a Claude Code config dir whose credential
        /// could not be read — a denied keychain prompt, a renamed directory,
        /// Claude Code signed out. Transient by nature.
        case liveUnavailable
    }

    /// Resolve tokens, keeping mapped accounts out of the sign-in path.
    ///
    /// A mapped account **never** falls through to Battery's own store. It used
    /// to: any failure to read the live credential — including clicking Deny
    /// once on the keychain prompt — returned nil, which surfaced as "needs
    /// reauth", opened a browser, and minted a second refresh chain for an
    /// account that already had a working one. That is exactly the stranding
    /// the live-credentials bridge exists to prevent, reached by the most
    /// ordinary user action available.
    func tokenLookup(for accountId: UUID) -> TokenLookup {
        if LiveCredentials.isMapped(accountId) {
            guard let live = LiveCredentials.tokens(for: accountId) else {
                return .liveUnavailable
            }
            return .tokens(live)
        }
        guard let stored = storedTokens(for: accountId) else { return .missing }
        return .tokens(stored)
    }

    func getTokens(for accountId: UUID) -> StoredTokens? {
        if case .tokens(let t) = tokenLookup(for: accountId) { return t }
        return nil
    }

    private func storedTokens(for accountId: UUID) -> StoredTokens? {
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

    /// - Returns: whether the tokens reached disk. Callers holding a rotated
    ///   refresh token must not discard it on `false`: the old one is already
    ///   spent server-side, so a silently dropped write strands the account.
    @discardableResult
    func saveTokens(_ tokens: StoredTokens, for accountId: UUID) -> Bool {
        do {
            try fileManager.createDirectory(at: tokensDir, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tokensDir.path)
            let data = try JSONEncoder().encode(tokens)
            try data.write(to: tokenFile(for: accountId), options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile(for: accountId).path)
            return true
        } catch {
            print("Failed to save tokens for \(accountId): \(error.localizedDescription)")
            return false
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
