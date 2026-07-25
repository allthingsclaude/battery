import SwiftUI

/// Signed-in home screen. A premium, on-brand reading of the desktop panel:
/// a hero session ring, a weekly/Opus card with branded bars, a projection card
/// mirroring the desktop's, and a subtle note on when the Live Activity appears.
struct DashboardView: View {
    @ObservedObject var service: UsageService
    @State private var showSettings = false
    @State private var showAccounts = false
    @AppStorage(LiveActivityMode.storageKey) private var liveActivityModeRaw = LiveActivityMode.smart.rawValue

    /// Only read inside branches where `service.payload != nil` — the dashboard
    /// never renders sample data as if it were real (see `waitingCard`).
    private var payload: UsagePayload { service.payload ?? .placeholder }

    var body: some View {
        ScrollView {
            VStack(spacing: BatteryMetrics.sectionSpacing) {
                header
                if service.payload != nil {
                    sessionCard
                    weeklyCard
                    if showsProjection { projectionCard }
                } else {
                    waitingCard
                }
                if let error = service.errorMessage { errorCard(error) }
                liveActivityNote
            }
            .padding(.horizontal, BatteryMetrics.hPadding)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(BatteryPalette.surface.ignoresSafeArea())
        .refreshable { await service.refresh() }
        .overlay(alignment: .bottomTrailing) { debugControl }
        .sheet(isPresented: $showSettings) {
            SettingsView(service: service)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAccounts) {
            AccountsView(service: service)
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder private var debugControl: some View {
        #if DEBUG
        if service.isDemoRunning {
            Button { service.toggleDemo() } label: {
                Label("Demo", systemImage: "stop.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(BatteryPalette.brand.opacity(0.4), lineWidth: 1))
            }
            .tint(BatteryPalette.brandDark)
            .padding(18)
        }
        #endif
    }

    // MARK: - Empty / error states

    /// Shown until the first successful poll. Never fabricates numbers.
    private var waitingCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.title2).foregroundStyle(BatteryPalette.brand)
            Text("Waiting for your first sync")
                .font(.subheadline.weight(.semibold))
            Text("Pull down to refresh.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .batteryCard(padding: 20)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(BatteryPalette.warn)
            Text(message)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(BatteryPalette.warn.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: BatteryMetrics.cardTight, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BatteryMetrics.cardTight, style: .continuous)
            .strokeBorder(BatteryPalette.warn.opacity(0.25), lineWidth: 1))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Battery")
                    .font(BatteryFont.heading(34, relativeTo: .largeTitle))
                HStack(spacing: 6) {
                    if let tier = service.payload?.planTier, !tier.isEmpty {
                        Text(tier)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(BatteryPalette.brand.opacity(0.16), in: Capsule())
                            .foregroundStyle(BatteryPalette.brandDark)
                    }
                    Button { showAccounts = true } label: {
                        HStack(spacing: 3) {
                            Text(service.selectedAccount?.name ?? "Account")
                                .font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            statusPill
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var statusPill: some View {
        if let payload = service.payload {
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 6) {
                    if payload.isSessionActive {
                        ActiveDot()
                        Text("Active").font(.caption.weight(.semibold)).foregroundStyle(BatteryPalette.brandDark)
                    } else {
                        Image(systemName: "moon.zzz.fill").font(.caption2).foregroundStyle(.tertiary)
                        Text("Idle").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(BatteryPalette.hairline, lineWidth: 1))

                (Text("Updated ") + Text(payload.updatedAt, style: .relative))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Session hero

    private var sessionCard: some View {
        VStack(spacing: 16) {
            HStack {
                SectionLabel(title: "Session · 5-hour", systemImage: "bolt.fill")
                Spacer()
                levelBadge(payload.sessionLevel)
            }

            UsageRing(utilization: payload.sessionUtilization,
                      size: 148, lineWidth: BatteryMetrics.ringLineHero,
                      gradientStroke: true)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    Text("used").font(.caption2).foregroundStyle(.tertiary).offset(y: 20)
                }

            if let reset = payload.sessionResetsAt {
                LiveCountdown(target: reset)
            } else {
                Label("No active session", systemImage: "moon.zzz")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if payload.burnRatePerHour > 0.05 {
                Divider().overlay(BatteryPalette.hairline)
                burnLine
            }
        }
        .frame(maxWidth: .infinity)
        .batteryCard(padding: 20)
    }

    private var burnLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill").font(.caption).foregroundStyle(BatteryPalette.brand)
            Text(String(format: "Burning %.1f%%/hr", payload.burnRatePerHour))
                .font(.caption.weight(.medium)).foregroundStyle(.primary)
            if let limit = payload.liveProjectedLimitAt {
                Text("· hits 100% \(Text(limit, style: .relative))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
    }

    // MARK: - Weekly + Opus

    private var weeklyCard: some View {
        VStack(spacing: 16) {
            barRow(title: "Weekly · 7-day", icon: "calendar", utilization: payload.weeklyUtilization,
                   reset: payload.weeklyResetsAt)
            if let opus = payload.opusUtilization {
                Divider().overlay(BatteryPalette.hairline)
                barRow(title: "Opus · 7-day", icon: "sparkles", utilization: opus, reset: nil)
            }
        }
        .batteryCard()
    }

    private func barRow(title: String, icon: String, utilization: Double, reset: Date?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionLabel(title: title, systemImage: icon)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(utilization.rounded()))")
                        .font(BatteryFont.numeric(17, weight: .strong, relativeTo: .body))
                        .foregroundStyle(UsageLevel.from(utilization: utilization).color)
                    Text("%").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            BatteryProgressBar(utilization: utilization)
            if let reset { LiveCountdown(target: reset) }
        }
    }

    // MARK: - Projection (mirrors the desktop ProjectionView)

    private var showsProjection: Bool {
        payload.burnRatePerHour > 0.05 && payload.sessionResetsAt != nil
    }

    private var projectionCard: some View {
        let reset = payload.sessionResetsAt ?? Date()
        let hoursToReset = max(0, reset.timeIntervalSinceNow / 3600)
        let atReset = min(100, payload.sessionUtilization + payload.burnRatePerHour * hoursToReset)
        let increasing = payload.burnRatePerHour > 1.0

        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                SectionLabel(title: "Projection", systemImage: "chart.line.uptrend.xyaxis")
                Spacer()
                trendBadge(increasing: increasing)
            }
            if let limit = payload.liveProjectedLimitAt, limit < reset {
                projectionRow(icon: "exclamationmark.triangle.fill",
                              tint: BatteryPalette.brandDeep,
                              text: "Hits limit in \(TimeFormatting.shortDuration(limit.timeIntervalSinceNow))")
            } else {
                projectionRow(icon: "checkmark.circle.fill",
                              tint: BatteryPalette.brand,
                              text: "Stays within the window")
            }
            projectionRow(icon: "arrow.right.circle", tint: .secondary,
                          text: "Projected \(Int(atReset))% at reset")
            projectionRow(icon: "speedometer", tint: .secondary,
                          text: String(format: "Burn rate %.1f%%/hr", payload.burnRatePerHour))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .batteryCard()
    }

    private func projectionRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.caption2).foregroundStyle(tint)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func trendBadge(increasing: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: increasing ? "arrow.up.right" : "arrow.right").font(.system(size: 8))
            Text(increasing ? "Increasing" : "Stable").font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background((increasing ? BatteryPalette.brandDark : BatteryPalette.brand).opacity(0.15), in: Capsule())
        .foregroundStyle(increasing ? BatteryPalette.brandDark : BatteryPalette.brand)
    }

    // MARK: - Bits

    private func levelBadge(_ level: UsageLevel) -> some View {
        Text(level.label.uppercased())
            .font(.system(size: 9, weight: .bold)).tracking(0.5)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(level.color.opacity(0.16), in: Capsule())
            .foregroundStyle(level.color)
    }

    private var liveActivityNote: some View {
        let mode = LiveActivityMode(rawValue: liveActivityModeRaw) ?? .smart
        let text: String
        switch mode {
        case .off:
            text = "Live Activity is off — turn it on in Settings."
        case .alwaysOn:
            text = "Live Activity stays on your Lock Screen for the whole session."
        case .smart:
            text = (payload.sessionUtilization >= 40 || payload.isSessionActive)
                ? "Live Activity is on your Lock Screen while this session is hot."
                : "A Live Activity appears on your Lock Screen once a session gets busy."
        }
        return Button { showSettings = true } label: {
            HStack(spacing: 10) {
                Image(systemName: mode == .off ? "lock.slash" : "lock.iphone")
                    .font(.callout).foregroundStyle(BatteryPalette.brand)
                Text(text).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(BatteryPalette.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: BatteryMetrics.cardTight, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BatteryMetrics.cardTight, style: .continuous)
                .strokeBorder(BatteryPalette.brand.opacity(0.14), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
