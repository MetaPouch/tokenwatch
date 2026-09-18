import Foundation

/// `loadCodeAssist` / `retrieveUserQuotaSummary` response shapes (field names confirmed against
/// github.com/wakamex/agy-usage's `_parse_quota_summary`, a real independent client for this
/// exact Antigravity backend).
struct AntigravityLoadCodeAssistResponse: Decodable {
    let cloudaicompanionProject: String?
}

struct AntigravityQuotaSummaryResponse: Decodable {
    struct Bucket: Decodable {
        let bucketId: String?
        let displayName: String?
        let remainingFraction: Double?
        let resetTime: String?
        let disabled: Bool?
        let window: String?
    }
    struct Group: Decodable {
        let description: String?
        let buckets: [Bucket]?
    }
    let groups: [Group]?
}

struct AntigravityUsageClient {
    let httpClient: HTTPClient
    /// Confirmed base URL (note the `daily-` prefix, distinct from the ordinary Gemini
    /// `cloudcode-pa.googleapis.com` host).
    private let baseURL = "https://daily-cloudcode-pa.googleapis.com/v1internal"

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func loadCodeAssist(accessToken: String) async throws -> AntigravityLoadCodeAssistResponse {
        let body = try JSONSerialization.data(withJSONObject: ["metadata": ["ideType": "ANTIGRAVITY"]])
        return try await httpClient.post(URL(string: "\(baseURL):loadCodeAssist")!, headers: headers(accessToken), body: body)
    }

    func retrieveUserQuotaSummary(accessToken: String, project: String) async throws -> AntigravityQuotaSummaryResponse {
        let body = try JSONSerialization.data(withJSONObject: ["project": project])
        return try await httpClient.post(URL(string: "\(baseURL):retrieveUserQuotaSummary")!, headers: headers(accessToken), body: body)
    }

    private func headers(_ accessToken: String) -> [String: String] {
        ["Authorization": "Bearer \(accessToken)", "Content-Type": "application/json", "Accept": "application/json"]
    }
}
