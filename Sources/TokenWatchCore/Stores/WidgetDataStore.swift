import Foundation
import Combine

/// Holds the latest snapshot per provider and orchestrates concurrent refreshes. Persists the
/// last-known snapshot per provider to `cache.json` for instant display on next launch
/// (stale-while-revalidate).
@MainActor
public final class WidgetDataStore: ObservableObject {
    @Published public private(set) var snapshots: [ProviderID: ProviderSnapshot] = [:]
    @Published public private(set) var isRefreshing: Bool = false

    private let runtimes: [any ProviderRuntime]
    private let cacheURL: URL

    public init(runtimes: [any ProviderRuntime], cacheDirectory: URL? = nil) {
        self.runtimes = runtimes
        let base = cacheDirectory ?? ConfigStore.defaultDirectory()
        self.cacheURL = base.appendingPathComponent("cache.json")
        self.snapshots = Self.loadCache(from: cacheURL)
    }

    /// Runs every enabled provider's `refresh()` concurrently and updates the in-memory
    /// dictionary, then persists the result.
    public func refreshAll(enabled: Set<ProviderID>) async {
        isRefreshing = true
        defer { isRefreshing = false }

        let active = runtimes.filter { enabled.contains(type(of: $0).id) }
        guard !active.isEmpty else { return }

        let results = await withTaskGroup(of: ProviderSnapshot.self) { group -> [ProviderSnapshot] in
            for runtime in active {
                group.addTask {
                    await runtime.refresh()
                }
            }
            var collected: [ProviderSnapshot] = []
            for await snapshot in group {
                collected.append(snapshot)
            }
            return collected
        }

        for snapshot in results {
            snapshots[snapshot.provider] = snapshot
        }
        persistCache()
    }

    public func snapshot(for provider: ProviderID) -> ProviderSnapshot? {
        snapshots[provider]
    }

    private func persistCache() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let keyed = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.rawValue, $0.value) })
        guard let data = try? encoder.encode(keyed) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func loadCache(from url: URL) -> [ProviderID: ProviderSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let keyed = try? decoder.decode([String: ProviderSnapshot].self, from: data) else { return [:] }
        var result: [ProviderID: ProviderSnapshot] = [:]
        for (key, value) in keyed {
            guard let id = ProviderID(rawValue: key) else { continue }
            result[id] = value
        }
        return result
    }
}
