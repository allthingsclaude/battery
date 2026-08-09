import Foundation
import SwiftUI

/// Foreground polling + payload production, now multi-account aware.
///
/// Each poll uses the **selected** account's tokens; switching accounts re-polls
/// and repaints the widgets/Live Activity. Per-account tokens live in the
/// Keychain (`TokenStore`); the account list is metadata (`AccountStore`).
@MainActor
final class UsageService: ObservableObject {
    @Published private(set) var payload: UsagePayload?
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?

    // Multi-account state (drives the switcher UI directly).
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var selectedAccountID: UUID?

    #if DEBUG
    @Published private(set) var isDemoRunning = false
    private var demoTask: Task<Void, Never>?
    #endif

    private let api = UsageAPI()
    private var pollTask: Task<Void, Never>?

    // Activity inference (reset when the selected account changes). The burn-rate
    // history itself lives in the App Group — see `SessionHistory` — so the
    // background task and the widget's self-fetch contribute to the same buffer.
    private var lastRiseAt: Date?
    private var lastUtilization: Double?
    private let activeWindow: TimeInterval = 10 * 60

    var isSignedIn: Bool { !accounts.isEmpty }

    var selectedAccount: Account? {
        accounts.first { $0.id == selectedAccountID } ?? accounts.first
    }

    /// Whether to show the dashboard vs. the sign-in gate.
    var showsDashboard: Bool {
        #if DEBUG
        return isSignedIn || isDemoRunning
        #else
        return isSignedIn
        #endif
    }

    init() {
        loadAccounts()
        payload = SharedStore.load() // show last-known instantly on launch
    }

    // MARK: - Accounts

    private func loadAccounts() {
        accounts = AccountStore.loadAccounts()
        selectedAccountID = AccountStore.selectedID ?? accounts.first?.id

        // One-time migration: a pre-multi-account install kept a single token under
        // the legacy key. Adopt it as "Account 1" so the user isn't signed out.
        if accounts.isEmpty, let legacy = TokenStore.legacyLoad() {
            let account = Account(name: "Account 1")
            // Only drop the legacy item once the new one is provably readable —
            // otherwise a failed write would destroy the only copy of the grant.
            guard TokenStore.save(legacy, for: account.id),
                  TokenStore.load(for: account.id) != nil else { return }
            accounts = [account]
            selectedAccountID = account.id
            TokenStore.legacyClear()
            persistAccounts()
        }
    }

    private func persistAccounts() {
        AccountStore.saveAccounts(accounts)
        AccountStore.selectedID = selectedAccountID
    }

    /// Add a freshly-authenticated account and switch to it. Used for the first
    /// sign-in and every subsequent "Add Account".
    func addAccount(_ tokens: StoredTokens) {
        let account = Account(name: nextAccountName())
        // If the credential can't be stored, don't pretend the account exists —
        // it would look signed in while every poll returned early.
        guard TokenStore.save(tokens, for: account.id) else {
            errorMessage = "Couldn't save your sign-in to the Keychain. Please try again."
            return
        }
        accounts.append(account)
        selectedAccountID = account.id
        persistAccounts()
        resetInferenceState()
        payload = nil
        errorMessage = nil
        SharedStore.saveToken(nil) // drop any previous account's mirrored token
        if pollTask == nil { startPolling() } else { Task { await refresh() } }
    }

    /// "Account N" using the highest existing suffix, so removing #1 from
    /// [1, 2] doesn't produce a second "Account 2".
    private func nextAccountName() -> String {
        let used = accounts.compactMap { account -> Int? in
            guard account.name.hasPrefix("Account ") else { return nil }
            return Int(account.name.dropFirst("Account ".count))
        }
        return "Account \((used.max() ?? accounts.count) + 1)"
    }

    func selectAccount(_ id: UUID) {
        guard id != selectedAccountID, accounts.contains(where: { $0.id == id }) else { return }
        selectedAccountID = id
        persistAccounts()
        resetInferenceState()
        payload = nil
        // Purge immediately: until the new account's poll lands, no surface should
        // be able to keep using the previous account's credential or data.
        SharedStore.saveToken(nil)
        Task { await refresh() }
    }

