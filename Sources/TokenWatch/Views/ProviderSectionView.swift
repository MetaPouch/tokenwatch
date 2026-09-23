import SwiftUI
import AppKit
import TokenWatchCore

/// One provider's card in the stacked dashboard list: an icon/name/plan header (with its own
/// right-click menu and an "Outdated" tag) over its metric rows, split into an always-visible
/// section and an on-demand section that hides behind an expand caret. A metric defaults to
/// always-visible until Customize moves it on-demand, so the caret only appears once a provider
/// actually has something tucked away.
struct ProviderSectionView: View {
    let provider: ProviderID
    let snapshot: ProviderSnapshot?
    @ObservedObject var layoutStore: LayoutStore
    @ObservedObject var displayStore: MeterDisplayStore
    let refreshIntervalSeconds: Int
    var timeFormat: TimeFormatPreference = .auto
    /// Which tab this card is rendering for -- filters `snapshot.lines` to just that category
    /// (see `MetricLine.category`) so quota bars only show under Limits and spend/cache-activity
    /// info only shows under Usage, instead of every provider mixing both on one card.
    let category: MetricCategory
    /// Whether to show the drag handle and accept reordering -- Limits owns provider order;
    /// Usage renders the same card type read-only, so its handle would do nothing if shown.
    var isDraggable: Bool = true
    /// Non-nil only for providers with a local spend-history scanner (today: Claude only), and
    /// only rendered when `category == .usage`. The inline Today/Yesterday spend row is simply
    /// absent for every other provider or on the Limits card.
    var spendHistoryStore: ClaudeSpendHistoryStore?
    var onRefresh: () -> Void
    var onHideProvider: () -> Void
    var onCustomizeProvider: () -> Void

    @Environment(\.appDensity) private var density
    @State private var isExpanded: Bool
    @State private var isSpendRowExpanded: Bool

    init(provider: ProviderID, snapshot: ProviderSnapshot?, layoutStore: LayoutStore, displayStore: MeterDisplayStore, refreshIntervalSeconds: Int, timeFormat: TimeFormatPreference = .auto, category: MetricCategory, isDraggable: Bool = true, spendHistoryStore: ClaudeSpendHistoryStore? = nil, onRefresh: @escaping () -> Void, onHideProvider: @escaping () -> Void, onCustomizeProvider: @escaping () -> Void) {
        self.provider = provider
        self.snapshot = snapshot
        self.layoutStore = layoutStore
        self.displayStore = displayStore
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.timeFormat = timeFormat
        self.category = category
        self.isDraggable = isDraggable
        self.spendHistoryStore = spendHistoryStore
        self.onRefresh = onRefresh
        self.onHideProvider = onHideProvider
        self.onCustomizeProvider = onCustomizeProvider
        _isExpanded = State(initialValue: UserDefaults.standard.bool(forKey: "sectionExpanded.\(provider.rawValue)"))
        _isSpendRowExpanded = State(initialValue: UserDefaults.standard.object(forKey: "spendRowExpanded.\(provider.rawValue)") as? Bool ?? true)
    }

