import SwiftUI
import AppKit

/// Layout constants shared between the panel chrome and the controller that
/// positions the panel. The margins are transparent window area reserved for
/// the card's shadow.
enum PanelMetrics {
    static let cardWidth: CGFloat = 320
    static let topMargin: CGFloat = 4
    static let horizontalMargin: CGFloat = 28
    static let bottomMargin: CGFloat = 36
}

/// Screen-dependent layout limits pushed down from the controller, so the
/// card can cap its own height and scroll instead of running off-screen.
final class PanelLayout: ObservableObject {
    @Published var maxCardHeight: CGFloat = 800
}

/// Root view of the status item panel: the popover content wrapped in
/// self-drawn chrome — glass background, continuous rounded corners, and
/// shadows. The window is fully transparent; everything visible is drawn
/// here, so the corner radius and shadow can never disagree.
struct PanelRootView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var updaterService: UpdaterService
    @ObservedObject var layout: PanelLayout
    var onSizeChange: (CGSize) -> Void = { _ in }

    var body: some View {
        PopoverView(viewModel: viewModel, updaterService: updaterService, layout: layout)
            .frame(width: PanelMetrics.cardWidth)
            .background {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(
                        .regular,
                        in: RoundedRectangle(cornerRadius: Constants.panelCornerRadius, style: .continuous)
                    )
                } else {
                    VibrancyBackground(cornerRadius: Constants.panelCornerRadius)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Constants.panelCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            .padding(.top, PanelMetrics.topMargin)
            .padding(.horizontal, PanelMetrics.horizontalMargin)
            .padding(.bottom, PanelMetrics.bottomMargin)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: PanelSizeKey.self, value: geo.size)
                }
            )
            .onPreferenceChange(PanelSizeKey.self) { size in
                if size.width > 1, size.height > 1 { onSizeChange(size) }
            }
    }
}

struct PanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// Frosted glass for pre-Tahoe systems, clipped to the card's corner shape.
private struct VibrancyBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
