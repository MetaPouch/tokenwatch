import Foundation
import Combine

/// Timer-driven refresh loop calling `WidgetDataStore.refreshAll()` at
/// `refreshIntervalSeconds` (default 300s, settings-adjustable 60-1800s), plus a manual
/// `refreshNow()` entry point for UI-triggered refreshes.
@MainActor
public final class RefreshScheduler: ObservableObject {
    /// When the next automatic refresh is due -- the footer's live countdown reads this.
    /// `nil` before `start()` has run, or immediately after a manual refresh completes and
    /// before the next cycle is rescheduled (a brief gap, not a meaningful state to show).
    @Published public private(set) var nextRefreshAt: Date?

    private let dataStore: WidgetDataStore
    private let enablementStore: ProviderEnablementStore
    private var timer: Timer?
    private var cancellable: AnyCancellable?

    public init(dataStore: WidgetDataStore, enablementStore: ProviderEnablementStore) {
        self.dataStore = dataStore
        self.enablementStore = enablementStore
    }

    public func start() {
        refreshNow()
        scheduleTimer(interval: enablementStore.refreshIntervalSeconds)
        cancellable = enablementStore.$refreshIntervalSeconds
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] interval in
                self?.scheduleTimer(interval: interval)
            }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        cancellable = nil
        nextRefreshAt = nil
    }

    public func refreshNow() {
        let enabled = enablementStore.enabledProviders
        Task { [dataStore] in
            await dataStore.refreshAll(enabled: enabled)
        }
    }

    /// Force-refreshes just one provider, skipping the cache -- the context-menu "Refresh
    /// <Provider>" action, which shouldn't wait out or re-trigger every other provider's fetch.
    public func refreshProvider(_ provider: ProviderID) {
        Task { [dataStore] in
            await dataStore.refreshAll(enabled: [provider])
        }
    }

    private func scheduleTimer(interval: Int) {
        timer?.invalidate()
        nextRefreshAt = Date().addingTimeInterval(TimeInterval(interval))
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.nextRefreshAt = Date().addingTimeInterval(TimeInterval(interval))
                self?.refreshNow()
            }
        }
    }
}
