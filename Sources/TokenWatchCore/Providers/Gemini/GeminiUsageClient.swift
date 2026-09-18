import Foundation

/// `loadCodeAssist` response: only `cloudaicompanionProject` is used (project discovery for the
/// quota call).
struct GeminiLoadCodeAssistResponse: Decodable {
    let cloudaicompanionProject: String?
}

/// `retrieveUserQuota` response shape (verified against CodexBar's `GeminiStatusProbe.swift`).
struct GeminiQuotaResponse: Decodable {
    struct Bucket: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
        let modelId: String?
    }
    let buckets: [Bucket]?
}

struct GeminiUsageClient {
    let httpClient: HTTPClient
    private let loadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func loadCodeAssist(accessToken: String) async throws -> GeminiLoadCodeAssistResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]
        ])
        return try await httpClient.post(loadCodeAssistURL, headers: authHeaders(accessToken), body: body)
    }

    func retrieveUserQuota(accessToken: String, project: String?) async throws -> GeminiQuotaResponse {
        var payload: [String: Any] = [:]
        if let project { payload["project"] = project }
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try await httpClient.post(quotaURL, headers: authHeaders(accessToken), body: body)
    }

    private func authHeaders(_ accessToken: String) -> [String: String] {
        ["Authorization": "Bearer \(accessToken)", "Content-Type": "application/json"]
    }
}
