import Foundation

// MARK: - API Response Models

struct UsageResponse: Codable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket
    let sevenDaySonnet: UsageBucket?
    let sevenDayOpus: UsageBucket?
    let extraUsage: ExtraUsage?
    let limits: [UsageLimit]

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case extraUsage = "extra_usage"
        case limits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try? container.decodeIfPresent(UsageBucket.self, forKey: .fiveHour)
        sevenDay = try container.decode(UsageBucket.self, forKey: .sevenDay)
        sevenDaySonnet = try? container.decodeIfPresent(UsageBucket.self, forKey: .sevenDaySonnet)
        sevenDayOpus = try? container.decodeIfPresent(UsageBucket.self, forKey: .sevenDayOpus)
        extraUsage = try? container.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
        limits = (try? container.decodeIfPresent([UsageLimit].self, forKey: .limits)) ?? []
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
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        utilization = (try? container.decodeIfPresent(Double.self, forKey: .utilization)) ?? 0
        resetsAt = try? container.decodeIfPresent(String.self, forKey: .resetsAt)
        scope = try? container.decodeIfPresent(Scope.self, forKey: .scope)
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

    /// Parse the ISO 8601 reset time into a Date
    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resetsAt) {
            return date
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAt)
    }
}

struct ExtraUsage: Codable {
    let isEnabled: Bool
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}
