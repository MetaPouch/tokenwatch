import Foundation

/// One locally discovered login's quota data, for providers that support more than one account
/// on the same machine (currently: Claude, Codex, via a second `CLAUDE_CONFIG_DIR`/`CODEX_HOME`
/// profile). Purely additive to the core single-account model every other part of TokenWatch
/// uses (`ProviderRuntime.refresh()` / `ProviderSnapshot`, unchanged) -- this exists only to feed
/// the "Usage" dashboard tab's consolidated, multi-account quota view.
public struct ProviderAccount: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let providerID: ProviderID
    /// Account email when known, else a source label (e.g. `~/.claude-work`).
    public let label: String
    /// The account TokenWatch's core single-account tracking already uses (the same one the
    /// menu bar and per-provider dashboard card show) -- always exactly one `true` per provider
    /// that has any accounts at all.
    public let isDefault: Bool
    /// Quota-meter lines only (`.progress`) -- cache-temperature and other enrichment badges are
    /// a per-session concept that doesn't generalize across accounts the way a quota meter does,
    /// so they're intentionally left out of this multi-account view.
    public let lines: [MetricLine]
    public let error: ProviderError?
    public let fetchedAt: Date

    public init(id: String, providerID: ProviderID, label: String, isDefault: Bool, lines: [MetricLine], error: ProviderError?, fetchedAt: Date) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.isDefault = isDefault
        self.lines = lines
        self.error = error
        self.fetchedAt = fetchedAt
    }
}

extension MetricLine {
    /// Whether this line is a quota meter (`.progress`) -- the only kind `ProviderAccount` keeps.
    var isQuotaMeter: Bool {
        if case .progress = self { return true }
        return false
    }
}
