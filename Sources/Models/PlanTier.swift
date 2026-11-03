import Foundation

/// Claude subscription plan tiers detected from Keychain credentials.
///
/// Anthropic renamed the plans on 2026-10-30: Max 20x became **Ultra** and
/// Max 5x became plain **Max**. Raw values are persisted (accounts, snapshot
/// rows), so `max5x` keeps its old raw value and only its label changes.
///
/// Don't infer limits from the tier. Verified Ultra accounts have no five-hour
/// window but unverified ones still do, so whether a session limit applies is
/// read from each usage response (`UsageResponse.hasSessionLimit`) instead.
enum PlanTier: String, Codable, CaseIterable {
    case pro = "pro"
    case max = "max"
    case max5x = "max_5x"
    case ultra = "ultra"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .pro: return "Pro"
        case .max, .max5x: return "Max"
        case .ultra: return "Ultra"
        case .unknown: return "Unknown"
        }
    }

    var hasOpusAccess: Bool {
        switch self {
        case .max, .max5x, .ultra: return true
        case .pro, .unknown: return false
        }
    }

    var hasSonnetTracking: Bool {
        return true // All plans have Sonnet tracking
    }

    /// Map the rateLimitTier string from Keychain to a PlanTier.
    ///
    /// Ultra accounts still report `default_claude_max_20x`, which contains
    /// "max" — so the 20x check has to come before the plain-Max one or Ultra
    /// is labelled as Max.
    static func from(rateLimitTier: String) -> PlanTier {
        switch rateLimitTier.lowercased() {
        case let t where t.contains("ultra") || t.contains("max_20x") || t.contains("max20x"):
            return .ultra
        case let t where t.contains("max_5x") || t.contains("max5x"):
            return .max5x
        case let t where t.contains("max"):
            return .max
        case let t where t.contains("pro"):
            return .pro
        default:
            return .unknown
        }
    }
}