    /// Whether this provider has anything at all to show for `category` -- lets a caller skip
    /// rendering an empty (header-only) card, e.g. most providers have no `.usage` lines today.
    static func hasContent(snapshot: ProviderSnapshot?, category: MetricCategory, layoutStore: LayoutStore, provider: ProviderID, spendHistoryStore: ClaudeSpendHistoryStore? = nil) -> Bool {
        if category == .usage, let spendHistoryStore, !spendHistoryStore.isLoading {
            let hasSpend = SpendAggregator.amount(for: .today, days: spendHistoryStore.days) > 0
                || SpendAggregator.amount(for: .yesterday, days: spendHistoryStore.days) > 0
            if hasSpend { return true }
        }
        guard let snapshot else { return false }
        return snapshot.lines.contains { line in
            line.category == category && !layoutStore.layout(for: provider, metricID: line.id).hidden
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Density.sectionSpacing(density)) {
            header
            if category == .usage, let spendHistoryStore, !spendHistoryStore.isLoading {
                inlineSpendRow(store: spendHistoryStore)
            }
            if let snapshot {
                let alwaysVisible = filteredLines(snapshot: snapshot, tier: .alwaysVisible)
                let onDemand = filteredLines(snapshot: snapshot, tier: .onDemand)
                // An error or empty snapshot has no lines in either tier -- fall through to
                // ProviderCardView's own error/empty-state rendering by passing every line.
                let showAll = alwaysVisible.isEmpty && onDemand.isEmpty
                ProviderCardView(
                    snapshot: snapshot,
                    lines: showAll ? nil : alwaysVisible,
                    displayStore: displayStore,
                    layoutStore: layoutStore,
                    onRefreshProvider: onRefresh,
                    timeFormat: timeFormat
                )
                if isExpanded && !onDemand.isEmpty {
                    ProviderCardView(
                        snapshot: snapshot,
                        lines: onDemand,
                        displayStore: displayStore,
                        layoutStore: layoutStore,
                        onRefreshProvider: onRefresh,
                        timeFormat: timeFormat
                    )
                }
            } else {
                Text("Loading…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Density.cardPadding(density))
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 6) {
            if isDraggable {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ProviderIcon(provider: provider, size: 16)
            Text(provider.displayName).font(.subheadline.weight(.semibold))
            if let plan = snapshot?.plan, !plan.isEmpty {
                Text(plan)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let snapshot, isOutdated(snapshot) {
                Text("Outdated")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help("Last updated \(relativeShort(snapshot.fetchedAt)) ago")
            }
            Spacer(minLength: 0)
            if let snapshot, !filteredLines(snapshot: snapshot, tier: .onDemand).isEmpty {
                Button(action: toggleExpanded) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            Button("Hide \(provider.displayName)") { onHideProvider() }
            Divider()
            Button("Refresh \(provider.displayName)") { onRefresh() }
            Button("Customize…") { onCustomizeProvider() }
            if snapshot != nil {
                Divider()
                Button("Share Screenshot") { shareScreenshot() }
            }
        }
    }


    private func toggleExpanded() {
        isExpanded.toggle()
        UserDefaults.standard.set(isExpanded, forKey: "sectionExpanded.\(provider.rawValue)")
    }

    /// Today/Yesterday local spend, chevron-collapsible to a per-model cost breakdown --
    /// mirrors `TotalSpendCard`'s cross-provider donut, scoped to just this provider. Absent
    /// entirely when neither day has any recorded spend (a brand-new install, or a provider with
    /// no local spend-history scanner never gets here at all -- see `spendHistoryStore`).
    @ViewBuilder
    private func inlineSpendRow(store: ClaudeSpendHistoryStore) -> some View {
        let today = SpendAggregator.amount(for: .today, days: store.days)
        let yesterday = SpendAggregator.amount(for: .yesterday, days: store.days)
        if today > 0 || yesterday > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: toggleSpendRow) {
                    HStack(spacing: 4) {
                        Image(systemName: isSpendRowExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text("Today \(compactDollars(today))")
                            .font(.caption2.weight(.medium))
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                        Text("Yesterday \(compactDollars(yesterday))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                if isSpendRowExpanded {
                    modelBreakdown(days: store.days)
                }
            }
        }
    }

    private func toggleSpendRow() {
        isSpendRowExpanded.toggle()
        UserDefaults.standard.set(isSpendRowExpanded, forKey: "spendRowExpanded.\(provider.rawValue)")
    }

    /// Ranked per-model spend for today, shown inline under the spend row once expanded.
    private func modelBreakdown(days: [ClaudeUsageDay]) -> some View {
        let breakdown = SpendAggregator.modelBreakdown(for: .today, days: days)
        let total = breakdown.reduce(0) { $0 + $1.costUSD }
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(breakdown) { model in
                HStack(spacing: 6) {
                    Text(model.id)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    let share = total > 0 ? model.costUSD / total : 0
                    Text("\(Int((share * 100).rounded()))%")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(compactDollars(model.costUSD))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 12)
        .padding(.top, 2)
    }

    private func compactDollars(_ amount: Double) -> String {
        amount < 10 ? String(format: "$%.2f", amount) : String(format: "$%.0f", amount)
    }

    private func filteredLines(snapshot: ProviderSnapshot, tier: MetricVisibilityTier) -> [MetricLine] {
        snapshot.lines.filter { line in
            guard line.category == category else { return false }
            let layout = layoutStore.layout(for: provider, metricID: line.id)
            return !layout.hidden && layout.tier == tier
        }
    }

    /// A successful-but-aging snapshot is flagged once it's more than two refresh cycles old --
    /// long enough that it's very unlikely to just be "the refresh currently in flight."
    private func isOutdated(_ snapshot: ProviderSnapshot) -> Bool {
        guard snapshot.error == nil else { return false }
        return Date().timeIntervalSince(snapshot.fetchedAt) > Double(refreshIntervalSeconds) * 2
    }

    private func relativeShort(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Renders this provider's card to a PNG and copies it to the clipboard.
    private func shareScreenshot() {
        guard let snapshot else { return }
        ProviderScreenshot.share(provider: provider, snapshot: snapshot, displayStore: displayStore, density: density, timeFormat: timeFormat)
    }
}
