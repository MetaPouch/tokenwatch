import SwiftUI
import TokenWatchCore

/// Estimated daily token/cost history for the last 7 days, one bar per day stacked by provider in
/// each provider's brand color -- every enabled provider with a local usage-history scanner
/// (`SpendHistoryStore.providers`), priced at API list rates (`ModelPricing`). Sliced from the
/// shared 30-day `SpendHistoryStore`, so switching to the Usage tab is instant after the first
/// load instead of a fresh multi-second disk scan every time.
struct UsageHistoryView: View {
    @ObservedObject var store: SpendHistoryStore
    /// Which providers to include, in stacking order (bottom first).
    let providers: [ProviderID]
    @State private var showCost = true

    /// One entry per day (oldest first), each with every provider's day for that date.
    private var days: [(id: String, date: Date, byProvider: [(provider: ProviderID, day: UsageDay)])] {
        let series = providers.map { ($0, Array(store.days(for: $0).suffix(7))) }
        guard let reference = series.first?.1 else { return [] }
        return reference.map { referenceDay in
            let byProvider = series.compactMap { provider, providerDays in
                providerDays.first { $0.id == referenceDay.id }.map { (provider: provider, day: $0) }
            }
            return (referenceDay.id, referenceDay.date, byProvider)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last 7 days")
                    .font(.caption.weight(.semibold))
                Spacer()
                Picker("", selection: $showCost) {
                    Text("Cost").tag(true)
                    Text("Tokens").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }

            let days = days
            if store.isLoading {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 24)
            } else if days.allSatisfy({ $0.byProvider.allSatisfy { $0.day.totalTokens == 0 } }) {
                Text("No local activity in the last 7 days")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                chart(days)
                if providers.count > 1 { legend }
                Text("Estimated at API list rates, refreshed against live pricing when reachable (static fallback updated \(ModelPricing.pricingTableUpdatedOn)) -- subscription usage isn't billed per token. ~ marks a day with a model priced approximately.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .task { store.loadIfNeeded() }
    }

    private func magnitude(_ day: UsageDay) -> Double {
        showCost ? day.estimatedCostUSD : Double(day.totalTokens)
    }

    private func chart(_ days: [(id: String, date: Date, byProvider: [(provider: ProviderID, day: UsageDay)])]) -> some View {
        let totals = days.map { $0.byProvider.reduce(0) { $0 + magnitude($1.day) } }
        let maxValue = max(totals.max() ?? 0, 0.0001)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                VStack(spacing: 3) {
                    Text(valueLabel(total: totals[index], approximate: day.byProvider.contains { $0.day.hasApproximateRate }))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    VStack(spacing: 0) {
                        ForEach(day.byProvider.reversed(), id: \.provider) { entry in
                            let value = magnitude(entry.day)
                            if value > 0 {
                                Rectangle()
                                    .fill(BrandColor.forProvider(entry.provider))
                                    .frame(height: CGFloat(value / maxValue) * 80)
                            }
                        }
                    }
                    .frame(minHeight: 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    Text(dayLabel(day.date))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 110, alignment: .bottom)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(providers, id: \.self) { provider in
                HStack(spacing: 4) {
                    Circle().fill(BrandColor.forProvider(provider)).frame(width: 6, height: 6)
                    Text(provider.displayName).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func valueLabel(total: Double, approximate: Bool) -> String {
        guard total > 0 else { return "" }
        let prefix = approximate ? "~" : ""
        guard showCost else { return prefix + TokenCountFormatter.compact(Int(total)) }
        return total < 0.01 ? "<$0.01" : prefix + String(format: "$%.2f", total)
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }
}
