import Foundation

/// `GET /api/oauth/usage` response shape (verified against a live response; `seven_day_sonnet`
/// and `limits` cross-checked against github.com/superset-sh/superset's own reader, which
/// surfaces them for plans with a model-scoped weekly cap in addition to the overall one). Only
/// the fields TokenWatch maps are declared; the endpoint returns many more experimental/unused
/// keys.
struct ClaudeUsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
    struct ExtraUsage: Decodable {
        let isEnabled: Bool
        let monthlyLimit: Double?
        let usedCredits: Double?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
        }
    }
    /// A weekly cap scoped to one model (e.g. a plan with a separate Sonnet-specific weekly
    /// limit in addition to the overall weekly one) rather than the account as a whole.
    struct ScopedLimit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" }
            }
            let model: Model?
        }
        let kind: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
        }
    }
    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDaySonnet: Window?
    let limits: [ScopedLimit]?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case limits
        case extraUsage = "extra_usage"
    }
}

struct ClaudeUsageClient {
    let httpClient: HTTPClient
    let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func fetchUsage(accessToken: String) async throws -> ClaudeUsageResponse {
        try await httpClient.get(url, headers: [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20"
        ])
    }
}
