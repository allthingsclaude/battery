import SwiftUI
import Combine

/// Main view model that coordinates all services and provides state to views.
@MainActor
class UsageViewModel: ObservableObject {
    // MARK: - Published State

    @Published var sessionUtilization: Double = 0
    @Published var sessionResetsAt: Date?
    @Published var weeklyUtilization: Double = 0
    @Published var weeklyResetsAt: Date?
    @Published var sonnetUtilization: Double?
    @Published var opusUtilization: Double?
    @Published var fableUtilization: Double?
    @Published var fableResetsAt: Date?
    @Published var extraUsageEnabled: Bool = false
    @Published var extraUsageCost: Double?
    @Published var extraUsageLimit: Double?
    @Published var extraUsageUtilization: Double?
    @Published var isConnected: Bool = false
    @Published var lastUpdated: Date?
    @Published var error: String?
    @Published var planTier: PlanTier = .unknown

    // Projections and history
    @Published var projection: BurnRateProjection?
    @Published var dailyPeaks: [(date: Date, peak: Double)] = []

    // Streaks and stats
    @Published var currentStreak: Int = 0
    @Published var activeDays: [Date: Double] = [:]
    @Published var todaySessionCount: Int = 0
    @Published var sessionProjectTokenUsage: [ProjectTokenUsage] = []
    @Published var weeklyProjectTokenUsage: [ProjectTokenUsage] = []

    // Hook-driven session awareness
    @Published var isSessionActive: Bool = false
    @Published var currentSessionStart: Date?

    // Multi-account state
    @Published var accounts: [Account] = []
    @Published var selectedAccountId: UUID?
    @Published var needsLogin: Bool = true
    /// Resolved Claude Code directory per account. Published so Settings can
    /// show each account's folder, and spot two accounts sharing one.
    @Published var accountConfigDirs: [UUID: String] = [:]

    // MARK: - Services

    let accountManager = AccountManager()
    let oauthService = OAuthService()
    /// Forwards each poll to a paired iPhone so its Lock Screen Live Activity
    /// stays current while that app is suspended. No-op until paired.
    let pushRelayService = PushRelayService()
    private let pollingService = UsagePollingService()
    private let databaseService = DatabaseService()
    private let notificationService = NotificationService()
    private let hookWatcher = HookFileWatcher()
    private let statsCacheRegistry = StatsCacheRegistry()
    private var cancellables = Set<AnyCancellable>()
    /// Held apart from `cancellables` because these are torn down and rebuilt
    /// every time the selected account changes directory.
    private var statsCancellables = Set<AnyCancellable>()
    private var dbInitialized = false
    /// Highest session utilization seen today, per account. Per-account because
    /// it is injected into that account's heat map, and one account's busy
    /// afternoon says nothing about another's.
    private var todayPeakSeen: [UUID: Double] = [:]
    private var todayPeakDate: Date = Calendar.current.startOfDay(for: Date())
    private var isReauthenticating = false
    private var projectTokenUsageTask: Task<Void, Never>?
    private var lastProjectTokenUsageRefresh: Date?
    private var lastProjectTokenUsageSessionReset: Date?
    private var lastProjectTokenUsageWeeklyReset: Date?
    private let projectTokenUsageRefreshInterval: TimeInterval = 5 * 60

    // Per-account usage state cache
    private var accountUsageStates: [UUID: AccountUsageState] = [:]

    // MARK: - Computed Properties

    var sessionTimeRemaining: TimeInterval {
        guard let resetsAt = sessionResetsAt else { return 0 }
        return max(0, resetsAt.timeIntervalSinceNow)
    }

    var weeklyTimeRemaining: TimeInterval {
        guard let resetsAt = weeklyResetsAt else { return 0 }
        return max(0, resetsAt.timeIntervalSinceNow)
    }

    var sessionColor: Color {
        UsageLevel.from(utilization: sessionUtilization).color
    }

    var weeklyColor: Color {
        UsageLevel.from(utilization: weeklyUtilization).color
    }

