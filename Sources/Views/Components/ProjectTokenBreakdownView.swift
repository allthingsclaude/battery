import SwiftUI

/// Compact per-project token share for a usage window.
///
/// Shows the top five projects, then a "See more" row that reveals the next
/// five and the "Other projects" roll-up of everything past them. Collapsed,
/// that row carries the hidden projects' combined share, so the total still
/// reads at a glance.
struct ProjectTokenBreakdownView: View {
    let entries: [ProjectTokenUsage]
    /// Drives a staggered fade-in: rows sit at opacity 0 until this flips true.
    var revealed: Bool = true

    /// Named projects shown before "See more".
    static let collapsedCount = 5

    @State private var expanded = false

    private var theme: ColorTheme { AppSettings.shared.activeTheme }

    /// Everything past the first five: the next named projects and the roll-up.
    private var hiddenEntries: ArraySlice<ProjectTokenUsage> {
        entries.dropFirst(Self.collapsedCount)
    }

    /// Only worth collapsing when there is something to hide.
    private var isCollapsible: Bool { !hiddenEntries.isEmpty }

    private var visibleEntries: [ProjectTokenUsage] {
        guard isCollapsible, !expanded else { return entries }
        return Array(entries.prefix(Self.collapsedCount))
    }

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                    ProjectTokenRow(entry: entry, color: color(for: entry.percentage))
                        .opacity(revealed ? 1 : 0)
                        .animation(rowAnimation(index: index), value: revealed)
                }
                if isCollapsible {
                    toggleRow
                        .opacity(revealed ? 1 : 0)
                        .animation(rowAnimation(index: visibleEntries.count), value: revealed)
                }
            }
            .padding(.top, 2)
        }
    }

    /// "See 5 more · 23%" collapsed, "See less" expanded.
    private var toggleRow: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(expanded ? "See less" : hiddenNamedCount > 0 ? "See \(hiddenNamedCount) more" : "See more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 8)

                if !expanded {
                    Text("\(Int(hiddenShare.rounded()))%")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(expanded ? "Show only the top \(Self.collapsedCount) projects" : "Show more projects")
    }

    /// Named projects the collapsed list leaves out. The roll-up isn't a
    /// project, so it isn't counted.
    private var hiddenNamedCount: Int {
        hiddenEntries.filter { !$0.isOtherProjects }.count
    }

    /// Combined share of everything the collapsed list leaves out.
    private var hiddenShare: Double {
        hiddenEntries.reduce(0) { $0 + $1.percentage }
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
