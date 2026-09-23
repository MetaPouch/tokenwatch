import XCTest
import SQLite3
@testable import TokenWatchCore

final class AgentUsageLogsTests: XCTestCase {
    private var root: URL!
    /// 2026-06-20T01:10:00Z; the 30-day window starts 2026-05-22 local time.
    private let now = Date(timeIntervalSince1970: 1_781_937_000)
    private let june15 = Date(timeIntervalSince1970: 1_781_517_600) // 2026-06-15T10:00:00Z
    private let april1 = Date(timeIntervalSince1970: 1_775_037_600) // before the window

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }

    private func write(_ relative: String, _ lines: [String]) {
        let url = root.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeDatabase(_ relative: String, _ statements: [String]) {
        let url = root.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        for statement in statements {
            XCTAssertEqual(sqlite3_exec(db, statement, nil, nil, nil), SQLITE_OK, statement)
        }
        sqlite3_close(db)
    }

    private func sqlString(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private func others(_ locations: LocalUsageLocations) -> [SpendSource: UsageDay] {
        LocalUsageHistoryScanner.dailyUsage(days: 30, now: now, locations: locations).compactMapValues { $0.first { $0.id == "2026-06-15" } }
    }

    // MARK: OpenCode

    private func openCodeMessage(provider: String, model: String, at date: Date, input: Int, output: Int, reasoning: Int = 0, cacheRead: Int = 0, cost: Double = 0, role: String = "assistant") -> String {
        #"{"role":"\#(role)","providerID":"\#(provider)","modelID":"\#(model)","time":{"created":\#(ms(date))},"cost":\#(cost),"tokens":{"input":\#(input),"output":\#(output),"reasoning":\#(reasoning),"cache":{"read":\#(cacheRead),"write":0}}}"#
    }

    private func makeOpenCodeDatabase(_ messages: [(Date, String)]) {
        makeDatabase("opencode/opencode.db", ["CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)"]
            + messages.enumerated().map { index, message in
                "INSERT INTO message VALUES ('m\(index)', 's', \(ms(message.0)), \(ms(message.0)), \(sqlString(message.1)))"
            })
    }

    /// OpenCode excludes reasoning from `tokens.output` and bills it as output; a subscription
    /// sign-in records cost 0, which is re-priced rather than taken as free. Each message counts
    /// toward the provider that served it.
    func testOpenCodeCountsReasoningAsOutputAndAttributesByProvider() {
        makeOpenCodeDatabase([
            (june15, openCodeMessage(provider: "anthropic", model: "claude-sonnet-5", at: june15, input: 1_000_000, output: 100, reasoning: 900)),
            (june15, openCodeMessage(provider: "openrouter", model: "x-ai/grok-4.6", at: june15, input: 10, output: 5, cost: 0.5)),
            (june15, openCodeMessage(provider: "anthropic", model: "claude-sonnet-5", at: june15, input: 7, output: 7, role: "user")),
            (april1, openCodeMessage(provider: "openrouter", model: "x-ai/grok-4.6", at: april1, input: 99, output: 99, cost: 9)),
        ])
        let locations = LocalUsageLocations(openCodeDataDirectory: path("opencode"))
        let claude = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: now, claudeRoots: [], localLogs: locations).first { $0.id == "2026-06-15" }
        XCTAssertEqual(claude?.inputTokens, 1_000_000)
        XCTAssertEqual(claude?.outputTokens, 1_000)
        XCTAssertEqual(claude?.estimatedCostUSD ?? -1, 2 + 0.01, accuracy: 1e-9) // sonnet-5: $2/M in, $10/M out
        XCTAssertEqual(others(locations)[.provider(.openrouter)]?.estimatedCostUSD ?? -1, 0.5, accuracy: 1e-9)
    }

    /// OpenCode's `openai` provider is a ChatGPT sign-in -- the Codex quota -- when its
    /// `auth.json` says `oauth`, and the OpenAI API otherwise.
    func testOpenCodeOpenAIFollowsItsSignInType() {
        makeOpenCodeDatabase([(june15, openCodeMessage(provider: "openai", model: "gpt-6-sol", at: june15, input: 40, output: 2, cost: 0.1))])
        let locations = LocalUsageLocations(openCodeDataDirectory: path("opencode"))
        XCTAssertEqual(others(locations)[.provider(.openai)]?.inputTokens, 40)

        write("opencode/auth.json", [#"{"openai":{"type":"oauth","access":"x","refresh":"y","expires":0}}"#])
        let codex = CodexUsageHistoryScanner.dailyUsage(days: 30, now: now, roots: [], localLogs: locations).first { $0.id == "2026-06-15" }
        XCTAssertEqual(codex?.inputTokens, 40)
        XCTAssertNil(others(locations)[.provider(.openai)])
    }

    /// Pre-database installs keep one JSON file per message; OpenCode migrates that tree into the
    /// database, so it only counts when there is no database.
    func testOpenCodeLegacyTreeCountsOnlyWithoutADatabase() {
        write("opencode/storage/message/ses_1/msg_1.json", [openCodeMessage(provider: "openrouter", model: "m", at: june15, input: 30, output: 0, cost: 0.3)])
        let locations = LocalUsageLocations(openCodeDataDirectory: path("opencode"))
        XCTAssertEqual(others(locations)[.provider(.openrouter)]?.inputTokens, 30)

        makeOpenCodeDatabase([(june15, openCodeMessage(provider: "openrouter", model: "m", at: june15, input: 30, output: 0, cost: 0.3))])
        XCTAssertEqual(others(locations)[.provider(.openrouter)]?.inputTokens, 30)
    }

    // MARK: Copilot CLI and Devin

    /// Copilot's `created_at` is UTC text without a zone; events before the window don't count,
    /// and everything counts toward Copilot at the served model's list rate.
    func testCopilotCLIEventsCountTowardCopilot() {
        makeDatabase("copilot/session-store.db", [
            "CREATE TABLE assistant_usage_events (id INTEGER PRIMARY KEY, session_id TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, reasoning_tokens INTEGER, created_at TEXT)",
            "INSERT INTO assistant_usage_events VALUES (1, 's', 'claude-haiku-4.5', 1000000, 0, 500, 0, 0, '2026-06-15 10:00:00')",
            "INSERT INTO assistant_usage_events VALUES (2, 's', 'claude-haiku-4.5', 7, 7, 0, 0, 0, '2026-04-01 10:00:00')",
        ])
        let day = others(LocalUsageLocations(copilotDatabase: path("copilot/session-store.db")))[.provider(.copilot)]
        XCTAssertEqual(day?.inputTokens, 1_000_000)
        XCTAssertEqual(day?.cacheReadTokens, 500)
        XCTAssertEqual(day?.estimatedCostUSD ?? -1, 1 + 500 * 0.1 / 1_000_000, accuracy: 1e-9) // haiku-4-5 $1/M
        XCTAssertEqual(day?.hasApproximateRate, false)
    }

    /// Devin writes each assistant message twice (streamed and committed, same request id).
    func testDevinCountsEachRequestOnce() {
        let message = #"{"role":"assistant","message_id":"%@","metadata":{"request_id":"req-1","generation_model":"swe-1.6","created_at":"2026-06-15T10:00:00Z","metrics":{"input_tokens":100,"output_tokens":10,"cache_read_tokens":1000}}}"#
        makeDatabase("devin/sessions.db", [
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, model TEXT, working_directory TEXT, title TEXT)",
            "CREATE TABLE message_nodes (id INTEGER PRIMARY KEY, session_id TEXT, chat_message TEXT, created_at INTEGER)",
            "INSERT INTO message_nodes VALUES (1, 's', \(sqlString(String(format: message, "a"))), \(Int(june15.timeIntervalSince1970)))",
            "INSERT INTO message_nodes VALUES (2, 's', \(sqlString(String(format: message, "b"))), \(Int(june15.timeIntervalSince1970)))",
        ])
        let day = others(LocalUsageLocations(devinDatabase: path("devin/sessions.db")))[.other]
        XCTAssertEqual(day?.inputTokens, 100)
        XCTAssertEqual(day?.cacheReadTokens, 1000)
    }

    // MARK: Grok, Antigravity, fx, Muse

    /// Grok's `prompt_tokens` includes the cached share; the model comes from the session summary.
    func testGrokSplitsCachedPromptAndReadsModelFromSummary() {
        write("grok/logs/unified.jsonl", [
            #"{"ts":"2026-06-15T10:00:00Z","sid":"s1","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000,"cached_prompt_tokens":800,"completion_tokens":50}}"#,
            #"{"ts":"2026-06-15T10:00:01Z","sid":"s1","msg":"shell.turn.started","ctx":{"prompt_tokens":5}}"#,
        ])
        write("grok/sessions/-Users-a-proj/s1/summary.json", [#"{"current_model_id":"grok-4.6"}"#])
        let day = others(LocalUsageLocations(grokHomes: [path("grok")]))[.provider(.grok)]
        XCTAssertEqual(day?.inputTokens, 200)
        XCTAssertEqual(day?.cacheReadTokens, 800)
        XCTAssertEqual(day?.outputTokens, 50)
        XCTAssertEqual(day?.modelBreakdown.map(\.id), ["grok-4.6"])
    }

    /// Gemini's candidate count excludes thinking tokens, which bill as output; an OpenAI-style
    /// `output_tokens` already includes reasoning. Input includes cached tokens in both.
    func testAntigravityAddsThoughtsOnlyToGeminiStyleOutput() {
        write("brain/s1/.system_generated/logs/transcript_full.jsonl", [
            #"{"type":"MODEL","timestamp":"2026-06-15T10:00:00Z","model":"gemini-3-pro","response":{"usageMetadata":{"promptTokenCount":1000,"cachedContentTokenCount":600,"candidatesTokenCount":100,"thoughtsTokenCount":40}}}"#,
            #"{"type":"MODEL","created_at":1781517600,"model":"gemini-3-pro","usage":{"input_tokens":10,"output_tokens":5,"reasoning_tokens":3}}"#,
        ])
        let day = others(LocalUsageLocations(antigravityBrain: path("brain")))[.provider(.antigravity)]
        XCTAssertEqual(day?.inputTokens, 400 + 10)
        XCTAssertEqual(day?.cacheReadTokens, 600)
        XCTAssertEqual(day?.outputTokens, 140 + 5)
    }

    /// fx checkpoints are cumulative per model: each call is the delta from the previous one.
    func testFxDiffsCumulativeCheckpoints() {
        func checkpoint(_ input: Int, _ cached: Int, _ cost: Double) -> String {
            #"{"timestamp_ms":\#(ms(june15)),"kind":"usage_checkpointed","payload":{"usage":{"models":[{"model":"gpt-6-sol","input_tokens":\#(input),"cache_read_tokens":\#(cached),"output_tokens":0,"total_cost":\#(cost)}]}}}"#
        }
        write("fx/s1/events.jsonl", [checkpoint(100, 40, 0.1), checkpoint(250, 100, 0.25)])
        let day = others(LocalUsageLocations(fxSessions: path("fx")))[.other]
        XCTAssertEqual(day?.inputTokens, 150) // 250 total, 100 of it cached
        XCTAssertEqual(day?.cacheReadTokens, 100)
        XCTAssertEqual(day?.estimatedCostUSD ?? -1, 0.25, accuracy: 1e-9)
    }

    /// A child run is mirrored into its own and its parent's log: it counts once. Dot-directories
    /// under the sessions root hold view caches, never logs.
    func testMuseCountsAMirroredRunOnceAndSkipsDotDirectories() {
        let call = #"{"id":"e1","recorded_at":1781517600000000,"payload_type":"runtime.session","payload":{"kind":"run","source_run_record_id":"run-7","event":{"kind":"model_completed","model":"muse-1","usage":{"input_tokens":500,"cached_tokens":300,"output_tokens":20,"cost_micros":2500}}}}"#
        write("muse/2026/06/15/parent/session.jsonl", [call])
        write("muse/2026/06/15/parent/child/session.jsonl", [call])
        write("muse/.msp-view-v1/2026/06/15/x/session.jsonl", [call.replacingOccurrences(of: "run-7", with: "run-8")])
        let day = others(LocalUsageLocations(museSessions: path("muse")))[.other]
        XCTAssertEqual(day?.inputTokens, 200)
        XCTAssertEqual(day?.cacheReadTokens, 300)
        XCTAssertEqual(day?.estimatedCostUSD ?? -1, 0.0025, accuracy: 1e-12)
    }

    // MARK: Cursor

    /// Shaped like a real `GetFilteredUsageEvents` page: the timestamp is an int64 in a string.
    /// `totalCents` (token-rate cost) wins over `chargedCents` (which adds Cursor's fee).
    func testCursorEventsDecodeAndPreferTokenRateCost() throws {
        let json = #"{"totalUsageEventsCount":"2","usageEventsDisplay":[{"timestamp":"1781517600000","model":"default","tokenUsage":{"inputTokens":69653,"outputTokens":16006,"cacheReadTokens":1313654,"totalCents":33.75723},"chargedCents":51.151575},{"timestamp":"1781517600000","model":"default","chargedCents":4}]}"#
        let page = try JSONDecoder().decode(CursorUsageHistory.Page.self, from: Data(json.utf8))
        let turns = CursorUsageHistory.turns(page.usageEventsDisplay ?? [])
        XCTAssertEqual(turns.count, 1) // an event without token usage isn't a call
        XCTAssertEqual(turns.first?.timestamp, june15)
        XCTAssertEqual(turns.first?.input, 69_653)
        XCTAssertEqual(turns.first?.cacheRead, 1_313_654)
        XCTAssertEqual(turns.first?.costUSD ?? -1, 0.3375723, accuracy: 1e-9)
        XCTAssertEqual(turns.first?.source, .provider(.cursor))
    }
}
