import SwiftUI

/// A horizontal progress bar with a rounded rectangle track and fill.
struct ProgressBarView: View {
    let value: Double   // 0.0 to 1.0
    let color: Color
    var height: CGFloat = 6
    var cornerRadius: CGFloat = 3

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
            }
        }
        .frame(height: height)
    }
}
