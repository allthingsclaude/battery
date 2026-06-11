import SwiftUI
import AppKit

/// Restyles the hosting `MenuBarExtra(.window)` panel with a larger,
/// Tahoe-style continuous corner radius. The panel's chrome is system-drawn
/// and SwiftUI exposes no API for it, so this reaches into the window:
/// it clears the square window background, rounds the frame view's layer
/// (clipping all content), re-masks the system material, replaces the
/// private corner mask the window server uses for the outer shape and
/// shadow, and keeps the panel's height in sync with its content.
struct PanelCornerStyler: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> StylerView {
        GlassRadiusOverride.radius = cornerRadius
        _ = GlassRadiusOverride.install
        let view = StylerView()
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: StylerView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.apply()
    }

    private static var cornerMaskOverridden = Set<ObjectIdentifier>()

    /// The window server cuts the panel's outer shape and shadow from the
    /// private `_cornerMask` image, which the MenuBarExtra panel class
    /// overrides with the stock radius — replace it with ours. Done
    /// per-class, so it only affects that panel class, not NSWindow
    /// generally.
    fileprivate static func overrideCornerMask(on window: NSWindow, radius: CGFloat) {
        guard let cls = object_getClass(window) else { return }
        let key = ObjectIdentifier(cls)
        guard !cornerMaskOverridden.contains(key) else { return }
        let selector = NSSelectorFromString("_cornerMask")
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        let block: @convention(block) (AnyObject) -> NSImage? = { _ in
            .roundedCornerMask(radius: radius)
        }
        class_replaceMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        cornerMaskOverridden.insert(key)
    }

    final class StylerView: NSView {
        var cornerRadius: CGFloat = 0
        private var frameObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // The panel finishes configuring itself after attaching views,
            // so re-apply once it has settled. The height sync runs only
            // here — once per opening, after layout, never from within a
            // setFrame cascade (it would recurse) — to correct the stale
            // height the panel caches between openings.
            DispatchQueue.main.async { [weak self] in
                self?.apply()
                self?.syncWindowHeight()
            }

            // The panel resizes as content loads, which can rebuild the
            // glass backdrop layers with the stock radius — re-apply.
            if let observer = frameObserver { NotificationCenter.default.removeObserver(observer) }
            frameObserver = nil
            if let frameView = window?.contentView?.superview {
                frameView.postsFrameChangedNotifications = true
                frameObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: frameView,
                    queue: .main
                ) { [weak self] _ in
                    self?.apply()
                    DispatchQueue.main.async { self?.apply() }
                }
            }
        }

        deinit {
            if let observer = frameObserver { NotificationCenter.default.removeObserver(observer) }
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

            // AppKit also keeps a corner radius of its own for the panel's
            // server-side shape — override it where the accessor exists.
            for target in [window, frameView] as [NSObject] {
                if target.responds(to: NSSelectorFromString("setCornerRadius:")) {
                    target.setValue(cornerRadius, forKey: "cornerRadius")
                }
            }

            // Tahoe's Liquid Glass defines its shape via SDF element layers.
            // New values are clamped by GlassRadiusOverride; this walk
            // retags layers created before the override was installed.
            if let rootLayer = frameView.layer {
                retagGlassLayers(in: rootLayer)
            }

            PanelCornerStyler.overrideCornerMask(on: window, radius: cornerRadius)

            window.invalidateShadow()
        }

        /// The panel window caches its frame between openings, so when the
        /// content gets shorter (e.g. the error state) the window keeps its
        /// old height and floats the content in the middle. This view is the
        /// content's background, so its own height is the content's ideal
        /// height — resize the window to match, keeping the top edge
        /// anchored under the menu bar. Must never be called from apply():
        /// apply() runs from the frame-change notification that setFrame
        /// posts synchronously, and the content view hasn't resized at that
        /// point, so the mismatch re-triggers and recurses to stack
        /// overflow.
        private func syncWindowHeight() {
            guard let window, let contentView = window.contentView else { return }
            let target = frame.height
            let current = contentView.frame.height
            guard target > 1, abs(current - target) > 0.5 else { return }
            var windowFrame = window.frame
            let delta = current - target
            windowFrame.size.height -= delta
            windowFrame.origin.y += delta
            window.setFrame(windowFrame, display: true)
        }

        private func retagGlassLayers(in layer: CALayer) {
            if String(describing: type(of: layer)).contains("SDFElement") {
                layer.cornerRadius = cornerRadius
                layer.cornerCurve = .continuous
            }
            (layer.sublayers ?? []).forEach { retagGlassLayers(in: $0) }
        }

        /// On pre-Tahoe systems the material is an `NSVisualEffectView`
        /// whose `maskImage` defines the stock corner radius; layer masks
        /// alone don't clip its behind-window blur, so replace the mask.
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

/// Tahoe's Liquid Glass regenerates its SDF element layers (private
/// `CASDFElementLayer`) with the stock corner radius on every render pass,
/// so one-time overrides always lose the race. This installs a
/// `setCornerRadius:` override on that one subclass that clamps every write
/// to our radius — the native glass pipeline (blur, rim, content portals,
/// shadow) stays fully intact, just rounder. No-ops on systems where the
/// class doesn't exist.
private enum GlassRadiusOverride {
    static var radius: CGFloat?

    static let install: Void = {
        guard let cls = NSClassFromString("CASDFElementLayer"),
              let method = class_getInstanceMethod(cls, #selector(setter: CALayer.cornerRadius)) else { return }
        let selector = #selector(setter: CALayer.cornerRadius)
        let original = method_getImplementation(method)
        typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        let block: @convention(block) (AnyObject, CGFloat) -> Void = { target, value in
            unsafeBitCast(original, to: Setter.self)(target, selector, radius ?? value)
        }
        // The setter is inherited where not overridden, so this lands on
        // CASDFElementLayer only — CALayer itself is untouched.
        class_replaceMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }()
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
