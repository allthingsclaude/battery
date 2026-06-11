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

    /// Replaces the panel class's private `_cornerMask` override (stock
    /// radius) with one returning our rounded mask. Done per-class, so it
    /// only affects the MenuBarExtra panel class — not NSWindow generally.
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
            // so re-apply once it has settled.
            DispatchQueue.main.async { [weak self] in self?.apply() }

            // TODO: temporary diagnostics — remove with debugDump()
            for delay in [1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.debugSettledDump(after: delay)
                }
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

            // The panel's outer shape (shadow + glass backdrop) is cut
            // server-side from a corner radius AppKit sets to the stock
            // value; layer masks can't reach it, so override it where the
            // accessor exists.
            for target in [window, frameView] as [NSObject] {
                if target.responds(to: NSSelectorFromString("setCornerRadius:")) {
                    target.setValue(cornerRadius, forKey: "cornerRadius")
                }
            }

            // Tahoe's Liquid Glass defines the panel's shape (and shadow)
            // via SDF element layers. New radius values are clamped by
            // GlassRadiusOverride; this walk retags layers created before
            // the override was installed.
            if let rootLayer = frameView.layer {
                retagGlassLayers(in: rootLayer)
            }

            // The window server cuts the panel's outer shape and shadow from
            // the private `_cornerMask` image, which MenuBarExtraWindow
            // overrides with the stock radius — replace it with ours.
            PanelCornerStyler.overrideCornerMask(on: window, radius: cornerRadius)

            window.invalidateShadow()
            debugDump()
        }

        // TODO: temporary diagnostics — remove after corner artifact is fixed
        private func debugSettledDump(after delay: Double) {
            var lines: [String] = ["=== settled +\(delay)s ==="]
            var dumpedClasses = Set<String>()
            func dumpClassInfo(_ layer: CALayer) {
                let name = String(describing: type(of: layer))
                guard name.contains("SDF") || name.contains("Backdrop"), !dumpedClasses.contains(name) else { return }
                dumpedClasses.insert(name)
                lines.append("--- introspect \(name) ---")
                var cls: AnyClass? = type(of: layer)
                while let current = cls, String(describing: current) != "CALayer" {
                    var methodCount: UInt32 = 0
                    if let methods = class_copyMethodList(current, &methodCount) {
                        let names = (0..<Int(methodCount))
                            .map { String(cString: sel_getName(method_getName(methods[$0]))) }
                            .sorted()
                        lines.append("  methods(\(String(describing: current))): \(names.joined(separator: " "))")
                        free(methods)
                    }
                    cls = class_getSuperclass(current)
                }
            }
            func walkLayer(_ layer: CALayer, _ depth: Int) {
                var info = String(repeating: "  ", count: depth)
                    + "LAYER \(type(of: layer)) frame=\(layer.frame) r=\(layer.cornerRadius) masks=\(layer.masksToBounds)"
                if layer.isHidden { info += " HIDDEN" }
                if layer.shadowOpacity > 0 {
                    info += " shadowOp=\(layer.shadowOpacity) shadowR=\(layer.shadowRadius) shadowOff=\(layer.shadowOffset)"
                }
                lines.append(info)
                dumpClassInfo(layer)
                (layer.sublayers ?? []).forEach { walkLayer($0, depth + 1) }
            }
            func dumpMatchingMethods(of object: AnyObject, label: String) {
                var collected: [String] = []
                var cls: AnyClass? = object_getClass(object)
                while let current = cls {
                    let clsName = String(describing: current)
                    if clsName == "NSResponder" || clsName == "NSObject" { break }
                    var count: UInt32 = 0
                    if let methods = class_copyMethodList(current, &count) {
                        for index in 0..<Int(count) {
                            let name = String(cString: sel_getName(method_getName(methods[index])))
                            let lower = name.lowercased()
                            if ["corner", "radius", "shadow", "shape", "glass", "mask"].contains(where: { lower.contains($0) }) {
                                collected.append("\(clsName).\(name)")
                            }
                        }
                        free(methods)
                    }
                    cls = class_getSuperclass(current)
                }
                lines.append("--- \(label) matching methods ---")
                collected.sorted().forEach { lines.append("  \($0)") }
            }
            if let panel = self.window {
                dumpMatchingMethods(of: panel, label: "panel \(type(of: panel))")
                var root: NSView? = panel.contentView
                while let parent = root?.superview { root = parent }
                if let root { dumpMatchingMethods(of: root, label: "frame \(type(of: root))") }
            }
            for w in NSApp.windows {
                lines.append("WINDOW \(type(of: w)) visible=\(w.isVisible) frame=\(w.frame) level=\(w.level.rawValue) hasShadow=\(w.hasShadow)")
                for child in w.childWindows ?? [] {
                    lines.append("  CHILD \(type(of: child)) visible=\(child.isVisible) frame=\(child.frame)")
                }
                var root: NSView? = w.contentView
                while let parent = root?.superview { root = parent }
                if let rootLayer = root?.layer { walkLayer(rootLayer, 1) }
            }
            let text = lines.joined(separator: "\n") + "\n\n"
            if let handle = FileHandle(forWritingAtPath: "/tmp/battery-panel-settled.txt") {
                handle.seekToEndOfFile()
                handle.write(text.data(using: .utf8)!)
            } else {
                try? text.write(toFile: "/tmp/battery-panel-settled.txt", atomically: true, encoding: .utf8)
            }
        }

        // TODO: temporary diagnostics — remove after corner artifact is fixed
        private func debugDump() {
            guard let window else { return }
            var lines: [String] = []
            lines.append("WINDOW: \(type(of: window)) frame=\(window.frame) opaque=\(window.isOpaque) hasShadow=\(window.hasShadow) bgClear=\(window.backgroundColor == .clear)")
            for child in window.childWindows ?? [] {
                lines.append("CHILD WINDOW: \(type(of: child)) frame=\(child.frame) level=\(child.level.rawValue)")
            }
            if let parent = window.parent {
                lines.append("PARENT WINDOW: \(type(of: parent)) frame=\(parent.frame)")
            }
            for w in NSApp.windows where w.isVisible {
                lines.append("APP WINDOW: \(type(of: w)) frame=\(w.frame) level=\(w.level.rawValue)")
            }
            func walk(_ view: NSView, _ depth: Int) {
                var info = String(repeating: "  ", count: depth) + "\(type(of: view)) frame=\(view.frame)"
                if let layer = view.layer {
                    info += " r=\(layer.cornerRadius) masks=\(layer.masksToBounds)"
                }
                if let ev = view as? NSVisualEffectView {
                    info += " maskImage=\(ev.maskImage != nil)"
                }
                lines.append(info)
                view.subviews.forEach { walk($0, depth + 1) }
            }
            var root: NSView? = window.contentView
            while let parent = root?.superview { root = parent }
            if let root { walk(root, 0) }
            for key in ["cornerRadius", "_cornerRadius", "maskCornerRadius", "_maskCornerRadius"] {
                for (label, target) in [("window", window as NSObject), ("frameView", root as NSObject? ?? window)] {
                    if target.responds(to: NSSelectorFromString(key)) {
                        lines.append("\(label).\(key) = \(target.value(forKey: key) ?? "nil")")
                    }
                }
            }
            func walkLayer(_ layer: CALayer, _ depth: Int) {
                lines.append(String(repeating: "  ", count: depth)
                    + "LAYER \(type(of: layer)) frame=\(layer.frame) r=\(layer.cornerRadius) masks=\(layer.masksToBounds)")
                (layer.sublayers ?? []).forEach { walkLayer($0, depth + 1) }
            }
            if let rootLayer = root?.layer { walkLayer(rootLayer, 0) }
            try? lines.joined(separator: "\n")
                .write(toFile: "/tmp/battery-panel-hierarchy.txt", atomically: true, encoding: .utf8)
        }

        private func retagGlassLayers(in layer: CALayer) {
            if String(describing: type(of: layer)).contains("SDFElement") {
                layer.cornerRadius = cornerRadius
                layer.cornerCurve = .continuous
            }
            (layer.sublayers ?? []).forEach { retagGlassLayers(in: $0) }
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
        // The setter is inherited from CALayer, so class_replaceMethod adds
        // an override on CASDFElementLayer only — CALayer itself untouched.
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
