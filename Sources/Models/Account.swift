import Foundation

/// A user account authenticated via OAuth PKCE.
struct Account: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var email: String?
    var planTier: PlanTier
    var isDefault: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String = "Account",
        email: String? = nil,
        planTier: PlanTier = .unknown,
        isDefault: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.planTier = planTier
        self.isDefault = isDefault
        self.createdAt = createdAt
    }
}

/// OAuth tokens stored on disk per account.
struct StoredTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Int64  // milliseconds since epoch

    /// True when read live from Claude Code's own credential (see
    /// LiveCredentials). Live tokens are never refreshed or persisted by
    /// Battery; external tooling keeps them fresh. Not encoded to disk.
    var isLive: Bool = false

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, expiresAt
    }

    var expiryDate: Date {
        Date(timeIntervalSince1970: Double(expiresAt) / 1000.0)
    }

    var isExpiringSoon: Bool {
        expiryDate.timeIntervalSinceNow < 300
    }

    init(accessToken: String, refreshToken: String?, expiresIn: Int) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = Int64((Date().timeIntervalSince1970 + Double(expiresIn)) * 1000.0)
    }

    init(accessToken: String, refreshToken: String?, expiresAt: Int64) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}
