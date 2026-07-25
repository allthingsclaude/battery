import Foundation

/// How the Lock Screen Live Activity behaves. User-chosen in Settings; read by
/// `LiveActivityController` on every sync. Stored in standard UserDefaults (the
/// controller runs in the app process, so no App Group is needed for this).
enum LiveActivityMode: String, CaseIterable, Identifiable {
    case off
    case smart
    case alwaysOn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:      return "Off"
        case .smart:    return "Smart"
        case .alwaysOn: return "Always On"
        }
    }

    var subtitle: String {
        switch self {
        case .off:      return "Never show a Live Activity"
        case .smart:    return "Only while a session is busy (default)"
        case .alwaysOn: return "Keep it on the Lock Screen all session"
        }
    }

    static let storageKey = "liveActivityMode"

    /// The current preference, defaulting to `.smart`.
    static var current: LiveActivityMode {
        LiveActivityMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .smart
    }
}
