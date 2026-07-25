import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Cross-platform color helpers shared by the iOS app, its widgets, and the
// Live Activity. Kept independent of the macOS app's `ColorThresholds.swift`
// (which depends on NSColor / AppSettings) so it compiles on iOS — but the
// palette values are copied verbatim so the two apps are visually identical.

extension Color {
    /// Initialize from a 24-bit hex value, e.g. `Color(hex: 0xD97757)`.
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Battery's terracotta brand palette. The usage ramp is deliberately
/// **monochrome terracotta** — matching the macOS default theme, which escalates
/// by *darkening* rather than shifting hue. (A multi-color scheme is the opt-in
/// "classic" theme on desktop; we keep the branded default here.)
enum BatteryPalette {
    /// Primary brand color — terracotta orange (#D97757)
    static let brand = Color(hex: 0xD97757)
    /// Darker brand variant (#B85A3A) — "high" usage
    static let brandDark = Color(hex: 0xB85A3A)
    /// Deepest brand variant (#9A4A2C) — "critical" usage, urgency without leaving the family
    static let brandDeep = Color(hex: 0x9A4A2C)
    /// Lighter brand variant (#F0C4AE)
    static let brandLight = Color(hex: 0xF0C4AE)
    /// Very light brand variant (#F5D9CB)
    static let brandLighter = Color(hex: 0xF5D9CB)
    /// Warning tone for genuine error states (matches desktop's `.orange`).
    static let warn = Color(hex: 0xE8833A)

    /// A soft brand gradient used on hero rings and buttons for depth.
    static let brandGradient = LinearGradient(
        colors: [Color(hex: 0xE08A6A), brand, brandDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Adaptive surfaces (light / dark), mirroring the desktop background

    #if canImport(UIKit)
    /// App background — light #FAF8F4, dark #191814 (same as macOS `ColorTheme.background`).
    static let surface = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x19/255, green: 0x18/255, blue: 0x14/255, alpha: 1)
        : UIColor(red: 0xFA/255, green: 0xF8/255, blue: 0xF4/255, alpha: 1) })

    /// Elevated card surface — a hair lighter/darker than the background.
    static let elevated = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x24/255, green: 0x22/255, blue: 0x1D/255, alpha: 1)
        : UIColor.white })

    /// Hairline stroke used on cards for a crisp edge in both appearances.
    static let hairline = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.08)
        : UIColor(red: 0x2C/255, green: 0x2C/255, blue: 0x2C/255, alpha: 0.06) })
    #else
    static let surface = Color(hex: 0xFAF8F4)
    static let elevated = Color.white
    static let hairline = Color.black.opacity(0.06)
    #endif
}
