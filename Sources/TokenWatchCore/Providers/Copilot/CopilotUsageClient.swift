import Foundation

/// `GET /copilot_internal/user` response shape (only the fields TokenWatch maps).
struct CopilotUserResponse: Decodable {
    struct QuotaSnapshot: Decodable {
        let percentRemaining: Double?
        enum CodingKeys: String, CodingKey { case percentRemaining = "percent_remaining" }
    }
    struct QuotaSnapshots: Decodable {
        let premiumInteractions: QuotaSnapshot?
        let chat: QuotaSnapshot?
        enum CodingKeys: String, CodingKey {
            case premiumInteractions = "premium_interactions"
            case chat
        }
    }
    let quotaSnapshots: QuotaSnapshots?
    let copilotPlan: String?

    enum CodingKeys: String, CodingKey {
        case quotaSnapshots = "quota_snapshots"
        case copilotPlan = "copilot_plan"
    }
}

struct CopilotUsageClient {
    let httpClient: HTTPClient
    let url = URL(string: "https://api.github.com/copilot_internal/user")!

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func fetchUser(oauthToken: String) async throws -> CopilotUserResponse {
        try await httpClient.get(url, headers: [
            "Authorization": "token \(oauthToken)",
            "Accept": "application/json",
            "Editor-Version": "vscode/1.96.2",
            "Editor-Plugin-Version": "copilot-chat/0.26.7",
            "User-Agent": "GitHubCopilotChat/0.26.7",
            "X-Github-Api-Version": "2025-04-01"
        ])
    }
}
