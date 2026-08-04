import SwiftUI

/// iOS app entry point. Registers the background-refresh handler, then gates on
/// sign-in: `LoginView` until authenticated, `DashboardView` after.
@main
struct BatteryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var service = UsageService()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode { AppearanceMode(rawValue: appearanceRaw) ?? .system }

    init() {
        BatteryFont.registerIfNeeded()
        BackgroundRefresher.register()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if service.showsDashboard {
                    DashboardView(service: service)
                } else {
                    LoginView(service: service) { tokens in service.addAccount(tokens) }
                }
            }
            .tint(BatteryPalette.brand)
            .preferredColorScheme(appearance.colorScheme)
            .task {
                // Re-assert the icon choice: a reinstall (or a restore to a new
                // phone) drops the alternate icon while the preference survives
                // in UserDefaults, so the two can drift apart.
                AppIconChoice.current.apply()
                service.startPolling()
                // A Live Activity can outlive the app process; re-attach its
                // push-token stream so the relay keeps a current token.
                LiveActivityController.shared.adoptExistingActivities()
                await PushRelayClient.shared.refreshStatus()
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                service.startPolling()
            case .background:
                service.stopPolling()
                BackgroundRefresher.schedule()
            default:
                break
            }
        }
    }
}
