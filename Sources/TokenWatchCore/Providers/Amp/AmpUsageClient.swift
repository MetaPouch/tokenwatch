import Foundation

/// `POST /api/internal` (`{"method": "userDisplayBalanceInfo"}`) response shape. The endpoint
/// returns a single human-readable `displayText` string rather than structured fields (verified
/// via a real captured request/response, cited from github.com/robinebers/openusage's Amp
/// provider notes); `AmpMapper` regex-parses it.
struct AmpBalanceResponse: Decodable {
    let displayText: String?
}

struct AmpUsageClient {
    let httpClient: HTTPClient
    private let url = URL(string: "https://ampcode.com/api/internal")!

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func fetchBalance(apiKey: String) async throws -> AmpBalanceResponse {
        let body = try JSONSerialization.data(withJSONObject: ["method": "userDisplayBalanceInfo"])
        return try await httpClient.post(url, headers: [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json"
        ], body: body)
    }
}
