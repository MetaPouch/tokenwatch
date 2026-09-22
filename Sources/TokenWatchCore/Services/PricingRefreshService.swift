import Foundation

/// Fetches LiteLLM's community-maintained `model_prices_and_context_window.json` roughly
/// hourly and feeds parsed rates into `DynamicPricingCache`, so `ModelPricing`'s cost estimates
/// track real, current vendor pricing instead of relying solely on its static table (which is
/// only ever as fresh as the last app release). A raw-GitHub JSON fetch, not a dedicated API --
/// no key, no telemetry, nothing about local usage leaves the machine. Network failure, a
/// malformed response, or simply not having fetched yet all fall straight through to the static
/// table; this is a best-effort enhancement, never a hard dependency for pricing to work.
public actor PricingRefreshService {
    private static let sourceURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private static let refreshInterval: TimeInterval = 3600

    private let cacheFileURL: URL
    private let session: URLSession
    private var loopTask: Task<Void, Never>?

    public init(cacheDirectory: URL? = nil, session: URLSession = .shared) {
        let base = cacheDirectory ?? ConfigStore.defaultDirectory()
        self.cacheFileURL = base.appendingPathComponent("pricing_cache.json")
        self.session = session
        loadFromDiskIfAvailable()
    }

    /// Starts the hourly background refresh loop. Idempotent -- a second call while already
    /// running is a no-op.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// One fetch-parse-store pass. Public and directly callable (not just via `start()`'s loop)
    /// so both tests and a manual "refresh now" can trigger it without waiting out the interval.
    public func refresh() async {
        do {
            let (data, response) = try await session.data(from: Self.sourceURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
            guard let rates = Self.parse(data) else { return }
            DynamicPricingCache.shared.replace(rates, updatedAt: Date())
            try? data.write(to: cacheFileURL, options: .atomic)
        } catch {
            // Offline, DNS failure, timeout, etc. -- the static table (or a previously cached
            // successful fetch) keeps serving estimates; there's nothing actionable to surface.
        }
    }

    private nonisolated func loadFromDiskIfAvailable() {
        guard let data = try? Data(contentsOf: cacheFileURL), let rates = Self.parse(data) else { return }
        let modified = (try? FileManager.default.attributesOfItem(atPath: cacheFileURL.path)[.modificationDate] as? Date) ?? Date()
        DynamicPricingCache.shared.replace(rates, updatedAt: modified)
    }

    /// LiteLLM's JSON is a flat `{ "<model-id>": { "input_cost_per_token": ..., ... }, ... }`
    /// map mixed with a handful of non-model metadata entries (e.g. `"sample_spec"`) that don't
    /// have cost fields and are silently skipped rather than treated as a parse failure.
    static func parse(_ data: Data) -> [String: ModelPricing.Rate]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result: [String: ModelPricing.Rate] = [:]
        for (key, value) in json {
            guard let entry = value as? [String: Any],
                  let inputCost = entry["input_cost_per_token"] as? Double,
                  let outputCost = entry["output_cost_per_token"] as? Double
            else { continue }
            let cacheReadCost = entry["cache_read_input_token_cost"] as? Double
            result[key.lowercased()] = ModelPricing.Rate(
                inputPerMillion: inputCost * 1_000_000,
                outputPerMillion: outputCost * 1_000_000,
                cacheReadPerMillion: cacheReadCost.map { $0 * 1_000_000 }
            )
        }
        return result.isEmpty ? nil : result
    }
}
