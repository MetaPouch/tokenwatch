import Foundation
import Combine

/// Reads/writes `ConfigStore.enabledProviders` and publishes changes for SwiftUI observers.
@MainActor
public final class ProviderEnablementStore: ObservableObject {
    @Published public private(set) var enabledProviders: Set<ProviderID>
    @Published public private(set) var refreshIntervalSeconds: Int

    private let configStore: ConfigStore

    public init(configStore: ConfigStore = .shared) {
        self.configStore = configStore
        let config = configStore.load()
        self.enabledProviders = config.enabledProviders
        self.refreshIntervalSeconds = config.refreshIntervalSeconds
    }

    public func isEnabled(_ provider: ProviderID) -> Bool {
        enabledProviders.contains(provider)
    }

    public func setEnabled(_ provider: ProviderID, _ enabled: Bool) {
        if enabled {
            enabledProviders.insert(provider)
        } else {
            enabledProviders.remove(provider)
        }
        persist()
    }

    /// Enables several providers at once with a single config write (onboarding's "Track").
    public func enable(_ providers: some Sequence<ProviderID>) {
        enabledProviders.formUnion(providers)
        persist()
    }

    public func setRefreshIntervalSeconds(_ seconds: Int) {
        refreshIntervalSeconds = min(max(seconds, 60), 1800)
        persist()
    }

    private func persist() {
        let enabled = enabledProviders
        let interval = refreshIntervalSeconds
        configStore.mutate { config in
            config.enabledProviders = enabled
            config.refreshIntervalSeconds = interval
        }
    }
}
