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

    // MARK: - Services

    let accountManager = AccountManager()
    let oauthService = OAuthService()
    private let pollingService = UsagePollingService()
    private let databaseService = DatabaseService()
    private let notificationService = NotificationService()
    private let hookWatcher = HookFileWatcher()
    private let statsCacheService = StatsCacheService()
    private var cancellables = Set<AnyCancellable>()
    private var dbInitialized = false
    private var todayPeakSeen: Double = 0
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

    // MARK: - Lifecycle

    init() {
        setupBindings()
        initializeDatabase()
        notificationService.requestPermission()
        hookWatcher.startWatching()
        statsCacheService.startWatching()

        // Load accounts and start polling if we have any
        accountManager.load()
        setupAccountBindings()

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
        statsCacheService.stopWatching()
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
                self.statsCacheService.reload()
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
        }

        // Reconfigure polling with new account's tokens
        configurePollingForSelectedAccount()
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
        accountManager.removeAccount(id: id)

        if accountManager.hasAccounts {
            configurePollingForSelectedAccount()
            Task { await pollingService.pollNow() }
        } else {
            pollingService.stopPolling()
            needsLogin = true
            restoreState(AccountUsageState())
        }
    }

    func renameAccount(id: UUID, newName: String) {
        guard var account = accounts.first(where: { $0.id == id }) else { return }
        account.name = newName
        accountManager.updateAccount(account)
    }

    func removeAllAccounts() {
        accountUsageStates.removeAll()
        accountManager.removeAllAccounts()
        pollingService.stopPolling()
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
        guard let account = accountManager.selectedAccount else { return }
        let tokens = accountManager.getTokens(for: account.id)
        pollingService.configure(tokens: tokens) { [weak self] updatedTokens in
            guard let self = self, let account = self.accountManager.selectedAccount else { return }
            self.accountManager.saveTokens(updatedTokens, for: account.id)
        }
    }

    private func captureCurrentState() -> AccountUsageState {
        var state = AccountUsageState()
        state.sessionUtilization = sessionUtilization
        state.sessionResetsAt = sessionResetsAt
        state.weeklyUtilization = weeklyUtilization
        state.weeklyResetsAt = weeklyResetsAt
        state.sonnetUtilization = sonnetUtilization
        state.opusUtilization = opusUtilization
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
                await MainActor.run { dbInitialized = true }
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

        // Stats cache: streak, heatmap, sparkline, session count
        statsCacheService.$currentStreak
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentStreak)

        statsCacheService.$activeDays
            .receive(on: DispatchQueue.main)
            .sink { [weak self] days in
                guard let self = self else { return }
                self.activeDays = self.injectTodayActivity(into: days)
            }
            .store(in: &cancellables)

        statsCacheService.$dailyPeaks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peaks in
                guard let self = self else { return }
                self.dailyPeaks = self.injectTodayPeak(into: peaks)
            }
            .store(in: &cancellables)

        statsCacheService.$todaySessionCount
            .receive(on: DispatchQueue.main)
            .assign(to: &$todaySessionCount)
    }

    private func updateFromUsage(_ usage: UsageResponse) {
        guard !needsLogin else { return }
        sessionUtilization = usage.fiveHour?.utilization ?? 0
        sessionResetsAt = usage.fiveHour?.resetsAtDate
        weeklyUtilization = usage.sevenDay.utilization
        weeklyResetsAt = usage.sevenDay.resetsAtDate
        sonnetUtilization = usage.sevenDaySonnet?.utilization
        opusUtilization = usage.sevenDayOpus?.utilization
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
            todayPeakSeen = 0
            todayPeakDate = today
        }
        todayPeakSeen = max(todayPeakSeen, sessionUtilization)

        // Ensure today appears in heatmap and sparkline with live data
        activeDays = injectTodayActivity(into: activeDays)
        dailyPeaks = injectTodayPeak(into: dailyPeaks)

        // If stats are still empty after injection, try reloading stats-cache
        if activeDays.isEmpty && dailyPeaks.isEmpty {
            statsCacheService.reload()
        }

        refreshProjectTokenUsage()

        // Reset notification thresholds when utilization drops
        notificationService.resetThresholds(below: sessionUtilization)

        // Save snapshot and compute projections (only with active session)
        guard dbInitialized, usage.fiveHour != nil else { return }
        Task {
            await saveSnapshotAndProject(usage)
        }
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
            planTier: planTier.rawValue,
            accountId: selectedAccountId
        )

        do {
            try await databaseService.saveSnapshot(snapshot)
        } catch {
            print("Failed to save snapshot: \(error.localizedDescription)")
        }

        // Compute projections from recent snapshots
        do {
            let recentSnapshots = try await databaseService.getLatestSnapshots(count: 20, accountId: selectedAccountId)
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
        guard days[today] == nil, isConnected, todayPeakSeen > 0 else { return days }
        var merged = days
        merged[today] = todayPeakSeen
        return merged
    }

    private func injectTodayPeak(into peaks: [(date: Date, peak: Double)]) -> [(date: Date, peak: Double)] {
        let today = Calendar.current.startOfDay(for: Date())
        guard !peaks.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: today) }) else { return peaks }
        guard isConnected, todayPeakSeen > 0 else { return peaks }
        return peaks + [(date: today, peak: todayPeakSeen)]
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
        let statsCacheService = statsCacheService

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
                self.sessionProjectTokenUsage = sessionUsage
                self.weeklyProjectTokenUsage = weeklyUsage
            }
        }
    }
}
