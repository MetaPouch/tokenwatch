import SwiftUI
import TokenWatchCore

/// Estimated daily token/cost history from local Claude session logs (both the real `claude` CLI
/// and a coding-agent harness's own transcripts -- see `ClaudeUsageHistoryScanner`), priced at
/// API list rates (`ModelPricing`). Scoped to Claude only and a 7-day window: a meaningful
/// trailing-week view without the full-file-scan cost of a longer one -- a machine with a long
/// session history can take several real seconds to scan (confirmed during development), so this
/// always runs off the main actor and shows a loading state rather than blocking the tab.
struct UsageHistoryView: View {
    @State private var days: [ClaudeUsageDay] = []
    @State private var isLoading = true
    @State private var showCost = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude · last 7 days")
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

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 24)
            } else if days.allSatisfy({ $0.totalTokens == 0 }) {
                Text("No local Claude activity in the last 7 days")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                chart
                Text("Estimated at API list rates, refreshed against live pricing when reachable (static fallback updated \(ModelPricing.pricingTableUpdatedOn)) -- subscription usage isn't billed per token.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .task {
            // App Nap can throttle this app's background work far more than a QoS bump alone
            // fixes (see TotalSpendCard) -- explicitly opt out since this gates visible UI
            // content the user is actively waiting on.
            let result = await withBackgroundActivity(reason: "Scanning local Claude usage history") {
                await Task.detached(priority: .userInitiated) {
                    ClaudeUsageHistoryScanner.dailyUsage(days: 7)
                }.value
            }
            days = result
            isLoading = false
        }
    }

    private var chart: some View {
        let maxValue = max(days.map { showCost ? $0.estimatedCostUSD : Double($0.totalTokens) }.max() ?? 0, 0.0001)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                let magnitude = showCost ? day.estimatedCostUSD : Double(day.totalTokens)
                VStack(spacing: 3) {
                    Text(valueLabel(day))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    RoundedRectangle(cornerRadius: 2)
                        .fill(day.hasApproximateRate ? Color.orange.opacity(0.6) : Color.accentColor.opacity(0.7))
                        .frame(height: max(2, CGFloat(magnitude / maxValue) * 80))
                    Text(dayLabel(day.date))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 110, alignment: .bottom)
    }

    private func valueLabel(_ day: ClaudeUsageDay) -> String {
        guard showCost else { return formatTokenCount(day.totalTokens) }
        guard day.estimatedCostUSD > 0 else { return "" }
        return day.estimatedCostUSD < 0.01 ? "<$0.01" : String(format: "$%.2f", day.estimatedCostUSD)
    }

    private func formatTokenCount(_ tokens: Int) -> String {
        if tokens == 0 { return "" }
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return "\(Int((Double(tokens) / 1_000).rounded()))k" }
        return "\(tokens)"
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }
}
