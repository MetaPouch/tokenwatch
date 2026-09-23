import SwiftUI
import TokenWatchCore

/// The last 7 days inside `TotalSpendCard`: one bar per day, stacked by provider in brand colors,
/// in whichever quantity the card shows (`SpendMetricMode`). Per-token rates don't stack, so
/// Cost/MTok draws one bar per day of combined cost over combined tokens. The days the card's
/// selected period covers stay full strength and the rest dim, tying the bars to the donut above.
struct SpendHistoryChart: View {
    @ObservedObject var store: SpendHistoryStore
    /// Which providers to include, in stacking order (bottom first).
    let providers: [ProviderID]
    let mode: SpendMetricMode
    let period: SpendPeriod

    private struct Day: Identifiable {
        let id: String
        let date: Date
        let byProvider: [(provider: ProviderID, day: UsageDay)]
    }

    /// One entry per day (oldest first, ending today), each with every provider's day for that date.
    private var days: [Day] {
        let series = providers.map { ($0, Array(store.days(for: $0).suffix(7))) }
        guard let reference = series.first?.1 else { return [] }
        return reference.map { referenceDay in
            Day(id: referenceDay.id, date: referenceDay.date, byProvider: series.compactMap { provider, providerDays in
                providerDays.first { $0.id == referenceDay.id }.map { (provider: provider, day: $0) }
            })
        }
    }

    var body: some View {
        let days = days
        let segments = days.map(segments(for:))
        let totals = days.map(total(for:))
        let maxValue = max(totals.max() ?? 0, 0.0001)
        VStack(alignment: .leading, spacing: 6) {
            Text("Last 7 days")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    VStack(spacing: 3) {
                        Text(valueLabel(total: totals[index], approximate: day.byProvider.contains { $0.day.hasApproximateRate }))
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                        VStack(spacing: 0) {
                            ForEach(Array(segments[index].reversed().enumerated()), id: \.offset) { _, segment in
                                Rectangle()
                                    .fill(segment.color)
                                    .frame(height: CGFloat(segment.value / maxValue) * 64)
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
                    .opacity(isInPeriod(index: index, count: days.count) ? 1 : 0.35)
                }
            }
            .frame(height: 92, alignment: .bottom)
        }
    }

    /// Bar segments for one day, bottom first.
    private func segments(for day: Day) -> [(color: Color, value: Double)] {
        switch mode {
        case .cost:
            return day.byProvider.map { (BrandColor.forProvider($0.provider), $0.day.estimatedCostUSD) }.filter { $0.value > 0 }
        case .tokens:
            return day.byProvider.map { (BrandColor.forProvider($0.provider), Double($0.day.totalTokens)) }.filter { $0.value > 0 }
        case .costPerMTok:
            let value = total(for: day)
            return value > 0 ? [(Color.accentColor.opacity(0.7), value)] : []
        }
    }

    private func total(for day: Day) -> Double {
        let cost = day.byProvider.reduce(0) { $0 + $1.day.estimatedCostUSD }
        let tokens = day.byProvider.reduce(0) { $0 + $1.day.totalTokens }
        switch mode {
        case .cost: return cost
        case .tokens: return Double(tokens)
        case .costPerMTok: return tokens > 0 ? cost / Double(tokens) * 1_000_000 : 0
        }
    }

    /// Days run oldest first and end today.
    private func isInPeriod(index: Int, count: Int) -> Bool {
        switch period {
        case .today: return index == count - 1
        case .yesterday: return index == count - 2
        case .thirtyDays: return true
        }
    }

    private func valueLabel(total: Double, approximate: Bool) -> String {
        guard total > 0 else { return "" }
        let prefix = approximate ? "~" : ""
        switch mode {
        case .cost: return total < 0.01 ? "<$0.01" : prefix + (total >= 1000 ? String(format: "$%.1fK", total / 1000) : String(format: "$%.0f", total))
        case .tokens: return prefix + TokenCountFormatter.compact(Int(total))
        case .costPerMTok: return prefix + String(format: "$%.2f", total)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return formatter
    }()

    private func dayLabel(_ date: Date) -> String {
        Self.dayFormatter.string(from: date)
    }
}
