import Foundation
import Combine
import Darwin

/// Watches one Claude Code configuration directory's `stats-cache.json` for
/// changes and publishes streak, heatmap, sparkline, and session count data
/// derived from it.
///
/// Scoped to a directory rather than to `~/.claude` because that is what makes
/// the numbers belong to a single account — see `ClaudeConfigDir`. One instance
/// per directory, shared by every account pointing at it; `StatsCacheRegistry`
/// owns them.
class StatsCacheService: ObservableObject {
    @Published var currentStreak: Int = 0
    @Published var activeDays: [Date: Double] = [:]
    @Published var dailyPeaks: [(date: Date, peak: Double)] = []
    @Published var todaySessionCount: Int = 0

    private static let assistantTypeData = Data(#""type":"assistant""#.utf8)
    private static let usageData = Data(#""usage""#.utf8)
    private static let inputTokensData = Data(#""input_tokens":"#.utf8)
    private static let outputTokensData = Data(#""output_tokens":"#.utf8)
    private static let cacheCreationTokensData = Data(#""cache_creation_input_tokens":"#.utf8)
    private static let cacheReadTokensData = Data(#""cache_read_input_tokens":"#.utf8)

    /// The Claude Code configuration directory this instance reads.
    let configDir: String

    private let filePath: String
    private let projectsPath: String
    private let supplementPath: String
    private let historyPath: String
    private let userName: String
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    /// Every reload runs here, one at a time.
    ///
    /// The watcher and the refresh timer both sit on concurrent global queues,
    /// so their reloads could overlap and tear the `cachedToday*` fields below —
    /// a Swift Dictionary read concurrent with a write is undefined, not merely
    /// stale. Serializing also keeps the first scan off the main thread, which
    /// is where `startWatching` used to run it.
    private let reloadQueue = DispatchQueue(label: "com.allthingsclaude.battery.stats-reload", qos: .utility)
    private var fallbackTimer: Timer?
    private var refreshTimer: DispatchSourceTimer?

    /// Whether `history.jsonl` has been read this launch. Touched only from
    /// `reloadQueue`, which serializes every reload.
    private var hasReadHistoryFile = false

    // In-memory cache for today's live scan
    private var cachedTodayDate: String = ""
    private var cachedTodayFileModDates: [String: Date] = [:]
    private var cachedTodayActivity: StatsCache.DailyActivity?

    private struct ProjectTokenAccumulator {
        let name: String
        let path: String
        var tokens: Int
    }

    init(configDir: String = ClaudeConfigDir.defaultDir) {
        let normalized = ClaudeConfigDir.normalize(configDir)
        self.configDir = normalized
        self.filePath = ClaudeConfigDir.statsCacheFile(in: normalized)
        self.projectsPath = ClaudeConfigDir.projectsDir(in: normalized)
        self.supplementPath = ClaudeConfigDir.statsSupplementFile(for: normalized).path
        self.historyPath = ClaudeConfigDir.historyFile(in: normalized)
        self.userName = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
    }

    /// Releasing a dispatch source that was never cancelled traps, so a service
    /// dropped without `stopWatching` would take the app down with it.
    deinit {
        stopWatching()
    }

    func startWatching() {
        reload()
        startFileWatcher()
        startRefreshTimer()
    }

    func stopWatching() {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        refreshTimer?.cancel()
        refreshTimer = nil
    }

    // MARK: - File Watching

    private func startFileWatcher() {
        if FileManager.default.fileExists(atPath: filePath) {
            attachDispatchSource()
        } else {
            // File doesn't exist yet; poll until it appears
            startFallbackTimer()
        }
    }

    private func attachDispatchSource() {
        // Clean up any existing watcher
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
        fallbackTimer?.invalidate()
        fallbackTimer = nil

        fileDescriptor = open(filePath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            startFallbackTimer()
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )

        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File was replaced (atomic write); re-attach
                self.source?.cancel()
                self.source = nil
                close(self.fileDescriptor)
                self.fileDescriptor = -1
                // Small delay for the new file to appear
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                    self.reload()
                    self.attachDispatchSource()
                }
            } else {
                self.reload()
            }
        }

        src.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        self.source = src
        src.resume()
    }

    private func startFallbackTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.fallbackTimer?.invalidate()
            self?.fallbackTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if FileManager.default.fileExists(atPath: self.filePath) {
                    self.reload()
                    self.attachDispatchSource()
                }
            }
        }
    }

