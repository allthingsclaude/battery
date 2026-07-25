import AppKit
import SwiftUI
import Combine

/// Borderless panel that can become key — so buttons and text fields inside
/// work — without activating the app. ESC closes it.
private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    var onCancel: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onCancel?()
            return
        }
        super.sendEvent(event)
    }
}

/// Owns the menu bar status item and the panel shown beneath it.
///
/// Replaces SwiftUI's `MenuBarExtra(.window)`: the panel here is a plain
/// transparent NSPanel whose chrome (glass, corners, shadow) is drawn
/// entirely by `PanelRootView`, and whose frame follows the content's ideal
/// size — so it grows and shrinks with the content, anchored under the icon.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let panel: StatusPanel
    private let viewModel: UsageViewModel
    private var hostingView: NSHostingView<PanelRootView>!
    private var clickMonitors: [Any] = []
    private var contentSize: CGSize = .zero
    private var labelCancellables = Set<AnyCancellable>()
    private let panelLayout = PanelLayout()

    init(viewModel: UsageViewModel, updaterService: UpdaterService) {
        self.viewModel = viewModel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.cardWidth, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init()

        panel.onCancel = { [weak self] in self?.closePanel() }

        hostingView = NSHostingView(rootView: PanelRootView(
            viewModel: viewModel,
            updaterService: updaterService,
            layout: panelLayout,
            onSizeChange: { [weak self] size in
                self?.contentSizeChanged(size)
            }
        ))
        panel.contentView = hostingView

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseDown])
        }
        updateLabel()

        // Refresh the label image on data changes (immediately) and once a
        // second so the countdown text ticks. variableLength re-measures the
        // new image, so no manual width management is needed.
        viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLabel() }
            .store(in: &labelCancellables)
        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updateLabel() }
            .store(in: &labelCancellables)

        // Content inside the panel can close the window directly (e.g. the
        // login flow calls NSApp.keyWindow?.close()) — clean up when it does.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.panelDidHide() }
        }
    }

    // MARK: - Label

    private func updateLabel() {
        statusItem.button?.image = MenuBarLabel.render(viewModel: viewModel)
    }

    // MARK: - Toggle

    @objc private func statusButtonClicked() {
        if panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        layoutPanel()
        statusItem.button?.highlight(true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        installClickMonitors()
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panelDidHide()
    }

    private func panelDidHide() {
        removeClickMonitors()
        statusItem.button?.highlight(false)
    }

    // MARK: - Sizing & Position

    private func contentSizeChanged(_ size: CGSize) {
        contentSize = size
        guard panel.isVisible else { return }
        guard abs(panel.frame.height - size.height) > 0.5
            || abs(panel.frame.width - size.width) > 0.5 else { return }
        layoutPanel()
    }

    /// Place the panel so the visible card is centered under the status item
    /// (clamped to the screen edge) with its top just below the menu bar.
    /// Called on every content size change — the top edge stays anchored, so
    /// the panel grows and shrinks downward.
    ///
    /// The frame is never animated here. SwiftUI already tweens the card's
    /// height and reports each intermediate size, so the window's job is to
    /// track it exactly; `setFrame(_:display:animate:)` would instead block
    /// the main thread in a nested run loop and ease its own way toward a
    /// target that has already moved on, which reads as jitter.
    private func layoutPanel() {
        updateMaxCardHeight()
        let frame = targetPanelFrame()
        guard frame != .zero else { return }
        panel.setFrame(frame, display: true)
    }

    /// Push the space between the menu bar and the bottom of the visible
    /// screen down to the SwiftUI layer, so the card caps its height and
    /// scrolls its body instead of extending past the screen edge.
    private func updateMaxCardHeight() {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen else { return }
        let available = buttonWindow.frame.minY - screen.visibleFrame.minY
            - PanelMetrics.topMargin - PanelMetrics.bottomMargin
        let clamped = max(240, available)
        if abs(panelLayout.maxCardHeight - clamped) > 0.5 {
            panelLayout.maxCardHeight = clamped
        }
    }

    private func targetPanelFrame() -> NSRect {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen else { return .zero }

        let size = contentSize.width > 1 ? contentSize : hostingView.fittingSize
        let buttonFrame = buttonWindow.frame

        var x = buttonFrame.midX - size.width / 2
        // Clamp using the visible card's edges, not the transparent margins.
        let minCardInset: CGFloat = 8
        let minX = screen.visibleFrame.minX + minCardInset - PanelMetrics.horizontalMargin
        let maxX = screen.visibleFrame.maxX - size.width + PanelMetrics.horizontalMargin - minCardInset
        x = min(max(x, minX), maxX)

        let top = buttonFrame.minY
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    // MARK: - Dismiss on outside click

    private func installClickMonitors() {
        removeClickMonitors()

        // Clicks in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }) {
            clickMonitors.append(global)
        }

        // Clicks in our own app outside the panel. Clicks on the status
        // button are left to its action, which toggles.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel, event.window !== self.statusItem.button?.window {
                self.closePanel()
            }
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func removeClickMonitors() {
        for monitor in clickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        clickMonitors.removeAll()
    }
}
