import Foundation
import Security
#if os(iOS)
import UIKit
#endif

/// The phone's half of the push relay.
///
/// The relay exists to solve one problem: iOS suspends this app, so a Live
/// Activity started here freezes until the app runs again. The Mac app is
/// already polling Anthropic every 60 seconds with its own credentials, so it
/// can push the fresh numbers to APNs on our behalf — provided it knows which
/// device to push to.
///
/// This type owns that "which device": a locally-generated id and secret kept in
/// the Keychain, plus whatever push tokens iOS has vended so far. By default it
/// uploads **only push tokens** — never a Claude credential.
///
/// Cloud sync (`enableCloudSync`) is the one exception, and it's opt-in: it runs
/// a *separate* OAuth grant scoped to `user:profile` alone and hands the relay
/// that refresh token, so the relay can poll on a schedule when no Mac of yours
/// is awake. That grant reads usage but carries no `user:inference`, so it can't
/// make calls billed to the account, and revoking it doesn't sign this app out.
@MainActor
final class PushRelayClient: ObservableObject {
    static let shared = PushRelayClient()

    /// True once a Mac has redeemed a pairing code for this device.
    @Published private(set) var isPaired = false
    /// True while the relay is polling Anthropic for us on a schedule.
    @Published private(set) var isCloudPolling = false
    /// Non-nil while a pairing code is on screen waiting to be typed into the Mac.
    @Published private(set) var pairing: PairingCode?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    struct PairingCode: Equatable {
        let code: String
        let expiresAt: Date

        /// "483 920" — grouped so it's easy to read off one screen and type into
        /// another.
        var formatted: String {
            guard code.count == 6 else { return code }
            let mid = code.index(code.startIndex, offsetBy: 3)
            return "\(code[code.startIndex..<mid]) \(code[mid...])"
        }
    }

    private let session: URLSession
    private var identity: Identity?
    /// Last tokens we successfully uploaded, so a re-registration with unchanged
    /// tokens is a no-op. The relay's KV store allows far fewer writes than
    /// reads, and iOS re-vends the same token on every launch.
    private var uploaded: [String: String] = [:]
    /// Held back rather than uploaded when the user has Live Activities off.
    private var latestPushToStartToken: String?
    private var pushToStartAllowed = LiveActivityMode.current != .off

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: - Availability

    /// The relay is opt-in: with no base URL configured, every call below is a
    /// no-op and the app behaves exactly as it did before.
    var isConfigured: Bool { AppConfig.pushRelayURL != nil }

    // MARK: - Registration

    /// Upload whichever tokens iOS has given us. Safe to call often — unchanged
    /// tokens are dropped before they reach the network.
    func register(
        liveActivityToken: String? = nil,
        pushToStartToken: String? = nil,
        remoteToken: String? = nil
    ) {
        var fields: [String: String] = [:]
        if let liveActivityToken { fields["liveActivityToken"] = liveActivityToken }
        if let pushToStartToken { fields["pushToStartToken"] = pushToStartToken }
        if let remoteToken { fields["remoteToken"] = remoteToken }
        upload(setting: fields, clearing: [])
    }

    /// Remember the push-to-start token, but only publish it while the user
    /// actually wants Live Activities.
    func notePushToStartToken(_ hex: String) {
        latestPushToStartToken = hex
        syncPushToStartToken()
    }

    /// The relay can only *start* an activity remotely if we've given it a
    /// push-to-start token. Withholding that token is how the user's "Off"
    /// preference is enforced against a Mac that has no idea what it's set to —
    /// the policy stays on the device that owns it.
    func setPushToStartAllowed(_ allowed: Bool) {
        guard pushToStartAllowed != allowed else { return }
        pushToStartAllowed = allowed
        syncPushToStartToken()
    }

    private func syncPushToStartToken() {
        if pushToStartAllowed, let token = latestPushToStartToken {
            upload(setting: ["pushToStartToken": token], clearing: [])
        } else if uploaded["pushToStartToken"] != nil {
            upload(setting: [:], clearing: ["pushToStartToken"])
        }
    }

