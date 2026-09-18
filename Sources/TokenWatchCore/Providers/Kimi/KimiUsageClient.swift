import Foundation

/// Numeric fields in Kimi's usage response are JSON strings (e.g. `"2048"`), not numbers.
struct KimiNumericString: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), let parsed = Double(string) {
            value = parsed
        } else {
            value = try container.decode(Double.self)
        }
    }
}

/// `GET /coding/v1/usages` response shape. `resetTime` is decoded as a raw string because Kimi
/// emits 9-digit fractional seconds (`"...716839300Z"`), which `ISO8601DateFormatter` rejects.
struct KimiUsagesResponse: Decodable {
    struct Detail: Decodable {
        let limit: KimiNumericString
        let used: KimiNumericString
        let remaining: KimiNumericString?
        let resetTime: String?
    }
    struct Window: Decodable {
        let duration: Int
        let timeUnit: String
    }
    struct LimitEntry: Decodable {
        let window: Window
        let detail: Detail
    }
    let usage: Detail
    let limits: [LimitEntry]?
}

struct KimiUsageClient {
    let httpClient: HTTPClient
    let baseURL: URL

    init(httpClient: HTTPClient = .shared, baseURL: URL = URL(string: "https://api.kimi.com/coding/v1/usages")!) {
        self.httpClient = httpClient
        self.baseURL = baseURL
    }

    func fetchUsages(apiKey: String) async throws -> KimiUsagesResponse {
        try await httpClient.get(baseURL, headers: ["Authorization": "Bearer \(apiKey)"])
    }
}
