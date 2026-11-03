import SwiftUI

/// A circular arc gauge that fills based on a 0-1 value.
struct GaugeRingView: View {
    let value: Double  // 0.0 to 1.0
    let color: Color
    let size: CGFloat
    let lineWidth: CGFloat
    /// Splits the ring into this many equal parts, e.g. 7 for the days of a
    /// weekly window. 1 draws a plain ring.
    let segments: Int
    /// Replaces the percentage in the middle, e.g. with a count of days.
    let label: String?

    init(
        value: Double,
        color: Color,
        size: CGFloat = 60,
        lineWidth: CGFloat = 6,
        segments: Int = 1,
        label: String? = nil
    ) {
        self.value = min(max(value, 0), 1)
        self.color = color
        self.size = size
        self.lineWidth = lineWidth
        self.segments = segments
        self.label = label
    }

    var body: some View {
        ZStack {
            ZStack {
                // Background ring
                Circle()
                    .stroke(.quaternary, lineWidth: lineWidth)

                // Filled arc. Segmented rings take flat ends: a round cap pokes
                // past the divider at twelve o'clock and leaves a stray dot.
                Circle()
                    .trim(from: 0, to: value)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: segments > 1 ? .butt : .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: value)

                // Cut the dividers out rather than painting them, so the gaps
                // show whatever is behind the panel, glass included.
                if segments > 1 {
                    ForEach(0..<segments, id: \.self) { index in
                        Rectangle()
                            .frame(width: 1.5, height: lineWidth + 2)
                            .offset(y: -size / 2)
                            .rotationEffect(.degrees(360 * Double(index) / Double(segments)))
                            .blendMode(.destinationOut)
                    }
                }
            }
            .compositingGroup()

            // Center value
            Text(label ?? "\(Int((value * 100).rounded()))")
                .font(.system(size: size * 0.28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}