    func renameAccount(_ id: UUID, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].name = name
        persistAccounts()
        if id == selectedAccountID { Task { await refresh() } } // repaint name in widgets/LA
    }

    func removeAccount(_ id: UUID) {
        TokenStore.delete(for: id)
        accounts.removeAll { $0.id == id }
        if selectedAccountID == id { selectedAccountID = accounts.first?.id }
        persistAccounts()
        // Purge the mirror now — if the next refresh fails, widgets must not keep
        // self-fetching with the removed account's token.
        SharedStore.saveToken(nil)

        if accounts.isEmpty {
            stopPolling()
            SharedStore.clear()
            LiveActivityController.shared.endAll()
            payload = nil
        } else {
            resetInferenceState()
            payload = nil
            Task { await refresh() }
        }
    }

    /// Remove every account (full sign-out).
    func signOutAll() {
        for account in accounts { TokenStore.delete(for: account.id) }
        accounts = []
        selectedAccountID = nil
        persistAccounts()
        stopPolling()
        SharedStore.clear()
        LiveActivityController.shared.endAll()
        payload = nil
    }

    private func resetInferenceState() {
        SessionHistory.reset()
        lastRiseAt = nil
        lastUtilization = nil
    }

    // MARK: - Polling

    func startPolling() {
        guard isSignedIn, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                let active = self.payload?.isSessionActive ?? false
                let interval = active ? AppConfig.foregroundActiveInterval : AppConfig.foregroundIdleInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Re-run the Live Activity state machine against the latest data — used when
    /// the user changes the Live Activity mode so it takes effect immediately.
    func reevaluateLiveActivity() {
        if let payload { LiveActivityController.shared.sync(with: payload) }
    }

    /// A single poll of the selected account.
    func refresh() async {
        guard let id = selectedAccountID else { return }
        guard let tokens = TokenStore.load(for: id) else {
            errorMessage = "Your saved sign-in is missing. Remove this account and add it again."
            return
        }
        guard !isRefreshing else { return } // pull-to-refresh during a poll
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let (usage, updated) = try await api.fetchUsage(tokens: tokens)
            // The account can change while the request is in flight — a late
            // response must never overwrite the newly-selected account's data,
            // name, or mirrored token.
            guard id == selectedAccountID else { return }

            if let updated { TokenStore.save(updated, for: id) }
            SharedStore.saveToken(updated ?? tokens) // mirror access token for widget self-refresh
            let built = buildPayload(from: usage, accountName: name(for: id))
            payload = built
            errorMessage = nil
            SharedStore.save(built)                 // reloads widgets
            LiveActivityController.shared.sync(with: built) // reconciles Lock Screen
        } catch {
            guard id == selectedAccountID else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // On `.unauthorized` this account's grant is dead — surfaced as an error;
            // the user can remove and re-add it from the Accounts screen.
        }
    }

    // MARK: - Payload construction

    private func name(for id: UUID) -> String {
        accounts.first { $0.id == id }?.name ?? "Account"
    }

    /// `accountName` is passed in (rather than read from `selectedAccount`) so a
    /// response can only ever be labelled with the account it was fetched for.
    private func buildPayload(from usage: UsageResponse, accountName: String) -> UsagePayload {
        let session = usage.fiveHour
        let sessionUtil = session?.utilization ?? 0
        let sessionReset = session?.resetsAtDate

        // Burn-rate projection, from the buffer shared with the widget and the
        // background task.
        let projection = SessionHistory.record(utilization: sessionUtil, resetsAt: sessionReset)

        // Activity inference: a session is "active" if utilization climbed recently.
        if let last = lastUtilization, sessionUtil > last + 0.01 { lastRiseAt = Date() }
        lastUtilization = sessionUtil
        let isActive = session != nil
            && (lastRiseAt.map { Date().timeIntervalSince($0) < activeWindow } ?? false)

        return UsagePayload(
            sessionUtilization: sessionUtil,
            sessionResetsAt: sessionReset,
            weeklyUtilization: usage.sevenDay.utilization,
            weeklyResetsAt: usage.sevenDay.resetsAtDate,
            opusUtilization: usage.sevenDayOpus?.utilization,
            fableUtilization: usage.fableUtilization,
            burnRatePerHour: projection.ratePerHour,
            projectedLimitAt: projection.limitAt,
            isSessionActive: isActive,
            planTier: usage.planDisplayName,
            accountName: accountName,
            isConnected: true,
            updatedAt: Date()
        )
    }

    // MARK: - Demo mode (DEBUG)

    #if DEBUG
    /// Testing aid: drives synthetic payloads so you can watch the full smart
    /// lifecycle — widgets refreshing, the Live Activity starting, escalating
    /// through High/Critical, then the reset card — without a live coding session
    /// or even signing in. Utilization climbs ~4%/tick, then rolls over.
    func toggleDemo() { isDemoRunning ? stopDemo() : startDemo() }

    private func startDemo() {
        stopPolling()
        isDemoRunning = true
        demoTask = Task { @MainActor in
            let sessionReset = Date().addingTimeInterval(2 * 3600 + 13 * 60)
            let weeklyReset = Date().addingTimeInterval(3 * 86400)
            var util = 38.0
            while !Task.isCancelled {
                util = util >= 96 ? 6 : util + 4
                let p = UsagePayload(
                    sessionUtilization: util,
                    sessionResetsAt: sessionReset,
                    weeklyUtilization: 63,
                    weeklyResetsAt: weeklyReset,
                    opusUtilization: 21,
                    fableUtilization: 34,
                    burnRatePerHour: 9.2,
                    projectedLimitAt: util > 55 ? Date().addingTimeInterval(40 * 60) : nil,
                    isSessionActive: util > 10,
                    planTier: "Max 5x",
                    accountName: "Demo",
                    isConnected: true,
                    updatedAt: Date()
                )
                payload = p
                SharedStore.save(p)
                LiveActivityController.shared.sync(with: p)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func stopDemo() {
        demoTask?.cancel()
        demoTask = nil
        isDemoRunning = false
        LiveActivityController.shared.endAll()
        SharedStore.clear()
    }
    #endif
}
