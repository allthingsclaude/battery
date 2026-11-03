import SwiftUI

/// A horizontal progress bar with a rounded rectangle track and fill.
struct ProgressBarView: View {
    let value: Double   // 0.0 to 1.0
    let color: Color
    var height: CGFloat = 6
    var cornerRadius: CGFloat = 3
    /// Splits the bar into this many equal parts, e.g. 7 for the days of a
    /// weekly window. 1 draws a plain bar.
    var segments: Int = 1

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.quaternary)
                    .frame(height: height)

                // No fill animation: usage changes almost always arrive while
                // the panel is closed, so the tween is never seen — but it does
                // play on account switches, where it reads as drift.
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(value, 0), 1.0), height: height)

                // Cut the dividers out rather than painting them, so the gaps
                // show whatever is behind the panel, glass included.
                if segments > 1 {
                    ForEach(1..<segments, id: \.self) { index in
                        Rectangle()
                            .frame(width: Self.dividerWidth, height: height)
                            .offset(x: geometry.size.width * CGFloat(index) / CGFloat(segments) - Self.dividerWidth / 2)
                            .blendMode(.destinationOut)
                    }
                }
            }
            .compositingGroup()
        }
        .frame(height: height)
    }

    private static let dividerWidth: CGFloat = 1.5
}
