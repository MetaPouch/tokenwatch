import XCTest
@testable import TokenWatchCore

final class CodexSessionScannerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    @discardableResult
    private func writeRollout(_ name: String, dateSubpath: String = "2026/01/01", lines: [String], modifiedSecondsAgo: TimeInterval = 0) -> URL {
        let dayDir = tempRoot.appendingPathComponent(dateSubpath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let fileURL = dayDir.appendingPathComponent(name)
        try? lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        if modifiedSecondsAgo != 0 {
            let date = Date().addingTimeInterval(-modifiedSecondsAgo)
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
        }
        return fileURL
    }

    private func sessionMetaLine(cwd: String? = nil) -> String {
        if let cwd {
            return #"{"timestamp":"2026-01-01T00:00:00.000Z","type":"session_meta","payload":{"cwd":"\#(cwd)"}}"#
        }
        return #"{"timestamp":"2026-01-01T00:00:00.000Z","type":"session_meta","payload":{}}"#
    }

    private func tokenCountLine(timestamp: String, input: Int, cached: Int, cacheFieldName: String = "cached_input_tokens") -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"\#(cacheFieldName)":\#(cached)}}}}"#
    }

    func testFindsLastTokenCountUsageInMostRecentFile() {
        writeRollout("rollout-older-11111111-1111.jsonl", lines: [
            sessionMetaLine(cwd: "/Users/alice/old-project"),
            tokenCountLine(timestamp: "2026-01-01T00:00:00.000Z", input: 100, cached: 0),
        ], modifiedSecondsAgo: 3600)

        writeRollout("rollout-newer-22222222-2222.jsonl", lines: [
            sessionMetaLine(cwd: "/Users/alice/my-project"),
            #"{"timestamp":"2026-01-01T00:10:00.000Z","type":"event_msg","payload":{"type":"agent_message"}}"#,
            tokenCountLine(timestamp: "2026-01-01T00:10:05.039Z", input: 18193, cached: 10624),
        ], modifiedSecondsAgo: 0)

        let activity = CodexSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity?.inputTokens, 18193)
        XCTAssertEqual(activity?.cachedInputTokens, 10624)
        XCTAssertEqual(activity?.sessionLabel, "my-project")
        XCTAssertEqual(activity?.timestamp, FlexibleISO8601.parse("2026-01-01T00:10:05.039Z"))
    }

    func testSessionLabelUsesCwdFromSessionMeta() {
        let url = writeRollout("rollout-x-33333333-3333.jsonl", lines: [
            sessionMetaLine(cwd: "/Users/alice/projects/agentick-workspace"),
            tokenCountLine(timestamp: "2026-01-01T00:00:00.000Z", input: 10, cached: 0),
        ])
        XCTAssertEqual(CodexSessionScanner.sessionLabel(forTranscriptPath: url.path), "agentick-workspace")
    }

    func testSessionLabelFallsBackToUUIDFragmentWhenNoCwd() {
        let url = writeRollout("rollout-2026-01-01T00-00-00-5973b6c0-94b8-487b-a530-2aeb6098ae0e.jsonl", lines: [
            sessionMetaLine(),
            tokenCountLine(timestamp: "2026-01-01T00:00:00.000Z", input: 10, cached: 0),
        ])
        let label = CodexSessionScanner.sessionLabel(forTranscriptPath: url.path)
        XCTAssertEqual(label, "session-5973b6c0")
    }

    func testDefensivelyParsesOlderCacheReadInputTokensFieldName() {
        writeRollout("rollout-old-field-44444444-4444.jsonl", lines: [
            sessionMetaLine(cwd: "/Users/alice/legacy"),
            tokenCountLine(timestamp: "2026-01-01T00:00:00.000Z", input: 500, cached: 200, cacheFieldName: "cache_read_input_tokens"),
        ])
        let activity = CodexSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity?.cachedInputTokens, 200)
    }

    func testSkipsNonTokenCountLines() {
        writeRollout("rollout-skip-55555555-5555.jsonl", lines: [
            sessionMetaLine(cwd: "/Users/alice/proj"),
            tokenCountLine(timestamp: "2026-01-01T00:00:00.000Z", input: 42, cached: 7),
            #"{"timestamp":"2026-01-01T00:05:00.000Z","type":"event_msg","payload":{"type":"agent_message","message":"hi"}}"#,
        ])
        // Falls back to the earlier token_count line since the later line isn't one.
        let activity = CodexSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity?.inputTokens, 42)
        XCTAssertEqual(activity?.cachedInputTokens, 7)
    }

    func testEmptyOrMissingRootsYieldNil() {
        XCTAssertNil(CodexSessionScanner.mostRecentActivity(roots: ["/nonexistent/path/xyz"]))
        XCTAssertNil(CodexSessionScanner.mostRecentActivity(roots: [tempRoot.path]))
    }

    func testProjectRootsHonorsCodexHomeOverride() {
        let roots = CodexSessionScanner.projectRoots(homeDirectory: "/home/user", environment: ["CODEX_HOME": "/custom/codex"])
        XCTAssertEqual(roots, ["/custom/codex/sessions"])
    }

    func testProjectRootsDefaultsToCodexSessions() {
        let roots = CodexSessionScanner.projectRoots(homeDirectory: "/home/user", environment: [:])
        XCTAssertEqual(roots, ["/home/user/.codex/sessions"])
    }

    func testAllRecentActivityExcludesSessionsOutsideWindowAndSortsNewestFirst() {
        writeRollout("rollout-stale-66666666-6666.jsonl", lines: [
            sessionMetaLine(cwd: "/Users/alice/stale-project"),
            tokenCountLine(timestamp: "2026-01-01T00:00:00.000Z", input: 10, cached: 0),
        ], modifiedSecondsAgo: 6 * 3600) // outside the default 5h window

        writeRollout("rollout-older-active-77777777-7777.jsonl", lines: [
            sessionMetaLine(cwd: "/Users/alice/older-active"),
            tokenCountLine(timestamp: "2026-01-01T07:00:00.000Z", input: 20, cached: 0),
        ], modifiedSecondsAgo: 3 * 3600)

        writeRollout("rollout-newest-active-88888888-8888.jsonl", lines: [
            sessionMetaLine(cwd: "/Users/alice/newest-active"),
            tokenCountLine(timestamp: "2026-01-01T09:00:00.000Z", input: 30, cached: 0),
        ], modifiedSecondsAgo: 60)

        let activity = CodexSessionScanner.allRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity.map(\.sessionLabel), ["newest-active", "older-active"])
        XCTAssertEqual(activity.map(\.inputTokens), [30, 20])
    }

    func testAllRecentActivityHonorsCustomWindow() {
        writeRollout("rollout-hourold-99999999-9999.jsonl", lines: [
            sessionMetaLine(cwd: "/Users/alice/hour-old"),
            tokenCountLine(timestamp: "2026-01-01T00:00:00.000Z", input: 10, cached: 0),
        ], modifiedSecondsAgo: 3600)

        XCTAssertTrue(CodexSessionScanner.allRecentActivity(roots: [tempRoot.path], windowSeconds: 1800).isEmpty)
        XCTAssertEqual(CodexSessionScanner.allRecentActivity(roots: [tempRoot.path], windowSeconds: 7200).count, 1)
    }

    func testAllRecentActivityEmptyWhenNoTranscripts() {
        XCTAssertTrue(CodexSessionScanner.allRecentActivity(roots: [tempRoot.path]).isEmpty)
        XCTAssertTrue(CodexSessionScanner.allRecentActivity(roots: ["/nonexistent/path/xyz"]).isEmpty)
    }
}
