import CoreText
import SwiftUI

/// The brand typeface set, matching allthingsclaude.cc.
///
///   Space Grotesk  headings and section labels
///   Inter          body and secondary text
///   JetBrains Mono anything numeric or technical
///
/// The app previously used SF Rounded throughout, which reads friendly but is
/// nothing like the brand. Everything routes through the semantic roles below
/// rather than naming families at call sites, so a future change lands in one
/// file — and so the numeric rule can't be forgotten.
///
/// **Numbers always use JetBrains Mono.** Figures that tick (a percentage
/// climbing, a countdown) jitter horribly in a proportional face because each
/// digit is a different width. SwiftUI's `monospacedDigit()` fixes that for
/// *system* fonts only and silently does nothing to a custom one, so the fix
/// here is a genuinely monospaced family — which is also what the brand uses
/// for technical text.
enum BatteryFont {

    private enum Family {
        static let heading = "SpaceGrotesk-Bold"
        static let body = "Inter-Regular"
        static let bodyStrong = "Inter-SemiBold"
        static let numeric = "JetBrainsMono-Regular"
        static let numericStrong = "JetBrainsMono-SemiBold"
    }

    // MARK: - Roles

    /// Section labels — "SESSION", "WEEKLY". Small, tracked, uppercase.
    static func label(_ size: CGFloat) -> Font {
        .custom(Family.heading, size: size)
    }

    /// A heading or emphasised title.
    static func heading(_ size: CGFloat, relativeTo style: Font.TextStyle = .headline) -> Font {
        .custom(Family.heading, size: size, relativeTo: style)
    }

    /// Ordinary and secondary prose.
    static func body(_ size: CGFloat, weight: Weight = .regular,
                     relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(weight == .regular ? Family.body : Family.bodyStrong,
                size: size, relativeTo: style)
    }

    /// Any figure that can change: percentages, countdowns, rates, timestamps.
    static func numeric(_ size: CGFloat, weight: Weight = .regular,
                        relativeTo style: Font.TextStyle? = nil) -> Font {
        let name = weight == .regular ? Family.numeric : Family.numericStrong
        if let style { return .custom(name, size: size, relativeTo: style) }
        // Fixed size — the hero numerals size themselves off their container.
        return .custom(name, size: size)
    }

    enum Weight { case regular, strong }

    // MARK: - Registration
    //
    // The app target registers via UIAppFonts in its Info.plist, but a widget
    // extension is a separate bundle: its Info.plist entry only covers fonts in
    // *its* bundle, and a Live Activity rendered by the system is another
    // process again. Registering programmatically from the bundle that actually
    // contains the file works in every case, and is a no-op when the plist
    // already did the job.

    /// `CTFontManagerRegisterFontsForURL` is itself safe to call twice — it just
    /// returns a "already registered" error — so this only avoids repeat file
    /// I/O. A lock keeps it correct under strict concurrency without forcing
    /// callers onto the main actor, since the widget extension registers from
    /// its `WidgetBundle` initialiser.
    private static let registrationLock = NSLock()
    nonisolated(unsafe) private static var didRegister = false

    /// Idempotent; safe to call from any entry point.
    static func registerIfNeeded() {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard !didRegister else { return }
        didRegister = true

        let names = [
            "Inter-Regular", "Inter-SemiBold",
            "SpaceGrotesk-Bold",
            "JetBrainsMono-Regular", "JetBrainsMono-SemiBold",
        ]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            var error: Unmanaged<CFError>?
            // Already-registered fonts return false with a "duplicate" error,
            // which is the expected path for the app target.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            error?.release()
        }
    }

    /// True when the brand fonts actually resolved. Used by previews and the
    /// render harness to catch a missing resource, rather than silently falling
    /// back to Helvetica on device.
    static var isAvailable: Bool {
        #if canImport(UIKit)
        return UIFont(name: Family.heading, size: 12) != nil
        #else
        return true
        #endif
    }
}
