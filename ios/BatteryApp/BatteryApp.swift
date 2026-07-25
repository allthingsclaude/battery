import SwiftUI

/// iOS app entry point. Registers the background-refresh handler, then gates on
/// sign-in: `LoginView` until authenticated, `DashboardView` after.
@main
struct BatteryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var service = UsageService()
    @Environment(\.scenePhase) private var scenePhase

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
            .task {
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
