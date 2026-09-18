import Foundation

/// `GET /api/v1/credits` response shape.
struct OpenRouterCreditsResponse: Decodable {
    struct Data: Decodable {
        let totalCredits: Double?
        let totalUsage: Double?

        enum CodingKeys: String, CodingKey {
            case totalCredits = "total_credits"
            case totalUsage = "total_usage"
        }
    }
    let data: Data
}

/// `GET /api/v1/key` response shape.
struct OpenRouterKeyResponse: Decodable {
    struct Data: Decodable {
        let limit: Double?
        let limitRemaining: Double?
        let usage: Double?

        enum CodingKeys: String, CodingKey {
            case limit
            case limitRemaining = "limit_remaining"
            case usage
        }
    }
    let data: Data
}

struct OpenRouterUsageClient {
    let httpClient: HTTPClient
    let baseURL: URL

    init(httpClient: HTTPClient = .shared, baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!) {
        self.httpClient = httpClient
        self.baseURL = baseURL
    }

    func fetchCredits(apiKey: String) async throws -> OpenRouterCreditsResponse {
        try await httpClient.get(baseURL.appendingPathComponent("credits"), headers: ["Authorization": "Bearer \(apiKey)"])
    }

    func fetchKey(apiKey: String) async throws -> OpenRouterKeyResponse {
        try await httpClient.get(baseURL.appendingPathComponent("key"), headers: ["Authorization": "Bearer \(apiKey)"])
    }
}
