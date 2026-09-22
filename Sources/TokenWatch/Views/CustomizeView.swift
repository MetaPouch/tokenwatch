import SwiftUI
import TokenWatchCore

/// Customize screen (pure content -- chrome/back-navigation lives in `DashboardView`'s shared
/// pager top bar): a provider list (on/off, drag to reorder, tap into detail) plus a per-provider
/// detail (Always Visible / On Demand sections, drag a metric between them, star up to two for
/// the menu bar). `detailProvider` is owned by `DashboardView` so its shared top bar can show
/// the right title/back-chevron/Reset-vs-Reset-All for whichever level is showing.
struct CustomizeView: View {
    @ObservedObject var enablementStore: ProviderEnablementStore
    @ObservedObject var layoutStore: LayoutStore
    @ObservedObject var dataStore: WidgetDataStore
    @Binding var detailProvider: ProviderID?
    @ObservedObject var hintStore: HintStore

    @State private var draggingProvider: ProviderID?
    @State private var draggingMetricID: String?
    @State private var starRejectionMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if let detailProvider {
                providerDetail(detailProvider)
            } else {
                providerList
            }
            if let starRejectionMessage {
                Text(starRejectionMessage)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.orange, in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .reportPanelHeight(for: .customize)
    }


    // MARK: - Provider list

    private var providerList: some View {
        MeasuredScrollView(maxHeight: 640, refreshID: "\(enablementStore.enabledProviders.count)-\(dataStore.snapshots.count)") {
            VStack(spacing: 4) {
                if !hintStore.customizeTipDismissed {
                    customizeTip
                }
                ForEach(ProviderID.allCases) { provider in
                    providerListRow(provider)
                        .opacity(draggingProvider == provider ? 0.4 : 1)
                        .onDrag {
                            draggingProvider = provider
                            return NSItemProvider(object: provider.rawValue as NSString)
                        }
                        .onDrop(of: [.text], delegate: ProviderDropDelegate(
                            target: provider,
                            draggingProvider: $draggingProvider,
                            enabled: enablementStore.enabledProviders,
                            layoutStore: layoutStore
                        ))
                }
            }
            .padding(14)
        }
    }

