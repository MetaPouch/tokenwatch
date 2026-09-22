import SwiftUI
import TokenWatchCore

/// Cross-provider spend summary: a donut segmented by provider, a Today/Yesterday/30 Days
/// toggle, and a centered total. Sources spend from whichever enabled providers have a local
/// spend-history scanner wired in -- today that's Claude only, via `ClaudeUsageHistoryScanner`
/// -- so adding another provider's local spend is additive to `providerTotals`, not a rewrite of
/// this view. Renders nothing (not an empty card) when no enabled provider has spend data for
/// the selected period, matching the rest of the dashboard's "never show a misleading zero"
/// stance.
struct TotalSpendCard: View {
    @ObservedObject var dataStore: WidgetDataStore
    @ObservedObject var enablementStore: ProviderEnablementStore

    @State private var period: SpendPeriod = .today
    @State private var claudeDays: [ClaudeUsageDay] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if !isLoading, let totals = providerTotals, !totals.isEmpty {
                card(totals: totals)
            } else {
                // A `Group` whose content is *conditionally entirely empty* on first render
                // doesn't reliably fire `.task`/`.onAppear` in SwiftUI -- confirmed via direct
                // instrumentation (the load below never even started). Always render something
                // concrete, even a zero-size placeholder, so this view has a stable identity to
                // attach the task to from the very first frame.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task {
            // `.utility` QoS measured far slower than a foreground process for the identical
            // scan under this app's background/App-Nap-eligible state -- this gates visible UI
            // content the user is actively waiting on, so it runs at `.userInitiated` priority
            // and explicitly opts out of App Nap (see `withBackgroundActivity`).
            let result = await withBackgroundActivity(reason: "Scanning local Claude spend history") {
                await Task.detached(priority: .userInitiated) {
                    ClaudeUsageHistoryScanner.dailyUsage(days: 30)
                }.value
            }
            claudeDays = result
            isLoading = false
        }
    }

    /// One entry per provider with spend in the selected period, largest first. `nil` while
    /// still loading.
    private var providerTotals: [(provider: ProviderID, amount: Double)]? {
        guard !isLoading else { return nil }
        var totals: [(ProviderID, Double)] = []
        if enablementStore.isEnabled(.claude) {
            let amount = SpendAggregator.amount(for: period, days: claudeDays)
            if amount > 0 { totals.append((.claude, amount)) }
        }
        return totals.sorted { $0.1 > $1.1 }.map { (provider: $0.0, amount: $0.1) }
    }

    private func card(totals: [(provider: ProviderID, amount: Double)]) -> some View {
        let total = totals.reduce(0) { $0 + $1.amount }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Total Spend").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("", selection: $period) {
                    ForEach(SpendPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            HStack(spacing: 16) {
                donut(totals: totals, total: total)
                    .frame(width: 72, height: 72)
                legend(totals: totals, total: total)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func donut(totals: [(provider: ProviderID, amount: Double)], total: Double) -> some View {
        ZStack {
            Canvas { context, size in
                let lineWidth: CGFloat = 10
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
                var startAngle = Angle(degrees: -90)
                for entry in totals {
                    let fraction = total > 0 ? entry.amount / total : 0
                    // A tiny share still gets a visible sliver rather than vanishing entirely.
                    let sweep = Angle(degrees: max(fraction * 360, totals.count > 1 ? 3 : 360))
                    var path = Path()
                    path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: startAngle, endAngle: startAngle + sweep, clockwise: false)
                    context.stroke(path, with: .color(brandColor(entry.provider)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    startAngle += sweep
                }
            }
            VStack(spacing: 0) {
                Text(compactDollars(total))
                    .font(.caption.weight(.bold).monospacedDigit())
                Text("dollars")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func legend(totals: [(provider: ProviderID, amount: Double)], total: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(totals, id: \.provider) { entry in
                HStack(spacing: 5) {
                    Circle().fill(brandColor(entry.provider)).frame(width: 6, height: 6)
                    Text(entry.provider.displayName).font(.caption2)
                    Spacer(minLength: 8)
                    Text(compactDollars(entry.amount)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Fixed per-provider accent so the same provider always reads the same color across the
    /// donut and its legend -- doesn't need to match every provider's real brand color exactly,
    /// just stay stable and distinct.
    private func brandColor(_ provider: ProviderID) -> Color {
        switch provider {
        case .claude: return Color(red: 0.82, green: 0.47, blue: 0.35)
        case .codex, .openai: return .green
        case .gemini, .antigravity: return .blue
        case .cursor: return .purple
        case .copilot: return .indigo
        case .openrouter: return .pink
        case .zai: return .teal
        case .kimi: return .mint
        case .amp: return .cyan
        case .grok: return .gray
        case .opencode: return .orange
        }
    }

    private func compactDollars(_ amount: Double) -> String {
        if amount >= 1000 { return String(format: "$%.1fK", amount / 1000) }
        if amount < 0.01 && amount > 0 { return "<$0.01" }
        return String(format: "$%.2f", amount)
    }
}
