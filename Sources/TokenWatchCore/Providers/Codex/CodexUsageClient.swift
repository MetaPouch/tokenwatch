import Foundation

/// `GET /backend-api/wham/usage` response shape (field names confirmed via
/// github.com/openai/codex#26370, where users quote the raw JSON: `primary_window.used_percent`,
/// `window_minutes`, `resets_at`; `additional_rate_limits` cross-checked against
/// github.com/superset-sh/superset's own reader, which surfaces named extra limits the endpoint
/// can return alongside primary/secondary).
struct CodexUsageResponse: Decodable {
    struct Window: Decodable {
        let usedPercent: Double?
        let windowMinutes: Int?
        let resetsAt: String?
        let resetAfterSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
            case resetAfterSeconds = "reset_after_seconds"
        }
    }
    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }
    struct AdditionalRateLimit: Decodable {
        let limitName: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case rateLimit = "rate_limit"
        }
    }
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]?
    let email: String?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case email
        case planType = "plan_type"
    }
}

struct CodexUsageClient {
    let httpClient: HTTPClient
    let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func fetchUsage(accessToken: String) async throws -> CodexUsageResponse {
        try await httpClient.get(url, headers: ["Authorization": "Bearer \(accessToken)"])
    }
}
