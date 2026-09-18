import Foundation

/// `GET /api/monitor/usage/quota/limit` response shape (verified against CodexBar's zai.js
/// plugin, not a first-hand live capture).
struct ZaiQuotaResponse: Decodable {
    struct DataBody: Decodable {
        struct Limit: Decodable {
            let type: String
            let unit: Int
            let number: Int
            let percentage: Int
            let usage: Int?
            let currentValue: Int?
            let remaining: Int?
            let nextResetTime: Int64?
        }
        let limits: [Limit]
        let planName: String?
        let plan: String?
        let planType: String?
        let packageName: String?
        let level: String?

        enum CodingKeys: String, CodingKey {
            case limits, planName, plan
            case planType = "plan_type"
            case packageName, level
        }
    }
    let success: Bool
    let code: Int
    let data: DataBody?
    let msg: String?
}

struct ZaiUsageClient {
    let httpClient: HTTPClient

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func fetchQuota(apiKey: String, region: ZaiRegion) async throws -> ZaiQuotaResponse {
        let url = URL(string: "\(region.host)/api/monitor/usage/quota/limit")!
        return try await httpClient.get(url, headers: ["authorization": "Bearer \(apiKey)", "accept": "application/json"])
    }
}
