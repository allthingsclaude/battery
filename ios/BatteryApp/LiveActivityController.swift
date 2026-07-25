import Foundation
#if os(iOS)
import ActivityKit
#endif

/// The "shown smartly when needed" brain.
///
/// A single call — `sync(with:)` — is made after every successful poll (foreground
/// or background). From the stream of payloads this controller decides, entirely
/// on-device, whether a Lock Screen Live Activity should **start**, **update**,
/// **escalate**, or **end**. The goal: the activity exists only while a session is
/// worth watching, and it gets out of the way the moment it isn't.
///
/// ── State machine ────────────────────────────────────────────────────────────
///
///   (no activity)
///        │  session active, or session ≥ START_THRESHOLD
///        ▼
///   ┌──────────┐  every poll → update ring / %, refresh live countdown
///   │  RUNNING │  crossing into High/Critical → one alerting update (banner)
///   └──────────┘
///        │  ├─ utilization collapses (was >30, now <10) → RESET card, dismiss ~30s
///        │  ├─ went idle & low for END_GRACE seconds       → end quietly
///        │  └─ past the session reset time                  → end quietly
///        ▼
///   (no activity)
///
/// Thresholds mirror the macOS `NotificationService` so phone + Mac agree on
/// what "worth surfacing" means.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private init() {}

    // Tunables (percent + seconds)
    private let startThreshold: Double = 40   // begin watching a climbing session
    private let endThreshold: Double = 25     // low enough to stop watching
    private let endGrace: TimeInterval = 10 * 60  // must stay idle+low this long to auto-end
    private let staleAfter: TimeInterval = 6 * 60 // dim the card if we can't refresh

    // Rolling state between calls
    private var previousUtilization: Double?
    private var alertedLevel: UsageLevel?
    private var idleSince: Date?

    /// Feed the latest payload; the controller reconciles the Live Activity to it.
    ///
    /// Respects the user's `LiveActivityMode`:
    ///   • `.off` — never show one (end any that's running).
    ///   • `.smart` — the state machine above (start hot, end idle/reset).
    ///   • `.alwaysOn` — keep it up for the whole session; skip the idle/reset
    ///     auto-end so it stays a permanent Lock Screen glance. Escalation alerts
    ///     still fire on High/Critical in every mode.
    func sync(with payload: UsagePayload) {
        #if os(iOS)
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let mode = LiveActivityMode.current
        let util = payload.sessionUtilization
        defer { previousUtilization = util }

        // The relay may only start an activity remotely when the user wants one.
        PushRelayClient.shared.setPushToStartAllowed(mode != .off)

        let existing = Activity<UsageActivityAttributes>.activities.first

        // Off — ensure nothing is running.
        if mode == .off {
            if let existing { Task { await end(existing) } }
            resetInternalState()
            return
        }

        let alwaysOn = mode == .alwaysOn

        // Session reset — a sharp collapse means the 5-hour window rolled over.
        // In Smart mode we show a reset card and dismiss; in Always On we just let
        // the ring drop to the new window's value without dismissing.
        let didReset = (previousUtilization ?? 0) > 30 && util < 10
        if didReset && !alwaysOn {
            if let existing { Task { await endWithReset(existing, payload: payload) } }
            resetInternalState()
            return
        }

        // Smart-only auto-end: past the reset time, or idle+low for a while.
        if !alwaysOn {
            let pastReset = payload.sessionResetsAt.map { $0 < Date() } ?? false
            let isIdleLow = !payload.isSessionActive && util < endThreshold
            idleSince = isIdleLow ? (idleSince ?? Date()) : nil
            let idledLongEnough = idleSince.map { Date().timeIntervalSince($0) >= endGrace } ?? false
            if let existing, pastReset || idledLongEnough {
                Task { await end(existing) }
                resetInternalState()
                return
            }
        } else {
            idleSince = nil
        }

        // Should one be running? Always On ⇒ yes; Smart ⇒ only when hot/active.
        let shouldRun = alwaysOn || payload.isSessionActive || util >= startThreshold
        guard shouldRun else {
            if let existing { Task { await end(existing) } }
            return
        }

        // Start or update.
        let state = contentState(from: payload, didReset: false)
        if let existing {
            let level = state.level
            // While a Mac is relaying, it owns escalation banners — it's awake at
            // the moments they matter, and one owner means no double-alerting.
            let crossedUp = level.isAlarming && level != alertedLevel
                && !PushRelayClient.shared.isPaired
            Task { await update(existing, state: state, alerting: crossedUp, level: level) }
            if crossedUp { alertedLevel = level }
        } else {
            start(attributes: attributes(from: payload), state: state)
            alertedLevel = state.level.isAlarming ? state.level : nil
        }
        #endif
    }

    /// Force-stop any running activity (e.g. on sign-out).
    func endAll() {
        #if os(iOS)
        guard #available(iOS 16.2, *) else { return }
        Task {
            for activity in Activity<UsageActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        resetInternalState()
        #endif
    }

    /// Re-attach a token observer to an activity that outlived the app process.
    /// After a relaunch the card is still on the Lock Screen, but nothing is
    /// streaming its (possibly rotated) token to the relay any more.
    func adoptExistingActivities() {
        #if os(iOS)
        guard #available(iOS 16.2, *), PushRelayClient.shared.isConfigured else { return }
        for activity in Activity<UsageActivityAttributes>.activities {
            observePushToken(of: activity)
        }
        #endif
    }

    // MARK: - Private

    private func resetInternalState() {
        alertedLevel = nil
        idleSince = nil
    }

    #if os(iOS)
    @available(iOS 16.2, *)
    private func attributes(from payload: UsagePayload) -> UsageActivityAttributes {
        UsageActivityAttributes(planTier: payload.planTier, accountName: payload.accountName)
    }

    @available(iOS 16.2, *)
    private func contentState(from payload: UsagePayload, didReset: Bool) -> UsageActivityAttributes.ContentState {
        UsageActivityAttributes.ContentState(
            sessionUtilization: payload.sessionUtilization,
            sessionResetsAt: payload.sessionResetsAt,
            weeklyUtilization: payload.weeklyUtilization,
            burnRatePerHour: payload.burnRatePerHour,
            projectedLimitAt: payload.liveProjectedLimitAt, // never push an expired projection
            isSessionActive: payload.isSessionActive,
            didReset: didReset,
            updatedAt: payload.updatedAt
        )
    }

    @available(iOS 16.2, *)
    private func relevance(for util: Double) -> Double { util } // 0–100; higher = more prominent

    @available(iOS 16.2, *)
    private func start(attributes: UsageActivityAttributes, state: UsageActivityAttributes.ContentState) {
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(staleAfter),
            relevanceScore: relevance(for: state.sessionUtilization)
        )
        do {
            // `.token` asks ActivityKit for an APNs token so the relay can keep
            // this card current while the app is suspended — the whole point of
            // the Mac→Worker→APNs path. Without a relay configured we ask for no
            // token at all, so a build with no push entitlement still works.
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: PushRelayClient.shared.isConfigured ? .token : nil
            )
            observePushToken(of: activity)
        } catch {
            print("Live Activity start failed: \(error.localizedDescription)")
        }
    }

    /// ActivityKit vends the update token asynchronously and rotates it during
    /// the activity's life, so this streams for as long as the activity exists.
    @available(iOS 16.2, *)
    private func observePushToken(of activity: Activity<UsageActivityAttributes>) {
        guard PushRelayClient.shared.isConfigured else { return }
        Task {
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.apnsHexToken
                await MainActor.run { PushRelayClient.shared.register(liveActivityToken: hex) }
            }
        }
    }


    @available(iOS 16.2, *)
    private func update(
        _ activity: Activity<UsageActivityAttributes>,
        state: UsageActivityAttributes.ContentState,
        alerting: Bool,
        level: UsageLevel
    ) async {
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(staleAfter),
            relevanceScore: relevance(for: state.sessionUtilization)
        )
        let alert: AlertConfiguration? = alerting ? AlertConfiguration(
            title: "Session usage \(level.label.lowercased())",
            body: "You're at \(Int(state.sessionUtilization.rounded()))% of your 5-hour limit.",
            sound: .default
        ) : nil
        await activity.update(content, alertConfiguration: alert)
    }

    @available(iOS 16.2, *)
    private func end(_ activity: Activity<UsageActivityAttributes>) async {
        await activity.end(nil, dismissalPolicy: .after(Date().addingTimeInterval(30)))
    }

    @available(iOS 16.2, *)
    private func endWithReset(_ activity: Activity<UsageActivityAttributes>, payload: UsagePayload) async {
        let state = contentState(from: payload, didReset: true)
        let content = ActivityContent(state: state, staleDate: nil, relevanceScore: 0)
        // Show the "reset" card briefly, then let the system dismiss it.
        await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(30)))
    }
    #endif
}
