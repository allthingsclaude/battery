import SwiftUI

/// A small settings sheet. Currently the home of the Live Activity mode picker;
/// structured so more preferences can slot in later.
struct SettingsView: View {
    @ObservedObject var service: UsageService
    @ObservedObject private var relay = PushRelayClient.shared
    /// A second auth service, kept separate from `service.auth` on purpose —
    /// cloud sync signs in again for a narrower grant rather than reusing the
    /// account's own tokens.
    @StateObject private var cloudAuth = AuthService()
    @State private var confirmingCloudOff = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage(LiveActivityMode.storageKey) private var modeRaw = LiveActivityMode.smart.rawValue
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(AppIconChoice.storageKey) private var appIconRaw = AppIconChoice.light.rawValue

    private var mode: LiveActivityMode { LiveActivityMode(rawValue: modeRaw) ?? .smart }
    private var appIcon: AppIconChoice { AppIconChoice(rawValue: appIconRaw) ?? .light }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(LiveActivityMode.allCases) { option in
                        Button { select(option) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).foregroundStyle(.primary)
                                    Text(option.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if mode == option {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(BatteryPalette.brand)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Lock Screen Live Activity")
                } footer: {
                    Text("“Always On” keeps the session on your Lock Screen and Dynamic Island the whole window. It may appear dimmed if the app hasn’t refreshed recently in the background.")
                }

                if relay.isConfigured {
                    macRelaySection
                    cloudSyncSection
                }

                appearanceSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $cloudAuth.isPresentingAuth) {
                if let url = cloudAuth.authURL {
                    AuthSafariView(url: url)
                        .ignoresSafeArea()
                        .onDisappear { cloudAuth.cancelIfPending() }
                }
            }
            .alert("Turn off cloud updates?", isPresented: $confirmingCloudOff) {
                Button("Turn Off", role: .destructive) {
                    Task { await relay.disableCloudSync() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Battery will stop polling for you in the background. You should also revoke the “Battery cloud sync” connection in your Claude account settings.")
            }
        }
        .tint(BatteryPalette.brand)
    }

    // MARK: - Live updates from the Mac
    //
    // iOS suspends this app, so the Live Activity it starts stops moving until
    // the app runs again. Pairing hands a Mac permission to push the numbers it's
    // already polling, straight to the Lock Screen.

    @ViewBuilder
    private var macRelaySection: some View {
        Section {
            if let pairing = relay.pairing {
                pairingCode(pairing)
            } else if relay.isPaired {
                LabeledContent {
                    Text("Connected")
                        .foregroundStyle(BatteryPalette.brand)
                        .font(.body.weight(.medium))
                } label: {
                    Label("Mac", systemImage: "laptopcomputer")
                }
                Button("Disconnect", role: .destructive) {
                    Task { await relay.unpair() }
                }
            } else {
                Button {
                    Task { await relay.requestPairingCode() }
                } label: {
                    HStack {
                        Label("Pair with Mac", systemImage: "laptopcomputer.and.iphone")
                        Spacer()
                        if relay.isWorking { ProgressView() }
                    }
                }
                .disabled(relay.isWorking)
            }

            if let error = relay.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Live Updates")
        } footer: {
            Text(relay.isPaired
                 ? "Your Mac sends usage updates straight to this phone’s Lock Screen, so the Live Activity keeps moving without opening the app."
                 : "Without a paired Mac, the Lock Screen only refreshes when iOS grants this app background time — often several minutes apart.")
        }
    }

    private func pairingCode(_ pairing: PushRelayClient.PairingCode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pairing.formatted)
                .font(BatteryFont.numeric(40, weight: .strong))
                .tracking(2)
                .foregroundStyle(BatteryPalette.brand)
                .frame(maxWidth: .infinity)

            Text("Open Battery on your Mac ▸ Settings ▸ Live Updates and enter this code.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            // A live countdown, so an expired code is obvious rather than just
            // mysteriously rejected on the Mac.
            HStack(spacing: 4) {
                Text("Expires")
                Text(pairing.expiresAt, style: .relative)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)

            Button("Cancel") { relay.clearPairingCode() }
                .font(.callout)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
        // The Mac claims the code out-of-band, so poll for the result rather than
        // making the user guess whether it worked.
        .task(id: pairing.code) {
            while !Task.isCancelled, Date() < pairing.expiresAt {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await relay.refreshStatus()
                if relay.isPaired { relay.clearPairingCode(); return }
            }
        }
    }

    // MARK: - Cloud updates
    //
    // The Mac relay above covers the common case, but it needs a Mac that's
    // awake. This covers the rest — coding from claude.ai, or from a machine
    // that isn't running Battery — by letting the relay poll on a schedule.
    //
    // It's the one place the app hands a credential to a server, so the UI says
    // exactly what's stored and what it can do, rather than burying it.

    @ViewBuilder
    private var cloudSyncSection: some View {
        Section {
            if relay.isCloudPolling {
                LabeledContent {
                    Text("On").foregroundStyle(BatteryPalette.brand).font(.body.weight(.medium))
                } label: {
                    Label("Cloud updates", systemImage: "cloud")
                }
                Button("Turn Off", role: .destructive) { confirmingCloudOff = true }
                    .disabled(relay.isWorking)
            } else {
                Button {
                    startCloudSignIn()
                } label: {
                    HStack {
                        Label("Set Up Cloud Updates", systemImage: "cloud")
                        Spacer()
                        if relay.isWorking { ProgressView() }
                    }
                }
                .disabled(relay.isWorking)

                VStack(alignment: .leading, spacing: 6) {
                    disclosure("Signs in again for a read-only permission — it can see your usage, but can’t send messages or spend on your account.")
                    disclosure("Separate from this app’s own sign-in, so you can revoke it without signing out.")
                    disclosure("Stored encrypted on the relay so your Lock Screen updates even when every Mac of yours is off.")
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Cloud Updates")
        } footer: {
            Text(relay.isCloudPolling
                 ? "Battery checks your usage every few minutes and pushes it to your Lock Screen. Your Mac stands down while this is on."
                 : "Optional. Without it, updates need a Mac running Battery.")
        }
    }

    private func disclosure(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func startCloudSignIn() {
        cloudAuth.startLogin(scopes: AppConfig.cloudSyncScopes) { result in
            guard case .success(let tokens) = result else { return }
            Task {
                await relay.enableCloudSync(
                    tokens: tokens,
                    planTier: service.payload?.planTier ?? "",
                    accountName: service.payload?.accountName ?? "Account"
                )
            }
        }
    }

    // MARK: - Appearance
    //
    // Theme and icon are separate choices on purpose: the theme is about the app
    // you're looking at, the icon about the Home Screen you're not.

    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 9) {
                Text("Theme").font(.subheadline.weight(.medium))
                Picker("Theme", selection: $appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 11) {
                Text("App Icon").font(.subheadline.weight(.medium))
                HStack(spacing: 16) {
                    ForEach(AppIconChoice.allCases) { choice in
                        iconOption(choice)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Theme applies to this app only — widgets and the Live Activity are drawn by iOS and always follow the system.")
        }
    }

    private func iconOption(_ choice: AppIconChoice) -> some View {
        let isSelected = appIcon == choice
        return Button {
            appIconRaw = choice.rawValue
            choice.apply()
        } label: {
            VStack(spacing: 7) {
                Group {
                    if let image = UIImage(named: choice.previewAssetName) {
                        Image(uiImage: image).resizable()
                    } else {
                        // Only reachable if the loose PNGs fall out of the bundle.
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(BatteryPalette.elevated)
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? BatteryPalette.brand : BatteryPalette.hairline,
                                      lineWidth: isSelected ? 2 : 1)
                )

                Text(choice.title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? BatteryPalette.brand : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.title) app icon")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func select(_ option: LiveActivityMode) {
        modeRaw = option.rawValue
        // Apply immediately — start/stop the activity to match the new choice.
        service.reevaluateLiveActivity()
    }
}
