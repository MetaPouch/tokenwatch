import Foundation

/// One model's share of a day's (or aggregated period's) spend, ranked for the hover breakdown.
public struct ModelSpend: Sendable, Equatable, Identifiable {
    public let id: String
    public let costUSD: Double
    public let tokens: Int

    public init(id: String, costUSD: Double, tokens: Int) {
        self.id = id
        self.costUSD = costUSD
        self.tokens = tokens
    }
}

/// One local calendar day of one provider's token usage, aggregated across its local session
/// logs and priced at API list rates (or at the cost the logs themselves recorded). Token buckets
/// are disjoint: `inputTokens` excludes cache reads/writes, so `totalTokens` is a plain sum.
public struct UsageDay: Sendable, Equatable, Identifiable {
    public let id: String
    public let date: Date
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let outputTokens: Int
    public let estimatedCostUSD: Double
    /// True when at least one turn priced into this day used a model not in `ModelPricing`'s
    /// table (fell back to the cheapest known rate) -- the day's total is a rougher estimate
    /// than usual.
    public let hasApproximateRate: Bool
    /// Per-model spend within this day, largest first. Empty for a day with no activity.
    public let modelBreakdown: [ModelSpend]

    public init(id: String, date: Date, inputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, outputTokens: Int, estimatedCostUSD: Double, hasApproximateRate: Bool, modelBreakdown: [ModelSpend] = []) {
        self.id = id
        self.date = date
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.hasApproximateRate = hasApproximateRate
        self.modelBreakdown = modelBreakdown
    }

    public var totalTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens + outputTokens }
}

/// Buckets priced turns into local calendar days over a trailing window, then emits one
/// `UsageDay` per day (zero-usage days included) -- shared by every provider's local
/// usage-history scanner so they agree on day boundaries and the breakdown shape.
struct UsageDayAccumulator {
    let cutoff: Date
    private let todayStart: Date
    private let calendar: Calendar
    private var buckets: [String: Bucket] = [:]

    /// The window covers `days` local days ending today; `cutoff` is the first day's start.
    init(days: Int, now: Date, calendar: Calendar) {
        self.calendar = calendar
        todayStart = calendar.startOfDay(for: now)
        cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
    }

    /// Adds one priced turn; turns before `cutoff` are ignored. Token counts are disjoint buckets.
    mutating func add(timestamp: Date, model: String, input: Int, cacheRead: Int, cacheWrite: Int, output: Int, costUSD: Double, approximate: Bool) {
        guard timestamp >= cutoff else { return }
        let dayStart = calendar.startOfDay(for: timestamp)
        let key = Self.dayKey(dayStart)
        var bucket = buckets[key] ?? Bucket()
        bucket.input += input
        bucket.cacheRead += cacheRead
        bucket.cacheWrite += cacheWrite
        bucket.output += output
        bucket.cost += costUSD
        bucket.approximate = bucket.approximate || approximate
        var modelBucket = bucket.byModel[model] ?? (0, 0)
        modelBucket.cost += costUSD
        modelBucket.tokens += input + cacheRead + cacheWrite + output
        bucket.byModel[model] = modelBucket
        buckets[key] = bucket
    }

    func build() -> [UsageDay] {
        var days: [UsageDay] = []
        var cursor = cutoff
        var previousCursor: Date?
        while cursor <= todayStart {
            let key = Self.dayKey(cursor)
            let bucket = buckets[key]
            let breakdown = (bucket?.byModel ?? [:])
                .map { ModelSpend(id: $0.key, costUSD: $0.value.cost, tokens: $0.value.tokens) }
                .sorted { $0.costUSD > $1.costUSD }
            days.append(UsageDay(
                id: key, date: cursor,
                inputTokens: bucket?.input ?? 0, cacheReadTokens: bucket?.cacheRead ?? 0,
                cacheWriteTokens: bucket?.cacheWrite ?? 0, outputTokens: bucket?.output ?? 0,
                estimatedCostUSD: bucket?.cost ?? 0, hasApproximateRate: bucket?.approximate ?? false,
                modelBreakdown: breakdown
            ))
            let next = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
            // Defensive: guarantee forward progress even if `calendar` misbehaves, rather than
            // trusting `Calendar.date(byAdding:)` never returns a non-advancing date.
            guard next > cursor, previousCursor != next else { break }
            previousCursor = cursor
            cursor = next
        }
        return days
    }

    private struct Bucket {
        var input = 0, cacheRead = 0, cacheWrite = 0, output = 0
        var cost = 0.0
        var approximate = false
        var byModel: [String: (cost: Double, tokens: Int)] = [:]
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayKey(_ dayStart: Date) -> String { dayFormatter.string(from: dayStart) }
}
