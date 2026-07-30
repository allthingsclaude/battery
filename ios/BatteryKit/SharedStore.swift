import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The bridge between the app process and its extensions.
///
/// The app writes the latest `UsagePayload` into the shared App Group container;
/// the widget and Live Activity read it back. The app also mirrors the selected
/// account's access token here so the **widget can self-refresh** (fetch on its
/// own WidgetKit schedule) without the app running.
///
/// Security note: the mirrored token lives in the App Group container — sandboxed
/// to this app + its extensions and protected by data protection (available after
/// first unlock), but less private than the Keychain. This is the trade-off for
/// widgets that update while the app is closed.
enum SharedStore {

    /// Must match the App Group capability added to BOTH targets in Xcode.
    static let appGroupID = "group.com.allthingsclaude.battery"

    private static let payloadKey = "latest_usage_payload"
    private static let tokenKey = "selected_account_token"
    private static let snapshotsKey = "session_snapshots"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: - Payload

    /// Persist the latest payload. `reloadWidgets` is false when the **widget
    /// itself** writes (it's already rebuilding — reloading would loop).
    static func save(_ payload: UsagePayload, reloadWidgets shouldReload: Bool = true) {
        guard let defaults, let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: payloadKey)
        if shouldReload { reloadWidgets() }
    }

    static func load() -> UsagePayload? {
        guard let defaults,
              let data = defaults.data(forKey: payloadKey),
              let payload = try? JSONDecoder().decode(UsagePayload.self, from: data)
        else { return nil }
        return payload
    }

    // MARK: - Burn-rate history
    //
    // Lives beside the payload rather than in the app's memory so the regression
    // survives a relaunch and — more importantly — so the *widget's* own fetch
    // contributes to it and reads from it. Previously each process kept its own
    // (or no) history, which is why a measured burn rate was so rarely available
    // that every surface fell back to an em dash.

    static func saveSnapshots(_ snapshots: [UsageSnapshot]) {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults.set(data, forKey: snapshotsKey)
    }

    static func loadSnapshots() -> [UsageSnapshot] {
        guard let defaults, let data = defaults.data(forKey: snapshotsKey),
              let snapshots = try? JSONDecoder().decode([UsageSnapshot].self, from: data)
        else { return [] }
        return snapshots
    }

    static func clearSnapshots() {
        defaults?.removeObject(forKey: snapshotsKey)
    }

    // MARK: - Mirrored token (for widget self-refresh)

    /// Mirror **only** the short-lived access token. The refresh token is a
    /// long-lived credential and the widget never refreshes (it only GETs), so it
    /// must never leave the Keychain — an unencrypted device backup would contain
    /// this plist verbatim.
    static func saveToken(_ tokens: StoredTokens?) {
        guard let defaults else { return }
        guard let tokens else {
            defaults.removeObject(forKey: tokenKey)
            return
        }
        let mirrored = StoredTokens(
            accessToken: tokens.accessToken,
            refreshToken: nil,
            expiresAt: tokens.expiresAt
        )
        guard let data = try? JSONEncoder().encode(mirrored) else { return }
        defaults.set(data, forKey: tokenKey)
    }

    static func loadToken() -> StoredTokens? {
        guard let defaults, let data = defaults.data(forKey: tokenKey) else { return nil }
        return try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    // MARK: - Clear

    static func clear() {
        defaults?.removeObject(forKey: payloadKey)
        defaults?.removeObject(forKey: tokenKey)
        defaults?.removeObject(forKey: snapshotsKey)
        reloadWidgets()
    }

    private static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
