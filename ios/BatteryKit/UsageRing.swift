import SwiftUI

/// The one canonical utilization ring, shared by the app, widgets, and the Live
/// Activity so every surface renders identically. A faithful port of the macOS
/// `GaugeRingView`: `.quaternary` track, round-capped brand arc rotated to start
/// at 12 o'clock, `easeInOut(0.5)` fill, and an SF Rounded, monospaced center
/// numeral tinted by the usage level.
struct UsageRing: View {
    let utilization: Double            // 0–100
    var size: CGFloat = 60
    var lineWidth: CGFloat = 6
    var showsLabel: Bool = true
    /// Premium gradient stroke (hero surfaces). Falls back to a flat color.
    var gradientStroke: Bool = false
    /// Soft brand glow at High/Critical. Turn OFF in tight containers (the
    /// Dynamic Island clips anything drawn past the ring's bounds).
    var glow: Bool = true
    /// Lock Screen accessory rendering: monochrome, tint-driven.
    var tinted: Bool = false

    private var fraction: CGFloat { CGFloat(min(100, max(0, utilization)) / 100) }
    private var level: UsageLevel { .from(utilization: utilization) }
    private var strokeColor: Color { tinted ? .primary : level.color }

    var body: some View {
        ZStack {
            // Inset by half the line width so the stroke stays *inside* the frame —
            // otherwise it overflows and tight containers (Dynamic Island) clip it.
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(tinted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary),
                        lineWidth: lineWidth)

            arc
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: fraction)

            if showsLabel {
                Text("\(Int(utilization.rounded()))")
                    .font(BatteryFont.numeric(size * 0.28, weight: .strong))
                    .foregroundStyle(tinted ? AnyShapeStyle(.primary) : AnyShapeStyle(level.color))
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var arc: some View {
        if gradientStroke && !tinted {
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: fraction)
                .stroke(level.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // A soft brand glow that only shows up once usage is climbing.
                .shadow(color: level.color.opacity(glow && level.isAlarming ? 0.45 : 0.0),
                        radius: glow && level.isAlarming ? 5 : 0)
        } else {
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: fraction)
                .stroke(strokeColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }
}
