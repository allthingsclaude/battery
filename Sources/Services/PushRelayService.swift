import Foundation
import Combine

/// The Mac's half of the iPhone Live Activity relay.
///
/// iOS suspends the Battery iPhone app, so a Live Activity it starts freezes on
/// the Lock Screen until the app runs again. This Mac already polls the usage
/// API every 60 seconds with the user's own credentials, so it's in a position
/// to keep that card current — it just needs a way to reach the phone.
///
/// That way is a small Cloudflare Worker (see `worker/`) which signs an APNs
/// token and forwards whatever we send it. **It never receives a Claude
/// credential**: we do the polling here and hand it only the already-computed
/// numbers plus a push key earned by pairing.
///
/// Pairing is one-directional and deliberately dumb: the phone shows a 6-digit
/// code, the user types it into Settings here, and we exchange it for a push key
/// stored at `~/.battery/push-relay.json` (0600).
@MainActor
final class PushRelayService: ObservableObject {

    /// True once a pairing code has been redeemed and we hold a push key.
    @Published private(set) var isPaired = false
    /// Timestamp of the last successful push — surfaced in Settings so a broken
    /// relay is visible rather than silently doing nothing.
    @Published private(set) var lastPushAt: Date?
    /// The phone has cloud updates switched on as a fallback for when this Mac
    /// isn't running. It does *not* mean we stop: an awake Mac is the better
    /// source — it polls on the user's own tokens at a faster cadence and costs
    /// the relay no upstream requests — so we stay primary and each push tells
    /// the relay to hold the cron off for a while.
    @Published private(set) var cloudEnabled = false
    @Published private(set) var lastError: String?
    @Published private(set) var isWorking = false

    /// One poll's worth of state, in the shape the Live Activity wants.
    struct Snapshot {
        var sessionUtilization: Double
        var sessionResetsAt: Date?
        var weeklyUtilization: Double
        var burnRatePerHour: Double
        var projectedLimitAt: Date?
        var isSessionActive: Bool
        var planTier: String
        var accountName: String
    }

    // MARK: - Tunables
    //
    // These govern how many pushes Apple sees. A Live Activity has a system
    // update budget even with NSSupportsLiveActivitiesFrequentUpdates declared,
    // so the rule is: push when the number the user is looking at would actually
    // change, and otherwise just often enough to stay un-dimmed.

    /// Don't push for movement smaller than this (percentage points).
    private let minimumDelta: Double = 1.0
    /// Floor between pushes, whatever else changed.
    private let minimumInterval: TimeInterval = 60
    /// Push even with nothing to say, so the card doesn't cross its stale date.
    private let heartbeatInterval: TimeInterval = 5 * 60
    /// Tells iOS to dim the card if we go quiet for this long.
    private let staleAfter: TimeInterval = 12 * 60
    /// Mirrors `LiveActivityController.startThreshold` on the phone — the phone
    /// owns this policy, and a remote start must not disagree with it.
    private let startThreshold: Double = 40

    // MARK: - State

