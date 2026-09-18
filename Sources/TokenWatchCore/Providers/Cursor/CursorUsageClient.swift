import Foundation

/// `GET /api/usage-summary` response shape (verified against CodexBar's
/// `CursorStatusProbe.swift`). Only the fields TokenWatch maps are declared.
struct CursorUsageSummary: Decodable {
    struct PlanUsage: Decodable {
        let used: Int?
        let limit: Int?
    }
    struct OnDemandUsage: Decodable {
        let used: Int?
        let limit: Int?
    }
    struct IndividualUsage: Decodable {
        let plan: PlanUsage?
        let onDemand: OnDemandUsage?
    }
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let individualUsage: IndividualUsage?
}

/// `GET /api/auth/me` response shape.
struct CursorUserInfo: Decodable {
    let email: String?
    let name: String?
}

struct CursorUsageClient {
    let httpClient: HTTPClient
    private let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    private let authMeURL = URL(string: "https://cursor.com/api/auth/me")!

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func fetchUsageSummary(sessionToken: String) async throws -> CursorUsageSummary {
        try await httpClient.get(usageSummaryURL, headers: cookieHeaders(sessionToken))
    }

    func fetchUserInfo(sessionToken: String) async throws -> CursorUserInfo {
        try await httpClient.get(authMeURL, headers: cookieHeaders(sessionToken))
    }

    private func cookieHeaders(_ sessionToken: String) -> [String: String] {
        ["Cookie": "WorkosCursorSessionToken=\(sessionToken)"]
    }
}