    private func startRefreshTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 600, repeating: 600)
        timer.setEventHandler { [weak self] in
            self?.reload()
        }
        self.refreshTimer = timer
        timer.resume()
    }

    // MARK: - Parsing

    /// Queue a reload. Results arrive on the published properties, so callers
    /// never needed this to finish before returning.
    func reload() {
        reloadQueue.async { [weak self] in
            self?.performReload()
        }
    }

    private func performReload() {
        guard let data = FileManager.default.contents(atPath: filePath) else { return }
        guard let cache = try? JSONDecoder().decode(StatsCache.self, from: data) else {
            print("StatsCacheService: Failed to decode stats-cache.json")
            return
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = calendar.timeZone

        // Parse daily activity into date-keyed data
        var parsed: [(date: Date, activity: StatsCache.DailyActivity)] = []
        for entry in cache.dailyActivity {
            if let d = dateFormatter.date(from: entry.date) {
                parsed.append((date: calendar.startOfDay(for: d), activity: entry))
            }
        }

        // Fill gap days from JSONL session files
        supplementFromJSONL(
            after: cache.lastComputedDate,
            into: &parsed,
            calendar: calendar,
            dateFormatter: dateFormatter
        )

        // Recover days neither source above can still see, from the one record
        // Claude Code does not prune. Once per launch is enough: the file only
        // grows, and now that every reload archives what it knows, a gap in
        // past days cannot open while the app is running.
        if !hasReadHistoryFile {
            hasReadHistoryFile = true
            supplementFromHistoryFile(into: &parsed, calendar: calendar, dateFormatter: dateFormatter)
        }

        // Write down everything now known about each day, while it is still
        // knowable. Both sources above forget: the cache window rolls forward
        // and the transcripts behind it are deleted, so a day not archived
        // during the weeks it is visible is gone for good — which is how a
        // streak that had been running for months kept shortening.
        archiveDailyActivity(
            parsed,
            lastComputedDate: cache.lastComputedDate,
            todayStr: dateFormatter.string(from: today),
            dateFormatter: dateFormatter,
            calendar: calendar
        )

        // --- Today's session count ---
        let todaySessions = parsed.first(where: { $0.date == today })?.activity.sessionCount ?? 0

        // --- Current streak (consecutive days backward from today/yesterday) ---
        let activeDateSet = Set(parsed.map(\.date))
        let streak: Int
        if activeDateSet.contains(today) {
            streak = countConsecutiveDays(from: today, activeDates: activeDateSet, calendar: calendar)
        } else {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            if activeDateSet.contains(yesterday) {
                streak = countConsecutiveDays(from: yesterday, activeDates: activeDateSet, calendar: calendar)
            } else {
                streak = 0
            }
        }

        // --- Active days (last 35 days, normalized by messageCount) ---
        let cutoff35 = calendar.date(byAdding: .day, value: -35, to: today)!
        let recentEntries = parsed.filter { $0.date >= cutoff35 }
        let maxMessages = recentEntries.map(\.activity.messageCount).max() ?? 1
        var days: [Date: Double] = [:]
        for entry in recentEntries {
            let normalized = Double(entry.activity.messageCount) / Double(max(maxMessages, 1)) * 100.0
            days[entry.date] = normalized
        }

        // --- Daily peaks (last 7 days, normalized by messageCount) ---
        let cutoff7 = calendar.date(byAdding: .day, value: -7, to: today)!
        let weekEntries = parsed.filter { $0.date >= cutoff7 }
        let weekByDate = Dictionary(weekEntries.map { ($0.date, $0.activity.messageCount) }, uniquingKeysWith: max)
        let maxWeekMessages = weekByDate.values.max() ?? 1
        var peaks: [(date: Date, peak: Double)] = []
        for dayOffset in -7...0 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let count = weekByDate[date] ?? 0
            let normalized = Double(count) / Double(max(maxWeekMessages, 1)) * 100.0
            peaks.append((date: date, peak: normalized))
        }

        DispatchQueue.main.async { [weak self] in
            self?.todaySessionCount = todaySessions
            self?.currentStreak = streak
            self?.activeDays = days
            self?.dailyPeaks = peaks
        }
    }

    // MARK: - Project Token Usage

    func scanProjectTokenUsage(from startDate: Date, to endDate: Date, limit: Int = 6) -> [ProjectTokenUsage] {
        guard startDate < endDate else { return [] }

        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsPath) else { return [] }

        var totals: [String: ProjectTokenAccumulator] = [:]

        for dir in projectDirs {
            if Task.isCancelled { return [] }
            let dirPath = (projectsPath as NSString).appendingPathComponent(dir)
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                if Task.isCancelled { return [] }
                let fullPath = (dirPath as NSString).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date,
                      modDate >= startDate else { continue }

                scanProjectTokensInJSONLFile(
                    path: fullPath,
                    projectDirectoryName: dir,
                    startDate: startDate,
                    endDate: endDate,
                    into: &totals
                )
            }
        }

        let totalTokens = totals.values.reduce(0) { $0 + $1.tokens }
        guard totalTokens > 0 else { return [] }

        let sortedTotals = totals
            .values
            .sorted { lhs, rhs in
                if lhs.tokens == rhs.tokens {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.tokens > rhs.tokens
            }

        guard sortedTotals.count > limit, limit > 1 else {
            return sortedTotals.prefix(limit).map {
                ProjectTokenUsage(
                    id: $0.path,
                    name: $0.name,
                    path: $0.path,
                    tokens: $0.tokens,
                    percentage: Double($0.tokens) / Double(totalTokens) * 100.0
                )
            }
        }

        let visibleCount = limit - 1
        let visible = sortedTotals.prefix(visibleCount).map {
            ProjectTokenUsage(
                id: $0.path,
                name: $0.name,
                path: $0.path,
                tokens: $0.tokens,
                percentage: Double($0.tokens) / Double(totalTokens) * 100.0
            )
        }
        let otherTokens = sortedTotals.dropFirst(visibleCount).reduce(0) { $0 + $1.tokens }
        let other = ProjectTokenUsage(
            id: "__other_projects__",
            name: "Other projects",
            path: "Other projects",
            tokens: otherTokens,
            percentage: Double(otherTokens) / Double(totalTokens) * 100.0
        )
        return visible + [other]
    }

    // MARK: - JSONL Supplement

    /// Battery's own archive of local daily activity, plus the date of the
    /// Claude Code cache it was last reconciled against.
    ///
    /// This is a record, not a cache. Neither source it draws from keeps
    /// history: `stats-cache.json` is a rolling 30-day window, and the
    /// transcripts its gaps are rebuilt from are deleted after
    /// `cleanupPeriodDays`. Anything older than that exists here or nowhere,
    /// which is why entries are merged in and never replaced.
    private struct PersistedSupplement: Codable {
        let lastComputedDate: String
        var days: [StatsCache.DailyActivity]
    }

    private func supplementFromJSONL(
        after lastComputedDate: String,
        into parsed: inout [(date: Date, activity: StatsCache.DailyActivity)],
        calendar: Calendar,
        dateFormatter: DateFormatter
    ) {
        let todayStr = dateFormatter.string(from: Date())
        let existingDates = Set(parsed.map { dateFormatter.string(from: $0.date) })

        // 1. Load archived past days, topped up from JSONL when a day is missing
        let sealedDays = loadOrComputeSealedDays(
            lastComputedDate: lastComputedDate,
            todayStr: todayStr,
            dateFormatter: dateFormatter,
            calendar: calendar
        )
        for activity in sealedDays where !existingDates.contains(activity.date) {
            if let d = dateFormatter.date(from: activity.date) {
                parsed.append((date: calendar.startOfDay(for: d), activity: activity))
            }
        }

        // 2. Live scan for today only
        guard !existingDates.contains(todayStr) else { return }
        if let todayActivity = scanTodayFromJSONL(todayStr: todayStr) {
            if let d = dateFormatter.date(from: todayStr) {
                parsed.append((date: calendar.startOfDay(for: d), activity: todayActivity))
            }
        }
    }

    // MARK: Prompt history (recovery source of last resort)

    private struct HistoryEntry: Decodable {
        let timestamp: Double?
        let sessionId: String?
    }

    private func supplementFromHistoryFile(
        into parsed: inout [(date: Date, activity: StatsCache.DailyActivity)],
        calendar: Calendar,
        dateFormatter: DateFormatter
    ) {
        guard let data = FileManager.default.contents(atPath: historyPath) else { return }
        let existingDates = Set(parsed.map { dateFormatter.string(from: $0.date) })
        for activity in Self.dailyActivityFromHistory(data, calendar: calendar)
        where !existingDates.contains(activity.date) {
            if let d = dateFormatter.date(from: activity.date) {
                parsed.append((date: calendar.startOfDay(for: d), activity: activity))
            }
        }
    }

    /// Which days a directory was used on, recovered from Claude Code's prompt
    /// history.
    ///
    /// This is the only record here that survives `cleanupPeriodDays`: one line
    /// per prompt, appended and never pruned, so it can still place a day whose
    /// transcript was deleted a month ago. Without it most gaps in Battery's
    /// history are phantom — days the account was plainly used, dropped because
    /// the only other evidence had been cleaned up, each one breaking a streak
    /// that should have run through it.
    ///
    /// `sessionCount` is exact, being the day's distinct session ids.
    /// `messageCount` is not comparable to the other sources — this counts
    /// prompts where they count assistant messages — so it stands as a floor
    /// that `mergeDailyActivity` lets a better-informed source raise.
    /// `toolCallCount` is unknowable from here and reported as zero.
    ///
    /// Lines are decoded as JSON rather than scanned for the two fields: a
    /// prompt that quotes `"timestamp":` — pasting JSON into Claude is hardly
    /// exotic — would otherwise be read as a day of its own.
    static func dailyActivityFromHistory(_ data: Data, calendar: Calendar) -> [StatsCache.DailyActivity] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = calendar.timeZone

        let decoder = JSONDecoder()
        var days: [String: (prompts: Int, sessions: Set<String>)] = [:]

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty,
                  let entry = try? decoder.decode(HistoryEntry.self, from: Data(line)),
                  let timestamp = entry.timestamp
            else { continue }

            // Claude Code writes milliseconds since the epoch.
            let key = dateFormatter.string(from: Date(timeIntervalSince1970: timestamp / 1000))
            var bucket = days[key] ?? (prompts: 0, sessions: [])
            bucket.prompts += 1
            if let sessionId = entry.sessionId { bucket.sessions.insert(sessionId) }
            days[key] = bucket
        }

        return days
            .map { date, counts in
                StatsCache.DailyActivity(
                    date: date,
                    messageCount: counts.prompts,
                    sessionCount: counts.sessions.count,
                    toolCallCount: 0
                )
            }
            .sorted { $0.date < $1.date }
    }

    // MARK: Archived days (persisted to ~/.battery/stats-supplement*.json)

    /// Past days the streak and heat map can be built from.
    ///
    /// Returns what the archive already holds, rescanning JSONL only when a day
    /// might be missing from it — when Claude Code has recomputed its cache, or
    /// when yesterday has not been recorded yet. The scan can only prove a day
    /// whose transcript still exists, so its result is merged into the archive
    /// rather than substituted for it; replacing was what made history erode
    /// from the back at the rate Claude Code prunes transcripts, and a streak
    /// snap down to the first hole that opened.
    private func loadOrComputeSealedDays(
        lastComputedDate: String,
        todayStr: String,
        dateFormatter: DateFormatter,
        calendar: Calendar
    ) -> [StatsCache.DailyActivity] {
        let stored = loadArchive()
        let storedDays = stored?.days ?? []

        let yesterdayStr: String? = {
            guard let today = dateFormatter.date(from: todayStr),
                  let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
            return dateFormatter.string(from: yesterday)
        }()
        // Yesterday is only Battery's to record when Claude Code's own cache
        // stops short of it.
        let needsYesterdaySeal = yesterdayStr != nil
            && yesterdayStr! > lastComputedDate
            && !storedDays.contains(where: { $0.date == yesterdayStr! })

        guard stored?.lastComputedDate != lastComputedDate || needsYesterdaySeal else {
            return storedDays.filter { $0.date < todayStr }
        }

        let scanned = scanSealedDaysFromJSONL(
            lastComputedDate: lastComputedDate,
            todayStr: todayStr,
            calendar: calendar
        )
        let earliest = earliestKeptDate(todayStr: todayStr, dateFormatter: dateFormatter, calendar: calendar)
        return Self.mergeDailyActivity(storedDays, scanned, earliestKept: earliest)
            .filter { $0.date < todayStr }
    }

    /// Rebuild past days from the transcripts still on disk.
    ///
    /// Only days after `lastComputedDate` are reported: everything at or before
    /// it is Claude Code's own cache to describe, and this cannot improve on it.
    private func scanSealedDaysFromJSONL(
        lastComputedDate: String,
        todayStr: String,
        calendar: Calendar
    ) -> [StatsCache.DailyActivity] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = calendar.timeZone
        guard let cutoffDate = dateFormatter.date(from: lastComputedDate) else { return [] }
        let cutoffStart = calendar.startOfDay(for: cutoffDate)

        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsPath) else { return [] }

        var dayCounts: [String: (messages: Int, toolCalls: Int, sessions: Set<String>)] = [:]

        for dir in projectDirs {
            let dirPath = (projectsPath as NSString).appendingPathComponent(dir)
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let fullPath = (dirPath as NSString).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }
                if modDate <= cutoffStart { continue }

                let sessionId = (file as NSString).deletingPathExtension
                scanJSONLFile(
                    path: fullPath,
                    cutoffDate: lastComputedDate,
                    onlyDate: nil,
                    excludeDate: todayStr,
                    sessionId: sessionId,
                    into: &dayCounts
                )
            }
        }

        return dayCounts.compactMap { dateStr, counts in
            guard dateStr < todayStr else { return nil }
            return StatsCache.DailyActivity(
                date: dateStr,
                messageCount: counts.messages,
                sessionCount: counts.sessions.count,
                toolCallCount: counts.toolCalls
            )
        }
    }

    /// Fold everything currently known about a day into the archive.
    ///
    /// Called on every reload with the assembled day set, so a day read out of
    /// Claude Code's rolling window is written down while it is still there —
    /// without this the archive only ever learned days Claude Code had already
    /// stopped reporting, and everything the window dropped went with it.
    ///
    /// Today is archived too, at whatever it has reached so far. Merging takes
    /// the higher counts, so later reloads carry it up as the day goes on, and
    /// tomorrow finds it already recorded even if its transcript is gone by
    /// then.
    private func archiveDailyActivity(
        _ parsed: [(date: Date, activity: StatsCache.DailyActivity)],
        lastComputedDate: String,
        todayStr: String,
        dateFormatter: DateFormatter,
        calendar: Calendar
    ) {
        let stored = loadArchive()
        let merged = Self.mergeDailyActivity(
            stored?.days ?? [],
            parsed.map(\.activity),
            earliestKept: earliestKeptDate(todayStr: todayStr, dateFormatter: dateFormatter, calendar: calendar)
        )

        // Rewriting an unchanged file on every reload would churn the disk and
        // retrigger the watchers of anything observing it.
        if let stored = stored, stored.lastComputedDate == lastComputedDate, stored.days == merged { return }
        writeArchive(PersistedSupplement(lastComputedDate: lastComputedDate, days: merged))
    }

    /// The oldest day the archive keeps, as a `yyyy-MM-dd` string.
    private func earliestKeptDate(todayStr: String, dateFormatter: DateFormatter, calendar: Calendar) -> String {
        guard let today = dateFormatter.date(from: todayStr),
              let earliest = calendar.date(byAdding: .day, value: -Constants.localHistoryRetentionDays, to: today)
        else { return "" }
        return dateFormatter.string(from: earliest)
    }

    /// Combine day sets into one, keyed by date, keeping the fullest account of
    /// each day and dropping anything past the retention window.
    ///
    /// Conflicts resolve to the higher counts in every field. A day can
    /// legitimately grow after the fact — a session resumed the next morning
    /// adds messages to the day before — while a rescan of a partially deleted
    /// transcript can only undercount, and the archive must not follow that
    /// down.
    ///
    /// Pure and static so the merge rule is testable without a filesystem.
    static func mergeDailyActivity(
        _ archived: [StatsCache.DailyActivity],
        _ incoming: [StatsCache.DailyActivity],
        earliestKept: String
    ) -> [StatsCache.DailyActivity] {
        var byDate: [String: StatsCache.DailyActivity] = [:]
        for day in archived + incoming where day.date >= earliestKept {
            guard let existing = byDate[day.date] else {
                byDate[day.date] = day
                continue
            }
            byDate[day.date] = StatsCache.DailyActivity(
                date: day.date,
                messageCount: max(existing.messageCount, day.messageCount),
                sessionCount: max(existing.sessionCount, day.sessionCount),
                toolCallCount: max(existing.toolCallCount, day.toolCallCount)
            )
        }
        return byDate.values.sorted { $0.date < $1.date }
    }

    private func loadArchive() -> PersistedSupplement? {
        guard let data = FileManager.default.contents(atPath: supplementPath) else { return nil }
        return try? JSONDecoder().decode(PersistedSupplement.self, from: data)
    }

    private func writeArchive(_ archive: PersistedSupplement) {
        guard let encoded = try? JSONEncoder().encode(archive) else { return }
        let fm = FileManager.default
        let dir = (supplementPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        fm.createFile(atPath: supplementPath, contents: encoded)
    }

    // MARK: Today (live scan, cached in memory by file mod dates)

    private func scanTodayFromJSONL(todayStr: String) -> StatsCache.DailyActivity? {
        let fm = FileManager.default
        let todayStart = Calendar.current.startOfDay(for: Date())
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsPath) else { return nil }

        // Collect JSONL files modified today
        var currentModDates: [String: Date] = [:]
        var jsonlFiles: [String] = []

        for dir in projectDirs {
            let dirPath = (projectsPath as NSString).appendingPathComponent(dir)
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let fullPath = (dirPath as NSString).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }
                if modDate < todayStart { continue }
                currentModDates[fullPath] = modDate
                jsonlFiles.append(fullPath)
            }
        }

        // Reuse cached result if no files changed
        if todayStr == cachedTodayDate,
           currentModDates == cachedTodayFileModDates,
           let cached = cachedTodayActivity {
            return cached
        }

        // Scan only today's entries — use yesterday as cutoff so dateStr > yesterday includes today
        let calendar = Calendar.current
        let yesterdayStr: String = {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.timeZone = calendar.timeZone
            return df.string(from: yesterday)
        }()

        var dayCounts: [String: (messages: Int, toolCalls: Int, sessions: Set<String>)] = [:]

        for fullPath in jsonlFiles {
            let sessionId = ((fullPath as NSString).lastPathComponent as NSString).deletingPathExtension
            scanJSONLFile(
                path: fullPath,
                cutoffDate: yesterdayStr,
                onlyDate: todayStr,
                excludeDate: nil,
                sessionId: sessionId,
                into: &dayCounts
            )
        }

        let activity: StatsCache.DailyActivity? = dayCounts[todayStr].map {
            StatsCache.DailyActivity(
                date: todayStr,
                messageCount: $0.messages,
                sessionCount: $0.sessions.count,
                toolCallCount: $0.toolCalls
            )
        }

        cachedTodayDate = todayStr
        cachedTodayFileModDates = currentModDates
        cachedTodayActivity = activity
        return activity
    }

    // MARK: JSONL file scanner

    private func scanJSONLFile(
        path: String,
        cutoffDate: String,
        onlyDate: String?,
        excludeDate: String?,
        sessionId: String,
        into dayCounts: inout [String: (messages: Int, toolCalls: Int, sessions: Set<String>)]
    ) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { fh.closeFile() }

        let bufferSize = 64 * 1024
        var leftover = Data()

        while true {
            let chunk = fh.readData(ofLength: bufferSize)
            if chunk.isEmpty && leftover.isEmpty { break }

            var working = leftover
            working.append(chunk)
            leftover = Data()

            while let newlineIndex = working.firstIndex(of: UInt8(0x0A)) {
                let lineData = working[working.startIndex..<newlineIndex]
                working = working[working.index(after: newlineIndex)...]
                if lineData.isEmpty { continue }
                processJSONLLine(lineData, cutoffDate: cutoffDate, onlyDate: onlyDate, excludeDate: excludeDate, sessionId: sessionId, into: &dayCounts)
            }

            if chunk.isEmpty {
                if !working.isEmpty {
                    processJSONLLine(working, cutoffDate: cutoffDate, onlyDate: onlyDate, excludeDate: excludeDate, sessionId: sessionId, into: &dayCounts)
                }
                break
            }
            leftover = Data(working)
        }
    }

    private func processJSONLLine(
        _ lineData: Data,
        cutoffDate: String,
        onlyDate: String?,
        excludeDate: String?,
        sessionId: String,
        into dayCounts: inout [String: (messages: Int, toolCalls: Int, sessions: Set<String>)]
    ) {
        // Lightweight field extraction — avoid full JSON parse for potentially multi-MB lines.
        // The top-level "type":"assistant" can appear at byte 700-1400 (after nested content types),
        // so we search for exact strings within the first 2KB.
        let searchLimit = min(lineData.count, 2048)
        let searchData = lineData[lineData.startIndex..<lineData.index(lineData.startIndex, offsetBy: searchLimit)]
        guard let searchStr = String(data: searchData, encoding: .utf8) else { return }

        let isUser = searchStr.contains("\"type\":\"user\"")
        let isAssistant = !isUser && searchStr.contains("\"type\":\"assistant\"")
        guard isUser || isAssistant else { return }

        guard let tsRange = searchStr.range(of: "\"timestamp\":\"") else { return }
        let tsStart = tsRange.upperBound
        let tsEndOffset = searchStr.index(tsStart, offsetBy: 10, limitedBy: searchStr.endIndex) ?? searchStr.endIndex
        let dateStr = String(searchStr[tsStart..<tsEndOffset])
        guard dateStr.count == 10, dateStr > cutoffDate else { return }

        if let only = onlyDate, dateStr != only { return }
        if let exclude = excludeDate, dateStr == exclude { return }

        var entry = dayCounts[dateStr] ?? (messages: 0, toolCalls: 0, sessions: Set<String>())
        entry.messages += 1
        entry.sessions.insert(sessionId)

        if isAssistant {
            if let fullLine = String(data: lineData, encoding: .utf8) {
                var searchFrom = fullLine.startIndex
                while let range = fullLine.range(of: "\"type\":\"tool_use\"", range: searchFrom..<fullLine.endIndex) {
                    entry.toolCalls += 1
                    searchFrom = range.upperBound
                }
            }
        }

        dayCounts[dateStr] = entry
    }

    private func scanProjectTokensInJSONLFile(
        path: String,
        projectDirectoryName: String,
        startDate: Date,
        endDate: Date,
        into totals: inout [String: ProjectTokenAccumulator]
    ) {
        guard let file = fopen(path, "r") else { return }
        defer { fclose(file) }

        let parser = TimestampParser()
        let startTimestamp = parser.string(from: startDate)
        let endTimestamp = parser.string(from: endDate)

        var linePointer: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(linePointer) }

        while getline(&linePointer, &capacity, file) > 0 {
            if Task.isCancelled { return }
            guard let linePointer else { continue }

            let length = strlen(linePointer)
            guard length > 0 else { continue }
            let lineLength = linePointer[length - 1] == UInt8(ascii: "\n") ? length - 1 : length
            guard lineLength > 0 else { continue }

            let lineData = Data(
                bytesNoCopy: UnsafeMutableRawPointer(linePointer),
                count: lineLength,
                deallocator: .none
            )
            processProjectTokenLine(
                lineData,
                projectDirectoryName: projectDirectoryName,
                startDate: startDate,
                endDate: endDate,
                startTimestamp: startTimestamp,
                endTimestamp: endTimestamp,
                timestampParser: parser,
                into: &totals
            )
        }
    }

    private func processProjectTokenLine(
        _ lineData: Data,
        projectDirectoryName: String,
        startDate: Date,
        endDate: Date,
        startTimestamp: String,
        endTimestamp: String,
        timestampParser: TimestampParser,
        into totals: inout [String: ProjectTokenAccumulator]
    ) {
        guard lineData.range(of: Self.assistantTypeData) != nil,
              lineData.range(of: Self.usageData) != nil else { return }
        guard let timestamp = extractJSONStringValue("timestamp", from: lineData),
              timestampIsInRange(
                timestamp,
                startDate: startDate,
                endDate: endDate,
                startTimestamp: startTimestamp,
                endTimestamp: endTimestamp,
                parser: timestampParser
              ),
              let tokenCount = tokenCount(from: lineData),
              tokenCount > 0 else { return }

        let project = projectIdentity(cwd: extractJSONStringValue("cwd", from: lineData), projectDirectoryName: projectDirectoryName)
        var entry = totals[project.path] ?? ProjectTokenAccumulator(name: project.name, path: project.path, tokens: 0)
        entry.tokens += tokenCount
        totals[project.path] = entry
    }

    private func timestampIsInRange(
        _ timestamp: String,
        startDate: Date,
        endDate: Date,
        startTimestamp: String,
        endTimestamp: String,
        parser: TimestampParser
    ) -> Bool {
        if timestamp.hasSuffix("Z") {
            return timestamp >= startTimestamp && timestamp <= endTimestamp
        }

        guard let date = parser.date(from: timestamp) else { return false }
        return date >= startDate && date <= endDate
    }

    private func tokenCount(from lineData: Data) -> Int? {
        let total =
            extractJSONIntValue(Self.inputTokensData, from: lineData)
            + extractJSONIntValue(Self.outputTokensData, from: lineData)
            + extractJSONIntValue(Self.cacheCreationTokensData, from: lineData)
            + extractJSONIntValue(Self.cacheReadTokensData, from: lineData)
        return total > 0 ? total : nil
    }

    private func extractJSONIntValue(_ pattern: Data, from lineData: Data) -> Int {
        guard let range = lineData.range(of: pattern) else { return 0 }
        var index = range.upperBound
        while index < lineData.endIndex, lineData[index] == UInt8(ascii: " ") {
            index += 1
        }

        let start = index
        var value = 0
        while index < lineData.endIndex {
            let byte = lineData[index]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { break }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
            index += 1
        }
        guard start < index else { return 0 }
        return value
    }

    private func extractJSONStringValue(_ key: String, from lineData: Data) -> String? {
        let pattern = Data("\"\(key)\":\"".utf8)
        guard let range = lineData.range(of: pattern) else { return nil }
        var index = range.upperBound
        var value = Data()
        var escaped = false

        while index < lineData.endIndex {
            let byte = lineData[index]
            if escaped {
                value.append(byte)
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                return String(data: value, encoding: .utf8)
            } else {
                value.append(byte)
            }
            index += 1
        }

        return nil
    }

    private func projectIdentity(cwd: String?, projectDirectoryName: String) -> (name: String, path: String) {
        if let cwd, !cwd.isEmpty {
            return (displayName(forPath: cwd) ?? cwd, cwd)
        }

        let decoded = projectDirectoryName.hasPrefix("-")
            ? "/" + projectDirectoryName.dropFirst().replacingOccurrences(of: "-", with: "/")
            : projectDirectoryName.replacingOccurrences(of: "-", with: "/")
        return (displayName(forPath: decoded) ?? projectDirectoryName, decoded)
    }

    /// Directory names that group packages inside a monorepo — a leaf under one
    /// of these tells us nothing on its own, so we qualify it with the repo.
    private static let monorepoContainers: Set<String> = [
        "apps", "app", "packages", "package", "services", "service",
        "libs", "lib", "modules", "sites", "examples", "crates",
        "pkgs", "projects", "workspaces"
    ]

    /// Leaf names that are too generic to identify a project on their own.
    private static let genericLeaves: Set<String> = [
        "web", "app", "www", "site", "frontend", "backend", "server",
        "client", "api", "docs", "landing", "admin", "dashboard", "mobile",
        "desktop", "core", "common", "shared", "ui", "cli", "src"
    ]

    /// Turns a working-directory path into a label that disambiguates monorepo
    /// packages: a package under a container dir (e.g. `…/mozhe/apps/landing`)
    /// becomes `mozhe/landing`, and a generic leaf directly under a repo
    /// (e.g. `…/shiftover/web`) becomes `shiftover/web`. Plain repos keep their
    /// bare folder name. Returns nil for an unusable path.
    private func displayName(forPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let leaf = parts.last else { return nil }
        guard parts.count >= 2 else { return leaf }

        let parent = parts[parts.count - 2]

        // Package inside a known monorepo container → qualify with the repo
        // (the container's parent), which is the meaningful, unique name.
        if Self.monorepoContainers.contains(parent.lowercased()) {
            if parts.count >= 3 {
                let repo = parts[parts.count - 3]
                return isUserName(repo) ? leaf : "\(repo)/\(leaf)"
            }
            return leaf
        }

        // Generic leaf sitting directly under its repo → qualify with the repo.
        if Self.genericLeaves.contains(leaf.lowercased()) {
            return isUserName(parent) ? leaf : "\(parent)/\(leaf)"
        }

        return leaf
    }

    /// A qualifier equal to the home-directory name (the macOS user) carries no
    /// information — `~/apps/marco` should read as `marco`, not `markoradak/marco`.
    private func isUserName(_ segment: String) -> Bool {
        !userName.isEmpty && segment.caseInsensitiveCompare(userName) == .orderedSame
    }

    private final class TimestampParser {
        private let fractionalFormatter: ISO8601DateFormatter
        private let wholeSecondFormatter: ISO8601DateFormatter

        init() {
            fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            wholeSecondFormatter = ISO8601DateFormatter()
            wholeSecondFormatter.formatOptions = [.withInternetDateTime]
        }

        func date(from string: String) -> Date? {
            fractionalFormatter.date(from: string) ?? wholeSecondFormatter.date(from: string)
        }

        func string(from date: Date) -> String {
            fractionalFormatter.string(from: date)
        }
    }

    private func countConsecutiveDays(from startDay: Date, activeDates: Set<Date>, calendar: Calendar) -> Int {
        var streak = 0
        var currentDay = startDay
        while activeDates.contains(currentDay) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: currentDay) else { break }
            currentDay = prev
        }
        return streak
    }
}
