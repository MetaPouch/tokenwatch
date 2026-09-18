import Foundation

/// `GET /zen/go/v1/usage` response shape. `usagePercent` is already 0-100.
struct OpenCodeUsageResponse: Decodable {
    struct Window: Decodable {
        let usagePercent: Double
        let resetInSec: Int?
    }
    let rollingUsage: Window
    let weeklyUsage: Window?
}

struct OpenCodeUsageClient {
    let httpClient: HTTPClient
    let url: URL

    init(httpClient: HTTPClient = .shared, url: URL = URL(string: "https://opencode.ai/zen/go/v1/usage")!) {
        self.httpClient = httpClient
        self.url = url
    }

    func fetchUsage(apiKey: String) async throws -> OpenCodeUsageResponse {
        try await httpClient.get(url, headers: ["Authorization": "Bearer \(apiKey)"])
    }
}
