import Foundation

/// OpenAI (raw API key) usage: today + 7-day spend from the Admin Costs API. Pay-as-you-go has
/// no fixed limit, so this reports `.values` (dollar totals) rather than a bounded `.progress`
/// line. A non-admin key gets HTTP 403 from this endpoint, surfaced as `.notConfigured` with
/// guidance that an Admin key is required.
public struct OpenAIProvider: ProviderRuntime {
    public static let id: ProviderID = .openai
    public static let displayName = "OpenAI"

    public let authStore: APIKeyAuthStore
    private let usageClient: OpenAIUsageClient

    public init(authStore: APIKeyAuthStore = makeOpenAIAuthStore()) {
        self.authStore = authStore
        self.usageClient = OpenAIUsageClient()
    }

    public func hasLocalCredentials() async -> Bool {
        authStore.currentAPIKey() != nil
    }

    public func refresh() async -> ProviderSnapshot {
        guard let apiKey = authStore.currentAPIKey() else {
            return .error(provider: Self.id, error: .credentialsMissing)
        }
        do {
            let now = Date()
            let startOfToday = Calendar(identifier: .gregorian).startOfDay(for: now)
            let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 3600)

            async let todayTask = usageClient.fetchCosts(apiKey: apiKey, startTime: Int(startOfToday.timeIntervalSince1970), limit: 1)
            async let weekTask = usageClient.fetchCosts(apiKey: apiKey, startTime: Int(sevenDaysAgo.timeIntervalSince1970), limit: 7)
            let today = try await todayTask
            let week = try await weekTask

            let lines = OpenAIMapper.map(today: today, last7Days: week)
            return ProviderSnapshot(provider: Self.id, plan: nil, lines: lines, fetchedAt: Date())
        } catch ProviderError.http(let status, _) where status == 403 {
            return .error(provider: Self.id, error: .notConfigured)
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }
}
