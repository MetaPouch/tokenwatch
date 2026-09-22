import Foundation
import TokenWatchCore

/// Composition root: builds the provider list and wires stores together. `swift run TokenWatch`
/// and the eventual app bundle both start here.
@MainActor
public final class AppContainer {
    public let enablementStore: ProviderEnablementStore
    public let dataStore: WidgetDataStore
    public let refreshScheduler: RefreshScheduler
    public let usageService: MultiAccountUsageService
    /// Providers backed by a plain API key, keyed by id, for Settings' secure text fields.
    /// Populated as `APIKeyManaging` providers land (Phase 1+).
    public let apiKeyManagers: [ProviderID: any APIKeyManaging]

    public init() {
        let runtimes: [any ProviderRuntime] = Self.buildRuntimes()
        let enablementStore = ProviderEnablementStore()
        let dataStore = WidgetDataStore(runtimes: runtimes)
        self.enablementStore = enablementStore
        self.dataStore = dataStore
        self.refreshScheduler = RefreshScheduler(dataStore: dataStore, enablementStore: enablementStore)
        self.usageService = MultiAccountUsageService(dataStore: dataStore, enablementStore: enablementStore)
        self.apiKeyManagers = Self.buildAPIKeyManagers()
    }

    /// Every registered provider runtime, in menu display order. Real providers are appended
    /// here as each phase lands.
    private static func buildRuntimes() -> [any ProviderRuntime] {
        [
            ClaudeProvider(),
            CodexProvider(),
            OpenAIProvider(),
            OpenRouterProvider(),
            ZaiProvider(),
            KimiProvider(),
            OpenCodeProvider(),
            GeminiProvider(),
            AntigravityProvider(),
            CopilotProvider(),
            CursorProvider(),
            AmpProvider(),
            GrokProvider()
        ]
    }

    /// API-key-backed providers exposed to Settings.
    private static func buildAPIKeyManagers() -> [ProviderID: any APIKeyManaging] {
        [
            .openrouter: makeOpenRouterAuthStore(),
            .zai: makeZaiAuthStore(),
            .kimi: makeKimiAuthStore(),
            .opencode: makeOpenCodeAuthStore(),
            .openai: makeOpenAIAuthStore(),
            .amp: makeAmpAuthStore()
        ]
    }

    public func start() {
        refreshScheduler.start()
    }
}
