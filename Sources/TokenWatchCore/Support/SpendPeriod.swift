import Foundation

/// Which trailing window a spend total covers.
public enum SpendPeriod: String, CaseIterable, Sendable, Identifiable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thirtyDays = "30 Days"

    public var id: String { rawValue }
}

/// Which quantity a cross-provider spend total is expressed in.
public enum SpendMetricMode: String, CaseIterable, Sendable, Identifiable {
    case cost = "Cost"
    case costPerMTok = "Cost/MTok"
    case tokens = "Tokens"

    public var id: String { rawValue }
}

/// Pure period-filtering over a day-bucketed local spend history, split out of
/// `TotalSpendCard` so it's testable without a real (multi-second) filesystem scan.
public enum SpendAggregator {
    public static func amount(for period: SpendPeriod, days: [UsageDay], calendar: Calendar = .current, now: Date = Date()) -> Double {
        sum(for: period, days: days, calendar: calendar, now: now) { $0.estimatedCostUSD }
    }

    public static func tokens(for period: SpendPeriod, days: [UsageDay], calendar: Calendar = .current, now: Date = Date()) -> Int {
        Int(sum(for: period, days: days, calendar: calendar, now: now) { Double($0.totalTokens) })
    }

    /// Dollars per million tokens over the period -- `nil` when there's no token volume to divide
    /// by (never a divide-by-zero crash, never a fabricated rate).
    public static func costPerMillionTokens(for period: SpendPeriod, days: [UsageDay], calendar: Calendar = .current, now: Date = Date()) -> Double? {
        let totalTokens = tokens(for: period, days: days, calendar: calendar, now: now)
        guard totalTokens > 0 else { return nil }
        let cost = amount(for: period, days: days, calendar: calendar, now: now)
        return cost / Double(totalTokens) * 1_000_000
    }

    /// Per-model spend across every day in the period, merged by model name and sorted largest
    /// first. Models past the top 5 or under 5% of the period's total cost fold into a single
    /// "Other" entry, so a long tail of one-off model names doesn't crowd out a hover list.
    public static func modelBreakdown(for period: SpendPeriod, days: [UsageDay], calendar: Calendar = .current, now: Date = Date()) -> [ModelSpend] {
        let relevantDays: [UsageDay]
        switch period {
        case .today:
            relevantDays = days.filter { calendar.isDate($0.date, inSameDayAs: now) }
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return [] }
            relevantDays = days.filter { calendar.isDate($0.date, inSameDayAs: yesterday) }
        case .thirtyDays:
            relevantDays = days
        }

        var merged: [String: ModelSpend] = [:]
        for day in relevantDays {
            for entry in day.modelBreakdown {
                merged[entry.id] = merged[entry.id].map { $0.adding(entry) } ?? entry
            }
        }
        let totalCost = merged.values.reduce(0) { $0 + $1.costUSD }
        guard totalCost > 0 else { return [] }

        let ranked = merged.values.sorted { $0.costUSD > $1.costUSD }
        let maxNamedModels = 5
        let minShare = 0.05
        let named = ranked.prefix(maxNamedModels).filter { $0.costUSD / totalCost >= minShare }
        let rest = ranked.dropFirst(named.count)
        guard !rest.isEmpty else { return Array(named) }
        return Array(named) + [rest.reduce(ModelSpend.empty("Other")) { $0.adding($1, as: "Other") }]
    }

    private static func sum(for period: SpendPeriod, days: [UsageDay], calendar: Calendar, now: Date, value: (UsageDay) -> Double) -> Double {
        switch period {
        case .today:
            return days.first { calendar.isDate($0.date, inSameDayAs: now) }.map(value) ?? 0
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return 0 }
            return days.first { calendar.isDate($0.date, inSameDayAs: yesterday) }.map(value) ?? 0
        case .thirtyDays:
            return days.reduce(0) { $0 + value($1) }
        }
    }
}
