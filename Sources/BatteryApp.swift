import SwiftUI
import AppKit

@main
struct BatteryApp: App {
    @StateObject private var viewModel = UsageViewModel()
    @StateObject private var updaterService = UpdaterService()

    // TODO: temporary — auto-opens the panel after launch for corner-radius
    // debugging; remove together with PanelCornerStyler.debugDump()
    init() {
        func findButton(in view: NSView?) -> NSStatusBarButton? {
            guard let view else { return nil }
            if let button = view as? NSStatusBarButton { return button }
            for subview in view.subviews {
                if let button = findButton(in: subview) { return button }
            }
            return nil
        }
        func logLine(_ text: String) {
            let line = text + "\n"
            if let handle = FileHandle(forWritingAtPath: "/tmp/battery-autoopen.log") {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
            } else {
                try? line.write(toFile: "/tmp/battery-autoopen.log", atomically: true, encoding: .utf8)
            }
        }
        func attempt(_ remaining: Int) {
            let statusWindows = NSApp.windows.filter { $0.className.contains("StatusBarWindow") }
            logLine("attempt remaining=\(remaining) statusWindows=\(statusWindows.count) allWindows=\(NSApp.windows.map { $0.className })")
            for window in statusWindows {
                if let button = findButton(in: window.contentView) {
                    logLine("clicking button in \(window.className)")
                    button.performClick(nil)
                    return
                }
            }
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { attempt(remaining - 1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { attempt(12) }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(viewModel: viewModel, updaterService: updaterService)
                .frame(width: 320)
                .background(PanelCornerStyler(cornerRadius: Constants.panelCornerRadius))
        } label: {
            MenuBarIconView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
