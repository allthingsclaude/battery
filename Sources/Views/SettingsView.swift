import SwiftUI

/// Full settings panel with accounts, display, notification, polling, data, general, and about sections.
struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var updaterService: UpdaterService
    @ObservedObject var usageViewModel: UsageViewModel
    var onClose: () -> Void

    @State private var renamingAccountId: UUID?
    @State private var renameText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    accountsSection
                    displaySection
                    notificationsSection
                    iPhoneSection
                    pollingSection
                    dataSection
                    generalSection
                    aboutSection
                }
                .padding(16)
            }
        }
        .frame(width: 320)
        .background(AppSettings.shared.activeTheme.popoverBackground)
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        SettingsSection(title: "Accounts", icon: "person.2") {
            ForEach(usageViewModel.accounts) { account in
                HStack(spacing: 8) {
                    if renamingAccountId == account.id {
                        TextField("Name", text: $renameText, onCommit: {
                            let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                usageViewModel.renameAccount(id: account.id, newName: trimmed)
                            }
                            renamingAccountId = nil
                        })
                        .font(.caption)
                        .textFieldStyle(.roundedBorder)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.name)
                                .font(.caption)
                                .fontWeight(account.id == usageViewModel.selectedAccountId ? .semibold : .regular)
                            if let email = account.email {
                                Text(email)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    Spacer()

                    Button(action: {
                        renameText = account.name
                        renamingAccountId = account.id
                    }) {
                        Image(systemName: "pencil")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Rename account")

                    Button(action: { usageViewModel.removeAccount(id: account.id) }) {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Remove account")
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    usageViewModel.selectAccount(id: account.id)
                }
            }

            if usageViewModel.accounts.count < 5 {
                HStack {
                    Button("Add Account") {
                        NSApp.keyWindow?.close()
                        usageViewModel.startOAuthLogin { success in
                            if success { onClose() }
                        }
                    }
                    .font(.caption)
                    .controlSize(.small)
                    .focusable(false)
                    Spacer()
                }
            }

            if !usageViewModel.accounts.isEmpty {
                Divider()
                HStack {
                    Button("Sign Out of All Accounts") {
                        usageViewModel.removeAllAccounts()
                    }
                    .font(.caption)
                    .controlSize(.small)
                    .focusable(false)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        SettingsSection(title: "Display", icon: "eye") {
            // Menu bar appearance
            VStack(alignment: .leading, spacing: 6) {
                Text("Menu Bar")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Show icon", isOn: $settings.showMenuBarIcon)
                    .font(.caption)

                Toggle("Show text", isOn: $settings.showMenuBarText)
                    .font(.caption)

                if settings.showMenuBarText {
                    Picker("Format", selection: Binding(
                        get: { settings.displayMode },
                        set: { settings.displayMode = $0 }
                    )) {
                        ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.caption)
                }
            }

            Divider()

            // Theme
            VStack(alignment: .leading, spacing: 6) {
                Text("Theme")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Picker("Theme", selection: Binding(
                    get: { settings.activeTheme },
                    set: { settings.activeTheme = $0 }
                )) {
                    ForEach(ColorTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            // Value display preferences
            VStack(alignment: .leading, spacing: 6) {
                Text("Values")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle(isOn: $settings.showPercentageRemaining) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show remaining percentage")
                            .font(.caption)
                        Text(settings.showPercentageRemaining ? "e.g. 51% left" : "e.g. 49% used")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Toggle(isOn: $settings.showTimeSinceReset) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show time elapsed")
                            .font(.caption)
                        Text(settings.showTimeSinceReset ? "e.g. Started 3h 37m ago" : "e.g. Resets in 1h 23m")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        SettingsSection(title: "Notifications", icon: "bell") {
            if !viewModel.notificationPermissionGranted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Notifications disabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Enable") {
                        viewModel.openNotificationSettings()
                    }
                    .font(.caption)
                    .controlSize(.small)
                    .focusable(false)
                }
            }

            Toggle("Notify at 80%", isOn: $settings.notifyAt80)
                .font(.caption)
            Toggle("Notify at 90%", isOn: $settings.notifyAt90)
                .font(.caption)
            Toggle("Notify at 95%", isOn: $settings.notifyAt95)
                .font(.caption)

            HStack {
                Spacer()
                Button("Test Notification") {
                    viewModel.sendTestNotification()
                }
                .font(.caption)
                .controlSize(.small)
                .focusable(false)
            }
        }
    }

    @ViewBuilder
    private var iPhoneSection: some View {
        // Hidden entirely when no relay is configured, matching iOS. Offering a
        // pairing box that can't reach anything would just look broken.
        if usageViewModel.pushRelayService.isConfigured {
            PushRelaySection(relay: usageViewModel.pushRelayService)
        }
    }


    // MARK: - Polling

    private var pollingSection: some View {
        SettingsSection(title: "Polling", icon: "arrow.clockwise") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Active interval")
                        .font(.caption)
                    Spacer()
                    Text("\(Int(settings.pollIntervalActive / 60))m")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.pollIntervalActive, in: 60...300, step: 60)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Idle interval")
                        .font(.caption)
                    Spacer()
                    Text("\(Int(settings.pollIntervalIdle / 60))m")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.pollIntervalIdle, in: 300...900, step: 300)
                    .controlSize(.small)
            }

            Text("Active polling is used when a Claude Code session is detected.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        SettingsSection(title: "Data", icon: "cylinder") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Retention period")
                        .font(.caption)
                    Spacer()
                    Text("\(settings.dataRetentionDays) days")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(settings.dataRetentionDays) },
                        set: { settings.dataRetentionDays = Int($0) }
                    ),
                    in: 7...365,
                    step: 7
                )
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button("Export Data") {
                    viewModel.exportData()
                }
                .font(.caption)
                .controlSize(.small)
                .focusable(false)

                Spacer()

                Button("Clear History") {
                    Task { await viewModel.clearHistory() }
                }
                .font(.caption)
                .controlSize(.small)
                .focusable(false)
            }
        }
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsSection(title: "General", icon: "gearshape") {
            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { viewModel.setLaunchAtLogin($0) }
            ))
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        SettingsSection(title: "About", icon: "info.circle") {
            HStack {
                Text("Battery")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Text("v\(viewModel.appVersion) (\(viewModel.buildNumber))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Claude Code usage monitor for your menu bar.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button("Check for Updates") {
                    updaterService.checkForUpdates()
                }
                .font(.caption)
                .controlSize(.small)
                .focusable(false)
                .disabled(!updaterService.canCheckForUpdates)
            }
        }
    }
}

