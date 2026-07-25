import SwiftUI

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Maps utilization percentages to color-coded severity levels.
enum UsageLevel: String, CaseIterable {
    case low       // 0-50%  green
    case moderate  // 50-75% yellow
    case high      // 75-90% orange
    case critical  // 90%+   red

    static func from(utilization: Double) -> UsageLevel {
        switch utilization {
        case ..<50:
            return .low
        case 50..<75:
            return .moderate
        case 75..<90:
            return .high
        default:
            return .critical
        }
    }

    var color: Color {
        color(for: AppSettings.shared.activeTheme)
    }

    func color(for theme: ColorTheme) -> Color {
        switch theme {
        case .default:
            switch self {
            case .low:      return ColorTheme.brand
            case .moderate: return ColorTheme.brand
            case .high:     return ColorTheme.brandDark
            case .critical: return ColorTheme.brandDark
            }
        case .classic:
            switch self {
            case .low:      return .green
            case .moderate: return .yellow
            case .high:     return .orange
            case .critical: return .red
            }
        }
    }

    var sfSymbol: String {
        switch self {
        case .low:      return "battery.75percent"
        case .moderate: return "battery.50percent"
        case .high:     return "battery.25percent"
        case .critical: return "battery.25percent"
        }
    }

    var label: String {
        switch self {
        case .low:      return "Good"
        case .moderate: return "Moderate"
        case .high:     return "High"
        case .critical: return "Critical"
        }
    }

    /// True once usage warrants surfacing an alert. Mirrors the same property on
    /// the iOS side so both platforms escalate at identical thresholds.
    var isAlarming: Bool { self == .high || self == .critical }
}