    var menuBarText: String { menuBarText(at: Date()) }

    func menuBarText(at now: Date) -> String {
        let settings = AppSettings.shared
        guard settings.showMenuBarText else { return "" }

        let pct = settings.displayPercentage(for: sessionUtilization)

        let time: String
        if let resetsAt = sessionResetsAt {
            let remaining = max(0, resetsAt.timeIntervalSince(now))
            if settings.showTimeSinceReset {
                // 5-hour window: time since reset = 5h - time remaining
                time = TimeFormatting.shortDuration(max(0, 18000 - remaining))
            } else {
                time = TimeFormatting.shortDuration(remaining)
            }
        } else {
            time = TimeFormatting.shortDuration(0)
        }

        switch settings.displayMode {
        case .percentageAndTime:
            return "\(pct)% · \(time)"
        case .percentageOnly:
            return "\(pct)%"
        case .timeOnly:
            return time
        case .iconOnly:
            return ""
        }
    }

    var menuBarSymbol: String {
        UsageLevel.from(utilization: sessionUtilization).sfSymbol
    }

    /// The account everything here is attributed to.
    ///
    /// Read from `accountManager` rather than the mirrored `@Published` copies:
    /// those arrive a run-loop hop later, so during `selectAccount` they still
    /// name the account being switched away from — and keying a peak or a stats
    /// refresh to that one is the very mix-up this is meant to end.
    private var activeAccountId: UUID? {
        accountManager.selectedAccount?.id
    }

    /// The Claude Code directory the selected account reads its history from.
    ///
    /// Served from the snapshot `bindStatsSource` maintains, so the file
    /// watcher's publishes do not each re-read the mapping from disk.
    private var activeConfigDir: String {
        guard let id = activeAccountId else { return ClaudeConfigDir.defaultDir }
        return accountConfigDirs[id] ?? ClaudeConfigDir.resolve(for: id)
    }

    /// Whether the local Claude Code history can stand in for the selected
    /// account's history.
    ///
    /// A configuration directory holds one interleaved transcript set with
    /// nothing recording which account ran a session, so a directory two
    /// accounts share describes both at once — which is why every account used
    /// to show the same streak, the same chart and the same project breakdown.
    /// Sole occupancy is exactly the condition that makes it attributable, and
    /// that history reaches back further than Battery's own, so where it holds
    /// it stays the better source.
    private var usesLocalStatsHistory: Bool {
        guard let id = activeAccountId else { return false }
        return ClaudeConfigDir.hasSoleClaim(id, among: accountConfigDirs)
    }

    /// Highest session utilization recorded today for the selected account.
    private var selectedTodayPeak: Double {
        guard let id = activeAccountId else { return 0 }
        return todayPeakSeen[id] ?? 0
    }

    // MARK: - Lifecycle

    init() {
        setupBindings()
        initializeDatabase()
        notificationService.requestPermission()
        hookWatcher.startWatching()

        // Load accounts and start polling if we have any
        accountManager.load()
        setupAccountBindings()
        // After `load`, so the first subscription is to the selected account's
        // directory rather than the default one.
        bindStatsSource()

        if accountManager.hasAccounts {
            needsLogin = false
            configurePollingForSelectedAccount()
            pollingService.startPolling()
        }
    }

    deinit {
        projectTokenUsageTask?.cancel()
        pollingService.stopPolling()
        hookWatcher.stopWatching()
    }

    func refresh() {
        Task {
            await pollingService.pollNow()
        }
    }

    // MARK: - Account Management

