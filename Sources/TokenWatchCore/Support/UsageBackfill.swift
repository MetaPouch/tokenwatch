import Foundation

/// Every day of local usage TokenWatch can extract, for the leaderboard's history upload --
/// past `SpendHistoryStore`'s 30-day window. It runs the same scanners (same files, dedup rules
/// and pricing) over a wider window, so a day inside both windows comes out identical, then
/// hands the result over one calendar month at a time, newest first, with empty days dropped.
/// Nothing here is published to the UI's history.
///
/// Each scanner parses its files once per scan, through the same caches the UI's scans use
/// (their next 30-day scan drops the older files again), and keeps per-day totals only.
/// Cancelling the calling task stops the scan between scanners and between months. Resuming is
/// the caller's job: pass the day before the oldest month it finished as `through`.
public enum UsageBackfill {
    /// The API rejects rows dated before this day (the contract's `USAGE_MIN_DATE`).
    public static let earliestDayID = "2023-01-01"

    /// One calendar month of history.
    public struct Month: Sendable, Equatable, Identifiable {
        /// `yyyy-MM`.
        public let id: String
        /// Each source's non-empty days in this month, oldest first.
        public let daysBySource: [SpendSource: [UsageDay]]

        public init(id: String, daysBySource: [SpendSource: [UsageDay]]) {
            self.id = id
            self.daysBySource = daysBySource
        }
    }

    public struct Summary: Sendable, Equatable {
        /// The oldest non-empty day found per source, `yyyy-MM-dd`.
        public let oldestDayBySource: [SpendSource: String]
        public let monthCount: Int
    }

    /// Where to look. `standard` is every location the UI's history reads; tests point these at
    /// fixtures.
    public struct Inputs: Sendable {
        public var claudeRoots: [String]?
        public var codexRoots: [String]?
        public var localLogs: LocalUsageLocations
        /// Cursor's account history for a window, or `nil` to leave Cursor to the local logs
        /// (as `SpendHistoryStore` does while the Cursor provider is off).
        public var cursor: (@Sendable (_ start: Date, _ end: Date) async -> [UsageDay]?)?

        public init(claudeRoots: [String]? = nil, codexRoots: [String]? = nil, localLogs: LocalUsageLocations = LocalUsageLocations(), cursor: (@Sendable (_ start: Date, _ end: Date) async -> [UsageDay]?)? = nil) {
            self.claudeRoots = claudeRoots
            self.codexRoots = codexRoots
            self.localLogs = localLogs
            self.cursor = cursor
        }

        public static func standard(includeCursor: Bool) -> Inputs {
            var inputs = Inputs(localLogs: .standard())
            if includeCursor {
                inputs.cursor = { start, end in await CursorUsageHistory.dailyUsage(from: start, through: end) }
            }
            return inputs
        }
    }

    /// Scans every local day from `since`'s (default and floor: `earliestDayID`) through `end`'s
    /// and passes each month that has usage to `emit`, newest first. Runs the scanners on the
    /// calling task: call it off the main actor.
    @discardableResult
    public static func scan(since: Date? = nil, through end: Date = Date(), calendar: Calendar = .current, inputs: Inputs, emit: (Month) async throws -> Void) async throws -> Summary {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let floor = gregorian.date(from: DateComponents(year: 2023, month: 1, day: 1)) ?? .distantPast
        let start = max(since ?? floor, floor)
        guard calendar.startOfDay(for: start) <= end else {
            return Summary(oldestDayBySource: [:], monthCount: 0)
        }

        var bySource: [SpendSource: [UsageDay]] = [:]
        try Task.checkCancellation()
        bySource[.provider(.claude)] = ClaudeUsageHistoryScanner.dailyUsage(from: start, through: end, calendar: calendar, claudeRoots: inputs.claudeRoots, localLogs: inputs.localLogs)
        try Task.checkCancellation()
        bySource[.provider(.codex)] = CodexUsageHistoryScanner.dailyUsage(from: start, through: end, calendar: calendar, roots: inputs.codexRoots, localLogs: inputs.localLogs)
        try Task.checkCancellation()
        bySource.merge(LocalUsageHistoryScanner.dailyUsage(from: start, through: end, calendar: calendar, locations: inputs.localLogs)) { _, new in new }
        try Task.checkCancellation()
        // Like `SpendHistoryStore`: Cursor's account history already includes locally logged
        // Cursor calls, so it replaces them when it's available.
        if let cursor = inputs.cursor, let cursorDays = await cursor(start, end) {
            bySource[.provider(.cursor)] = cursorDays
        }

        var months: [String: [SpendSource: [UsageDay]]] = [:]
        var oldest: [SpendSource: String] = [:]
        for (source, days) in bySource {
            for day in days where !day.isEmpty {
                months[String(day.id.prefix(7)), default: [:]][source, default: []].append(day)
                oldest[source] = min(oldest[source] ?? day.id, day.id)
            }
        }
        let monthIDs = months.keys.sorted(by: >)
        for id in monthIDs {
            try Task.checkCancellation()
            try await emit(Month(id: id, daysBySource: months.removeValue(forKey: id) ?? [:]))
        }
        return Summary(oldestDayBySource: oldest, monthCount: monthIDs.count)
    }
}
