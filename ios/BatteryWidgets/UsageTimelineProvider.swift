import WidgetKit
import SwiftUI

/// One timeline entry. `payload` is nil when the widget has no *real* shared data
/// yet — the app hasn't synced, or the App Group isn't enabled — so the view can
/// show an honest "open the app" state instead of inventing sample numbers.
struct UsageEntry: TimelineEntry {
    let date: Date
    let payload: UsagePayload?
}

/// The widget **self-refreshes**: on each timeline rebuild it reuses recent shared
/// data if fresh, otherwise fetches `/api/oauth/usage` directly with the token the
/// app mirrored into the App Group — so widgets update on WidgetKit's own schedule
/// without the app running. It never refreshes the token (the app does that); if
/// the mirrored token is expired it falls back to the last known data.
struct UsageProvider: TimelineProvider {
    /// Treat shared data as "fresh" for this long before self-fetching (also
    /// dedupes fetches across widget families/instances).
    private let freshFor: TimeInterval = 10 * 60
    private let refreshEvery: TimeInterval = 15 * 60

    // The redacted skeleton / gallery preview may use sample data — that's what
    // placeholders are *for*. Real timelines never do.
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), payload: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        // Widget gallery should look populated; a live snapshot uses real data.
        let payload: UsagePayload? = context.isPreview ? .placeholder : SharedStore.load()
        completion(UsageEntry(date: Date(), payload: payload))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            let entry = UsageEntry(date: Date(), payload: await currentPayload())
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(refreshEvery))))
        }
    }

    /// Fresh cached data → reuse it. Stale/absent + a valid mirrored token → fetch.
    /// Otherwise → last known data (may be nil → empty state).
    private func currentPayload() async -> UsagePayload? {
        let cached = SharedStore.load()
        if let cached, Date().timeIntervalSince(cached.updatedAt) < freshFor {
            return cached
        }
        guard let token = SharedStore.loadToken(),
              token.expiryDate.timeIntervalSinceNow > 30
        else { return cached }

        do {
            let usage = try await UsageFetcher.fetch(accessToken: token.accessToken)
            let fresh = UsagePayload.from(
                usage: usage,
                previous: cached,
                accountName: cached?.accountName ?? "Account"
            )
            SharedStore.save(fresh, reloadWidgets: false) // share with siblings; don't loop
            return fresh
        } catch {
            return cached // expired token / network / rate limit → last known
        }
    }
}

/// Shared wrapper for every Home Screen widget: honest empty state when there's
/// no data, plus the surface background.
@ViewBuilder
func widgetBody<Content: View>(
    _ entry: UsageEntry,
    @ViewBuilder content: (UsagePayload) -> Content
) -> some View {
    Group {
        if let payload = entry.payload {
            content(payload)
        } else {
            WidgetEmptyView()
        }
    }
    .widgetBackground(BatteryPalette.surface)
}

/// Shown when the widget has no synced data (open the app / enable the App Group).
struct WidgetEmptyView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("Open Battery to sync", systemImage: "bolt.slash")
        case .accessoryCircular:
            Image(systemName: "bolt.slash.fill").font(.title3).widgetAccentable()
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("Battery").font(.caption.weight(.semibold)).widgetAccentable()
                Text("Open the app to sync").font(.caption2).foregroundStyle(.secondary)
            }
        default:
            VStack(spacing: 7) {
                Image(systemName: "bolt.slash.fill").font(.title2).foregroundStyle(BatteryPalette.brand)
                Text("Open Battery").font(.footnote.weight(.semibold))
                Text("to sync your usage").font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

extension View {
    /// `containerBackground(_:for:)` is iOS 17+. On iOS 16 a widget just draws its
    /// own background, so fall back to a plain fill to keep the 16.2 target valid.
    @ViewBuilder
    func widgetBackground(_ style: some ShapeStyle) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(style, for: .widget)
        } else {
            background(style)
        }
    }
}

/// Widget-safe "resets in" text. Unlike the app's `LiveCountdown` (which uses a
/// periodic `TimelineView`, inert in a widget), this leans on WidgetKit's
/// self-updating date text so it ticks without new timeline entries.
struct WidgetCountdown: View {
    let reset: Date?
    var prefix: String = "Resets in"

    // Compact absolute date for the weekly window (kept short to fit a small tile).
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    var body: some View {
        if let reset {
            if reset.timeIntervalSinceNow > 86400 {
                Text("Resets \(Self.dateFormatter.string(from: reset))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            } else {
                (Text(prefix + " ") + Text(reset, style: .relative))
                    .font(BatteryFont.numeric(11, relativeTo: .caption2)).foregroundStyle(.secondary)
            }
        } else {
            Text("No active window").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
