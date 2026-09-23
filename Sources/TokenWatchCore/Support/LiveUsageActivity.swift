import Foundation

/// Recently observed logged usage, not an indication that a model is currently streaming.
/// Rates use matched output/duration counters; polling and filesystem latency never enter them.
public struct LiveUsageActivity: Sendable, Equatable {
    public static let activeSeconds: TimeInterval = 8
    public static let rateRetentionSeconds: TimeInterval = 180
    /// Do not present imported history or a delayed reconciliation as live activity.
    private static let maximumRecordAge: TimeInterval = 30

    public private(set) var lastObservedAt: Date?
    private var baseline: Counters?
    private var rate: Double?
    private var sampledAt: Date?

    public init() {}

    public func isActive(at now: Date) -> Bool {
        guard let lastObservedAt else { return false }
        return now >= lastObservedAt && now < lastObservedAt.addingTimeInterval(Self.activeSeconds)
    }

    public func outputTokensPerSecond(at now: Date) -> Double? {
        guard let sampledAt, now >= sampledAt,
              now < sampledAt.addingTimeInterval(Self.rateRetentionSeconds) else { return nil }
        return rate
    }

    /// Only two scheduled UI updates per sample, rather than an always-running animation timer.
    public func transitionDates(after now: Date) -> [Date] {
        [lastObservedAt?.addingTimeInterval(Self.activeSeconds),
         sampledAt?.addingTimeInterval(Self.rateRetentionSeconds)]
            .compactMap { $0 }.filter { $0 > now }.sorted()
    }

    public mutating func observe(_ day: UsageDay?, now: Date = Date()) {
        guard let day else {
            self = Self()
            return
        }
        let current = Counters(day)
        let previous = baseline
        baseline = current
        // Startup, midnight and counter regressions establish a baseline, never a rate spike.
        guard let previous, previous.dayID == current.dayID,
              current.total >= previous.total,
              current.output >= previous.output,
              current.duration >= previous.duration else {
            clearObservation()
            return
        }
        guard current.total > previous.total else { return }
        guard let timestamp = day.latestUsageAt,
              timestamp >= now.addingTimeInterval(-Self.maximumRecordAge), timestamp <= now else {
            clearObservation()
            return
        }
        // A backfilled file may increase today's counters while its newest response stays the
        // same. Rebaseline those counters without reviving activity or replacing the last rate.
        guard previous.latestUsageAt.map({ timestamp > $0 }) ?? true else { return }
        lastObservedAt = now
        let duration = current.duration - previous.duration
        let output = current.output - previous.output
        // A new untimed response invalidates the old rate instead of presenting it as current.
        guard duration.isFinite, duration > 0, output > 0 else {
            rate = nil
            sampledAt = nil
            return
        }
        let value = Double(output) * 1000 / duration
        guard value.isFinite, value > 0 else {
            rate = nil
            sampledAt = nil
            return
        }
        rate = value
        sampledAt = now
    }

    private mutating func clearObservation() {
        lastObservedAt = nil
        rate = nil
        sampledAt = nil
    }

    private struct Counters: Sendable, Equatable {
        let dayID: String
        let total: Int
        let output: Int
        let duration: Double
        let latestUsageAt: Date?

        init(_ day: UsageDay) {
            dayID = day.id
            total = day.totalTokens
            output = day.timedOutputTokens
            duration = day.timedDurationMs
            latestUsageAt = day.latestUsageAt
        }
    }
}
