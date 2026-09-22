import SwiftUI
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
    var onRefresh: () -> Void
    var onHideProvider: () -> Void
    var onCustomizeProvider: () -> Void

    @Environment(\.appDensity) private var density
    @State private var isExpanded: Bool

    init(provider: ProviderID, snapshot: ProviderSnapshot?, layoutStore: LayoutStore, displayStore: MeterDisplayStore, refreshIntervalSeconds: Int, timeFormat: TimeFormatPreference = .auto, onRefresh: @escaping () -> Void, onHideProvider: @escaping () -> Void, onCustomizeProvider: @escaping () -> Void) {
        self.provider = provider
        self.snapshot = snapshot
        self.layoutStore = layoutStore
        self.displayStore = displayStore
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.timeFormat = timeFormat
        self.onRefresh = onRefresh
        self.onHideProvider = onHideProvider
        self.onCustomizeProvider = onCustomizeProvider
        _isExpanded = State(initialValue: UserDefaults.standard.bool(forKey: "sectionExpanded.\(provider.rawValue)"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Density.sectionSpacing(density)) {
            header
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
        }
    }

    private func toggleExpanded() {
        isExpanded.toggle()
        UserDefaults.standard.set(isExpanded, forKey: "sectionExpanded.\(provider.rawValue)")
    }

    private func filteredLines(snapshot: ProviderSnapshot, tier: MetricVisibilityTier) -> [MetricLine] {
        snapshot.lines.filter { line in
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
}
