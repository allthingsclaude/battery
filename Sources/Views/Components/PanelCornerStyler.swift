import SwiftUI
import AppKit

/// Restyles the hosting `MenuBarExtra(.window)` panel with a larger,
/// Tahoe-style continuous corner radius. The panel's chrome is system-drawn
/// and SwiftUI exposes no API for it, so this reaches into the window:
/// it clears the square window background, rounds the frame view's layer
/// (clipping all content), and re-masks the system material to match.
struct PanelCornerStyler: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> StylerView {
        let view = StylerView()
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: StylerView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.apply()
    }

    final class StylerView: NSView {
        var cornerRadius: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // The panel finishes configuring itself after attaching views,
            // so re-apply once it has settled.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let window, let frameView = window.contentView?.superview else { return }

            window.isOpaque = false
            window.backgroundColor = .clear

            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = cornerRadius
            frameView.layer?.cornerCurve = .continuous
            frameView.layer?.masksToBounds = true

            remaskVisualEffectViews(in: frameView)
            window.invalidateShadow()
        }

        /// The system material is an `NSVisualEffectView` whose `maskImage`
        /// defines the stock corner radius; layer masks alone don't clip its
        /// behind-window blur, so the mask itself must be replaced.
        private func remaskVisualEffectViews(in view: NSView) {
            if let effectView = view as? NSVisualEffectView {
                effectView.maskImage = .roundedCornerMask(radius: cornerRadius)
            }
            for subview in view.subviews where !String(describing: type(of: subview)).contains("HostingView") {
                remaskVisualEffectViews(in: subview)
            }
        }
    }
}

private extension NSImage {
    /// Stretchable rounded-rect mask, cap-inset so the corners keep their
    /// radius at any panel size.
    static func roundedCornerMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