// MARK: - iPhone Live Updates
//
// Pairing for the iOS companion. This Mac already polls every minute, so it
// relays each poll to the phone's Lock Screen Live Activity — which iOS would
// otherwise freeze the moment that app is suspended. Its own view rather than a
// computed property on SettingsView so the relay's published state is observed.

private struct PushRelaySection: View {
    @ObservedObject var relay: PushRelayService
    @State private var code: String = ""

    var body: some View {
        SettingsSection(title: "iPhone", icon: "iphone") {
            if relay.isPaired { connected } else { pairingForm }

            if let error = relay.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(UsageLevel.low.color)
                Text("Sending live updates")
                    .font(.caption)
                Spacer()
                Button("Disconnect") {
                    Task { await relay.unpair() }
                }
                .font(.caption)
                .controlSize(.small)
                .focusable(false)
            }

            Text(relay.lastPushAt.map { "Last update \(TimeFormatting.relativeTime($0))" }
                 ?? "Waiting for the next poll.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Cloud updates only cover the gaps while this Mac is asleep — say
            // so, or "on" in two places looks like double work.
            if relay.cloudEnabled {
                Text("Cloud updates are on as a backup, and pause while this Mac is sending.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pairingForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter the code from Battery on iPhone ▸ Settings ▸ Live Updates.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                TextField("000000", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 80)
                    .onChange(of: code) { newValue in
                        // Digits only, capped at six, so the Pair button's
                        // enabled state is never ambiguous.
                        code = String(newValue.filter(\.isNumber).prefix(6))
                    }
                Button("Pair") {
                    Task {
                        await relay.pair(code: code)
                        if relay.isPaired { code = "" }
                    }
                }
                .font(.caption)
                .controlSize(.small)
                .focusable(false)
                .disabled(code.count != 6 || relay.isWorking)
                Spacer()
                if relay.isWorking { ProgressView().controlSize(.small) }
            }
        }
    }
}

// MARK: - Reusable Section Component

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(10)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
