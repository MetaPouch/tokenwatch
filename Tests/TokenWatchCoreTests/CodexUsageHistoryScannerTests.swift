import XCTest
@testable import TokenWatchCore

final class CodexUsageHistoryScannerTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_781_937_000)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func writeRollout(_ relativePath: String, lines: [String]) {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func meta(_ payload: String = "{}", timestamp: String = "2026-06-15T08:00:00.000Z") -> String {
        #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":\#(payload)}"#
    }

    private func turnContext(_ model: String) -> String {
        #"{"timestamp":"2026-06-15T08:00:00.000Z","type":"turn_context","payload":{"model":"\#(model)"}}"#
    }

    private func usageJSON(_ input: Int, _ cached: Int, _ output: Int) -> String {
        #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(input + output)}"#
    }

    private func tokenCount(at timestamp: String, last: (Int, Int, Int)?, total: (Int, Int, Int)?) -> String {
        var info: [String] = []
        if let last { info.append(#""last_token_usage":\#(usageJSON(last.0, last.1, last.2))"#) }
        if let total { info.append(#""total_token_usage":\#(usageJSON(total.0, total.1, total.2))"#) }
        return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{\#(info.joined(separator: ","))}}}"#
    }

    private func taskStarted(startedAt: TimeInterval, timestamp: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"task_started","started_at":\#(Int(startedAt))}}"#
    }

    private func day15() -> UsageDay? {
        CodexUsageHistoryScanner.dailyUsage(days: 30, now: now, roots: [root.appendingPathComponent("sessions").path, root.appendingPathComponent("archived_sessions").path])
            .first { $0.id == "2026-06-15" }
    }

    /// Cached tokens are inside `input_tokens`: only the uncached part bills at the input rate.
    /// A re-emitted snapshot with an unchanged running total is not another turn, and a line with
    /// only a running total counts as its delta from the previous one.
    func testCountsTurnsOnceWithCachedSplitAndDeltas() {
        writeRollout("sessions/2026/06/15/a.jsonl", lines: [
            meta(),
            turnContext("gpt-5.6-terra"),
            tokenCount(at: "2026-06-15T08:01:00.000Z", last: (100_000, 40_000, 10_000), total: (100_000, 40_000, 10_000)),
            tokenCount(at: "2026-06-15T08:01:05.000Z", last: (100_000, 40_000, 10_000), total: (100_000, 40_000, 10_000)),
            tokenCount(at: "2026-06-15T08:02:00.000Z", last: nil, total: (150_000, 40_000, 15_000)),
        ])
        let day = day15()
        XCTAssertEqual(day?.inputTokens, 110_000) // uncached: 60K + 50K
        XCTAssertEqual(day?.cacheReadTokens, 40_000)
        XCTAssertEqual(day?.outputTokens, 15_000)
        // terra $2 in / $0.20 cached / $12 out: 0.12 + 0.008 + 0.12, then 0.10 + 0 + 0.06.
        XCTAssertEqual(day?.estimatedCostUSD ?? -1, 0.408, accuracy: 0.0001)
        XCTAssertEqual(day?.modelBreakdown.map(\.id), ["gpt-5.6-terra"])
    }

    /// A subagent rollout opens by replaying its parent's history under new timestamps. None of it
    /// is the child's own usage; counting starts at the child's first live turn.
    func testChildSessionReplayIsNotCounted() {
        let created = "2026-06-15T09:00:00.000Z"
        let createdAt = FlexibleISO8601.parse(created)!.timeIntervalSince1970
        writeRollout("sessions/2026/06/15/child.jsonl", lines: [
            meta(#"{"thread_source":"subagent","forked_from_id":"parent"}"#, timestamp: created),
            turnContext("gpt-5.6-terra"),
            taskStarted(startedAt: createdAt - 3600, timestamp: "2026-06-15T09:00:01.000Z"),
            tokenCount(at: "2026-06-15T09:00:01.000Z", last: (900_000, 0, 90_000), total: (900_000, 0, 90_000)),
            taskStarted(startedAt: createdAt + 5, timestamp: "2026-06-15T09:00:05.000Z"),
            tokenCount(at: "2026-06-15T09:00:30.000Z", last: (10_000, 0, 1_000), total: (910_000, 0, 91_000)),
        ])
        XCTAssertEqual(day15()?.inputTokens, 10_000)
    }

    /// `"forked_from_id": null` is a root session, not a child -- its turns count.
    func testNullParentFieldIsNotAChildSession() {
        writeRollout("sessions/2026/06/15/root.jsonl", lines: [
            meta(#"{"forked_from_id":null}"#),
            tokenCount(at: "2026-06-15T08:01:00.000Z", last: (100, 0, 10), total: (100, 0, 10)),
        ])
        XCTAssertEqual(day15()?.inputTokens, 100)
    }

    /// The same rollout in `sessions/` and `archived_sessions/` counts once.
    func testIdenticalEventsAcrossCopiedFilesCountOnce() {
        let lines = [meta(), turnContext("gpt-5.6-terra"), tokenCount(at: "2026-06-15T08:01:00.000Z", last: (100, 0, 10), total: (100, 0, 10))]
        writeRollout("sessions/2026/06/15/r.jsonl", lines: lines)
        writeRollout("archived_sessions/r.jsonl", lines: lines)
        XCTAssertEqual(day15()?.inputTokens, 100)
    }

    /// Priority ("fast") tier bills the whole request at 2x; above 272K input, a model with a
    /// long-context tier bills 2x input and 1.5x output.
    func testPriorityTierAndLongContextPricing() {
        let priority = ModelPricing.codexCostUSD(model: "gpt-5.6-terra", inputTokens: 100_000, cachedInputTokens: 0, outputTokens: 0, priorityTier: true)
        XCTAssertEqual(priority.cost, 0.4, accuracy: 0.0001)
        let longContext = ModelPricing.codexCostUSD(model: "gpt-6-astra", inputTokens: 300_000, cachedInputTokens: 0, outputTokens: 10_000)
        XCTAssertEqual(longContext.cost, 6.75, accuracy: 0.0001) // 300K x $20/M + 10K x $75/M
        let belowThreshold = ModelPricing.codexCostUSD(model: "gpt-6-astra", inputTokens: 272_000, cachedInputTokens: 0, outputTokens: 0)
        XCTAssertEqual(belowThreshold.cost, 272_000 * 10 / 1e6, accuracy: 0.0001)
    }

    func testPriorityTierFromSessionSettingsAppliesToLaterTurns() {
        writeRollout("sessions/2026/06/15/fast.jsonl", lines: [
            meta(),
            turnContext("gpt-5.6-terra"),
            #"{"timestamp":"2026-06-15T08:00:10.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"priority"}}}"#,
            tokenCount(at: "2026-06-15T08:01:00.000Z", last: (100_000, 0, 0), total: (100_000, 0, 0)),
        ])
        XCTAssertEqual(day15()?.estimatedCostUSD ?? -1, 0.4, accuracy: 0.0001)
    }
}
