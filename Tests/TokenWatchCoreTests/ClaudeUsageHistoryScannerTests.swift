import XCTest
@testable import TokenWatchCore

final class ClaudeUsageHistoryScannerTests: XCTestCase {
    private var claudeRoot: URL!
    private var ompRoot: URL!

    override func setUp() {
        super.setUp()
        claudeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ompRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: ompRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: claudeRoot)
        try? FileManager.default.removeItem(at: ompRoot)
        super.tearDown()
    }

    private func writeClaudeTranscript(_ name: String, lines: [String]) {
        let dir = claudeRoot.appendingPathComponent("some-project", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func writeOmpTranscript(_ name: String, lines: [String]) {
        let dir = ompRoot.appendingPathComponent("some-project", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func claudeCodeLine(timestamp: String, model: String, input: Int, cacheRead: Int, cacheCreate: Int, output: Int, messageID: String? = nil, requestID: String? = nil) -> String {
        let idField = messageID.map { #""id":"\#($0)","# } ?? ""
        let requestField = requestID.map { #""requestId":"\#($0)","# } ?? ""
        return #"{"type":"assistant",\#(requestField)"timestamp":"\#(timestamp)","message":{\#(idField)"model":"\#(model)","usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreate),"output_tokens":\#(output)}}}"#
    }

    private func ompLine(timestamp: String, model: String, input: Int, cacheRead: Int, cacheWrite: Int, output: Int, duration: String? = nil, completedAt: String? = nil) -> String {
        let durationField = duration.map { #""duration":\#($0),"# } ?? ""
        let completedField = completedAt.map { #""completedAt":\#($0),"# } ?? ""
        return #"{"type":"message","timestamp":"\#(timestamp)","message":{\#(durationField)\#(completedField)"role":"assistant","provider":"anthropic","model":"\#(model)","usage":{"input":\#(input),"cacheRead":\#(cacheRead),"cacheWrite":\#(cacheWrite),"output":\#(output)}}}"#
    }

    func testSumsClaudeCodeTurnsOnSameDay() {
        writeClaudeTranscript("session.jsonl", lines: [
            claudeCodeLine(timestamp: "2026-06-15T08:00:00.000Z", model: "claude-sonnet-5", input: 100, cacheRead: 0, cacheCreate: 0, output: 50),
            claudeCodeLine(timestamp: "2026-06-15T09:00:00.000Z", model: "claude-sonnet-5", input: 200, cacheRead: 0, cacheCreate: 0, output: 75),
        ])
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], localLogs: LocalUsageLocations(harnessRoots: [ompRoot.path]))
        let day = days.first { $0.id == "2026-06-15" }
        XCTAssertEqual(day?.inputTokens, 300)
        XCTAssertEqual(day?.outputTokens, 125)
    }

    func testCombinesClaudeCodeAndOmpSourcesOnSameDay() {
        writeClaudeTranscript("session.jsonl", lines: [
            claudeCodeLine(timestamp: "2026-06-15T08:00:00.000Z", model: "claude-sonnet-5", input: 100, cacheRead: 0, cacheCreate: 0, output: 50),
        ])
        writeOmpTranscript("session.jsonl", lines: [
            ompLine(timestamp: "2026-06-15T10:00:00.000Z", model: "claude-sonnet-5", input: 400, cacheRead: 0, cacheWrite: 0, output: 20),
        ])
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], localLogs: LocalUsageLocations(harnessRoots: [ompRoot.path]))
        let day = days.first { $0.id == "2026-06-15" }
        XCTAssertEqual(day?.inputTokens, 500)
        XCTAssertEqual(day?.outputTokens, 70)
    }

    func testOnlyRecordedOmpResponseDurationsContributeToThroughput() throws {
        // Native transcript duration/turn_duration is not a per-response generation timer.
        let native = #"{"type":"assistant","requestId":"r","timestamp":"2026-06-15T08:00:00.000Z","duration":50,"turn_duration":50,"message":{"id":"m","duration":50,"model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":50}}}"#
        writeClaudeTranscript("native.jsonl", lines: [native, native])
        let timestamp = "2026-06-15T10:00:00.000Z"
        let completed = try XCTUnwrap(FlexibleISO8601.parse("2026-06-15T10:00:22.000Z"))
        writeOmpTranscript("timed.jsonl", lines: [
            ompLine(timestamp: timestamp, model: "claude-sonnet-5", input: 10, cacheRead: 0, cacheWrite: 0, output: 30, duration: "1000", completedAt: "\(completed.timeIntervalSince1970 * 1000)"),
            ompLine(timestamp: timestamp, model: "claude-sonnet-5", input: 20, cacheRead: 0, cacheWrite: 0, output: 70, duration: "3000"),
            ompLine(timestamp: timestamp, model: "claude-sonnet-5", input: 30, cacheRead: 0, cacheWrite: 0, output: 90),
        ])
        let day = try XCTUnwrap(dailyUsageOn15th())
        XCTAssertEqual(day.inputTokens, 160)
        XCTAssertEqual(day.outputTokens, 240)
        XCTAssertEqual(day.timedOutputTokens, 100)
        XCTAssertEqual(day.timedDurationMs, 4000)
        XCTAssertEqual(Double(day.timedOutputTokens) / (day.timedDurationMs / 1000), 25)
        XCTAssertEqual(day.latestUsageAt, completed)
        // A cached rescan must not accumulate the same timed responses again.
        XCTAssertEqual(dailyUsageOn15th()?.timedOutputTokens, 100)
        XCTAssertEqual(dailyUsageOn15th()?.timedDurationMs, 4000)
    }

    func testMalformedTimingPreservesUsageAndFallsBackToUsageTimestamp() throws {
        let timestamp = "2026-06-15T10:00:00.000Z"
        let badTiming = [#""invalid""#, "{}", "true", "null", "0", "-1"]
        writeOmpTranscript("malformed.jsonl", lines: badTiming.map {
            ompLine(timestamp: timestamp, model: "claude-sonnet-5", input: 10, cacheRead: 2, cacheWrite: 3, output: 5, duration: $0, completedAt: $0)
        } + [
            // Empty assistant records, even with later completion, are not usage activity.
            ompLine(timestamp: "2026-06-15T11:00:00.000Z", model: "claude-sonnet-5", input: 0, cacheRead: 0, cacheWrite: 0, output: 0, duration: "1000"),
        ])
        let day = try XCTUnwrap(dailyUsageOn15th())
        XCTAssertEqual(day.inputTokens, 60)
        XCTAssertEqual(day.cacheReadTokens, 12)
        XCTAssertEqual(day.cacheWriteTokens, 18)
        XCTAssertEqual(day.outputTokens, 30)
        XCTAssertGreaterThan(day.estimatedCostUSD, 0)
        XCTAssertEqual(day.timedOutputTokens, 0)
        XCTAssertEqual(day.timedDurationMs, 0)
        XCTAssertEqual(day.latestUsageAt, FlexibleISO8601.parse(timestamp))
    }

    func testCompletionTimestampDoesNotMoveBillingDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let timestamp = try XCTUnwrap(FlexibleISO8601.parse("2026-06-14T23:59:59.000Z"))
        let completed = timestamp.addingTimeInterval(2)
        writeOmpTranscript("midnight.jsonl", lines: [
            ompLine(timestamp: "2026-06-14T23:59:59.000Z", model: "claude-sonnet-5", input: 10, cacheRead: 0, cacheWrite: 0, output: 20, duration: "2000", completedAt: "\(completed.timeIntervalSince1970 * 1000)"),
        ])
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 2, now: completed, calendar: calendar, claudeRoots: [], localLogs: LocalUsageLocations(harnessRoots: [ompRoot.path]))
        let billedDay = try XCTUnwrap(days.first { $0.date == calendar.startOfDay(for: timestamp) })
        let nextDay = try XCTUnwrap(days.first { $0.date == calendar.startOfDay(for: completed) })
        XCTAssertEqual(billedDay.outputTokens, 20)
        XCTAssertEqual(billedDay.latestUsageAt, completed)
        XCTAssertEqual(billedDay.timedDurationMs, 2000)
        XCTAssertEqual(nextDay.totalTokens, 0)
        XCTAssertNil(nextDay.latestUsageAt)
    }

    func testAccumulatorRejectsNonfiniteDurationsWithoutDiscardingTokens() throws {
        let timestamp = try XCTUnwrap(FlexibleISO8601.parse("2026-06-15T10:00:00.000Z"))
        var accumulator = UsageDayAccumulator(days: 1, now: timestamp, calendar: .current)
        for duration in [Double.nan, .infinity, -.infinity, 0, -1, 250] {
            accumulator.add(timestamp: timestamp, model: "claude-sonnet-5", input: 1, cacheRead: 0, cacheWrite: 0, output: 5, costUSD: 0.1, approximate: false, durationMs: duration)
        }
        let day = try XCTUnwrap(accumulator.build().first)
        XCTAssertEqual(day.totalTokens, 36)
        XCTAssertEqual(day.estimatedCostUSD, 0.6, accuracy: 0.0001)
        XCTAssertEqual(day.timedOutputTokens, 5)
        XCTAssertEqual(day.timedDurationMs, 250)
        XCTAssertEqual(day.latestUsageAt, timestamp)
    }

    /// Claude Code writes one line per content block of a response (thinking, then a tool call),
    /// each repeating the full usage, and a resumed session copies prior messages into a new
    /// file. Each response must count once; a different response with identical numbers must not
    /// be collapsed into it.
    func testCountsEachResponseOnceAcrossContentBlocksAndResumedFiles() {
        let response = { (ts: String) in
            self.claudeCodeLine(timestamp: ts, model: "claude-sonnet-5", input: 100, cacheRead: 1_000, cacheCreate: 10, output: 50, messageID: "msg_A", requestID: "req_A")
        }
        writeClaudeTranscript("original.jsonl", lines: [
            response("2026-06-15T08:00:00.000Z"),
            response("2026-06-15T08:00:01.000Z"),
            claudeCodeLine(timestamp: "2026-06-15T08:05:00.000Z", model: "claude-sonnet-5", input: 100, cacheRead: 1_000, cacheCreate: 10, output: 50, messageID: "msg_B", requestID: "req_B"),
        ])
        writeClaudeTranscript("resumed.jsonl", lines: [response("2026-06-15T08:00:00.000Z")])
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], localLogs: LocalUsageLocations(harnessRoots: [ompRoot.path]))
        let day = days.first { $0.id == "2026-06-15" }
        XCTAssertEqual(day?.inputTokens, 200)
        XCTAssertEqual(day?.outputTokens, 100)
        XCTAssertEqual(day?.totalTokens, 2 * 1_160)
    }

    private func dailyUsageOn15th() -> UsageDay? {
        ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], localLogs: LocalUsageLocations(harnessRoots: [ompRoot.path]))
            .first { $0.id == "2026-06-15" }
    }

    func testAppendedResponseStillDeduplicatesAgainstCachedHistory() throws {
        let first = claudeCodeLine(timestamp: "2026-06-15T08:00:00.000Z", model: "claude-sonnet-5", input: 100, cacheRead: 0, cacheCreate: 0, output: 10, messageID: "message", requestID: "request")
        writeClaudeTranscript("incremental.jsonl", lines: [first])
        XCTAssertEqual(dailyUsageOn15th()?.inputTokens, 100)
        let file = claudeRoot.appendingPathComponent("some-project/incremental.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let larger = claudeCodeLine(timestamp: "2026-06-15T08:00:00.000Z", model: "claude-sonnet-5", input: 150, cacheRead: 0, cacheCreate: 0, output: 15, messageID: "message", requestID: "request")
        try handle.write(contentsOf: Data(("\n" + first + "\n" + larger + "\n").utf8))
        XCTAssertEqual(dailyUsageOn15th()?.inputTokens, 150)
        XCTAssertEqual(dailyUsageOn15th()?.outputTokens, 15)
    }

    /// A subagent (sidechain) log replays its parent's message under a new request id. It must be
    /// counted once, and the main-chain copy kept even when the sidechain copy was seen first.
    func testSidechainReplayUnderNewRequestIDCountsOnceAndKeepsMainChain() {
        let sidechain = #"{"type":"assistant","isSidechain":true,"requestId":"req_side","timestamp":"2026-06-15T08:00:00.000Z","message":{"id":"msg_A","model":"claude-sonnet-5","usage":{"input_tokens":999,"output_tokens":1}}}"#
        writeClaudeTranscript("a-subagent.jsonl", lines: [sidechain])
        writeClaudeTranscript("b-main.jsonl", lines: [
            claudeCodeLine(timestamp: "2026-06-15T08:00:00.000Z", model: "claude-sonnet-5", input: 100, cacheRead: 0, cacheCreate: 0, output: 50, messageID: "msg_A", requestID: "req_main"),
        ])
        XCTAssertEqual(dailyUsageOn15th()?.inputTokens, 100)
    }

    /// An advisor model consulted inside a response is a separate, separately-priced entry under
    /// its own model; ordinary iterations are already inside the parent's totals.
    func testAdvisorIterationsCountUnderTheirOwnModel() {
        let line = #"{"type":"assistant","requestId":"r","timestamp":"2026-06-15T08:00:00.000Z","message":{"id":"m","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":10,"iterations":[{"type":"message","input_tokens":100,"output_tokens":10},{"type":"advisor_message","model":"claude-opus-5","input_tokens":40,"output_tokens":4}]}}}"#
        writeClaudeTranscript("s.jsonl", lines: [line, line])
        let day = dailyUsageOn15th()
        XCTAssertEqual(day?.inputTokens, 140)
        XCTAssertEqual(Set(day?.modelBreakdown.map(\.id) ?? []), ["claude-sonnet-5", "claude-opus-5"])
    }

    /// A cost recorded in the log (Claude Code's `costUSD`, omp's `usage.cost.total`) is used as-is
    /// instead of re-pricing the tokens.
    func testCarriedCostsWinOverRepricing() {
        writeClaudeTranscript("s.jsonl", lines: [
            #"{"type":"assistant","costUSD":1.5,"timestamp":"2026-06-15T08:00:00.000Z","message":{"id":"m","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}"#,
        ])
        writeOmpTranscript("s.jsonl", lines: [
            #"{"type":"message","timestamp":"2026-06-15T09:00:00.000Z","message":{"role":"assistant","provider":"anthropic","model":"claude-sonnet-5","usage":{"input":1000000,"output":0,"cost":{"total":0.25}}}}"#,
        ])
        XCTAssertEqual(dailyUsageOn15th()?.estimatedCostUSD ?? -1, 1.75, accuracy: 0.0001)
    }

    /// omp records 1-hour cache writes in `cttl`; without a carried cost they price at 2x input.
    func testOmpOneHourCacheWritesPriceAtTwiceInput() {
        writeOmpTranscript("s.jsonl", lines: [
            #"{"type":"message","timestamp":"2026-06-15T09:00:00.000Z","message":{"role":"assistant","provider":"anthropic","model":"claude-sonnet-5","usage":{"input":0,"output":0,"cacheWrite":1000000,"cttl":{"ephemeral1h":1000000}}}}"#,
        ])
        XCTAssertEqual(dailyUsageOn15th()?.estimatedCostUSD ?? -1, 4, accuracy: 0.0001) // $2/M input x 2
    }

    /// `<synthetic>` is Claude Code's placeholder for a locally generated message: no API call, so
    /// no cost, and not a reason to mark the day's estimate approximate.
    func testSyntheticPlaceholderIsFreeAndNotApproximate() {
        writeClaudeTranscript("s.jsonl", lines: [
            claudeCodeLine(timestamp: "2026-06-15T08:00:00.000Z", model: "<synthetic>", input: 1_000, cacheRead: 0, cacheCreate: 0, output: 1_000),
        ])
        let day = dailyUsageOn15th()
        XCTAssertEqual(day?.estimatedCostUSD, 0)
        XCTAssertEqual(day?.hasApproximateRate, false)
    }

    func testBucketsIntoSeparateDays() {
        writeClaudeTranscript("session.jsonl", lines: [
            claudeCodeLine(timestamp: "2026-06-14T23:00:00.000Z", model: "claude-sonnet-5", input: 10, cacheRead: 0, cacheCreate: 0, output: 1),
            claudeCodeLine(timestamp: "2026-06-15T01:00:00.000Z", model: "claude-sonnet-5", input: 20, cacheRead: 0, cacheCreate: 0, output: 2),
        ])
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: Date(timeIntervalSince1970: 1_781_937_000), calendar: {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            return cal
        }(), claudeRoots: [claudeRoot.path], localLogs: LocalUsageLocations(harnessRoots: [ompRoot.path]))
        XCTAssertEqual(days.first { $0.id == "2026-06-14" }?.inputTokens, 10)
        XCTAssertEqual(days.first { $0.id == "2026-06-15" }?.inputTokens, 20)
    }

    func testExcludesTurnsOutsideWindow() {
        writeClaudeTranscript("session.jsonl", lines: [
            claudeCodeLine(timestamp: "2026-01-01T00:00:00.000Z", model: "claude-sonnet-5", input: 999, cacheRead: 0, cacheCreate: 0, output: 999),
        ])
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 7, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], localLogs: LocalUsageLocations(harnessRoots: [ompRoot.path]))
        XCTAssertEqual(days.reduce(0) { $0 + $1.inputTokens }, 0)
    }

    func testEstimatesCostUsingModelPricing() {
        writeClaudeTranscript("session.jsonl", lines: [
            claudeCodeLine(timestamp: "2026-06-15T08:00:00.000Z", model: "claude-sonnet-5", input: 1_000_000, cacheRead: 0, cacheCreate: 0, output: 1_000_000),
        ])
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], localLogs: LocalUsageLocations(harnessRoots: [ompRoot.path]))
        let day = days.first { $0.id == "2026-06-15" }
        XCTAssertEqual(day?.estimatedCostUSD ?? -1, 12, accuracy: 0.01) // $2/M input + $10/M output
    }

    func testFlagsApproximateRateForUnknownModel() {
        writeClaudeTranscript("session.jsonl", lines: [
            claudeCodeLine(timestamp: "2026-06-15T08:00:00.000Z", model: "claude-mystery-model", input: 100, cacheRead: 0, cacheCreate: 0, output: 100),
        ])
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], localLogs: LocalUsageLocations(harnessRoots: [ompRoot.path]))
        XCTAssertEqual(days.first { $0.id == "2026-06-15" }?.hasApproximateRate, true)
    }

    func testReturnsEveryDayInWindowIncludingZeroUsageDays() {
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 7, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], localLogs: LocalUsageLocations(harnessRoots: [ompRoot.path]))
        XCTAssertEqual(days.count, 7)
        XCTAssertTrue(days.allSatisfy { $0.totalTokens == 0 })
    }

    func testSkipsNonAssistantAndNonAnthropicLines() {
        writeClaudeTranscript("session.jsonl", lines: [
            #"{"type":"user","timestamp":"2026-06-15T08:00:00.000Z"}"#,
        ])
        writeOmpTranscript("session.jsonl", lines: [
            ompLine(timestamp: "2026-06-15T08:00:00.000Z", model: "gpt-5", input: 500, cacheRead: 0, cacheWrite: 0, output: 500).replacingOccurrences(of: "\"provider\":\"anthropic\"", with: "\"provider\":\"openai\""),
        ])
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], localLogs: LocalUsageLocations(harnessRoots: [ompRoot.path]))
        XCTAssertEqual(days.reduce(0) { $0 + $1.totalTokens }, 0)
    }
}