    /// Shown once -- dismissed permanently via `HintStore`.
    private var customizeTip: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.point.up.left.fill")
                .foregroundStyle(.blue)
            Text("Drag rows to reorder. Tap a provider to move metrics between Always Visible and On Demand, and star up to two for the menu bar.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button(action: hintStore.dismissCustomizeTip) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func providerListRow(_ provider: ProviderID) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.caption)
            ProviderIcon(provider: provider, size: 16)
            Text(provider.displayName).font(.subheadline)
            Spacer()
            Text("\(metricCount(provider)) metrics")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Toggle("", isOn: Binding(
                get: { enablementStore.isEnabled(provider) },
                set: { enablementStore.setEnabled(provider, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            Button(action: { detailProvider = provider }) {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .opacity(enablementStore.isEnabled(provider) ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture { detailProvider = provider }
    }

    private func metricCount(_ provider: ProviderID) -> Int {
        dataStore.snapshot(for: provider)?.lines.count ?? 0
    }

    // MARK: - Provider detail

    private func providerDetail(_ provider: ProviderID) -> some View {
        let lines = dataStore.snapshot(for: provider)?.lines ?? []
        let alwaysVisible = lines.filter { layoutStore.layout(for: provider, metricID: $0.id).tier == .alwaysVisible }
        let onDemand = lines.filter { layoutStore.layout(for: provider, metricID: $0.id).tier == .onDemand }

        return MeasuredScrollView(maxHeight: 640, refreshID: "\(provider.rawValue)-\(alwaysVisible.count)-\(onDemand.count)") {
            VStack(alignment: .leading, spacing: 16) {
                metricTierSection(title: "Always Visible", provider: provider, lines: alwaysVisible, tier: .alwaysVisible, emptyHint: "Drag metrics here")
                metricTierSection(title: "On Demand", provider: provider, lines: onDemand, tier: .onDemand, emptyHint: "Drag metrics here")
            }
            .padding(14)
        }
    }

    private func metricTierSection(title: String, provider: ProviderID, lines: [MetricLine], tier: MetricVisibilityTier, emptyHint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if lines.isEmpty {
                Text(emptyHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])))
                    .onDrop(of: [.text], delegate: MetricDropDelegate(
                        provider: provider, targetMetricID: nil, targetTier: tier,
                        draggingMetricID: $draggingMetricID, layoutStore: layoutStore
                    ))
            } else {
                VStack(spacing: 2) {
                    ForEach(lines) { line in
                        metricDetailRow(provider: provider, line: line)
                            .opacity(draggingMetricID == line.id ? 0.4 : 1)
                            .onDrag {
                                draggingMetricID = line.id
                                return NSItemProvider(object: line.id as NSString)
                            }
                            .onDrop(of: [.text], delegate: MetricDropDelegate(
                                provider: provider, targetMetricID: line.id, targetTier: tier,
                                draggingMetricID: $draggingMetricID, layoutStore: layoutStore
                            ))
                    }
                }
                .padding(6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func metricDetailRow(provider: ProviderID, line: MetricLine) -> some View {
        let layout = layoutStore.layout(for: provider, metricID: line.id)
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.caption2)
            Text(rowLabel(line))
                .font(.caption)
            Spacer()
            Button(action: { toggleStar(provider: provider, metricID: line.id) }) {
                Image(systemName: layout.starred ? "star.fill" : "star")
                    .foregroundStyle(layout.starred ? Color.yellow : Color.secondary.opacity(0.5))
                    .font(.caption)
            }
            .buttonStyle(.plain)
            Toggle("", isOn: Binding(
                get: { !layout.hidden },
                set: { layoutStore.setHidden(!$0, provider: provider, metricID: line.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
    }

    private func toggleStar(provider: ProviderID, metricID: String) {
        let ok = layoutStore.toggleStar(provider: provider, metricID: metricID)
        guard !ok else { return }
        starRejectionMessage = "Up to \(LayoutStore.maxStarsPerProvider) stars per provider"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            starRejectionMessage = nil
        }
    }

    private func rowLabel(_ line: MetricLine) -> String {
        switch line {
        case let .progress(_, label, _, _, _, _, _): return label
        case let .values(_, label, _): return label
        case let .badge(_, text, _, _, _): return text
        case let .chart(_, label, _): return label
        case let .text(_, value): return value
        }
    }
}

/// Reorders the enabled-provider list as a row is dragged over another.
struct ProviderDropDelegate: DropDelegate {
    let target: ProviderID
    @Binding var draggingProvider: ProviderID?
    let enabled: Set<ProviderID>
    let layoutStore: LayoutStore

    func dropEntered(info: DropInfo) {
        guard let draggingProvider, draggingProvider != target else { return }
        let order = layoutStore.orderedProviders(enabled: enabled)
        guard let toIndex = order.firstIndex(of: target) else { return }
        layoutStore.moveProvider(draggingProvider, enabled: enabled, toIndex: toIndex)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingProvider = nil
        return true
    }
}

/// Reorders a metric within/across the Always Visible and On Demand sections as it's dragged.
private struct MetricDropDelegate: DropDelegate {
    let provider: ProviderID
    let targetMetricID: String?
    let targetTier: MetricVisibilityTier
    @Binding var draggingMetricID: String?
    let layoutStore: LayoutStore

    func dropEntered(info: DropInfo) {
        guard let draggingMetricID else { return }
        layoutStore.setTier(targetTier, provider: provider, metricID: draggingMetricID)
        if let targetMetricID, targetMetricID != draggingMetricID {
            let targetOrder = layoutStore.layout(for: provider, metricID: targetMetricID).order
            layoutStore.setOrder(targetOrder, provider: provider, metricID: draggingMetricID)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingMetricID = nil
        return true
    }
}