    func startOAuthLogin(completion: ((Bool) -> Void)? = nil) {
        oauthService.startLogin { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let tokenPair):
                let accountNumber = self.accounts.count + 1
                let account = Account(
                    name: "Account \(accountNumber)",
                    planTier: .unknown,
                    isDefault: self.accounts.isEmpty
                )
                let tokens = StoredTokens(
                    accessToken: tokenPair.accessToken,
                    refreshToken: tokenPair.refreshToken,
                    expiresIn: tokenPair.expiresIn
                )
                self.accountManager.addAccount(account, tokens: tokens)
                self.needsLogin = false
                // A second account landing in a directory is what makes its
                // history ambiguous, so the source may have just changed for
                // everyone pointing there.
                self.discardCachedHistory()
                self.bindStatsSource()
                self.refreshStats()
                self.configurePollingForSelectedAccount()

                if !self.pollingService.isPolling {
                    self.pollingService.startPolling()
                } else {
                    Task { await self.pollingService.pollNow() }
                }
                completion?(true)

            case .failure(let error):
                self.error = error.localizedDescription
                completion?(false)
            }
        }
    }

    func selectAccount(id: UUID) {
        guard id != selectedAccountId else { return }

        // Cache current account's state
        if let oldId = selectedAccountId {
            accountUsageStates[oldId] = captureCurrentState()
        }

        accountManager.selectAccount(id: id)

        // Restore cached state for new account (keep current view if no cache yet)
        if let cached = accountUsageStates[id] {
            withAnimation(.none) {
                restoreState(cached)
            }
        } else {
            // History is the one part that must not carry over: the outgoing
            // account's streak, chart and project list would read as this
            // account's until the refresh lands.
            clearDisplayedHistory()
            sessionProjectTokenUsage = []
            weeklyProjectTokenUsage = []
        }

        // Reconfigure polling with new account's tokens
        configurePollingForSelectedAccount()
        bindStatsSource()
        refreshStats()
        // The throttle is about sparing repeated scans of one directory, not
        // about withholding the incoming account's projects.
        invalidateProjectTokenUsage()
        Task { await pollingService.pollNow() }
    }

    /// Re-authenticate the current account (replaces tokens without creating a new account).
    func reauthenticateCurrentAccount() {
        attemptSilentReauth()
    }

    /// Silently re-authenticate the current account when the refresh token expires.
    /// Opens the browser OAuth flow. If the user completes it, tokens are replaced
    /// and polling resumes. If it fails, falls back to a notification.
    private func attemptSilentReauth() {
        guard !isReauthenticating else { return }
        guard let account = accountManager.selectedAccount else {
            notificationService.notifyTokenRefreshFailure()
            return
        }

        isReauthenticating = true
        error = "Session expired — signing in again…"

        oauthService.startLogin { [weak self] result in
            guard let self = self else { return }
            self.isReauthenticating = false

            switch result {
            case .success(let tokenPair):
                let tokens = StoredTokens(
                    accessToken: tokenPair.accessToken,
                    refreshToken: tokenPair.refreshToken,
                    expiresIn: tokenPair.expiresIn
                )
                self.accountManager.saveTokens(tokens, for: account.id)
                self.error = nil
                self.configurePollingForSelectedAccount()
                Task { await self.pollingService.pollNow() }

            case .failure:
                self.notificationService.notifyTokenRefreshFailure()
            }
        }
    }

    func removeAccount(id: UUID) {
        accountUsageStates.removeValue(forKey: id)
        todayPeakSeen.removeValue(forKey: id)
        // Otherwise a later sign-in reusing this id would inherit the folder.
        ClaudeConfigDir.clearDir(for: id)
        accountManager.removeAccount(id: id)

        if accountManager.hasAccounts {
            // Leaving a directory to a single account hands it back its local
            // history, so anything cached under the other source goes.
            discardCachedHistory()
            configurePollingForSelectedAccount()
            bindStatsSource()
            refreshStats()
            Task { await pollingService.pollNow() }
        } else {
            pollingService.stopPolling()
            statsCacheRegistry.retainOnly([])
            statsCancellables.removeAll()
            accountConfigDirs.removeAll()
            needsLogin = true
            restoreState(AccountUsageState())
        }
    }

    /// Point an account at a Claude Code directory, or pass nil to return it to
    /// the default `~/.claude`.
    ///
    /// Only affects where local history is read from. Credentials keep coming
    /// from wherever they came from before — Battery's own sign-in, unless the
    /// account is separately bridged via `~/.battery/live-creds.json`.
    func setConfigDir(_ dir: String?, for accountId: UUID) {
        do {
            try ClaudeConfigDir.setDir(dir, for: accountId)
        } catch {
            self.error = "Could not save the folder: \(error.localizedDescription)"
            return
        }

        // Adopt the identity the directory reports, so the account stops being
        // an anonymous "Account 2" and a later mismatch is detectable.
        if let dir = dir,
           let identity = ClaudeConfigDir.identity(in: dir),
           var account = accountManager.accounts.first(where: { $0.id == accountId }) {
            account.email = identity.email
            accountManager.updateAccount(account)
        }

        // Every account's attribution can change at once: a directory that two
        // accounts shared may now hold one, which hands it back its local
        // history.
        discardCachedHistory()
        bindStatsSource()
        refreshStats()
        invalidateProjectTokenUsage()
        if accountId == activeAccountId {
            sessionProjectTokenUsage = []
            weeklyProjectTokenUsage = []
        }
        refreshProjectTokenUsage()
    }

    /// What the folder reports about itself, for the picker to show before the
    /// choice is committed.
    func identity(forConfigDir dir: String) -> ClaudeAccountIdentity? {
        ClaudeConfigDir.identity(in: dir)
    }

    func renameAccount(id: UUID, newName: String) {
        guard var account = accounts.first(where: { $0.id == id }) else { return }
        account.name = newName
        accountManager.updateAccount(account)
    }

    func removeAllAccounts() {
        accountUsageStates.removeAll()
        todayPeakSeen.removeAll()
        for account in accountManager.accounts {
            ClaudeConfigDir.clearDir(for: account.id)
        }
        accountManager.removeAllAccounts()
        pollingService.stopPolling()
        statsCacheRegistry.retainOnly([])
        statsCancellables.removeAll()
        accountConfigDirs.removeAll()
        needsLogin = true
        restoreState(AccountUsageState())
    }

    // MARK: - Private: Account State

    private func setupAccountBindings() {
        accountManager.$accounts
            .receive(on: DispatchQueue.main)
            .assign(to: &$accounts)

        accountManager.$selectedAccountId
            .receive(on: DispatchQueue.main)
            .assign(to: &$selectedAccountId)

        pollingService.$needsReauth
            .receive(on: DispatchQueue.main)
            .sink { [weak self] needsReauth in
                guard let self = self, needsReauth else { return }
                self.attemptSilentReauth()
            }
            .store(in: &cancellables)
    }

    private func configurePollingForSelectedAccount() {
        guard accountManager.selectedAccount != nil else { return }
        pollingService.configure(tokenProvider: { [weak self] in
            guard let self = self, let account = self.accountManager.selectedAccount else { return .missing }
            return self.accountManager.tokenLookup(for: account.id)
        }, onTokensRefreshed: { [weak self] updatedTokens in
            guard let self = self, let account = self.accountManager.selectedAccount else { return false }
            return self.accountManager.saveTokens(updatedTokens, for: account.id)
        })
    }

    private func captureCurrentState() -> AccountUsageState {
        var state = AccountUsageState()
        state.sessionUtilization = sessionUtilization
        state.sessionResetsAt = sessionResetsAt
        state.weeklyUtilization = weeklyUtilization
        state.weeklyResetsAt = weeklyResetsAt
        state.sonnetUtilization = sonnetUtilization
        state.opusUtilization = opusUtilization
        state.fableUtilization = fableUtilization
        state.fableResetsAt = fableResetsAt
        state.extraUsageEnabled = extraUsageEnabled
        state.extraUsageCost = extraUsageCost
        state.extraUsageLimit = extraUsageLimit
        state.extraUsageUtilization = extraUsageUtilization
        state.isConnected = isConnected
        state.lastUpdated = lastUpdated
        state.error = error
        state.planTier = planTier
        state.projection = projection
        state.dailyPeaks = dailyPeaks
        state.currentStreak = currentStreak
        state.activeDays = activeDays
        state.todaySessionCount = todaySessionCount
        state.sessionProjectTokenUsage = sessionProjectTokenUsage
        state.weeklyProjectTokenUsage = weeklyProjectTokenUsage
        return state
    }

    private func restoreState(_ state: AccountUsageState) {
        sessionUtilization = state.sessionUtilization
        sessionResetsAt = state.sessionResetsAt
        weeklyUtilization = state.weeklyUtilization
        weeklyResetsAt = state.weeklyResetsAt
        sonnetUtilization = state.sonnetUtilization
        opusUtilization = state.opusUtilization
        fableUtilization = state.fableUtilization
        fableResetsAt = state.fableResetsAt
        extraUsageEnabled = state.extraUsageEnabled
        extraUsageCost = state.extraUsageCost
        extraUsageLimit = state.extraUsageLimit
        extraUsageUtilization = state.extraUsageUtilization
        isConnected = state.isConnected
        lastUpdated = state.lastUpdated
        error = state.error
        planTier = state.planTier
        projection = state.projection
        dailyPeaks = state.dailyPeaks
        currentStreak = state.currentStreak
        activeDays = state.activeDays
        todaySessionCount = state.todaySessionCount
        sessionProjectTokenUsage = state.sessionProjectTokenUsage
        weeklyProjectTokenUsage = state.weeklyProjectTokenUsage
    }

    // MARK: - Private: Database

    private func initializeDatabase() {
        Task {
            do {
                try await databaseService.initialize()
                await MainActor.run {
                    dbInitialized = true
                    // Multi-account history lives in this database, so it could
                    // not be read until now.
                    refreshStats()
                }
                // Prune old data
                let cutoff = Date().addingTimeInterval(-Double(Constants.dataRetentionDays) * 86400)
                try await databaseService.pruneOldData(olderThan: cutoff)
            } catch {
                print("Database init error: \(error.localizedDescription)")
            }
        }
    }

    private func setupBindings() {
        pollingService.$latestUsage
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] usage in
                self?.updateFromUsage(usage)
            }
            .store(in: &cancellables)

        pollingService.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.error = error?.localizedDescription
                // Only disconnect for non-transient errors (not rate limits)
                if error != nil {
                    let isRateLimit = (error as? AnthropicAPI.APIError).flatMap {
                        if case .rateLimited = $0 { return true }
                        return false
                    } ?? false
                    if !isRateLimit {
                        self?.isConnected = false
                    }
                }
            }
            .store(in: &cancellables)

        // Hook watcher: adjust polling rate based on session activity
        hookWatcher.$isSessionActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self = self else { return }
                self.isSessionActive = active
                let settings = AppSettings.shared
                let interval = active ? settings.pollIntervalActive : settings.pollIntervalIdle
                self.pollingService.setInterval(interval)
            }
            .store(in: &cancellables)

        hookWatcher.$currentSessionStart
            .receive(on: DispatchQueue.main)
            .sink { [weak self] start in
                self?.currentSessionStart = start
            }
            .store(in: &cancellables)

        // Forward settings changes so menu bar icon updates immediately
        AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Private: Stats Source

    /// The stats watcher for the selected account's directory, started on demand.
    private var currentStatsService: StatsCacheService {
        statsCacheRegistry.service(for: activeConfigDir)
    }

    /// Subscribe to the selected account's directory, dropping any previous
    /// subscription.
    ///
    /// Streak, heat map and sparkline only land while that directory belongs to
    /// this account alone; otherwise they are the shared numbers every account
    /// used to show, and `refreshAccountStats` supplies per-account ones from
    /// Battery's own snapshots instead. Today's session count is always taken
    /// from the directory — it describes the machine, not a plan.
    private func bindStatsSource() {
        statsCancellables.removeAll()
        // Resolved once and reused: each `resolve` reads the mapping files, and
        // both the snapshot and the retain set need the same answers.
        accountConfigDirs = Dictionary(
            uniqueKeysWithValues: accountManager.accounts.map { ($0.id, ClaudeConfigDir.resolve(for: $0.id)) }
        )

        // Watchers for directories nothing points at any more can stop.
        statsCacheRegistry.retainOnly(Set(accountConfigDirs.values))

        let service = currentStatsService

        service.$currentStreak
            .receive(on: DispatchQueue.main)
            .sink { [weak self] streak in
                guard let self = self, self.usesLocalStatsHistory else { return }
                self.currentStreak = streak
            }
            .store(in: &statsCancellables)

        service.$activeDays
            .receive(on: DispatchQueue.main)
            .sink { [weak self] days in
                guard let self = self, self.usesLocalStatsHistory else { return }
                self.activeDays = self.injectTodayActivity(into: days)
            }
            .store(in: &statsCancellables)

        service.$dailyPeaks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peaks in
                guard let self = self, self.usesLocalStatsHistory else { return }
                self.dailyPeaks = self.injectTodayPeak(into: peaks)
            }
            .store(in: &statsCancellables)

        service.$todaySessionCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.todaySessionCount = count
            }
            .store(in: &statsCancellables)
    }

    // MARK: - Private: Per-Account Stats

    /// Blank the history on screen, leaving utilization and reset times alone —
    /// those stay valid across a change of account or history source.
    private func clearDisplayedHistory() {
        currentStreak = 0
        activeDays = [:]
        dailyPeaks = []
    }

    /// Drop every streak, heat map and sparkline Battery is holding — on screen
    /// and in the per-account cache — because the source they came from no
    /// longer applies. Utilization and reset times are untouched; those stay
    /// valid across a change of history source.
    private func discardCachedHistory() {
        clearDisplayedHistory()
        for id in accountUsageStates.keys {
            accountUsageStates[id]?.currentStreak = 0
            accountUsageStates[id]?.activeDays = [:]
            accountUsageStates[id]?.dailyPeaks = []
        }
    }

    /// Repopulate streak, heat map and sparkline from whichever source currently
    /// applies to the selected account.
    private func refreshStats() {
        if usesLocalStatsHistory {
            currentStatsService.reload()
        } else {
            refreshAccountStats()
        }
    }

    /// Rebuild the selected account's streak, heat map and sparkline from the
    /// snapshots Battery recorded against that account.
    private func refreshAccountStats() {
        guard dbInitialized, !usesLocalStatsHistory, let accountId = activeAccountId else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // The streak reaches as far back as Battery has snapshots, not as far as
        // the heat map draws. Querying the heat-map window instead capped every
        // streak at `heatMapDays + 1`, so an account that had been used daily for
        // months sat frozen at 36 and could only ever move downwards from there.
        guard let windowStart = calendar.date(byAdding: .day, value: -Constants.dataRetentionDays, to: today) else { return }

        Task {
            do {
                let dayPeaks = try await databaseService.dailyPeakUtilization(
                    from: windowStart,
                    to: Date(),
                    accountId: accountId
                )
                let stats = AccountActivityStats.build(
                    dayPeaks: dayPeaks,
                    today: today,
                    calendar: calendar,
                    heatMapDays: Constants.heatMapDays
                )
                // A switch mid-flight would otherwise paint one account's history
                // under another's name, and a directory that became this
                // account's alone while the query ran has a better answer than
                // this one — the local reload racing it must win.
                guard activeAccountId == accountId, !usesLocalStatsHistory else { return }
                currentStreak = stats.currentStreak
                activeDays = injectTodayActivity(into: stats.activeDays)
                dailyPeaks = injectTodayPeak(into: stats.dailyPeaks)
            } catch {
                print("Failed to load account stats: \(error.localizedDescription)")
            }
        }
    }

    private func updateFromUsage(_ usage: UsageResponse) {
        guard !needsLogin else { return }
        sessionUtilization = usage.fiveHour?.utilization ?? 0
        sessionResetsAt = usage.fiveHour?.resetsAtDate
        weeklyUtilization = usage.sevenDay.utilization
        weeklyResetsAt = usage.sevenDay.resetsAtDate
        sonnetUtilization = usage.sevenDaySonnet?.utilization
        opusUtilization = usage.sevenDayOpus?.utilization
        fableUtilization = usage.fableUtilization
        fableResetsAt = usage.fableLimit?.resetsAtDate
        extraUsageEnabled = usage.extraUsage?.isEnabled ?? false
        extraUsageCost = usage.extraUsage?.usedCredits
        extraUsageLimit = usage.extraUsage?.monthlyLimit
        extraUsageUtilization = usage.extraUsage?.utilization
        isConnected = true
        lastUpdated = Date()
        error = nil

        // Clear projections when no active session
        if usage.fiveHour == nil {
            projection = nil
        }

        // Track today's peak utilization (survives session resets)
        let today = Calendar.current.startOfDay(for: Date())
        if today != todayPeakDate {
            todayPeakSeen.removeAll()
            todayPeakDate = today
        }
        if let accountId = activeAccountId {
            todayPeakSeen[accountId] = max(selectedTodayPeak, sessionUtilization)
        }

        // Ensure today appears in heatmap and sparkline with live data
        activeDays = injectTodayActivity(into: activeDays)
        dailyPeaks = injectTodayPeak(into: dailyPeaks)

        // If stats are still empty after injection, try the source again
        if activeDays.isEmpty && dailyPeaks.isEmpty {
            refreshStats()
        }

        refreshProjectTokenUsage()

        // Reset notification thresholds when utilization drops
        notificationService.resetThresholds(below: sessionUtilization)

        // Relay to a paired iPhone. Uses the projection from the previous poll —
        // it's a slow-moving estimate, and waiting for this poll's regression
        // would delay the Lock Screen by a full cycle.
        pushRelayService.send(pushSnapshot())

        // Save snapshot and compute projections (only with active session)
        guard dbInitialized, usage.fiveHour != nil else { return }
        Task {
            await saveSnapshotAndProject(usage)
        }
    }

    /// Current state in the shape the iPhone's Live Activity expects.
    private func pushSnapshot() -> PushRelayService.Snapshot {
        PushRelayService.Snapshot(
            sessionUtilization: sessionUtilization,
            sessionResetsAt: sessionResetsAt,
            weeklyUtilization: weeklyUtilization,
            burnRatePerHour: projection?.currentRate ?? 0,
            projectedLimitAt: projection?.projectedLimitTime,
            isSessionActive: isSessionActive,
            // The phone hides an unknown tier rather than guessing, so send an
            // empty string instead of the literal "Unknown".
            planTier: planTier == .unknown ? "" : planTier.displayName,
            accountName: accountManager.selectedAccount?.name ?? "Account"
        )
    }

    private func saveSnapshotAndProject(_ usage: UsageResponse) async {
        guard let fiveHour = usage.fiveHour else { return }

        // Save snapshot
        let snapshot = UsageSnapshot(
            sessionUtilization: fiveHour.utilization,
            sessionResetsAt: fiveHour.resetsAtDate ?? Date(),
            weeklyUtilization: usage.sevenDay.utilization,
            weeklyResetsAt: usage.sevenDay.resetsAtDate ?? Date(),
            sonnetUtilization: usage.sevenDaySonnet?.utilization,
            opusUtilization: usage.sevenDayOpus?.utilization,
            fableUtilization: usage.fableUtilization,
            planTier: planTier.rawValue,
            accountId: activeAccountId
        )

        do {
            try await databaseService.saveSnapshot(snapshot)
            // This snapshot is what marks today active for this account and sets
            // its peak, so the history is stale until it is read back.
            refreshAccountStats()
        } catch {
            print("Failed to save snapshot: \(error.localizedDescription)")
        }

        // Compute projections from recent snapshots
        do {
            let recentSnapshots = try await databaseService.getLatestSnapshots(count: 20, accountId: activeAccountId)
            guard let resetsAt = fiveHour.resetsAtDate else { return }

            let proj = BurnRateCalculator.calculate(
                snapshots: recentSnapshots,
                currentUtilization: fiveHour.utilization,
                resetsAt: resetsAt
            )

            await MainActor.run {
                self.projection = proj
            }

            // Check notifications with projection data
            await MainActor.run {
                self.notificationService.checkAndNotify(
                    sessionUtilization: fiveHour.utilization,
                    weeklyUtilization: usage.sevenDay.utilization,
                    projection: proj,
                    sessionResetsAt: fiveHour.resetsAtDate
                )
            }
        } catch {
            print("Failed to compute projections: \(error.localizedDescription)")
        }
    }

    // MARK: - Today Injection

    private func injectTodayActivity(into days: [Date: Double]) -> [Date: Double] {
        let today = Calendar.current.startOfDay(for: Date())
        let peak = selectedTodayPeak
        guard days[today] == nil, isConnected, peak > 0 else { return days }
        var merged = days
        merged[today] = peak
        return merged
    }

    private func injectTodayPeak(into peaks: [(date: Date, peak: Double)]) -> [(date: Date, peak: Double)] {
        let today = Calendar.current.startOfDay(for: Date())
        guard !peaks.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: today) }) else { return peaks }
        let peak = selectedTodayPeak
        guard isConnected, peak > 0 else { return peaks }
        return peaks + [(date: today, peak: peak)]
    }

    /// Drop the throttle so the next poll rescans, without clearing what is on
    /// screen — a restored per-account breakdown is the right thing to show
    /// until the fresh scan lands.
    private func invalidateProjectTokenUsage() {
        projectTokenUsageTask?.cancel()
        lastProjectTokenUsageRefresh = nil
    }

    private func refreshProjectTokenUsage() {
        let now = Date()
        let resetWindowChanged = sessionResetsAt != lastProjectTokenUsageSessionReset
            || weeklyResetsAt != lastProjectTokenUsageWeeklyReset
        if !resetWindowChanged,
           let lastProjectTokenUsageRefresh,
           now.timeIntervalSince(lastProjectTokenUsageRefresh) < projectTokenUsageRefreshInterval {
            return
        }

        lastProjectTokenUsageRefresh = now
        lastProjectTokenUsageSessionReset = sessionResetsAt
        lastProjectTokenUsageWeeklyReset = weeklyResetsAt

        let sessionStart = sessionResetsAt.map { $0.addingTimeInterval(-5 * 60 * 60) }
        let sessionEnd = sessionResetsAt.map { min($0, now) }
        let weeklyStart = weeklyResetsAt.map { $0.addingTimeInterval(-7 * 24 * 60 * 60) }
        let weeklyEnd = weeklyResetsAt.map { min($0, now) }
        // Scans this account's own directory, which is what finally separates
        // the project breakdown — a shared directory pools every account's
        // transcripts and can only ever produce one list.
        let statsCacheService = currentStatsService
        let scannedAccountId = activeAccountId

        projectTokenUsageTask?.cancel()
        projectTokenUsageTask = Task.detached(priority: .utility) { [weak statsCacheService] in
            guard let statsCacheService else { return }

            let sessionUsage: [ProjectTokenUsage]
            if let sessionStart, let sessionEnd, !Task.isCancelled {
                sessionUsage = statsCacheService.scanProjectTokenUsage(from: sessionStart, to: sessionEnd)
            } else {
                sessionUsage = []
            }

            let weeklyUsage: [ProjectTokenUsage]
            if let weeklyStart, let weeklyEnd, !Task.isCancelled {
                weeklyUsage = statsCacheService.scanProjectTokenUsage(from: weeklyStart, to: weeklyEnd)
            } else {
                weeklyUsage = []
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                // A switch mid-scan would otherwise list one account's projects
                // under another's name.
                guard self.activeAccountId == scannedAccountId else { return }
                self.sessionProjectTokenUsage = sessionUsage
                self.weeklyProjectTokenUsage = weeklyUsage
            }
        }
    }
}
