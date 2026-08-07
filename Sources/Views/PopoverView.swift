import SwiftUI

/// Main popover panel shown when clicking the menu bar icon.
struct PopoverView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var updaterService: UpdaterService
    @ObservedObject var layout: PanelLayout
    @State private var showSettings = false
    @State private var showDetails = true
    @State private var renderDetails = true
    @State private var detailsRevealed = true
    @State private var detailsToggleGeneration = 0
    @State private var mainContentHeight: CGFloat = 460
    @State private var bodyHeight: CGFloat = 380
    @State private var animateBodyHeight = false
    @State private var headerHeight: CGFloat = 56
    @State private var footerHeight: CGFloat = 40

    var body: some View {
        Group {
            if showSettings {
                SettingsView(updaterService: updaterService, usageViewModel: viewModel, onClose: { showSettings = false })
                    .frame(height: min(mainContentHeight, layout.maxCardHeight))
                    .id("settings")
            } else if viewModel.needsLogin {
                LoginView(viewModel: viewModel)
                    .id("login")
            } else {
                mainContent
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: MainContentHeightKey.self, value: geo.size.height)
                        }
                    )
                    .id("main")
                    .onAppear { viewModel.refresh() }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onPreferenceChange(MainContentHeightKey.self) { newValue in
            if newValue > 0 { mainContentHeight = newValue }
        }
        .animation(.none, value: showSettings)
        .animation(.none, value: viewModel.needsLogin)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.className.contains("StatusBarWindow") || window.className.contains("MenuBarExtra") ||
                  window.level == .statusBar || window.level == .popUpMenu else { return }
            // Delay reset until after the panel's close animation finishes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showSettings = false
            }
        }
    }

    /// The card is a scrolling body sandwiched between two pinned bars.
    /// The bars are safe-area insets over the scroll view, so body content
    /// slides behind their translucent material when it scrolls. Height is
    /// content-driven up to `layout.maxCardHeight` (screen space below the
    /// menu bar), after which the body scrolls.
    private var mainContent: some View {
        ScrollView(.vertical) {
            bodyContent
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: BodyHeightKey.self, value: geo.size.height)
                    }
                )
        }
        // The body's measured height reaches the frame a frame late, so while
        // the details rows are being added the content briefly overflows a
        // frame that hasn't grown yet — enough for AppKit to flash an overlay
        // scroller. Suppressing the scroller while the card fits keeps that
        // transient overflow invisible; the rows are at opacity 0 during the
        // resize anyway, so the clipping itself never shows.
        .scrollIndicators(cardFitsWithoutScrolling ? .never : .automatic)
        .scrollDisabled(cardFitsWithoutScrolling)
        .safeAreaInset(edge: .top, spacing: 0) { headerBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { footerBar }
        .frame(height: min(headerHeight + bodyHeight + footerHeight, layout.maxCardHeight))
        // The frame follows `bodyHeight`, which arrives via preference — an
        // untransacted write, so it has to carry its own animation. Only the
        // details toggle animates it; account switches snap, so rows with
        // differing project counts don't drift. Exactly one tween per toggle:
        // if the measurement instead trickles in over several frames, tweening
        // each one restarts the animation and the card lags its own content.
        .onPreferenceChange(BodyHeightKey.self) { newValue in
            guard newValue > 0, newValue != bodyHeight else { return }
            if animateBodyHeight {
                animateBodyHeight = false
                withAnimation(detailsResizeAnimation) { bodyHeight = newValue }
            } else {
                bodyHeight = newValue
            }
        }
        .onPreferenceChange(HeaderHeightKey.self) { if $0 > 0 { headerHeight = $0 } }
        .onPreferenceChange(FooterHeightKey.self) { if $0 > 0 { footerHeight = $0 } }
        .animation(.none, value: viewModel.selectedAccountId)
        .animation(detailsResizeAnimation, value: renderDetails)
        .background(AppSettings.shared.activeTheme.popoverBackground)
    }

    /// Pinned header: title + details toggle, account tabs beneath, sitting
    /// on a hairline the tabs visually attach to.
    private var headerBar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Claude Battery")
                    .font(.headline)
                if let tier = Optional(viewModel.planTier), tier != .unknown {
                    Text(tier.displayName)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
                Spacer()
                VStack(spacing: 4) {
                    Toggle("", isOn: showDetailsBinding)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .tint(detailsTint)
                        .help(showDetails ? "Hide details" : "Show details")
                    Text("details")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(showDetails ? detailsTint : Color.secondary.opacity(0.45))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, viewModel.accounts.count > 1 ? 8 : 10)

            if viewModel.accounts.count > 1 {
                AccountTabsView(
                    accounts: viewModel.accounts,
                    selectedAccountId: viewModel.selectedAccountId,
                    onSelect: { viewModel.selectAccount(id: $0) },
                    onAddAccount: {
                        NSApp.keyWindow?.close()
                        viewModel.startOAuthLogin { _ in }
                    }
                )
                .padding(.horizontal, 16)
            }

            Divider()
        }
        .background(.ultraThinMaterial)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: HeaderHeightKey.self, value: geo.size.height)
            }
        )
    }

    /// Pinned footer: last-updated + action buttons.
    private var footerBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if let lastUpdated = viewModel.lastUpdated {
                    Text("Updated \(TimeFormatting.relativeTime(lastUpdated))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .focusable(false)

                Button(action: { viewModel.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .focusable(false)

                Button(action: { updaterService.checkForUpdates() }) {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(!updaterService.canCheckForUpdates)
                .help("Check for Updates")
                .focusable(false)

                QuitButton()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: FooterHeightKey.self, value: geo.size.height)
            }
        )
    }

    @ViewBuilder
    private var bodyContent: some View {
        VStack(spacing: 16) {
            if let error = viewModel.error, !viewModel.isConnected {
                // Error state (only when we have no data at all)
                VStack(spacing: 8) {
                    if error.contains("Session expired") {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else if error.contains("invalid_grant") || error.contains("Refresh token") {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text("Session expired. Please sign in again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Sign In") {
                            viewModel.reauthenticateCurrentAccount()
                        }
                        .controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                // Session gauge (5-hour) or no active session
                if viewModel.sessionResetsAt != nil {
                    SessionGaugeView(
                        title: "Session (5-hour)",
                        utilization: viewModel.sessionUtilization,
                        resetsAt: viewModel.sessionResetsAt,
                        color: viewModel.sessionColor
                    )
                    if renderDetails {
                        ProjectTokenBreakdownView(entries: viewModel.sessionProjectTokenUsage, revealed: detailsRevealed)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("No active session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                Divider()

                // Weekly gauge (7-day)
                WeeklyGaugeView(
                    title: "Weekly (7-day)",
                    utilization: viewModel.weeklyUtilization,
                    resetsAt: viewModel.weeklyResetsAt,
                    color: viewModel.weeklyColor
                )
                if renderDetails {
                    ProjectTokenBreakdownView(entries: viewModel.weeklyProjectTokenUsage, revealed: detailsRevealed)
                }

                // Opus gauge (if applicable)
                if let opusUtil = viewModel.opusUtilization {
                    Divider()
                    WeeklyGaugeView(
                        title: "Opus (7-day)",
                        utilization: opusUtil,
                        resetsAt: viewModel.weeklyResetsAt,
                        color: UsageLevel.from(utilization: opusUtil).color
                    )
                }

                // Fable gauge (if applicable)
                if let fableUtil = viewModel.fableUtilization {
                    Divider()
                    WeeklyGaugeView(
                        title: "Fable (7-day)",
                        utilization: fableUtil,
                        resetsAt: viewModel.fableResetsAt ?? viewModel.weeklyResetsAt,
                        color: UsageLevel.from(utilization: fableUtil).color
                    )
                }

                // Extra usage (if enabled)
                if viewModel.extraUsageEnabled {
                    Divider()
                    ExtraUsageView(
                        usedCredits: viewModel.extraUsageCost,
                        monthlyLimit: viewModel.extraUsageLimit,
                        utilization: viewModel.extraUsageUtilization
                    )
                }

                // Projections (Phase 2)
                Divider()
                if let projection = viewModel.projection, projection.hasEnoughData {
                    ProjectionView(projection: viewModel.projection, sessionResetsAt: viewModel.sessionResetsAt)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("Projections appear after more activity")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Stats: streak, heat map, 7-day chart (Phase 2+3)
                if !viewModel.dailyPeaks.isEmpty || !viewModel.activeDays.isEmpty {
                    Divider()
                    StatsView(
                        dailyPeaks: viewModel.dailyPeaks,
                        currentStreak: viewModel.currentStreak,
                        activeDays: viewModel.activeDays,
                        todaySessionCount: viewModel.todaySessionCount
                    )
                }
            }
        }
    }

    /// True while the card is short enough to show its whole body, which is
    /// every state except a very tall panel on a short screen.
    private var cardFitsWithoutScrolling: Bool {
        headerHeight + bodyHeight + footerHeight <= layout.maxCardHeight
    }

    private var detailsTint: Color {
        AppSettings.shared.activeTheme == .default ? ColorTheme.brand : .orange
    }

    private var showDetailsBinding: Binding<Bool> {
        Binding(
            get: { showDetails },
            set: { newValue in
                setDetailsVisible(newValue)
            }
        )
    }

    private let detailsResizeDuration: Double = 0.2
    private let detailsFadeOutDuration: Double = 0.1

    private var detailsResizeAnimation: Animation {
        .easeInOut(duration: detailsResizeDuration)
    }

    /// Show and hide are kept symmetric: the panel only ever resizes while the
    /// rows are invisible, and the rows only ever fade while the panel size is
    /// fixed. Overlapping the two (as a naive show did) makes the panel resize
    /// under half-faded rows, which reads as a layout jump. The per-row
    /// staggered fade itself lives in ProjectTokenBreakdownView, keyed on
    /// `detailsRevealed`.
    private func setDetailsVisible(_ visible: Bool) {
        guard visible != showDetails else { return }

        detailsToggleGeneration += 1
        let generation = detailsToggleGeneration
        showDetails = visible

        // Let the card's height tween for the length of this toggle only.
        animateBodyHeight = true
        let settleDelay = detailsFadeOutDuration + detailsResizeDuration + 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
            guard generation == detailsToggleGeneration else { return }
            animateBodyHeight = false
        }

        if visible {
            // Grow the panel first (rows invisible), then stagger the rows in.
            detailsRevealed = false
            withAnimation(detailsResizeAnimation) {
                renderDetails = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + detailsResizeDuration + 0.01) {
                guard generation == detailsToggleGeneration, showDetails else { return }
                detailsRevealed = true
            }
        } else {
            // Fade the rows out first, then shrink the panel.
            detailsRevealed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + detailsFadeOutDuration + 0.01) {
                guard generation == detailsToggleGeneration, !showDetails else { return }
                withAnimation(detailsResizeAnimation) {
                    renderDetails = false
                }
            }
        }
    }
}

private struct MainContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FooterHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