    private func upload(setting fields: [String: String], clearing cleared: [String]) {
        guard isConfigured else { return }
        let changed = fields.filter { uploaded[$0.key] != $0.value }
        guard !changed.isEmpty || !cleared.isEmpty else { return }

        Task {
            guard let identity = loadOrCreateIdentity() else { return }
            var body: [String: Any] = [
                "deviceId": identity.deviceId.uuidString,
                "deviceSecret": identity.secret,
                "env": Self.apnsEnvironment,
            ]
            for (key, value) in changed { body[key] = value }
            for key in cleared { body[key] = NSNull() }

            do {
                let response: RegisterResponse = try await post("/v1/device", body: body)
                uploaded.merge(changed) { _, new in new }
                for key in cleared { uploaded.removeValue(forKey: key) }
                isPaired = response.paired
                isCloudPolling = response.cloudPolling ?? isCloudPolling
                errorMessage = nil
            } catch {
                // Token registration is best-effort background housekeeping —
                // surfacing a failure here would be noise. The next launch, or
                // the next token rotation, retries.
            }
        }
    }

    /// Ask the relay for a code to display. The Mac types it in to pair.
    func requestPairingCode() async {
        guard isConfigured, let identity = loadOrCreateIdentity() else {
            errorMessage = "Push relay isn't configured in this build."
            return
        }
        isWorking = true
        defer { isWorking = false }

        do {
            pairing = try await mintPairingCode(identity)
            errorMessage = nil
        } catch RelayError.status(404, _) {
            // The relay has never seen this device, which happens whenever the
            // launch-time registration failed — offline, or push registration
            // hadn't completed yet. That's precisely the moment someone first
            // taps Pair, so register now and try once more rather than telling
            // them to go away and come back.
            do {
                try await ensureRegistered(identity)
                pairing = try await mintPairingCode(identity)
                errorMessage = nil
            } catch {
                errorMessage = friendlyMessage(for: error)
            }
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    private func mintPairingCode(_ identity: Identity) async throws -> PairingCode {
        let response: PairResponse = try await post("/v1/pair", body: [
            "deviceId": identity.deviceId.uuidString,
            "deviceSecret": identity.secret,
        ])
        return PairingCode(
            code: response.code,
            expiresAt: Date().addingTimeInterval(response.expiresIn)
        )
    }

    /// Create the device record, awaiting the result — unlike `upload`, which is
    /// fire-and-forget background housekeeping.
    private func ensureRegistered(_ identity: Identity) async throws {
        var body: [String: Any] = [
            "deviceId": identity.deviceId.uuidString,
            "deviceSecret": identity.secret,
            "env": Self.apnsEnvironment,
        ]
        // Include whatever tokens iOS has vended so far, so the freshly-created
        // record is immediately useful.
        for (key, value) in uploaded { body[key] = value }
        if pushToStartAllowed, let token = latestPushToStartToken {
            body["pushToStartToken"] = token
        }
        let response: RegisterResponse = try await post("/v1/device", body: body)
        isPaired = response.paired
        isCloudPolling = response.cloudPolling ?? isCloudPolling
    }

    func clearPairingCode() { pairing = nil }

    /// Revoke the Mac's push key. The device record (and its tokens) survives, so
    /// re-pairing later is just another code.
    func unpair() async {
        guard isConfigured, let identity = loadOrCreateIdentity() else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let _: OKResponse = try await post("/v1/unpair", body: [
                "deviceId": identity.deviceId.uuidString,
                "deviceSecret": identity.secret,
            ])
            isPaired = false
            pairing = nil
            errorMessage = nil
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    // MARK: - Cloud sync

    /// Hand the relay a narrow, separate grant so it can poll on a schedule.
    ///
    /// The `tokens` here come from a dedicated `user:profile`-only sign-in, not
    /// from the account the app uses. Two grants means the relay's token can be
    /// revoked on its own, and the two holders never fight over a rotated
    /// refresh token.
    func enableCloudSync(tokens: StoredTokens, planTier: String, accountName: String) async {
        guard isConfigured, let identity = loadOrCreateIdentity() else {
            errorMessage = "Push relay isn't configured in this build."
            return
        }
        guard let refreshToken = tokens.refreshToken else {
            errorMessage = "That sign-in didn't return a refresh token, so it can't be used here."
            return
        }
        isWorking = true
        defer { isWorking = false }

        do {
            let response: CloudResponse = try await post("/v1/cloud", body: [
                "deviceId": identity.deviceId.uuidString,
                "deviceSecret": identity.secret,
                "refreshToken": refreshToken,
                "planTier": planTier,
                "accountName": accountName,
            ])
            isCloudPolling = response.cloudPolling
            errorMessage = nil
        } catch RelayError.status(400, let reason) where reason == "grant_rejected" {
            errorMessage = "Claude rejected that sign-in. Try again."
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// Delete the stored grant. The user should also revoke it from their Claude
    /// account settings — this only stops us using it.
    func disableCloudSync() async {
        guard isConfigured, let identity = loadOrCreateIdentity() else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let response: CloudResponse = try await post("/v1/cloud", body: [
                "deviceId": identity.deviceId.uuidString,
                "deviceSecret": identity.secret,
                "enabled": false,
            ])
            isCloudPolling = response.cloudPolling
            errorMessage = nil
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// Refresh `isPaired` without changing anything — a registration with no
    /// token fields is effectively a status probe.
    func refreshStatus() async {
        guard isConfigured, let identity = loadOrCreateIdentity() else { return }
        do {
            let response: RegisterResponse = try await post("/v1/device", body: [
                "deviceId": identity.deviceId.uuidString,
                "deviceSecret": identity.secret,
                "env": Self.apnsEnvironment,
            ])
            isPaired = response.paired
            isCloudPolling = response.cloudPolling ?? isCloudPolling
        } catch {
            // Leave the last known value; a network blip isn't "unpaired".
        }
    }

    // MARK: - Networking

    private struct RegisterResponse: Decodable {
        let ok: Bool
        let paired: Bool
        let cloudPolling: Bool?
    }
    private struct PairResponse: Decodable { let code: String; let expiresIn: TimeInterval }
    private struct CloudResponse: Decodable { let ok: Bool; let cloudPolling: Bool }
    private struct OKResponse: Decodable { let ok: Bool }

    enum RelayError: Error {
        case notConfigured
        case status(Int, String?)
        case malformedResponse
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        guard let base = AppConfig.pushRelayURL, let url = URL(string: path, relativeTo: base) else {
            throw RelayError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw RelayError.status(code, reason)
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
        return "Couldn't reach the push relay. Check your connection."
    }

    /// Which APNs host issued this build's push tokens.
    ///
    /// Read from the embedded provisioning profile's `aps-environment`
    /// entitlement rather than inferred from the profile's mere presence — a
    /// TestFlight build ships a profile *and* uses production APNs, so
    /// presence alone reports the wrong host for every beta tester. The relay
    /// would recover through its own probe, but only after wasting a rejected
    /// round-trip per device.
    private static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        // No profile at all means App Store, which is always production.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              // The profile is CMS-signed binary with a plist embedded in it;
              // isoLatin1 round-trips arbitrary bytes so the range survives.
              let raw = String(data: data, encoding: .isoLatin1),
              let start = raw.range(of: "<?xml"),
              let end = raw.range(of: "</plist>"),
              let plistData = String(raw[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String
        else { return "production" }

        return environment == "development" ? "sandbox" : "production"
        #endif
    }

    // MARK: - Device identity (Keychain)

    private struct Identity: Codable {
        let deviceId: UUID
        let secret: String
    }

    private static let keychainAccount = "push-relay-identity"

    private func loadOrCreateIdentity() -> Identity? {
        if let identity { return identity }
        if let existing = readIdentity() {
            identity = existing
            return existing
        }
        let fresh = Identity(deviceId: UUID(), secret: Self.randomSecret())
        guard writeIdentity(fresh) else { return nil }
        identity = fresh
        return fresh
    }

    private static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        return Data(bytes).base64EncodedString()
    }

    private func readIdentity() -> Identity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let identity = try? JSONDecoder().decode(Identity.self, from: data)
        else { return nil }
        return identity
    }

    private func writeIdentity(_ identity: Identity) -> Bool {
        guard let data = try? JSONEncoder().encode(identity) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}

extension Data {
    /// APNs identifies devices by the lowercase hex of the raw token bytes.
    var apnsHexToken: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
