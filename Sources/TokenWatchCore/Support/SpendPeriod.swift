import Foundation

/// Which trailing window a spend total covers.
public enum SpendPeriod: String, CaseIterable, Sendable, Identifiable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thirtyDays = "30 Days"

    public var id: String { rawValue }
}

/// Pure period-filtering over a day-bucketed local spend history, split out of
/// `TotalSpendCard` so it's testable without a real (multi-second) filesystem scan.
public enum SpendAggregator {
    public static func amount(for period: SpendPeriod, days: [ClaudeUsageDay], calendar: Calendar = .current, now: Date = Date()) -> Double {
        switch period {
        case .today:
            return days.first { calendar.isDate($0.date, inSameDayAs: now) }?.estimatedCostUSD ?? 0
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return 0 }
            return days.first { calendar.isDate($0.date, inSameDayAs: yesterday) }?.estimatedCostUSD ?? 0
        case .thirtyDays:
            return days.reduce(0) { $0 + $1.estimatedCostUSD }
        }
    }
}
