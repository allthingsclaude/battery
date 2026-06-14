import AppKit

/// Renders the menu bar label (progress bar + usage text) as a single
/// template `NSImage` to set as the status item button's image.
///
/// Drawing a template image — rather than embedding a live SwiftUI view in
/// the button — is what makes the status item behave natively: the system
/// sizes the variable-length item to the image, draws the standard
/// rounded-rect selection highlight, and tints the monochrome label to match
/// the menu bar (light/dark, reduced transparency, etc.). The text uses the
/// system menu bar font so it matches every other item.
enum MenuBarLabel {
    private static let barWidth: CGFloat = 24
    private static let barHeight: CGFloat = 10
    private static let gap: CGFloat = 5

    @MainActor
    static func render(viewModel: UsageViewModel, at now: Date = Date()) -> NSImage {
        let settings = AppSettings.shared
        let showIcon = settings.showMenuBarIcon
        let text = viewModel.isConnected ? viewModel.menuBarText(at: now) : "--"
        let hasText = !text.isEmpty

        let font = NSFont.menuBarFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = hasText ? attributed.size() : .zero

        // Always keep something clickable: if both icon and text are off,
        // fall back to drawing the icon.
        let drawIcon = showIcon || !hasText
        let iconWidth = drawIcon ? barWidth : 0
        let spacing = (drawIcon && hasText) ? gap : 0

        let fraction = viewModel.isConnected
            ? Double(settings.displayPercentage(for: viewModel.sessionUtilization)) / 100
            : 0

        let width = ceil(iconWidth + spacing + textSize.width)
        let height = ceil(max(barHeight, textSize.height))

        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: false) { _ in
            if drawIcon {
                let barRect = NSRect(
                    x: 0,
                    y: (height - barHeight) / 2,
                    width: barWidth,
                    height: barHeight
                )
                drawProgressBar(in: barRect, fraction: fraction)
            }
            if hasText {
                let textOrigin = NSPoint(
                    x: iconWidth + spacing,
                    y: (height - textSize.height) / 2
                )
                attributed.draw(at: textOrigin)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Draws the rounded progress bar (border + fill) in black for use in a
    /// template image. Mirrors the previous standalone menu bar icon.
    private static func drawProgressBar(in rect: NSRect, fraction: Double) {
        let borderRadius: CGFloat = 4
        let lineWidth: CGFloat = 1.5
        let fillInset: CGFloat = 2

        let borderRect = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: borderRadius, yRadius: borderRadius)
        borderPath.lineWidth = lineWidth
        NSColor.black.setStroke()
        borderPath.stroke()

        let innerRect = borderRect.insetBy(dx: fillInset, dy: fillInset)
        let fillWidth = max(0, innerRect.width * min(1, CGFloat(fraction)))
        if fillWidth > 0 {
            let fillRadius = max(0, borderRadius - fillInset)
            let fillRect = NSRect(x: innerRect.origin.x, y: innerRect.origin.y, width: fillWidth, height: innerRect.height)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: fillRadius, yRadius: fillRadius)
            NSColor.black.setFill()
            fillPath.fill()
        }
    }
}
