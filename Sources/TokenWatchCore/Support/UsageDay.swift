import Foundation

/// One model's share of a day's (or aggregated period's) usage, ranked for the hover breakdown.
/// Token buckets are disjoint, like `UsageDay`'s: `inputTokens` excludes cache reads/writes.
public struct ModelSpend: Sendable, Equatable, Identifiable {
    public let id: String
    public let costUSD: Double
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let outputTokens: Int
    /// True when any contributing turn used a model missing from `ModelPricing`'s table.
    public let hasApproximateRate: Bool

    public init(id: String, costUSD: Double, inputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, outputTokens: Int, hasApproximateRate: Bool = false) {
        self.id = id
        self.costUSD = costUSD
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.hasApproximateRate = hasApproximateRate
    }

    public var tokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens + outputTokens }

    /// Sums every bucket of `other` into this entry under `id`.
    public func adding(_ other: ModelSpend, as id: String? = nil) -> ModelSpend {
        ModelSpend(
            id: id ?? self.id, costUSD: costUSD + other.costUSD,
            inputTokens: inputTokens + other.inputTokens, cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens, outputTokens: outputTokens + other.outputTokens,
            hasApproximateRate: hasApproximateRate || other.hasApproximateRate
        )
    }

    static func empty(_ id: String) -> ModelSpend {
        ModelSpend(id: id, costUSD: 0, inputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 0)
    }
}

/// A coding agent that bills through its own service rather than a model provider TokenWatch has
/// a card for: its spend still gets its own named slice.
public enum BillingService: String, CaseIterable, Sendable {
    case devin
    case fx
    case muse

    public var displayName: String {
        switch self {
        case .devin: return "Devin"
        case .fx: return "fx"
        case .muse: return "Muse Code"
        }
    }
}

/// Who a slice of spend belongs to: one of TokenWatch's providers, a `BillingService` with no
/// provider card, or `other` -- a model provider an agent called that TokenWatch has no provider
/// for (DeepSeek, Mistral, Bedrock, Groq, ...). Kept rather than dropped, so Total Spend really is
/// the total.
public enum SpendSource: Hashable, Sendable, Identifiable, Comparable {
    case provider(ProviderID)
    case service(BillingService)
    case other

    public var id: String {
        switch self {
        case let .provider(provider): return provider.rawValue
        case let .service(service): return "service." + service.rawValue
        case .other: return "other"
        }
    }

    public var displayName: String {
        switch self {
        case let .provider(provider): return provider.displayName
        case let .service(service): return service.displayName
        case .other: return "Other"
        }
    }

    /// `ProviderID` order, then `BillingService` order, then `other`.
    public static func < (lhs: SpendSource, rhs: SpendSource) -> Bool {
        func rank(_ source: SpendSource) -> Int {
            switch source {
            case let .provider(provider): return ProviderID.allCases.firstIndex(of: provider) ?? 0
            case let .service(service): return ProviderID.allCases.count + (BillingService.allCases.firstIndex(of: service) ?? 0)
            case .other: return ProviderID.allCases.count + BillingService.allCases.count
            }
        }
        return rank(lhs) < rank(rhs)
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
    /// Latest contributing usage observation, not a file's modification time.
    public let latestUsageAt: Date?
    /// Output and matching recorded request durations for output-bearing responses only.
    public let timedOutputTokens: Int
    public let timedDurationMs: Double

    public init(id: String, date: Date, inputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, outputTokens: Int, estimatedCostUSD: Double, hasApproximateRate: Bool, modelBreakdown: [ModelSpend] = [], latestUsageAt: Date? = nil, timedOutputTokens: Int = 0, timedDurationMs: Double = 0) {
        self.id = id
        self.date = date
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.hasApproximateRate = hasApproximateRate
        self.modelBreakdown = modelBreakdown
        self.latestUsageAt = latestUsageAt
        self.timedOutputTokens = timedOutputTokens
        self.timedDurationMs = timedDurationMs
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
    /// `observedAt` may reflect response completion without changing the usage's billing day.
    mutating func add(timestamp: Date, model: String, input: Int, cacheRead: Int, cacheWrite: Int, output: Int, costUSD: Double, approximate: Bool, observedAt: Date? = nil, durationMs: Double? = nil) {
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
        if input > 0 || cacheRead > 0 || cacheWrite > 0 || output > 0 {
            let latest = observedAt ?? timestamp
            if latest.timeIntervalSince1970.isFinite {
                bucket.latestUsageAt = max(bucket.latestUsageAt ?? latest, latest)
            }
        }
        if output > 0, let durationMs, durationMs.isFinite, durationMs > 0 {
            bucket.timedOutput += output
            bucket.timedDurationMs += durationMs
        }
        let turn = ModelSpend(id: model, costUSD: costUSD, inputTokens: input, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, outputTokens: output, hasApproximateRate: approximate)
        bucket.byModel[model] = (bucket.byModel[model] ?? .empty(model)).adding(turn)
        buckets[key] = bucket
    }

    func build() -> [UsageDay] {
        var days: [UsageDay] = []
        var cursor = cutoff
        var previousCursor: Date?
        while cursor <= todayStart {
            let key = Self.dayKey(cursor)
            let bucket = buckets[key]
            let breakdown = (bucket.map { Array($0.byModel.values) } ?? [])
                .sorted { $0.costUSD > $1.costUSD }
            days.append(UsageDay(
                id: key, date: cursor,
                inputTokens: bucket?.input ?? 0, cacheReadTokens: bucket?.cacheRead ?? 0,
                cacheWriteTokens: bucket?.cacheWrite ?? 0, outputTokens: bucket?.output ?? 0,
                estimatedCostUSD: bucket?.cost ?? 0, hasApproximateRate: bucket?.approximate ?? false,
                modelBreakdown: breakdown, latestUsageAt: bucket?.latestUsageAt,
                timedOutputTokens: bucket?.timedOutput ?? 0, timedDurationMs: bucket?.timedDurationMs ?? 0
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
        var latestUsageAt: Date?
        var timedOutput = 0
        var timedDurationMs = 0.0
        var byModel: [String: ModelSpend] = [:]
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayKey(_ dayStart: Date) -> String { dayFormatter.string(from: dayStart) }
}
