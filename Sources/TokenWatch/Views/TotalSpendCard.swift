import SwiftUI
import AppKit
import TokenWatchCore

/// Cross-provider spend: a donut segmented by provider for the selected period (Today /
/// Yesterday / 30 Days), a Cost / Cost per MTok / Tokens mode picker, and below it the last 7 days
/// as a stacked bar chart (`SpendHistoryChart`) in the same mode, the selected period's days
/// highlighted. Sources spend from every enabled provider with a local usage-history scanner
/// (`SpendHistoryStore.providers`: Claude and Codex). Shown whenever any of them has history in
/// the window; a period with nothing in it says so instead of drawing an empty donut.
struct TotalSpendCard: View {
    @ObservedObject var dataStore: WidgetDataStore
    @ObservedObject var enablementStore: ProviderEnablementStore
    @ObservedObject var displayStore: MeterDisplayStore
    @ObservedObject var spendHistoryStore: SpendHistoryStore

    @AppStorage("totalSpendPeriod") private var periodRaw: String = SpendPeriod.today.rawValue
    @AppStorage("totalSpendMode") private var modeRaw: String = SpendMetricMode.cost.rawValue
    @State private var isHoveringCenter = false
    @State private var hoveredProvider: ProviderID?

    private var period: SpendPeriod { SpendPeriod(rawValue: periodRaw) ?? .today }
    private var mode: SpendMetricMode { SpendMetricMode(rawValue: modeRaw) ?? .cost }
    private var isLoading: Bool { spendHistoryStore.isLoading }

