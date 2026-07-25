import SwiftUI

/// Shared layout + component tokens so every iOS surface feels like one premium,
/// on-brand product. Mirrors the macOS design language: continuous rounded
/// corners, glass/elevated surfaces, `.quaternary` tracks, SF Rounded monospaced
/// numerals, and a tight caption/tertiary type hierarchy.
enum BatteryMetrics {
    /// Continuous corner radius for cards (the desktop panel uses 24 for its shell).
    static let card: CGFloat = 22
    static let cardTight: CGFloat = 16
    static let ringLine: CGFloat = 6
    static let ringLineHero: CGFloat = 9
    static let sectionSpacing: CGFloat = 16
    static let hPadding: CGFloat = 18
}

// MARK: - Card surface

private struct PremiumCard: ViewModifier {
    var radius: CGFloat = BatteryMetrics.card
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(BatteryPalette.elevated, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(BatteryPalette.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
            .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
    }
}

extension View {
    /// Elevated, hairline-edged, softly-shadowed card — the app's core surface.
    func batteryCard(radius: CGFloat = BatteryMetrics.card, padding: CGFloat = 16) -> some View {
        modifier(PremiumCard(radius: radius, padding: padding))
    }
}

// MARK: - Branded progress bar (ports the macOS ProgressBarView)

struct BatteryProgressBar: View {
    let utilization: Double        // 0–100
    var height: CGFloat = 7

    private var level: UsageLevel { .from(utilization: utilization) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level.gradient)
                    .frame(width: geo.size.width * CGFloat(min(100, max(0, utilization)) / 100))
                    .animation(.easeInOut(duration: 0.4), value: utilization)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Live countdown (ports the macOS CountdownLabel, updates every second)

struct LiveCountdown: View {
    let target: Date
    var prefix: String = "Resets in"
    var icon: String = "clock"

    /// Matches the macOS `CountdownLabel`: an absolute date/time when the reset is
    /// more than a day out (weekly window), a live countdown when it's close.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d 'at' h:mm a"
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, target.timeIntervalSince(context.date))
            HStack(spacing: 4) {
                Image(systemName: remaining > 86400 ? "calendar" : icon)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if remaining > 86400 {
                    Text("Resets \(Self.dateFormatter.string(from: target))")
                        .font(BatteryFont.numeric(11, relativeTo: .caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    if !prefix.isEmpty {
                        Text(prefix).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(remaining > 0 ? TimeFormatting.shortDuration(remaining) : "now")
                        .font(BatteryFont.numeric(12, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Active-session pulse

/// A soft pulsing brand dot signalling a live, burning session.
struct ActiveDot: View {
    var size: CGFloat = 7
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(BatteryPalette.brand)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(BatteryPalette.brand, lineWidth: 2)
                    .scaleEffect(pulse ? 2.2 : 1)
                    .opacity(pulse ? 0 : 0.6)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
    }
}

// MARK: - Section label

struct SectionLabel: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(title.uppercased())
                .font(BatteryFont.label(11))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
    }
}
