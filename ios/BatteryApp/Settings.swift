import Foundation
import SwiftUI
import UIKit

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

/// Which interface style the app runs in, independent of the system setting.
/// Applied once at the root of the scene in `BatteryApp`; every surface already
/// paints from `BatteryPalette`, which is appearance-adaptive.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// `nil` is how SwiftUI spells "inherit the system setting".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    static let storageKey = "appearance"

    /// The current preference, defaulting to `.system`.
    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }
}

/// Which artwork the Home Screen icon uses. Deliberately separate from
/// `AppearanceMode` — a dark icon on a light Home Screen (or the reverse) is a
/// legitimate taste, and iOS never tells an app which wallpaper it sits on.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark:  return "Dark"
        }
    }

    /// The bundled PNG behind the Settings thumbnail. Both artworks ship as
    /// loose files in `BatteryApp/AlternateIcons/`, so `UIImage(named:)` finds
    /// them by filename.
    var previewAssetName: String {
        switch self {
        case .light: return "AppIcon-Light"
        case .dark:  return "AppIcon-Dark"
        }
    }

    /// What `setAlternateIconName` needs. The light artwork *is* the target's
    /// primary icon, so choosing it means clearing the alternate rather than
    /// setting one — which also keeps anyone who never opens this setting from
    /// seeing the system's "You have changed the icon" alert.
    var alternateIconName: String? {
        switch self {
        case .light: return nil
        case .dark:  return "AppIcon-Dark"
        }
    }

    static let storageKey = "appIcon"

    /// The current preference, defaulting to `.light` (the primary icon).
    static var current: AppIconChoice {
        AppIconChoice(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .light
    }

    /// Put this icon on the Home Screen. No-op when it's already the one iOS is
    /// showing, so relaunches don't re-trigger the system alert.
    @MainActor
    func apply() {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.alternateIconName != alternateIconName else { return }
        app.setAlternateIconName(alternateIconName)
    }
}