    private let session: URLSession
    private var credentials: Credentials?
    private var lastSent: Snapshot?
    private var lastSentAt: Date?
    private var alertedLevel: UsageLevel?
    private var inFlight = false

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
        credentials = Self.loadCredentials()
        isPaired = credentials != nil
    }

    // MARK: - Pairing

    /// Redeem the 6-digit code shown on the phone.
    func pair(code rawCode: String) async {
        let code = rawCode.filter(\.isNumber)
        guard code.count == 6 else {
            lastError = "Enter the 6-digit code shown on your iPhone."
            return
        }
        guard let base = relayURL else {
            lastError = "No push relay is configured."
            return
        }

        isWorking = true
        defer { isWorking = false }

        struct ClaimResponse: Decodable { let deviceId: String; let pushKey: String }
        do {
            let response: ClaimResponse = try await post("/v1/pair/claim", to: base, body: ["code": code])
            guard let deviceId = UUID(uuidString: response.deviceId) else {
                lastError = "The relay returned an unexpected response."
                return
            }
            let creds = Credentials(deviceId: deviceId, pushKey: response.pushKey)
            guard Self.saveCredentials(creds) else {
                lastError = "Couldn't write ~/.battery/push-relay.json."
                return
            }
            credentials = creds
            isPaired = true
            lastError = nil
            // Reset the change gate so the newly paired phone gets a card
            // immediately rather than waiting for the next 1% move.
            lastSent = nil
            lastSentAt = nil
        } catch RelayError.status(404, _) {
            lastError = "That code has expired. Tap “Pair with Mac” on your iPhone for a new one."
        } catch {
            lastError = friendlyMessage(for: error)
        }
    }

    func unpair() async {
        guard let creds = credentials, let base = relayURL else {
            Self.deleteCredentials()
            credentials = nil
            isPaired = false
            return
        }
        isWorking = true
        defer { isWorking = false }

        struct OKResponse: Decodable { let ok: Bool }
        // Best-effort revoke; local state is cleared either way so the UI never
        // gets stuck claiming to be paired.
        _ = try? await post("/v1/unpair", to: base, body: [
            "deviceId": creds.deviceId.uuidString,
            "pushKey": creds.pushKey,
        ]) as OKResponse

        Self.deleteCredentials()
        credentials = nil
        isPaired = false
        lastPushAt = nil
        lastError = nil
        resetGate()
    }

    // MARK: - Pushing

    /// Called after every poll. Decides whether this snapshot is worth a push and
    /// sends it if so — the change-gating lives here, on the side that knows the
    /// previous value, which also keeps the relay itself free of per-push writes.
    func send(_ snapshot: Snapshot) {
        guard isPaired, credentials != nil, relayURL != nil, !inFlight else { return }

        let previous = lastSent
        let didReset = (previous?.sessionUtilization ?? 0) > 30 && snapshot.sessionUtilization < 10
        guard didReset || shouldPush(snapshot) else { return }

        // A collapse means the 5-hour window rolled over: close the card with a
        // brief "session reset" message, matching what the phone does locally.
        if didReset {
            deliver(snapshot, event: "end", didReset: true, alert: nil)
            resetGate()
            lastSent = snapshot
            lastSentAt = Date()
            return
        }

        let level = UsageLevel.from(utilization: snapshot.sessionUtilization)
        // Escalation banners are pushed from here rather than raised on the
        // phone, because the phone is usually asleep at the moment they matter.
        // `LiveActivityController` steps aside while we're paired.
        var alert: [String: Any]?
        if level.isAlarming && level != alertedLevel {
            alert = [
                "title": "Session usage \(level.label.lowercased())",
                "body": "You're at \(Int(snapshot.sessionUtilization.rounded()))% of your 5-hour limit.",
            ]
            alertedLevel = level
        } else if !level.isAlarming {
            alertedLevel = nil
        }

        deliver(snapshot, event: "update", didReset: false, alert: alert)
        lastSent = snapshot
        lastSentAt = Date()
    }

    private func shouldPush(_ snapshot: Snapshot) -> Bool {
        guard let previous = lastSent, let sentAt = lastSentAt else { return true }

        let elapsed = Date().timeIntervalSince(sentAt)
        guard elapsed >= minimumInterval else { return false }
        if elapsed >= heartbeatInterval { return true }

        if abs(snapshot.sessionUtilization - previous.sessionUtilization) >= minimumDelta { return true }
        if snapshot.isSessionActive != previous.isSessionActive { return true }
        if snapshot.sessionResetsAt != previous.sessionResetsAt { return true }
        return UsageLevel.from(utilization: snapshot.sessionUtilization)
            != UsageLevel.from(utilization: previous.sessionUtilization)
    }

    private func deliver(_ snapshot: Snapshot, event: String, didReset: Bool, alert: [String: Any]?) {
        guard let creds = credentials, let base = relayURL else { return }

        var body: [String: Any] = [
            "deviceId": creds.deviceId.uuidString,
            "pushKey": creds.pushKey,
            "event": event,
            "contentState": contentState(from: snapshot, didReset: didReset),
            "staleAfter": staleAfter,
            "relevanceScore": snapshot.sessionUtilization,
            // Nudge the phone awake so the Home Screen widgets reload too — the
            // ActivityKit push alone can't reach them.
            "reloadWidgets": true,
        ]
        if didReset { body["dismissAfter"] = 30 }
        if let alert { body["alert"] = alert }

        inFlight = true
        Task {
            defer { inFlight = false }
            struct PushResponse: Decodable {
                let ok: Bool
                let cloudEnabled: Bool?
            }
            do {
                let response = try await post("/v1/push", to: base, body: body) as PushResponse
                cloudEnabled = response.cloudEnabled ?? false
                lastPushAt = Date()
                lastError = nil
            } catch RelayError.status(409, let reason) where reason == "no_activity_token" {
                // No activity is running on the phone. If the session is worth
                // watching, ask the relay to start one (iOS 17.2+ push-to-start);
                // if the phone withheld its token — Live Activities off — this
                // fails harmlessly and we simply stay quiet.
                if event == "update" { await startRemotely(snapshot, base: base, creds: creds) }
            } catch RelayError.status(404, _) {
                // The relay forgot this device (or it was unpaired from the
                // phone). Stop pretending we're connected.
                Self.deleteCredentials()
                credentials = nil
                isPaired = false
                lastError = "Your iPhone unpaired. Pair again from Settings."
            } catch {
                lastError = friendlyMessage(for: error)
            }
        }
    }

    private func startRemotely(_ snapshot: Snapshot, base: URL, creds: Credentials) async {
        guard snapshot.isSessionActive || snapshot.sessionUtilization >= startThreshold else { return }

        struct PushResponse: Decodable { let ok: Bool }
        let body: [String: Any] = [
            "deviceId": creds.deviceId.uuidString,
            "pushKey": creds.pushKey,
            "event": "start",
            "contentState": contentState(from: snapshot, didReset: false),
            "attributes": [
                "planTier": snapshot.planTier,
                "accountName": snapshot.accountName,
            ],
            "staleAfter": staleAfter,
            "relevanceScore": snapshot.sessionUtilization,
        ]
        do {
            _ = try await post("/v1/push", to: base, body: body) as PushResponse
            lastPushAt = Date()
            lastError = nil
        } catch {
            // Expected on iOS < 17.2 and whenever the user has Live Activities
            // turned off — not worth surfacing.
        }
    }

    /// Must match `UsageActivityAttributes.ContentState` on iOS, which decodes
    /// dates as Unix epoch seconds.
    private func contentState(from snapshot: Snapshot, didReset: Bool) -> [String: Any] {
        var state: [String: Any] = [
            "sessionUtilization": snapshot.sessionUtilization,
            "weeklyUtilization": snapshot.weeklyUtilization,
            "burnRatePerHour": snapshot.burnRatePerHour,
            "isSessionActive": snapshot.isSessionActive,
            "didReset": didReset,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        if let resetsAt = snapshot.sessionResetsAt {
            state["sessionResetsAt"] = resetsAt.timeIntervalSince1970
        }
        // Only forward a projection that's still in the future; a stale one would
        // render as "hits limit in -3m".
        if let limit = snapshot.projectedLimitAt, limit > Date(), snapshot.burnRatePerHour > 0.05 {
            state["projectedLimitAt"] = limit.timeIntervalSince1970
        }
        return state
    }

    private func resetGate() {
        lastSent = nil
        lastSentAt = nil
        alertedLevel = nil
    }

    // MARK: - Networking

    enum RelayError: Error {
        case notConfigured
        case status(Int, String?)
        case malformedResponse
    }

    /// Whether a relay is configured at all. Released builds ship this blank —
    /// a shared relay can't work for anyone else, because its APNs key is bound
    /// to one Apple team — so self-hosters point it at their own Worker with:
    ///   defaults write com.allthingsclaude.battery pushRelayURL https://…
    var isConfigured: Bool { relayURL != nil }

    private var relayURL: URL? {
        let raw = (UserDefaults.standard.string(forKey: "pushRelayURL") ?? Constants.pushRelayURL)
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private func post<T: Decodable>(_ path: String, to base: URL, body: [String: Any]) async throws -> T {
        guard let url = URL(string: path, relativeTo: base) else { throw RelayError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Constants.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw RelayError.status(status, reason)
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw RelayError.malformedResponse
        }
        return decoded
    }

    private func friendlyMessage(for error: Error) -> String {
        if case RelayError.status(let code, let reason) = error {
            return "Relay error \(code)\(reason.map { " (\($0))" } ?? "")."
        }
        return "Couldn't reach the push relay."
    }

    // MARK: - Credential storage
    //
    // Same home and permissions as the OAuth tokens next door: the Mac app
    // deliberately avoids the Keychain to dodge repeated unlock prompts.

    private struct Credentials: Codable {
        let deviceId: UUID
        let pushKey: String
    }

    private static var credentialsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".battery")
            .appendingPathComponent("push-relay.json")
    }

    private static func loadCredentials() -> Credentials? {
        guard let data = try? Data(contentsOf: credentialsFile) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    private static func saveCredentials(_ credentials: Credentials) -> Bool {
        let fileManager = FileManager.default
        let file = credentialsFile
        do {
            try fileManager.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(credentials).write(to: file, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            print("Failed to save push relay credentials: \(error.localizedDescription)")
            return false
        }
    }

    private static func deleteCredentials() {
        try? FileManager.default.removeItem(at: credentialsFile)
    }
}
