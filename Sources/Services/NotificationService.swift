import Foundation
import UserNotifications

/// Manages macOS native notifications for usage threshold alerts.
class NotificationService {
    private var notifiedThresholds: Set<Int> = []
    private var lastProjectionNotification: Date?
    private var lastResetNotification: Date?
    /// The last reading checked, and which window it was for. A switch between
    /// windows (Ultra verification landing or lapsing) is not a reset, however
    /// far the number moves.
    private var previousReading: (window: UsageWindow, utilization: Double)?
    private var lastCredentialNotification: Date?

    private let projectionDebounceInterval: TimeInterval = 1800  // 30 minutes
    private let thresholdDebounceInterval: TimeInterval = 3600   // 1 hour
    private let credentialDebounceInterval: TimeInterval = 3600  // 1 hour

    /// Track when each threshold was last notified to prevent spam
    private var thresholdNotifiedAt: [Int: Date] = [:]

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    /// - Parameters:
    ///   - window: The window that can stop work — the five-hour session, or
    ///     the weekly window for an account with no session limit.
    ///   - utilization: That window's utilization.
    ///   - resetsAt: When that window resets.
    func checkAndNotify(
        window: UsageWindow,
        utilization: Double,
        projection: BurnRateProjection? = nil,
        resetsAt: Date? = nil,
        settings: AppSettings = .shared
    ) {
        if let previous = previousReading, previous.window != window {
            // Thresholds crossed in one window say nothing about the other.
            notifiedThresholds.removeAll()
            thresholdNotifiedAt.removeAll()
            previousReading = nil
        }

        // Threshold-based notifications
        checkThresholds(window: window, utilization: utilization, settings: settings)

        // Projection-based notification: projected to hit limit within 30 min
        // Skip if the projected limit is after the window resets (usage resets first)
        if let projection = projection, let limitTime = projection.projectedLimitTime {
            let limitAfterReset = resetsAt.map { limitTime > $0 } ?? false
            let remaining = limitTime.timeIntervalSinceNow
            if remaining > 0 && remaining < 1800 && !limitAfterReset {
                if shouldSendProjectionNotification() {
                    sendNotification(
                        title: "Approaching Usage Limit",
                        body: "At current pace, you'll hit the \(Self.limitName(window)) in \(TimeFormatting.shortDuration(remaining))."
                    )
                    lastProjectionNotification = Date()
                }
            }
        }

        // Reset detection: utilization dropped significantly
        if let previous = previousReading?.utilization,
           previous > 30 && utilization < 10 {
            if shouldSendResetNotification() {
                sendNotification(
                    title: window == .session ? "Session Reset" : "Weekly Usage Reset",
                    body: "Your \(window == .session ? "5-hour session" : "weekly") usage has reset. You're back to \(Int(utilization.rounded()))%."
                )
                lastResetNotification = Date()
                // Clear notified thresholds on reset
                notifiedThresholds.removeAll()
                thresholdNotifiedAt.removeAll()
            }
        }

        previousReading = (window, utilization)
    }

    func notifyTokenRefreshFailure() {
        guard shouldSendCredentialNotification() else { return }
        sendNotification(
            title: "Credentials Need Attention",
            body: "Battery couldn't refresh your token. Please sign in again from Battery."
        )
        lastCredentialNotification = Date()
    }

    func resetThresholds(below utilization: Double) {
        let toRemove = notifiedThresholds.filter { Double($0) > utilization }
        for threshold in toRemove {
            notifiedThresholds.remove(threshold)
            thresholdNotifiedAt.removeValue(forKey: threshold)
        }
    }

    // MARK: - Private

    private func checkThresholds(window: UsageWindow, utilization: Double, settings: AppSettings) {
        let activeThresholds: [(Int, Bool)] = [
            (80, settings.notifyAt80),
            (90, settings.notifyAt90),
            (95, settings.notifyAt95),
        ]

        for (threshold, enabled) in activeThresholds {
            guard enabled else { continue }
            if utilization >= Double(threshold) && !notifiedThresholds.contains(threshold) {
                if shouldSendThresholdNotification(threshold) {
                    sendNotification(
                        title: "\(window == .session ? "Session" : "Weekly") Usage at \(threshold)%",
                        body: window == .session
                            ? "Your 5-hour Claude Code session is at \(Int(utilization.rounded()))% utilization."
                            : "Your weekly Claude usage is at \(Int(utilization.rounded()))% utilization."
                    )
                    notifiedThresholds.insert(threshold)
                    thresholdNotifiedAt[threshold] = Date()
                }
            }
        }
    }

    private static func limitName(_ window: UsageWindow) -> String {
        window == .session ? "session limit" : "weekly limit"
    }

    private func shouldSendThresholdNotification(_ threshold: Int) -> Bool {
        guard let lastNotified = thresholdNotifiedAt[threshold] else { return true }
        return Date().timeIntervalSince(lastNotified) >= thresholdDebounceInterval
    }

    private func shouldSendProjectionNotification() -> Bool {
        guard let last = lastProjectionNotification else { return true }
        return Date().timeIntervalSince(last) >= projectionDebounceInterval
    }

    private func shouldSendResetNotification() -> Bool {
        guard let last = lastResetNotification else { return true }
        return Date().timeIntervalSince(last) >= 300  // 5 min debounce for resets
    }

    private func shouldSendCredentialNotification() -> Bool {
        guard let last = lastCredentialNotification else { return true }
        return Date().timeIntervalSince(last) >= credentialDebounceInterval
    }

    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
