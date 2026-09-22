import Foundation
import Combine

/// Which section of a provider's card a metric renders in. Always-visible metrics render
/// directly on the card; on-demand metrics hide behind an expand caret until opened.
public enum MetricVisibilityTier: String, Sendable, Codable {
    case alwaysVisible
    case onDemand
}

/// Per-metric customization, keyed externally by `"\(provider.rawValue):\(metricLine.id)"`.
public struct MetricLayout: Sendable, Codable, Equatable {
    public var tier: MetricVisibilityTier
    public var starred: Bool
    public var hidden: Bool
    /// Explicit sort position within its tier; ties broken by the mapper's natural order.
    public var order: Int

    public init(tier: MetricVisibilityTier = .alwaysVisible, starred: Bool = false, hidden: Bool = false, order: Int = 0) {
        self.tier = tier
        self.starred = starred
        self.hidden = hidden
        self.order = order
    }
}

private struct LayoutFile: Codable {
    var providerOrder: [String]
    var metrics: [String: MetricLayout]
}

/// Persists dashboard customization -- provider order and per-metric tier/star/hidden state --
/// to its own `layout.json`, deliberately independent of `AppConfig`/`ConfigStore` so a decode
/// failure here can never take down provider enablement (or vice versa).
@MainActor
public final class LayoutStore: ObservableObject {
    @Published public private(set) var providerOrder: [ProviderID]
    @Published public private(set) var metricLayouts: [String: MetricLayout]

    private let fileURL: URL
    /// Matches the competitor UX this was modeled on: enough to keep the menu bar readable,
    /// forces a deliberate choice about which two numbers matter most for a given provider.
    public static let maxStarsPerProvider = 2
    private static let maxUndoDepth = 20

    /// Snapshots pushed before each customization mutation; `undo()` pops and restores the
    /// most recent one, so repeated ⌘Z steps back through recent changes one at a time.
    /// Deliberately in-memory only (not persisted) -- undo history starts fresh each launch.
    private var undoStack: [(providerOrder: [ProviderID], metricLayouts: [String: MetricLayout])] = []

    public var canUndo: Bool { !undoStack.isEmpty }

    public init(directory: URL? = nil) {
        let base = directory ?? ConfigStore.defaultDirectory()
        self.fileURL = base.appendingPathComponent("layout.json")
        let loaded = Self.load(from: fileURL)
        self.providerOrder = loaded?.providerOrder.compactMap { ProviderID(rawValue: $0) } ?? []
        self.metricLayouts = loaded?.metrics ?? [:]
    }

    /// Enabled providers in stored order; a provider enabled after the layout was last saved
    /// (or never reordered) is appended at the end rather than dropped.
    public func orderedProviders(enabled: Set<ProviderID>) -> [ProviderID] {
        var seen = Set<ProviderID>()
        var result: [ProviderID] = []
        for provider in providerOrder where enabled.contains(provider) && !seen.contains(provider) {
            result.append(provider)
            seen.insert(provider)
        }
        for provider in ProviderID.allCases where enabled.contains(provider) && !seen.contains(provider) {
            result.append(provider)
            seen.insert(provider)
        }
        return result
    }

    /// Reorders `provider` to `toIndex` among the currently-enabled set. Providers outside
    /// `enabled` keep their stored relative order, appended after the visible ones, so their
    /// customization survives being toggled off and back on.
    public func moveProvider(_ provider: ProviderID, enabled: Set<ProviderID>, toIndex: Int) {
        var order = orderedProviders(enabled: enabled)
        guard let from = order.firstIndex(of: provider) else { return }
        recordUndoSnapshot()
        order.remove(at: from)
        order.insert(provider, at: min(max(toIndex, 0), order.count))
        let untouched = providerOrder.filter { !enabled.contains($0) }
        providerOrder = order + untouched
        persist()
    }

    private func key(_ provider: ProviderID, _ metricID: String) -> String { "\(provider.rawValue):\(metricID)" }

    public func layout(for provider: ProviderID, metricID: String) -> MetricLayout {
        metricLayouts[key(provider, metricID)] ?? MetricLayout()
    }

    public func setTier(_ tier: MetricVisibilityTier, provider: ProviderID, metricID: String) {
        recordUndoSnapshot()
        var layout = layout(for: provider, metricID: metricID)
        layout.tier = tier
        metricLayouts[key(provider, metricID)] = layout
        persist()
    }

    public func setHidden(_ hidden: Bool, provider: ProviderID, metricID: String) {
        recordUndoSnapshot()
        var layout = layout(for: provider, metricID: metricID)
        layout.hidden = hidden
        metricLayouts[key(provider, metricID)] = layout
        persist()
    }

    public func setOrder(_ order: Int, provider: ProviderID, metricID: String) {
        recordUndoSnapshot()
        var layout = layout(for: provider, metricID: metricID)
        layout.order = order
        metricLayouts[key(provider, metricID)] = layout
        persist()
    }


    /// Returns `false` (state unchanged) when starring would exceed the per-provider cap --
    /// callers show a rejection instead of silently no-opping.
    @discardableResult
    public func toggleStar(provider: ProviderID, metricID: String) -> Bool {
        var layout = layout(for: provider, metricID: metricID)
        if !layout.starred {
            let currentStars = starredMetricIDs(for: provider).count
            guard currentStars < Self.maxStarsPerProvider else { return false }
        }
        recordUndoSnapshot()
        layout.starred.toggle()
        metricLayouts[key(provider, metricID)] = layout
        persist()
        return true
    }

    public func starredMetricIDs(for provider: ProviderID) -> [String] {
        let prefix = "\(provider.rawValue):"
        return metricLayouts
            .filter { $0.key.hasPrefix(prefix) && $0.value.starred }
            .map { String($0.key.dropFirst(prefix.count)) }
    }

    /// Restores one provider's metrics to their defaults (no stored customization) without
    /// touching its position in `providerOrder` or any other provider's metrics.
    public func resetProvider(_ provider: ProviderID) {
        let prefix = "\(provider.rawValue):"
        metricLayouts = metricLayouts.filter { !$0.key.hasPrefix(prefix) }
        persist()
    }

    /// Wipes all customization: provider order and every metric's tier/star/hidden state.
    public func resetAll() {
        providerOrder = []
        metricLayouts = [:]
        undoStack.removeAll()
        persist()
    }

    /// Steps back one customization change: hiding/showing, reordering, starring, and moving a
    /// metric across the tier boundary all undo. No-op when there's nothing to undo.
    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        providerOrder = previous.providerOrder
        metricLayouts = previous.metricLayouts
        persist()
    }

    private func recordUndoSnapshot() {
        undoStack.append((providerOrder: providerOrder, metricLayouts: metricLayouts))
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth)
        }
    }

    private func persist() {
        let file = LayoutFile(providerOrder: providerOrder.map(\.rawValue), metrics: metricLayouts)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> LayoutFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LayoutFile.self, from: data)
    }
}
