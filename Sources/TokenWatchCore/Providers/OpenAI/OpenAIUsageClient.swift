import Foundation

/// `GET /v1/organization/costs` response shape (verified against
/// developers.openai.com/api-reference/usage -- a real example response for this endpoint
/// returns `results[].amount.value` in USD). Used instead of `/v1/organization/usage/completions`
/// because it reports dollar spend directly, matching the "today/7d spend" mapping this provider
/// needs, rather than raw token counts.
struct OpenAICostsResponse: Decodable {
    struct Amount: Decodable {
        let value: Double?
        let currency: String?
    }
    struct Result: Decodable {
        let amount: Amount?
    }
    struct Bucket: Decodable {
        let results: [Result]
    }
    let data: [Bucket]
}

struct OpenAIUsageClient {
    let httpClient: HTTPClient
    private let baseURL = URL(string: "https://api.openai.com/v1/organization/costs")!

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    /// `startTime`/`endTime` are Unix seconds. `bucketWidth` is `"1d"` (the only width the costs
    /// endpoint supports) and `limit` bounds the number of returned buckets.
    func fetchCosts(apiKey: String, startTime: Int, limit: Int) async throws -> OpenAICostsResponse {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(startTime)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        return try await httpClient.get(components.url!, headers: ["Authorization": "Bearer \(apiKey)"])
    }
}
