import XCTest
@testable import TokenWatchCore

final class UsageSourcesTests: XCTestCase {
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

    private func write(_ relativePath: String, _ lines: [String] = []) {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func mkdir(_ relativePath: String) {
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(relativePath), withIntermediateDirectories: true)
    }

    private func harnessTurn(_ provider: String, _ model: String, input: Int, cost: Double? = nil) -> String {
        let costField = cost.map { #","cost":{"total":\#($0)}"# } ?? ""
        return #"{"type":"message","timestamp":"2026-06-15T10:00:00.000Z","message":{"role":"assistant","provider":"\#(provider)","model":"\#(model)","usage":{"input":\#(input),"cacheRead":0,"cacheWrite":0,"output":0\#(costField)}}}"#
    }

    private func day15(_ days: [UsageDay]?) -> UsageDay? { days?.first { $0.id == "2026-06-15" } }

    /// One harness session can switch providers. Every turn lands on exactly one source: Anthropic
    /// on Claude, OpenRouter on OpenRouter, a provider TokenWatch has no card for on Other -- and
    /// pi's sessions count the same as omp's.
    func testHarnessTurnsAreAttributedToTheProviderThatServedThem() {
        write("omp/-proj/s.jsonl", [
            harnessTurn("anthropic", "claude-sonnet-5", input: 100, cost: 1),
            harnessTurn("openrouter", "anthropic/claude-sonnet-5", input: 20, cost: 0.2),
            harnessTurn("deepseek", "deepseek-v4", input: 3, cost: 0.03),
        ])
        write("pi/-proj/s.jsonl", [harnessTurn("openrouter", "google/gemini-3-flash", input: 5, cost: 0.05)])
        let roots = [root.appendingPathComponent("omp").path, root.appendingPathComponent("pi").path]

        let others = LocalUsageHistoryScanner.dailyUsage(days: 30, now: now, locations: LocalUsageLocations(harnessRoots: roots))
        XCTAssertEqual(Set(others.keys), [.provider(.openrouter), .other])
        XCTAssertEqual(day15(others[.provider(.openrouter)])?.inputTokens, 25)
        XCTAssertEqual(day15(others[.other])?.estimatedCostUSD ?? -1, 0.03, accuracy: 1e-9)

        let claude = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: now, claudeRoots: ["/nonexistent"], localLogs: LocalUsageLocations(harnessRoots: roots))
        XCTAssertEqual(day15(claude)?.inputTokens, 100)
    }

    func testIncrementalHarnessTimingStaysWithItsBilledSource() throws {
        let completed = try XCTUnwrap(FlexibleISO8601.parse("2026-06-15T10:00:02.000Z"))
        write("pi/-proj/s.jsonl", [
            #"{"type":"message","timestamp":"2026-06-15T10:00:00.000Z","message":{"role":"assistant","provider":"openrouter","model":"m","duration":2000,"completedAt":\#(completed.timeIntervalSince1970 * 1000),"usage":{"input":10,"output":40,"cost":{"total":0.2}}}}"#,
        ])
        let locations = LocalUsageLocations(harnessRoots: [root.appendingPathComponent("pi").path])
        let first = LocalUsageHistoryScanner.dailyUsage(days: 30, now: now, locations: locations)
        XCTAssertEqual(day15(first[.provider(.openrouter)])?.timedOutputTokens, 40)
        XCTAssertEqual(day15(first[.provider(.openrouter)])?.timedDurationMs, 2000)
        XCTAssertEqual(day15(first[.provider(.openrouter)])?.latestUsageAt, completed)

        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("pi/-proj/s.jsonl"))
        defer { try? handle.close() }
        try handle.seekToEnd()
        let other = #"{"type":"message","timestamp":"2026-06-15T10:01:00.000Z","message":{"role":"assistant","provider":"deepseek","model":"m","duration":500,"usage":{"input":20,"output":10,"cost":{"total":0.1}}}}"#
        try handle.write(contentsOf: Data(("\n" + other + "\n").utf8))
        let appended = LocalUsageHistoryScanner.dailyUsage(days: 30, now: now, locations: locations)
        XCTAssertEqual(Set(appended.keys), [.provider(.openrouter), .other])
        XCTAssertEqual(day15(appended[.provider(.openrouter)])?.timedOutputTokens, 40)
        XCTAssertEqual(day15(appended[.provider(.openrouter)])?.estimatedCostUSD ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(day15(appended[.other])?.timedOutputTokens, 10)
        XCTAssertEqual(day15(appended[.other])?.timedDurationMs, 500)
        XCTAssertEqual(day15(appended[.other])?.latestUsageAt, FlexibleISO8601.parse("2026-06-15T10:01:00.000Z"))
    }

    /// A harness turn without a recorded cost is priced from whichever table knows the model, and
    /// only flagged approximate when none does.
    func testHarnessTurnWithoutCostIsPricedByModelFamily() {
        write("omp/-proj/s.jsonl", [
            harnessTurn("openrouter", "x-ai/grok-4.6", input: 1_000_000),
            harnessTurn("deepseek", "deepseek-v4", input: 1_000_000),
        ])
        let others = LocalUsageHistoryScanner.dailyUsage(days: 30, now: now, locations: LocalUsageLocations(harnessRoots: [root.appendingPathComponent("omp").path]))
        XCTAssertEqual(day15(others[.provider(.openrouter)])?.estimatedCostUSD ?? -1, 2, accuracy: 1e-9) // grok-4.6 $2/M input
        XCTAssertEqual(day15(others[.provider(.openrouter)])?.hasApproximateRate, false)
        XCTAssertEqual(day15(others[.other])?.hasApproximateRate, true)
    }

    /// A second Claude account keeps its transcripts inside its own config dir; its `projects/`
    /// counts, as does each entry of a comma-separated CLAUDE_CONFIG_DIR. A directory without
    /// Claude's own files doesn't, and a profile sharing `~/.claude/projects` via a symlink counts once.
    func testClaudeHistoryRootsCoverProfilesOnceEach() throws {
        mkdir(".claude/projects")
        write(".claude-work/.claude.json", ["{}"]); mkdir(".claude-work/projects")
        mkdir(".not-claude/projects")
        write(".claude-shared/.credentials.json", ["{}"])
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(".claude-shared/projects").path, withDestinationPath: root.appendingPathComponent(".claude/projects").path)
        mkdir("elsewhere/a/projects"); mkdir("elsewhere/b/projects")

        let home = root.path
        let roots = ClaudeAccountDiscovery.historyRoots(homeDirectory: home, environment: ["CLAUDE_CONFIG_DIR": "\(home)/elsewhere/a, \(home)/elsewhere/b"])
        let resolved = (home as NSString).resolvingSymlinksInPath
        XCTAssertEqual(Set(roots), Set(["/.claude/projects", "/.claude-work/projects", "/elsewhere/a/projects", "/elsewhere/b/projects"].map { resolved + $0 }))
        XCTAssertEqual(roots.count, 4)
    }

    /// Every `~/.codex*` home's rollouts count, not just the default one's.
    func testCodexHistoryRootsCoverEveryCodexHome() {
        mkdir(".codex/sessions"); mkdir(".codex-work/sessions"); mkdir(".codex-work/archived_sessions")
        let resolved = (root.path as NSString).resolvingSymlinksInPath
        let roots = CodexAccountDiscovery.historyRoots(homeDirectory: root.path, environment: [:])
        XCTAssertEqual(roots, ["/.codex/sessions", "/.codex-work/sessions", "/.codex-work/archived_sessions"].map { resolved + $0 })
    }
}
