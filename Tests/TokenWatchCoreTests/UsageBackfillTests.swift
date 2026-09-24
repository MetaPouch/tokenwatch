import XCTest
@testable import TokenWatchCore

final class UsageBackfillTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_781_937_000) // 2026-06-20
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Fixtures

    private var claudeRoot: String { root.appendingPathComponent("claude").path }
    private var codexRoot: String { root.appendingPathComponent("codex").path }
    private var ompRoot: String { root.appendingPathComponent("omp").path }
    private var inputs: UsageBackfill.Inputs {
        UsageBackfill.Inputs(claudeRoots: [claudeRoot], codexRoots: [codexRoot], localLogs: LocalUsageLocations(harnessRoots: [ompRoot]))
    }

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// Writes a log whose modification time is its newest record, as a real append-only log's is.
    private func write(_ root: String, _ name: String, modified: Date, lines: [String]) throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent("project/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func claudeLine(_ date: Date, model: String = "claude-sonnet-4-5", input: Int, output: Int, messageID: String, requestID: String) -> String {
        #"{"type":"assistant","requestId":"\#(requestID)","timestamp":"\#(iso(date))","message":{"id":"\#(messageID)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(input * 10),"cache_creation_input_tokens":\#(input * 2),"output_tokens":\#(output)}}}"#
    }

    private func ompLine(_ date: Date, provider: String, model: String, input: Int, output: Int) -> String {
        #"{"type":"message","timestamp":"\#(iso(date))","message":{"role":"assistant","provider":"\#(provider)","model":"\#(model)","usage":{"input":\#(input),"cacheRead":\#(input * 3),"cacheWrite":0,"output":\#(output)}}}"#
    }

    private func codexRollout(_ date: Date, model: String, input: Int, cached: Int, output: Int) -> [String] {
        let usage = #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(input + output)}"#
        return [
            #"{"timestamp":"\#(iso(date))","type":"session_meta","payload":{}}"#,
            #"{"timestamp":"\#(iso(date))","type":"turn_context","payload":{"model":"\#(model)"}}"#,
            #"{"timestamp":"\#(iso(date))","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":\#(usage),"total_token_usage":\#(usage)}}}"#,
        ]
    }

    /// History on both sides of the 30-day window: an old session, a resumed session that copied
    /// an old message into a new file, other agents' logs, and Codex rollouts.
    private func writeHistory() throws {
        let old = daysAgo(45)
        let oldTurn = claudeLine(old, input: 100, output: 40, messageID: "msg_old", requestID: "req_old")
        try write(claudeRoot, "old.jsonl", modified: old, lines: [
            claudeLine(daysAgo(400), input: 7, output: 3, messageID: "msg_ancient", requestID: "req_ancient"),
            oldTurn,
        ])
        let recent = daysAgo(10)
        let recentTurn = claudeLine(recent, model: "claude-opus-4-5", input: 300, output: 90, messageID: "msg_recent", requestID: "req_recent")
        try write(claudeRoot, "recent.jsonl", modified: recent, lines: [recentTurn, recentTurn])
        // A resumed session repeats earlier messages (the old one and the recent one) and adds its own.
        try write(claudeRoot, "resumed.jsonl", modified: daysAgo(0.1), lines: [
            oldTurn,
            recentTurn,
            claudeLine(daysAgo(0.2), input: 50, output: 20, messageID: "msg_today", requestID: "req_today"),
        ])
        try write(ompRoot, "old.jsonl", modified: daysAgo(40), lines: [
            ompLine(daysAgo(40), provider: "anthropic", model: "claude-sonnet-4-5", input: 11, output: 5),
            ompLine(daysAgo(40), provider: "google", model: "gemini-3-pro", input: 13, output: 6),
        ])
        try write(ompRoot, "recent.jsonl", modified: daysAgo(2), lines: [
            ompLine(daysAgo(5), provider: "google", model: "gemini-3-pro", input: 17, output: 8),
            ompLine(daysAgo(2), provider: "anthropic", model: "claude-sonnet-4-5", input: 19, output: 9),
            ompLine(daysAgo(2), provider: "deepseek", model: "deepseek-v4", input: 23, output: 10),
        ])
        try write(codexRoot, "old.jsonl", modified: daysAgo(50), lines: codexRollout(daysAgo(50), model: "gpt-5", input: 1_000, cached: 400, output: 70))
        try write(codexRoot, "recent.jsonl", modified: daysAgo(1), lines: codexRollout(daysAgo(1), model: "gpt-5", input: 2_000, cached: 900, output: 80))
    }

    /// What `SpendHistoryStore` computes for its 30-day window, non-empty days only.
    private func uiHistory() -> [SpendSource: [UsageDay]] {
        var result = LocalUsageHistoryScanner.dailyUsage(days: 30, now: now, calendar: calendar, locations: inputs.localLogs)
        result[.provider(.claude)] = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: now, calendar: calendar, claudeRoots: [claudeRoot], localLogs: inputs.localLogs)
        result[.provider(.codex)] = CodexUsageHistoryScanner.dailyUsage(days: 30, now: now, calendar: calendar, roots: [codexRoot], localLogs: inputs.localLogs)
        return result.mapValues { $0.filter { !$0.isEmpty } }.filter { !$0.value.isEmpty }
    }

    private func backfill(through end: Date? = nil) async throws -> (months: [UsageBackfill.Month], summary: UsageBackfill.Summary) {
        var months: [UsageBackfill.Month] = []
        let summary = try await UsageBackfill.scan(through: end ?? now, calendar: calendar, inputs: inputs) { months.append($0) }
        return (months, summary)
    }

    // MARK: - Tests

    func testOverlappingDaysMatchTheThirtyDayHistoryExactly() async throws {
        try writeHistory()
        let ui = uiHistory()
        let (months, summary) = try await backfill()

        var backfilled: [SpendSource: [UsageDay]] = [:]
        for month in months {
            for (source, days) in month.daysBySource {
                XCTAssertTrue(days.allSatisfy { $0.id.hasPrefix(month.id) && !$0.isEmpty }, "\(month.id) \(source)")
                backfilled[source, default: []] += days
            }
        }
        let cutoffID = UsageDay.dayID(for: daysAgo(29), timeZone: calendar.timeZone)
        let recent = backfilled.mapValues { $0.filter { $0.id >= cutoffID }.sorted { $0.id < $1.id } }.filter { !$0.value.isEmpty }
        XCTAssertEqual(Set(recent.keys), Set(ui.keys))
        for (source, days) in ui {
            // Every field: cost, all four buckets, the per-model breakdown and timing.
            XCTAssertEqual(recent[source], days, "\(source)")
        }
        XCTAssertEqual(ui[.provider(.claude)]?.count, 3)
        XCTAssertEqual(Set(ui.keys), [.provider(.claude), .provider(.codex), .provider(.gemini), .other])

        // Older days come from the same files; the old message the resumed session repeated counts once.
        let claudeOld = try XCTUnwrap(backfilled[.provider(.claude)]?.first { $0.id == UsageDay.dayID(for: daysAgo(45), timeZone: calendar.timeZone) })
        XCTAssertEqual(claudeOld.inputTokens, 100)
        XCTAssertEqual(claudeOld.outputTokens, 40)
        XCTAssertEqual(summary.oldestDayBySource, [
            .provider(.claude): UsageDay.dayID(for: daysAgo(400), timeZone: calendar.timeZone),
            .provider(.codex): UsageDay.dayID(for: daysAgo(50), timeZone: calendar.timeZone),
            .provider(.gemini): UsageDay.dayID(for: daysAgo(40), timeZone: calendar.timeZone),
            .other: UsageDay.dayID(for: daysAgo(2), timeZone: calendar.timeZone),
        ])
        XCTAssertEqual(months.map(\.id), months.map(\.id).sorted(by: >), "newest month first")
        XCTAssertEqual(summary.monthCount, months.count)
    }

    func testResumingThroughAnEarlierDayOnlyScansOlderMonths() async throws {
        try writeHistory()
        let all = try await backfill().months
        let newest = try XCTUnwrap(all.first)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let newestStart = try XCTUnwrap(gregorian.date(from: DateComponents(year: Int(newest.id.prefix(4)), month: Int(newest.id.suffix(2)), day: 1)))

        let resumed = try await backfill(through: newestStart.addingTimeInterval(-1)).months
        XCTAssertEqual(resumed, Array(all.dropFirst()))
    }

    func testCancellingStopsBeforeTheNextMonth() async throws {
        try writeHistory()
        final class Emitted: @unchecked Sendable { var ids: [String] = [] }
        let emitted = Emitted()
        let task = Task { [calendar, inputs, now] in
            try await UsageBackfill.scan(through: now, calendar: calendar, inputs: inputs) { month in
                emitted.ids.append(month.id)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(emitted.ids.count, 1)
    }

    /// 400 local days in a zone with two DST transitions: one key per calendar day, each turn on
    /// its own local day, whatever the calendar the user picked.
    func testFourHundredDayWindowKeysEveryLocalDayAcrossDST() throws {
        for identifier in [Calendar.Identifier.gregorian, .buddhist] {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
                gregorian.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
            }
            let start = local(2025, 1, 15, 12)
            let end = local(2026, 2, 18, 12) // 400 days, spanning 2025-03-09 and 2025-11-02
            var accumulator = UsageDayAccumulator(from: start, through: end, calendar: calendar)
            let turns: [(Date, String)] = [
                (local(2025, 3, 9, 0, 30), "2025-03-09"),  // before spring-forward
                (local(2025, 3, 9, 23, 30), "2025-03-09"), // 23-hour day's last half hour
                (local(2025, 11, 2, 1, 30), "2025-11-02"), // the repeated hour
                (local(2025, 11, 2, 23, 59), "2025-11-02"), // 25-hour day's last minute
                (local(2025, 11, 3, 0, 0), "2025-11-03"),
            ]
            for (index, turn) in turns.enumerated() {
                accumulator.add(timestamp: turn.0, model: "m", input: index + 1, cacheRead: 0, cacheWrite: 0, output: 0, costUSD: 0, approximate: false)
            }
            let days = accumulator.build()

            XCTAssertEqual(days.count, 400, "\(identifier)")
            XCTAssertEqual(days.first?.id, "2025-01-15")
            XCTAssertEqual(days.last?.id, "2026-02-18")
            XCTAssertEqual(Set(days.map(\.id)).count, 400)
            for (previous, next) in zip(days, days.dropFirst()) {
                XCTAssertEqual(gregorian.dateComponents([.day], from: previous.date, to: next.date).day, 1, "\(previous.id) → \(next.id)")
                XCTAssertEqual(next.id, UsageDay.dayID(for: next.date, timeZone: calendar.timeZone))
            }
            let inputByDay = Dictionary(grouping: turns.enumerated(), by: { $0.element.1 }).mapValues { $0.reduce(0) { $0 + $1.offset + 1 } }
            for (id, input) in inputByDay {
                XCTAssertEqual(days.first { $0.id == id }?.inputTokens, input, "\(identifier) \(id)")
            }
            XCTAssertEqual(days.filter { !$0.isEmpty }.count, 3)
        }
    }
}
