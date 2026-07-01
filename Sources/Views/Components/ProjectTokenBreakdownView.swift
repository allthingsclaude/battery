import SwiftUI

/// Compact per-project token share for a usage window.
struct ProjectTokenBreakdownView: View {
    let entries: [ProjectTokenUsage]
    /// Drives a staggered fade-in: rows sit at opacity 0 until this flips true.
    var revealed: Bool = true

    private var theme: ColorTheme { AppSettings.shared.activeTheme }

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    ProjectTokenRow(entry: entry, color: color(for: entry.percentage))
                        .opacity(revealed ? 1 : 0)
                        .animation(rowAnimation(index: index), value: revealed)
                }
            }
            .padding(.top, 2)
        }
    }

    /// Fade rows in one after another; fade them all out together (snappier hide).
    private func rowAnimation(index: Int) -> Animation {
        revealed
            ? .easeOut(duration: 0.16).delay(Double(index) * 0.035)
            : .easeOut(duration: 0.1)
    }

    private func color(for percentage: Double) -> Color {
        switch theme {
        case .default:
            return percentage >= 50 ? ColorTheme.brandDark : percentage >= 25 ? ColorTheme.brand : ColorTheme.brandLight
        case .classic:
            return percentage >= 50 ? .orange : percentage >= 25 ? .yellow : .green
        }
    }
}

private struct ProjectTokenRow: View {
    let entry: ProjectTokenUsage
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("/\(entry.name.lowercased())")
                    .font(.caption2)
                    .fontWeight(.light)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Text("\(Int(entry.percentage.rounded()))%")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(color)
                    .monospacedDigit()
            }

            ProgressBarView(value: entry.percentage / 100.0, color: color, height: 3)
        }
        .help("\(entry.path): \(formattedTokens(entry.tokens)) tokens")
    }

    private func formattedTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000.0)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000.0)
        }
        return "\(tokens)"
    }
}