    var body: some View {
        Group {
            if displayStore.showTotalSpend, !isLoading, hasHistory, let entries = providerValues {
                card(entries: entries)
            } else {
                // A view that's conditionally entirely empty on its first render doesn't
                // reliably fire `.task` in SwiftUI -- always render something concrete so the
                // load below is guaranteed to start.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task { spendHistoryStore.loadIfNeeded() }
    }

    private var historyProviders: [ProviderID] {
        SpendHistoryStore.providers.filter { enablementStore.isEnabled($0) }
    }

    /// Any enabled provider has local activity in the last 7 days (what the chart covers).
    private var hasHistory: Bool {
        historyProviders.contains { spendHistoryStore.days(for: $0).suffix(7).contains { $0.totalTokens > 0 } }
    }

    /// One entry per provider with a nonzero value for the current mode/period, largest first.
    /// `nil` while still loading.
    private var providerValues: [(provider: ProviderID, value: Double)]? {
        guard !isLoading else { return nil }
        var entries: [(provider: ProviderID, value: Double)] = []
        for provider in SpendHistoryStore.providers where enablementStore.isEnabled(provider) {
            let days = spendHistoryStore.days(for: provider)
            let value: Double?
            switch mode {
            case .cost: value = SpendAggregator.amount(for: period, days: days)
            case .tokens: value = Double(SpendAggregator.tokens(for: period, days: days))
            case .costPerMTok: value = SpendAggregator.costPerMillionTokens(for: period, days: days)
            }
            if let value, value > 0 { entries.append((provider, value)) }
        }
        return entries.sorted { $0.value > $1.value }
    }

    /// The figure in the donut's center. Costs and tokens add up across providers; per-token
    /// rates don't, so Cost/MTok is combined cost over combined tokens instead of a sum of rates.
    private func centerValue(entries: [(provider: ProviderID, value: Double)]) -> Double {
        guard mode == .costPerMTok else { return entries.reduce(0) { $0 + $1.value } }
        let days = entries.map { spendHistoryStore.days(for: $0.provider) }
        let cost = days.reduce(0) { $0 + SpendAggregator.amount(for: period, days: $1) }
        let tokens = days.reduce(0) { $0 + SpendAggregator.tokens(for: period, days: $1) }
        return tokens > 0 ? cost / Double(tokens) * 1_000_000 : 0
    }

    private func card(entries: [(provider: ProviderID, value: Double)]) -> some View {
        let total = entries.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(SpendMetricMode.allCases) { candidate in
                        Button(candidate.rawValue) { modeRaw = candidate.rawValue }
                    }
                } label: {
                    // `Menu` already renders its own disclosure chevron -- confirmed via an
                    // isolated render test (a second, manually-added chevron.down showed up as
                    // a visible duplicate). Just the label text here.
                    Text("Total Spend").font(.subheadline.weight(.semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Includes: \(historyProviders.map(\.displayName).joined(separator: ", ")). Estimated at API list rates, refreshed against live pricing when reachable (static fallback updated \(ModelPricing.pricingTableUpdatedOn)) -- subscription usage isn't billed per token. ~ marks a day with a model priced approximately.")
                Spacer()
                Button(action: { shareToClipboard(entries: entries, total: total) }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy a PNG of this card to the clipboard")
            }
            Picker("", selection: $periodRaw) {
                ForEach(SpendPeriod.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if entries.isEmpty {
                Text("No local usage \(period == .thirtyDays ? "in the last 30 days" : period.rawValue.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                HStack(spacing: 16) {
                    donutWithCenter(entries: entries, total: total, center: centerValue(entries: entries))
                        .frame(width: 72, height: 72)
                    legend(entries: entries, total: total)
                }
            }
            Divider()
            chart
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private var chart: some View {
        SpendHistoryChart(store: spendHistoryStore, providers: historyProviders, mode: mode, period: period)
    }

    private func donutWithCenter(entries: [(provider: ProviderID, value: Double)], total: Double, center: Double) -> some View {
        ZStack {
            donut(entries: entries, total: total)
            if isHoveringCenter {
                Text(preciseCenterText(total: center))
                    .font(.system(size: 9, weight: .bold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .lineLimit(2)
                    .padding(4)
            } else {
                VStack(spacing: 0) {
                    Text(compactCenterNumber(total: center))
                        .font(.caption.weight(.bold).monospacedDigit())
                    Text(centerUnit(total: center))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onHover { isHoveringCenter = $0 }
    }

    private func donut(entries: [(provider: ProviderID, value: Double)], total: Double) -> some View {
        Canvas { context, size in
            let lineWidth: CGFloat = 10
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            var startAngle = Angle(degrees: -90)
            for entry in entries {
                let fraction = total > 0 ? entry.value / total : 0
                // A tiny share still gets a visible sliver rather than vanishing entirely.
                let sweep = Angle(degrees: max(fraction * 360, entries.count > 1 ? 3 : 360))
                var path = Path()
                path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: startAngle, endAngle: startAngle + sweep, clockwise: false)
                context.stroke(path, with: .color(BrandColor.forProvider(entry.provider)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                startAngle += sweep
            }
        }
    }

    private func legend(entries: [(provider: ProviderID, value: Double)], total: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(entries, id: \.provider) { entry in
                HStack(spacing: 5) {
                    Circle().fill(BrandColor.forProvider(entry.provider)).frame(width: 6, height: 6)
                    Text(entry.provider.displayName).font(.caption2)
                    Spacer(minLength: 8)
                    Text(legendValueText(entry.value)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .background(hoveredProvider == entry.provider ? Color.secondary.opacity(0.12) : .clear)
                .onHover { isHovering in
                    hoveredProvider = isHovering ? entry.provider : (hoveredProvider == entry.provider ? nil : hoveredProvider)
                }
                .popover(isPresented: Binding(
                    get: { hoveredProvider == entry.provider },
                    set: { if !$0 { hoveredProvider = nil } }
                ), arrowEdge: .trailing) {
                    modelBreakdownPopover(provider: entry.provider)
                }
            }
        }
    }

    /// A ranked per-model spend list for `provider`, shown while hovering its legend row.
    private func modelBreakdownPopover(provider: ProviderID) -> some View {
        let breakdown = SpendAggregator.modelBreakdown(for: period, days: spendHistoryStore.days(for: provider))
        let breakdownTotal = breakdown.reduce(0) { $0 + $1.costUSD }
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(provider.displayName) by model").font(.caption.weight(.semibold))
            ForEach(breakdown) { model in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.id).font(.caption2)
                        Spacer()
                        Text(compactDollars(model.costUSD)).font(.caption2.monospacedDigit())
                    }
                    HStack {
                        let share = breakdownTotal > 0 ? model.costUSD / breakdownTotal : 0
                        Text("\(Int((share * 100).rounded()))% · \(compactTokenCount(Double(model.tokens)))")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    GeometryReader { proxy in
                        Capsule().fill(Color.secondary.opacity(0.2))
                            .overlay(alignment: .leading) {
                                let share = breakdownTotal > 0 ? model.costUSD / breakdownTotal : 0
                                Capsule().fill(BrandColor.forProvider(provider)).frame(width: proxy.size.width * CGFloat(share))
                            }
                    }
                    .frame(height: 3)
                }
            }
        }
        .padding(10)
        .frame(width: 200)
    }


    private func shareToClipboard(entries: [(provider: ProviderID, value: Double)], total: Double) {
        let content = VStack(spacing: 10) {
            Text("TokenWatch — Total Spend").font(.headline)
            if !entries.isEmpty {
                donut(entries: entries, total: total).frame(width: 96, height: 96)
                legend(entries: entries, total: total)
            }
            chart
        }
        .frame(width: 290)
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func centerUnit(total: Double) -> String {
        switch mode {
        case .cost: return "dollars"
        case .tokens: return total >= 1_000_000_000 ? "billion" : "million"
        case .costPerMTok: return "MTok"
        }
    }

    private func compactCenterNumber(total: Double) -> String {
        switch mode {
        case .cost: return compactDollars(total)
        case .tokens: return String(format: "%.1f", total / (total >= 1_000_000_000 ? 1_000_000_000 : 1_000_000))
        case .costPerMTok: return String(format: "$%.2f", total)
        }
    }

    /// Forces Western thousands-grouping regardless of the system locale -- the rest of the
    /// app's number formatting (`String(format: "%.2f", ...)`, the hand-rolled K/M/B suffixes)
    /// is already locale-independent, and Foundation's default `.formatted()` grouping follows
    /// the *current* locale, which on an Indian-locale system renders "74,20,123" (lakhs/crores
    /// grouping) instead of "7,420,123" -- confirmed directly, not assumed.
    private static let groupingLocale = Locale(identifier: "en_US")

    private func preciseCenterText(total: Double) -> String {
        switch mode {
        case .cost: return "$" + total.formatted(.number.locale(Self.groupingLocale).precision(.fractionLength(2)))
        case .tokens: return "\(Int(total).formatted(.number.locale(Self.groupingLocale))) tokens"
        case .costPerMTok: return "$" + total.formatted(.number.locale(Self.groupingLocale).precision(.fractionLength(2))) + "/MTok"
        }
    }

    private func legendValueText(_ value: Double) -> String {
        switch mode {
        case .cost: return compactDollars(value)
        case .tokens: return compactTokenCount(value)
        case .costPerMTok: return String(format: "$%.2f/MTok", value)
        }
    }

    private func compactDollars(_ amount: Double) -> String {
        if amount >= 1000 { return String(format: "$%.1fK", amount / 1000) }
        if amount < 0.01 && amount > 0 { return "<$0.01" }
        return String(format: "$%.2f", amount)
    }

    private func compactTokenCount(_ tokens: Double) -> String {
        "\(TokenCountFormatter.compact(tokens)) tok"
    }
}

/// Fixed per-provider accent so the same provider always reads the same color across the donut
/// and its legend. Close, representative brand colors where widely known (Claude's terracotta,
/// OpenAI's teal-green, Google's blue, GitHub's purple) -- not a claim of exact hex-for-hex
/// accuracy for every provider, just stable and visually distinct.
enum BrandColor {
    static func forProvider(_ provider: ProviderID) -> Color {
        switch provider {
        case .claude: return Color(red: 0.851, green: 0.467, blue: 0.341) // Anthropic terracotta
        case .codex, .openai: return Color(red: 0.063, green: 0.639, blue: 0.498) // OpenAI teal-green
        case .gemini: return Color(red: 0.259, green: 0.522, blue: 0.957) // Google blue
        case .antigravity: return Color(red: 0.204, green: 0.659, blue: 0.325) // Google green
        case .cursor: return Color(red: 0.431, green: 0.337, blue: 0.812) // Anysphere purple
        case .copilot: return Color(red: 0.431, green: 0.251, blue: 0.788) // GitHub Copilot purple (#6E40C9, brand.github.com)
        case .openrouter: return Color(red: 0.392, green: 0.404, blue: 0.949) // indigo
        case .zai: return Color(red: 0.298, green: 0.435, blue: 1.0) // blue
        case .kimi: return Color(red: 0.475, green: 0.325, blue: 0.796) // deep violet
        case .amp: return Color(red: 0.910, green: 0.451, blue: 0.204) // amp orange
        case .grok: return Color(white: 0.82) // xAI near-white/gray (visible on dark UI)
        case .opencode: return Color(red: 0.204, green: 0.780, blue: 0.349) // terminal green
        }
    }
}
