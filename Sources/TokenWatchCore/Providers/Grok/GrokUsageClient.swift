import Foundation

/// `GET /v1/billing?format=credits` response shape (field names per CodexBar's documented
/// `GrokCreditsProxyFetcher` mapping: `config.creditUsagePercent`, `onDemandUsed.val` /
/// `onDemandCap.val`, `config.currentPeriod.end`, `config.billingPeriodEnd`).
struct GrokBillingResponse: Decodable {
    struct MoneyValue: Decodable {
        let val: Double?
    }
    struct Period: Decodable {
        let end: String?
    }
    struct Config: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: Period?
        let billingPeriodEnd: String?
        let subscriptionTier: String?
    }
    let config: Config?
    let onDemandUsed: MoneyValue?
    let onDemandCap: MoneyValue?
}

struct GrokUsageClient {
    let httpClient: HTTPClient
    private let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func fetchBilling(accessToken: String) async throws -> GrokBillingResponse {
        try await httpClient.get(url, headers: [
            "Authorization": "Bearer \(accessToken)",
            "x-xai-token-auth": "xai-grok-cli",
            "Accept": "application/json"
        ])
    }
}
