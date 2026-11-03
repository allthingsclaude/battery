import Foundation

// Shared between the app and the widget so the widget can self-refresh.
// The app remains the sole token *refresher*; the widget only ever reads a
// mirrored access token and does a plain GET with it.

// MARK: - Tokens

/// OAuth tokens for one account. The widget reads the app-mirrored copy from the
/// App Group to self-fetch; it never refreshes (avoids refresh-token rotation
/// conflicts with the app).
struct StoredTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Int64 // milliseconds since epoch

    var expiryDate: Date { Date(timeIntervalSince1970: Double(expiresAt) / 1000.0) }
    var isExpiringSoon: Bool { expiryDate.timeIntervalSinceNow < 300 }

    init(accessToken: String, refreshToken: String?, expiresIn: Int) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = Int64((Date().timeIntervalSince1970 + Double(expiresIn)) * 1000.0)
    }

    init(accessToken: String, refreshToken: String?, expiresAt: Int64) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

// MARK: - API response models

struct UsageResponse: Codable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket
    let sevenDayOpus: UsageBucket?
    /// Plan/rate-limit tier if the API returns it (it usually doesn't). We never
    /// guess the plan from Opus presence.
    let rateLimitTier: String?
    let limits: [UsageLimit]

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case rateLimitTier = "rate_limit_tier"
        case limits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try? c.decodeIfPresent(UsageBucket.self, forKey: .fiveHour)
        sevenDay = try c.decode(UsageBucket.self, forKey: .sevenDay)
        sevenDayOpus = try? c.decodeIfPresent(UsageBucket.self, forKey: .sevenDayOpus)
        rateLimitTier = try? c.decodeIfPresent(String.self, forKey: .rateLimitTier)
        limits = (try? c.decodeIfPresent([UsageLimit].self, forKey: .limits)) ?? []
    }

    /// Fable's weekly window, which the API reports only inside `limits` — there
    /// is no `seven_day_fable` counterpart to the other per-model buckets.
    var fableLimit: UsageLimit? {
        limits.first {
            $0.kind == "weekly_scoped"
                && $0.modelName?.caseInsensitiveCompare("Fable") == .orderedSame
        }
    }

    var fableUtilization: Double? { fableLimit?.utilization }

    /// The five-hour (session) window, wherever the API reported it — nil when
    /// the account doesn't have one.
    ///
    /// A verified Ultra account has weekly limits only: the API answers with
    /// `"five_hour": null` and no `session` entry in `limits`. Everyone else
    /// gets the top-level bucket; the `limits` entry only fills in for a
    /// response that reports the window there and nowhere else.
    var sessionBucket: UsageBucket? {
        if let fiveHour { return fiveHour }
        guard let limit = limits.first(where: { $0.kind == "session" }) else { return nil }
        return UsageBucket(utilization: limit.utilization, resetsAt: limit.resetsAt)
    }

    /// Whether this account has a five-hour window at all. Read from the data,
    /// never from the plan: an unverified Ultra account still carries a
    /// temporary five-hour limit, so the name alone can't say.
    var hasSessionLimit: Bool { sessionBucket != nil }

    /// The window every glanceable surface leads with: the session when there
    /// is one, otherwise the weekly. See `UsagePayload.primaryWindow`.
    var primaryWindow: UsagePayload.FocusWindow { hasSessionLimit ? .session : .weekly }

    var primaryUtilization: Double {
        if let session = sessionBucket { return session.utilization }
        return sevenDay.utilization
    }

    var primaryResetsAt: Date? {
        if let session = sessionBucket { return session.resetsAtDate }
        return sevenDay.resetsAtDate
    }

    /// Display name for the plan, or "" when unknown.
    var planDisplayName: String { PlanLabel.from(rateLimitTier: rateLimitTier) }
}

// MARK: - Plan labels

/// The plan names every platform shows — the Mac, this app, and Android all
/// produce the same strings from the same tier.
///
/// Anthropic renamed the plans on 2026-10-30: Max 20x is now **Ultra** and Max
/// 5x is plain **Max**. The tier string for Ultra still reads
/// `default_claude_max_20x` today and may later say `ultra`, so both spellings
/// land on the new name. Order matters: every Max tier contains "max".
enum PlanLabel {
    static func from(rateLimitTier: String?) -> String {
        guard let t = rateLimitTier?.lowercased() else { return "" }
        if t.contains("ultra") || t.contains("max_20x") || t.contains("max20x") { return "Ultra" }
        if t.contains("max_5x") || t.contains("max5x") { return "Max" }
        if t.contains("max") { return "Max" }
        if t.contains("pro") { return "Pro" }
        return ""
    }

    /// Bring a label written before the rename up to date. Applied wherever a
    /// stored or remotely-supplied label is read — a payload saved by the
    /// previous version, or the plan a Mac stamped on a Live Activity — so
    /// "Max 20x" doesn't linger until the next successful poll replaces it.
    static func migrated(_ label: String) -> String {
        switch label {
        case "Max 20x": return "Ultra"
        case "Max 5x":  return "Max"
        default:        return label
        }
    }
}

