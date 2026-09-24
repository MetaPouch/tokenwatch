import Foundation
import Combine
import TokenWatchCore

/// Composition root: builds the provider list and wires stores together. `swift run TokenWatch`
/// and the eventual app bundle both start here.
@MainActor
public final class AppContainer {
    public let enablementStore: ProviderEnablementStore
    public let dataStore: WidgetDataStore
    public let refreshScheduler: RefreshScheduler
    public let usageService: MultiAccountUsageService
    public let layoutStore: LayoutStore
    public let displayStore: MeterDisplayStore
    public let appearanceStore: AppearanceStore
    public let notificationSettingsStore: NotificationSettingsStore
    let notificationService: QuotaNotificationService
    public let pricingRefreshService: PricingRefreshService
    public let spendHistoryStore: SpendHistoryStore
    public let detectionStore: ProviderDetectionStore
    public let hintStore = HintStore()
    /// The opt-in leaderboard. Idle (no Keychain read, no request) until the user joins.
    public let leaderboardService: LeaderboardService
    let webAuthenticationPresenter = WebAuthenticationPresenter()
    /// Providers backed by a plain API key, keyed by id, for Settings' secure text fields.
    public let apiKeyManagers: [ProviderID: any APIKeyManaging]
    /// Assigned by `AppDelegate` once the status item controller exists -- lets Settings'
    /// shortcut recorder re-register the global hotkey without `AppContainer` needing to know
    /// about `StatusItemController` (which is itself constructed with `AppContainer` as input).
    public var toggleDashboardPanel: () -> Void = {}

    private var notificationCancellable: AnyCancellable?
    private var spendRefreshCancellable: AnyCancellable?
    private var leaderboardCancellable: AnyCancellable?

    public init() {
        let runtimes: [any ProviderRuntime] = Self.buildRuntimes()
        let enablementStore = ProviderEnablementStore()
        let dataStore = WidgetDataStore(runtimes: runtimes)
        self.detectionStore = ProviderDetectionStore(runtimes: runtimes)
        self.enablementStore = enablementStore
        self.dataStore = dataStore
        self.refreshScheduler = RefreshScheduler(dataStore: dataStore, enablementStore: enablementStore)
        self.usageService = MultiAccountUsageService(dataStore: dataStore, enablementStore: enablementStore)
        self.layoutStore = LayoutStore()
        self.displayStore = MeterDisplayStore()
        self.appearanceStore = AppearanceStore()
        let notificationSettingsStore = NotificationSettingsStore()
        self.notificationSettingsStore = notificationSettingsStore
        self.notificationService = QuotaNotificationService(settingsStore: notificationSettingsStore)
        self.pricingRefreshService = PricingRefreshService()
        self.apiKeyManagers = Self.buildAPIKeyManagers()
        self.spendHistoryStore = SpendHistoryStore(includeCursor: { enablementStore.isEnabled(.cursor) })
        self.leaderboardService = LeaderboardService(
            clientVersion: AppVersion.leaderboardClientVersion,
            environment: LeaderboardService.Environment(includeCursorHistory: { enablementStore.isEnabled(.cursor) })
        )

        let notificationService = self.notificationService
        notificationCancellable = dataStore.$snapshots
            .receive(on: RunLoop.main)
            .sink { snapshots in notificationService.evaluate(snapshots: snapshots) }

        // Provider refreshes also reconcile local history, as a fallback to filesystem events
        // and to pick up pricing changes even when no new turns have been written.
        let spendHistoryStore = self.spendHistoryStore
        spendRefreshCancellable = dataStore.$isRefreshing
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .receive(on: RunLoop.main)
            .sink { _ in spendHistoryStore.reload() }

        // The leaderboard syncs what the history store already scanned -- after filesystem
        // events and provider refreshes alike -- and never scans on its own for it.
        let leaderboardService = self.leaderboardService
        leaderboardCancellable = spendHistoryStore.$daysBySource
            .combineLatest(spendHistoryStore.$isLoading)
            .filter { !$0.1 }
            .map(\.0)
            .receive(on: RunLoop.main)
            .sink { days in leaderboardService.usageDidChange(days) }
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
        spendHistoryStore.startWatching()
        refreshScheduler.start()
        Task { await pricingRefreshService.start() }
        leaderboardService.start()
    }
}
