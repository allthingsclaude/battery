import Foundation

/// A signed-in account. Tokens live in the Keychain (`TokenStore`) keyed by `id`;
/// this metadata is persisted separately (`AccountStore`).
struct Account: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// Persists the account list + which one is selected (metadata only — no secrets).
enum AccountStore {
    private static let accountsKey = "accounts_v1"
    private static let selectedKey = "selectedAccountID"
    private static var defaults: UserDefaults { .standard }

    static func loadAccounts() -> [Account] {
        guard let data = defaults.data(forKey: accountsKey),
              let list = try? JSONDecoder().decode([Account].self, from: data)
        else { return [] }
        return list
    }

    static func saveAccounts(_ accounts: [Account]) {
        // Never overwrite a good list with empty data on an encode failure —
        // that would orphan every account's Keychain item.
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: accountsKey)
    }

    static var selectedID: UUID? {
        get { defaults.string(forKey: selectedKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: selectedKey) }
    }
}
