import SwiftUI

/// Maps a utilization percentage (0–100) to a color-coded severity level.
///
/// Thresholds match the macOS app exactly (50 / 75 / 90) and, like the desktop
/// default theme, the ramp stays **within the terracotta family** — escalating
/// by darkening (`brand` → `brandDark` → `brandDeep`) rather than turning red.
enum UsageLevel: String, CaseIterable, Codable {
    case low       // 0–50%
    case moderate  // 50–75%
    case high      // 75–90%
    case critical  // 90%+

    static func from(utilization: Double) -> UsageLevel {
        switch utilization {
        case ..<50:   return .low
        case 50..<75: return .moderate
        case 75..<90: return .high
        default:      return .critical
        }
    }

    /// Solid fill color for gauges, numerals, and bars.
    var color: Color {
        switch self {
        case .low:      return BatteryPalette.brand
        case .moderate: return BatteryPalette.brand
        case .high:     return BatteryPalette.brandDark
        case .critical: return BatteryPalette.brandDeep
        }
    }

    /// A two-stop gradient (color → one shade deeper) for premium ring strokes.
    var gradient: LinearGradient {
        let deep: Color
        switch self {
        case .low, .moderate: deep = BatteryPalette.brandDark
        case .high:           deep = BatteryPalette.brandDeep
        case .critical:       deep = BatteryPalette.brandDeep
        }
        return LinearGradient(colors: [color, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Accent used on the monochrome Lock Screen accessory slots.
    var accentColor: Color { color }

    /// SF Symbol used in compact surfaces (Dynamic Island, inline widgets).
    var sfSymbol: String {
        switch self {
        case .low:      return "battery.100percent"
        case .moderate: return "battery.75percent"
        case .high:     return "battery.25percent"
        case .critical: return "battery.0percent"
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

    /// True once usage warrants surfacing an alert / bringing the activity forward.
    var isAlarming: Bool { self == .high || self == .critical }
}
