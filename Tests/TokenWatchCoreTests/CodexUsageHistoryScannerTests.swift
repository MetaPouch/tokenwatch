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
        CodexUsageHistoryScanner.dailyUsage(days: 30, now: now, roots: [root.appendingPathComponent("sessions").path, root.appendingPathComponent("archived_sessions").path], localLogs: LocalUsageLocations(harnessRoots: [root.appendingPathComponent("omp").path]))
            .first { $0.id == "2026-06-15" }
    }

    func testIncrementalRolloutPreservesReplayGateTotalsModelAndTier() throws {
        let path = "sessions/child.jsonl"
        let created = "2026-06-15T09:00:00.000Z"
        let createdAt = try XCTUnwrap(FlexibleISO8601.parse(created)).timeIntervalSince1970
        writeRollout(path, lines: [
            meta(#"{"thread_source":"subagent","forked_from_id":"parent"}"#, timestamp: created),
            turnContext("gpt-5.6-terra"),
            #"{"type":"event_msg","payload":{"type":"thread_settings_applied","service_tier":"priority"}}"#,
            tokenCount(at: "2026-06-15T09:00:01.000Z", last: nil, total: (900_000, 0, 0)),
        ])
        XCTAssertEqual(day15()?.inputTokens, 0)
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        let live = tokenCount(at: "2026-06-15T09:01:00.000Z", last: nil, total: (1_000_000, 0, 0))
        let split = live.index(live.startIndex, offsetBy: live.count / 2)
        try handle.write(contentsOf: Data(("\n" + taskStarted(startedAt: createdAt + 5, timestamp: "2026-06-15T09:00:05.000Z") + "\n" + live[..<split]).utf8))
        XCTAssertEqual(day15()?.inputTokens, 0)
        try handle.write(contentsOf: Data((live[split...] + "\n").utf8))
        XCTAssertEqual(day15()?.inputTokens, 100_000)
        XCTAssertEqual(day15()?.estimatedCostUSD ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(day15()?.modelBreakdown.map(\.id), ["gpt-5.6-terra"])
        try handle.write(contentsOf: Data((live + "\n" + tokenCount(at: "2026-06-15T09:02:00.000Z", last: nil, total: (1_050_000, 0, 0)) + "\n").utf8))
        XCTAssertEqual(day15()?.inputTokens, 150_000)
        XCTAssertEqual(day15()?.estimatedCostUSD ?? -1, 0.6, accuracy: 0.0001)
    }

    func testSharedOmpCacheRetainsBothProvidersAcrossIncrementalScans() throws {
        let path = "omp/session.jsonl"
        let codex = #"{"type":"message","timestamp":"2026-06-15T10:00:00.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-6-astra","duration":250,"usage":{"input":10,"output":1}}}"#
        let claude = #"{"type":"message","timestamp":"2026-06-15T10:01:00.000Z","message":{"role":"assistant","provider":"anthropic","model":"claude-sonnet-5","duration":500,"usage":{"input":20,"output":2}}}"#
        writeRollout(path, lines: [codex])
        XCTAssertEqual(day15()?.inputTokens, 10)
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + claude + "\n").utf8))
        let claudeDays = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: now, claudeRoots: [], localLogs: LocalUsageLocations(harnessRoots: [root.appendingPathComponent("omp").path]))
        XCTAssertEqual(claudeDays.first { $0.id == "2026-06-15" }?.inputTokens, 20)
        XCTAssertEqual(day15()?.inputTokens, 10)
        XCTAssertEqual(day15()?.timedOutputTokens, 1)
        XCTAssertEqual(day15()?.timedDurationMs, 250)
        XCTAssertEqual(claudeDays.first { $0.id == "2026-06-15" }?.timedOutputTokens, 2)
        XCTAssertEqual(claudeDays.first { $0.id == "2026-06-15" }?.timedDurationMs, 500)
    }

    /// Codex used through omp is logged only in omp's session files (omp calls the API itself), in
    /// omp's disjoint buckets with its own cost. It counts toward Codex -- and only omp's
    /// `openai-codex` turns do, not the Anthropic turns in the same session.
    func testOmpCodexTurnsCountTowardCodexButNotOtherProviders() {
        let turn = { (provider: String, model: String) in
            #"{"type":"message","timestamp":"2026-06-15T10:00:00.000Z","message":{"role":"assistant","provider":"\#(provider)","model":"\#(model)","usage":{"input":4000,"cacheRead":30000,"cacheWrite":0,"output":500,"cost":{"total":0.1}}}}"#
        }
        writeRollout("omp/-Users-alice-widget/session.jsonl", lines: [
            turn("openai-codex", "gpt-6-astra"),
            turn("anthropic", "claude-sonnet-5"),
        ])
        let day = day15()
        XCTAssertEqual(day?.inputTokens, 4_000)
        XCTAssertEqual(day?.cacheReadTokens, 30_000)
        XCTAssertEqual(day?.estimatedCostUSD ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(day?.modelBreakdown.map(\.id), ["gpt-6-astra"])
    }

    func testCodexRateUsesOnlyOmpResponseTimingNotNativeTurnDuration() throws {
        let completed = try XCTUnwrap(FlexibleISO8601.parse("2026-06-15T10:00:22.000Z"))
        writeRollout("sessions/native.jsonl", lines: [
            meta(),
            tokenCount(at: "2026-06-15T09:00:00.000Z", last: (100, 0, 10), total: (100, 0, 10)),
            #"{"timestamp":"2026-06-15T09:00:01.000Z","type":"event_msg","payload":{"type":"turn_duration","duration":1}}"#,
        ])
        writeRollout("omp/timed.jsonl", lines: [
            #"{"type":"message","timestamp":"2026-06-15T10:00:00.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-6-astra","duration":21810.824874999933,"completedAt":\#(completed.timeIntervalSince1970 * 1000),"usage":{"input":20,"output":500,"cost":{"total":0.1}}}}"#,
            #"{"type":"message","timestamp":"2026-06-15T10:00:00.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-6-astra","duration":"bad","completedAt":[],"usage":{"input":30,"output":50,"cost":{"total":0.2}}}}"#,
            #"{"type":"message","timestamp":"2026-06-15T10:00:00.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-6-astra","usage":{"input":40,"output":60,"cost":{"total":0.3}}}}"#,
        ])
        let day = try XCTUnwrap(day15())
        XCTAssertEqual(day.inputTokens, 190)
        XCTAssertEqual(day.outputTokens, 620)
        XCTAssertEqual(day.timedOutputTokens, 500)
        XCTAssertEqual(day.timedDurationMs, 21810.824874999933, accuracy: 0.000001)
        XCTAssertEqual(day.latestUsageAt, completed)
        let nativeCost = ModelPricing.codexCostUSD(model: "gpt-5", inputTokens: 100, cachedInputTokens: 0, outputTokens: 10).cost
        XCTAssertEqual(day.estimatedCostUSD, 0.6 + nativeCost, accuracy: 0.000001)
    }

    /// Without a recorded cost, omp's disjoint input is re-joined with its cache reads so cached
    /// tokens bill at the cache rate: gpt-6-astra 4K x $10/M + 30K x $1/M + 500 x $50/M.
    func testOmpCodexTurnWithoutCostIsRepricedAtCacheRate() {
        writeRollout("omp/-Users-alice-widget/session.jsonl", lines: [
            #"{"type":"message","timestamp":"2026-06-15T10:00:00.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-6-astra","usage":{"input":4000,"cacheRead":30000,"cacheWrite":0,"output":500}}}"#,
        ])
        XCTAssertEqual(day15()?.estimatedCostUSD ?? -1, 0.095, accuracy: 0.0001)
    }

    /// Cache writes are inside `input_tokens` too: they leave the input bucket, land in cache
    /// writes, and bill at 1.25x input. gpt-6-sol: 1M uncached x $2/M + 1M written x $2.5/M.
    func testCacheWritesAreSplitOutOfInput() {
        writeRollout("sessions/2026/06/15/rollout.jsonl", lines: [
            meta(),
            turnContext("gpt-6-sol"),
            #"{"timestamp":"2026-06-15T09:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":2000000,"cached_input_tokens":0,"cache_write_input_tokens":1000000,"output_tokens":0,"total_tokens":2000000}}}}"#,
        ])
        let day = day15()
        XCTAssertEqual(day?.inputTokens, 1_000_000)
        XCTAssertEqual(day?.cacheWriteTokens, 1_000_000)
        XCTAssertEqual(day?.estimatedCostUSD ?? -1, 4.5, accuracy: 1e-9)
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
