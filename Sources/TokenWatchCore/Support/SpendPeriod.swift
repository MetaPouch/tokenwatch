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
    public static func amount(for period: SpendPeriod, days: [ClaudeUsageDay], calendar: Calendar = .current, now: Date = Date()) -> Double {
        sum(for: period, days: days, calendar: calendar, now: now) { $0.estimatedCostUSD }
    }

    public static func tokens(for period: SpendPeriod, days: [ClaudeUsageDay], calendar: Calendar = .current, now: Date = Date()) -> Int {
        Int(sum(for: period, days: days, calendar: calendar, now: now) { Double($0.totalTokens) })
    }

    /// Dollars per million tokens over the period -- `nil` when there's no token volume to divide
    /// by (never a divide-by-zero crash, never a fabricated rate).
    public static func costPerMillionTokens(for period: SpendPeriod, days: [ClaudeUsageDay], calendar: Calendar = .current, now: Date = Date()) -> Double? {
        let totalTokens = tokens(for: period, days: days, calendar: calendar, now: now)
        guard totalTokens > 0 else { return nil }
        let cost = amount(for: period, days: days, calendar: calendar, now: now)
        return cost / Double(totalTokens) * 1_000_000
    }

    private static func sum(for period: SpendPeriod, days: [ClaudeUsageDay], calendar: Calendar, now: Date, value: (ClaudeUsageDay) -> Double) -> Double {
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
