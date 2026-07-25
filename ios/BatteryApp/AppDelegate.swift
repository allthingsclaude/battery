import SwiftUI
#if os(iOS)
import UIKit
import ActivityKit
#endif

/// Owns everything that has to happen at the `UIApplication` level rather than in
/// SwiftUI: APNs registration and silent-push handling.
///
/// Both exist to serve the push relay. ActivityKit pushes keep the *Live
/// Activity* current on their own, but they can't touch the Home Screen widgets
/// — those read the App Group snapshot, which only this process can write. So
/// the relay also sends a silent `content-available` push, which wakes us just
/// long enough to poll once and reload the timelines.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Silent pushes need no user permission, so this never prompts. (The
        // Live Activity's own alerting updates go through ActivityKit, which is
        // governed by the Live Activities toggle, not notification authorization.)
        application.registerForRemoteNotifications()
        observePushToStartToken()
        return true
    }

    // MARK: - APNs registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.apnsHexToken
        Task { @MainActor in PushRelayClient.shared.register(remoteToken: hex) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Non-fatal: without a remote token the Live Activity still updates via
        // ActivityKit pushes; only the widget-reload nudge is lost.
        print("Remote notification registration failed: \(error.localizedDescription)")
    }

    // MARK: - Silent push → refresh widgets

    // The completion-handler form rather than the `async` one: the payload
    // dictionary isn't Sendable, and the async overload would have to carry it
    // across an isolation boundary to reach us. We never read it anyway — the
    // push carries no data, it exists purely to buy this process some runtime.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            await BackgroundRefresher.performOneShotRefresh()
            completionHandler(.newData)
        }
    }

    // MARK: - Push-to-start

    /// iOS 17.2+ vends a token that lets the relay *start* an activity remotely.
    /// That's what makes the Lock Screen card appear during a session the user
    /// never opened the app for. On 16.2–17.1 this simply never fires, and the
    /// activity is started locally by `LiveActivityController` as before.
    private func observePushToStartToken() {
        #if os(iOS)
        guard #available(iOS 17.2, *) else { return }
        Task {
            for await tokenData in Activity<UsageActivityAttributes>.pushToStartTokenUpdates {
                let hex = tokenData.apnsHexToken
                await MainActor.run { PushRelayClient.shared.notePushToStartToken(hex) }
            }
        }
        #endif
    }
}
