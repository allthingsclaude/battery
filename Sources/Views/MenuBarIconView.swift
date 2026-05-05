import AppKit
import SwiftUI

/// The label displayed in the macOS menu bar.
struct MenuBarIconView: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        HStack(spacing: 6) {
            if AppSettings.shared.showMenuBarIcon {
                Image(nsImage: makeProgressBarImage(
                    fraction: viewModel.isConnected
                        ? Double(AppSettings.shared.displayPercentage(for: viewModel.sessionUtilization)) / 100
                        : 0
                ))
            }

            if viewModel.isConnected {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let text = viewModel.menuBarText(at: context.date)
                    if !text.isEmpty {
                        Text(" \(text)")
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
            } else {
                Text("--")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Renders a tiny progress bar as an NSImage suitable for menu bar display.
private func makeProgressBarImage(fraction: Double) -> NSImage {
    let width: CGFloat = 24
    let height: CGFloat = 10
    let borderRadius: CGFloat = 4
    let lineWidth: CGFloat = 1.5
    let fillInset: CGFloat = 2
    let size = NSSize(width: width, height: height)

    let image = NSImage(size: size, flipped: false) { rect in
        let borderRect = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)

        // Border
        let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: borderRadius, yRadius: borderRadius)
        borderPath.lineWidth = lineWidth
        NSColor.black.setStroke()
        borderPath.stroke()

        // Fill (inset from border edge)
        let innerRect = borderRect.insetBy(dx: fillInset, dy: fillInset)
        let fillWidth = max(0, innerRect.width * min(1, CGFloat(fraction)))
        if fillWidth > 0 {
            let fillRadius = max(0, borderRadius - fillInset)
            let fillRect = NSRect(x: innerRect.origin.x, y: innerRect.origin.y, width: fillWidth, height: innerRect.height)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: fillRadius, yRadius: fillRadius)
            NSColor.black.setFill()
            fillPath.fill()
        }

        return true
    }

    image.isTemplate = true
    return image
}