/// One entry in the API's `limits` array — a generic per-window shape that sits
/// alongside the fixed `five_hour` / `seven_day` / `seven_day_<model>` fields.
///
/// The `session` and `weekly_all` entries restate buckets we already read from
/// the top level; the interesting ones are `weekly_scoped`, which carry the
/// model they apply to in `scope`.
struct UsageLimit: Codable {
    let kind: String
    /// The API sends whole numbers here today. Decoded as `Double` to match the
    /// `utilization` it is displayed alongside, and in case it gains a
    /// fractional part later.
    let utilization: Double
    let resetsAt: String?
    let scope: Scope?

    enum CodingKeys: String, CodingKey {
        case kind
        case utilization = "percent"
        case resetsAt = "resets_at"
        case scope
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        utilization = (try? c.decodeIfPresent(Double.self, forKey: .utilization)) ?? 0
        resetsAt = try? c.decodeIfPresent(String.self, forKey: .resetsAt)
        scope = try? c.decodeIfPresent(Scope.self, forKey: .scope)
    }

    /// The only model identifier the API offers — `scope.model.id` comes back
    /// null, so a display name is all there is to match on.
    var modelName: String? { scope?.model?.displayName }

    var resetsAtDate: Date? {
        UsageBucket(utilization: utilization, resetsAt: resetsAt).resetsAtDate
    }

    struct Scope: Codable {
        let model: Model?

        struct Model: Codable {
            let displayName: String?
            let id: String?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case id
            }
        }
    }
}

struct UsageBucket: Codable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: resetsAt) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: resetsAt)
    }
}

// MARK: - Raw fetch (no token refresh)

enum UsageFetcher {
    static let apiBaseURL = "https://api.anthropic.com"
    static let betaHeader = "oauth-2025-04-20"
    static let userAgent = BatteryVersion.userAgent

    enum FetchError: Error { case unauthorized, rateLimited, server(Int), badResponse }

    static func fetch(accessToken: String) async throws -> UsageResponse {
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse }
        switch http.statusCode {
        case 200: return try JSONDecoder().decode(UsageResponse.self, from: data)
        case 401: throw FetchError.unauthorized
        case 429: throw FetchError.rateLimited
        default:  throw FetchError.server(http.statusCode)
        }
    }
}

// MARK: - Stateless payload builder

extension UsagePayload {
    /// Build a payload from a usage response outside the app's poll loop — used
    /// by the widget's self-fetch and the background-refresh task.
    ///
    /// This used to only *carry* a burn rate forward from `previous`, which
    /// meant neither of those two paths could ever originate one: a phone whose
    /// widgets refreshed on WidgetKit's schedule saw a permanent em dash. Both
    /// now record into the shared `SessionHistory`, so every poll — whoever
    /// makes it — builds the regression up.
    ///
    /// The regression follows the primary window: the session when the account
    /// has one, the weekly window when it doesn't (verified Ultra). The session
    /// fields are then written as 0 / nil — never a fabricated window.
    static func from(usage: UsageResponse, previous: UsagePayload?, accountName: String) -> UsagePayload {
        let session = usage.sessionBucket
        let window = usage.primaryWindow
        let primaryUtil = usage.primaryUtilization

        let projection = SessionHistory.record(
            utilization: primaryUtil,
            resetsAt: usage.primaryResetsAt,
            window: window
        )

        // Only a payload that described the same window has anything to carry:
        // a session rate is meaningless against the weekly window, and the
        // other way round. An account flipping between the two (verification
        // landing, or a temporary limit coming back) starts from scratch.
        let comparable = previous?.primaryWindow == window ? previous : nil

        // Until the shared buffer holds enough samples to regress, fall back to
        // the last payload's rate — but only while the sample it came from is
        // recent enough to mean anything, otherwise an hours-old "9.2%/hr" gets
        // presented as current.
        let carriedIsFresh = comparable.map { Date().timeIntervalSince($0.updatedAt) < 3600 } ?? false
        let carriedLimit = carriedIsFresh ? comparable?.liveProjectedLimitAt : nil
        let carriedRate = carriedLimit != nil ? (comparable?.burnRatePerHour ?? 0) : 0

        let hasFreshProjection = projection.ratePerHour > 0

        return UsagePayload(
            hasSessionLimit: session != nil,
            sessionUtilization: session?.utilization ?? 0,
            sessionResetsAt: session?.resetsAtDate,
            weeklyUtilization: usage.sevenDay.utilization,
            weeklyResetsAt: usage.sevenDay.resetsAtDate,
            opusUtilization: usage.sevenDayOpus?.utilization,
            fableUtilization: usage.fableUtilization,
            burnRatePerHour: hasFreshProjection ? projection.ratePerHour : carriedRate,
            projectedLimitAt: hasFreshProjection ? projection.limitAt : carriedLimit,
            isSessionActive: primaryUtil > (comparable?.primaryUtilization ?? 0),
            planTier: usage.planDisplayName,
            accountName: accountName,
            isConnected: true,
            updatedAt: Date()
        )
    }
}
