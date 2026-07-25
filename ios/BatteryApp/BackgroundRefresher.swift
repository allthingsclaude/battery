import Foundation
import BackgroundTasks

/// Keeps widgets and the Live Activity fresh while the app is backgrounded.
///
/// iOS gates how often `BGAppRefreshTask` actually runs (it learns from usage),
/// so this is best-effort: whenever the system grants us a slot we do one poll,
/// write the payload, reconcile the Live Activity, and schedule the next request.
///
/// This is the fallback path. When a Mac is paired, the push relay drives the
/// Live Activity directly and also sends a silent push that lands in
/// `AppDelegate` and calls `performOneShotRefresh()` below — so the widgets get
/// refreshed on the relay's schedule rather than the scheduler's.
enum BackgroundRefresher {

    /// Call once from `App.init` / launch.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppConfig.bgRefreshTaskID,
            using: nil
        ) { task in
            handle(task as! BGAppRefreshTask)
        }
    }

    /// Ask the system to schedule the next refresh.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: AppConfig.bgRefreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(AppConfig.backgroundRefreshInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Private

    private static func handle(_ task: BGAppRefreshTask) {
        schedule() // always queue the next one first

        let work = Task {
            await performOneShotRefresh()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// A stateless single poll usable outside the main polling loop. Unlike the
    /// foreground path it doesn't keep a regression buffer across launches, so
    /// burn rate is only carried forward from the last saved payload.
    static func performOneShotRefresh() async {
        // Poll the currently-selected account.
        let accounts = AccountStore.loadAccounts()
        guard let id = AccountStore.selectedID ?? accounts.first?.id,
              let tokens = TokenStore.load(for: id) else { return }
        let api = UsageAPI()
        do {
            let (usage, updated) = try await api.fetchUsage(tokens: tokens)
            if let updated { TokenStore.save(updated, for: id) }
            SharedStore.saveToken(updated ?? tokens)

            let previous = SharedStore.load()
            let accountName = accounts.first { $0.id == id }?.name ?? previous?.accountName ?? "Account"
            let payload = UsagePayload.from(usage: usage, previous: previous, accountName: accountName)
            SharedStore.save(payload)
            await LiveActivityController.shared.sync(with: payload)
        } catch {
            // Silent: a failed background poll just means stale (dimmed) widgets.
        }
    }
}
