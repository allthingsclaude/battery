import SwiftUI

/// Color theme for the app UI.
enum ColorTheme: String, CaseIterable {
    case `default`  // Warm terracotta monochrome palette
    case classic    // Multi-color green/yellow/orange/red

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .classic: return "Classic"
        }
    }

    // MARK: - Default Theme Colors

    /// Primary brand color — terracotta orange (#D97757)
    static let brand = Color(hex: 0xD97757)
    /// Darker brand variant (#B85A3A)
    static let brandDark = Color(hex: 0xB85A3A)
    /// Lighter brand variant (#F0C4AE)
    static let brandLight = Color(hex: 0xF0C4AE)
    /// Very light brand variant (#F5D9CB)
    static let brandLighter = Color(hex: 0xF5D9CB)
    /// Track/background color (#E6E0D8)
    static let trackBG = Color(hex: 0xE6E0D8)
    /// Classic theme background — light: white 50%, dark: black 30%
    static let classicBackground = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0, alpha: 0.3)
                : NSColor(white: 1, alpha: 0.5)
        }
    ))
    /// Returns a color for a 4-tier intensity value (0-100).
    func intensityColor(for value: Double) -> Color {
        switch self {
        case .default:
            if value >= 75 { return Self.brandDark }
            if value >= 50 { return Self.brand }
            if value >= 25 { return Self.brandLight }
            return Self.brandLighter
        case .classic:
            if value >= 75 { return .red }
            if value >= 50 { return .orange }
            if value >= 25 { return .yellow }
            return .green
        }
    }

    /// The appropriate popover background for this theme.
    var popoverBackground: Color {
        self == .default ? Self.background : Self.classicBackground
    }

    /// Screen background — light: #FAF8F4, dark: #191814 (slightly transparent)
    static let background = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0x19/255.0, green: 0x18/255.0, blue: 0x14/255.0, alpha: 0.3)
                : NSColor(red: 0xFA/255.0, green: 0xF8/255.0, blue: 0xF4/255.0, alpha: 0.5)
        }
    ))
}

/// Display modes for menu bar text.
enum MenuBarDisplayMode: String, CaseIterable {
    case percentageAndTime = "percentageAndTime"
    case percentageOnly = "percentageOnly"
    case timeOnly = "timeOnly"
    case iconOnly = "iconOnly"

    var displayName: String {
        switch self {
        case .percentageAndTime: return "49% · 1h 23m"
        case .percentageOnly: return "49%"
        case .timeOnly: return "1h 23m"
        case .iconOnly: return "Icon only"
        }
    }
}

/// App settings backed by UserDefaults via @AppStorage.
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // Notifications
    @AppStorage("notifyAt80") var notifyAt80: Bool = true
    @AppStorage("notifyAt90") var notifyAt90: Bool = true
    @AppStorage("notifyAt95") var notifyAt95: Bool = true

    // Display
    @AppStorage("colorTheme") var colorTheme: String = ColorTheme.default.rawValue
    @AppStorage("showMenuBarIcon") var showMenuBarIcon: Bool = true
    @AppStorage("showMenuBarText") var showMenuBarText: Bool = true
    @AppStorage("menuBarDisplayMode") var menuBarDisplayMode: String = MenuBarDisplayMode.percentageAndTime.rawValue
    @AppStorage("showPercentageRemaining") var showPercentageRemaining: Bool = false
    @AppStorage("showTimeSinceReset") var showTimeSinceReset: Bool = false
    @AppStorage("showWeeklyAsDays") var showWeeklyAsDays: Bool = false

    // Polling
    @AppStorage("pollIntervalActive") var pollIntervalActive: Double = 60
    @AppStorage("pollIntervalIdle") var pollIntervalIdle: Double = 300

    // General
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false

    // Data
    @AppStorage("dataRetentionDays") var dataRetentionDays: Int = 90

    var displayMode: MenuBarDisplayMode {
        get { MenuBarDisplayMode(rawValue: menuBarDisplayMode) ?? .percentageAndTime }
        set { menuBarDisplayMode = newValue.rawValue }
    }

    var activeTheme: ColorTheme {
        get { ColorTheme(rawValue: colorTheme) ?? .default }
        set { colorTheme = newValue.rawValue }
    }

    /// Display percentage accounting for the "remaining" preference.
    func displayPercentage(for utilization: Double) -> Int {
        showPercentageRemaining
            ? Int(max(0, (100 - utilization)).rounded())
            : Int(utilization.rounded())
    }

    /// "left" or "used" suffix matching the percentage display preference.
    var percentageSuffix: String {
        showPercentageRemaining ? "left" : "used"
    }

    // MARK: Weekly usage in days

    static let daysPerWeek = 7

    /// A 7-day window's usage as days of the week, honouring the "remaining"
    /// preference: 25% used is 1.75 days used, or 5.25 days left.
    static func weekDays(forUtilization utilization: Double, remaining: Bool) -> Double {
        let percent = remaining ? max(0, 100 - utilization) : utilization
        return percent / 100 * Double(daysPerWeek)
    }

    /// One decimal in the user's locale, so it reads "2,5" where commas are decimal marks.
    static func formatWeekDays(_ days: Double, locale: Locale = .current) -> String {
        days.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// The headline figure for a 7-day window: "36" as a percentage, or "2.5" as days.
    func weeklyDisplayValue(for utilization: Double) -> String {
        guard showWeeklyAsDays else { return "\(displayPercentage(for: utilization))%" }
        return Self.formatWeekDays(Self.weekDays(forUtilization: utilization, remaining: showPercentageRemaining))
    }

    /// The words after the headline figure: "used", or "of 7 days used".
    var weeklySuffix: String {
        showWeeklyAsDays ? "of \(Self.daysPerWeek) days \(percentageSuffix)" : percentageSuffix
    }
}
