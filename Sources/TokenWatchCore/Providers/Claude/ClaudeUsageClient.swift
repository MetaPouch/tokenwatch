import Foundation

/// `GET /api/oauth/usage` response shape (verified against a live response). Only the fields
/// TokenWatch maps are declared; the endpoint returns many more experimental/unused keys.
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
    let fiveHour: Window?
    let sevenDay: Window?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
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
