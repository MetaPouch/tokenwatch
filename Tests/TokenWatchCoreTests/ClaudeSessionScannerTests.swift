import XCTest
@testable import TokenWatchCore

final class ClaudeSessionScannerTests: XCTestCase {
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

    private func writeTranscript(_ name: String, lines: [String], modifiedSecondsAgo: TimeInterval = 0) -> URL {
        let projectDir = tempRoot.appendingPathComponent("some-project", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let fileURL = projectDir.appendingPathComponent(name)
        try? lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        if modifiedSecondsAgo != 0 {
            let date = Date().addingTimeInterval(-modifiedSecondsAgo)
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
        }
        return fileURL
    }

    private func assistantLine(timestamp: String, input: Int, cacheRead: Int, cacheCreate: Int) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","message":{"usage":{"input_tokens":\(input),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheCreate)}}}
        """
    }

    func testFindsLastAssistantUsageInMostRecentFile() {
        _ = writeTranscript("older.jsonl", lines: [
            assistantLine(timestamp: "2026-01-01T00:00:00.000Z", input: 1, cacheRead: 1, cacheCreate: 1)
        ], modifiedSecondsAgo: 3600)

        _ = writeTranscript("newer.jsonl", lines: [
            "{\"type\":\"user\",\"timestamp\":\"2026-09-19T08:00:00.000Z\"}",
            assistantLine(timestamp: "2026-09-19T08:25:34.039Z", input: 2, cacheRead: 484_489, cacheCreate: 1_460),
        ], modifiedSecondsAgo: 0)

        let activity = ClaudeSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity?.inputTokens, 2)
        XCTAssertEqual(activity?.cacheReadTokens, 484_489)
        XCTAssertEqual(activity?.cacheCreationTokens, 1_460)
        XCTAssertEqual(activity?.timestamp, FlexibleISO8601.parse("2026-09-19T08:25:34.039Z"))
        XCTAssertEqual(activity?.sessionLabel, "some-project")
    }

    func testSessionLabelStripsEncodedHomeDirectoryPrefix() {
        let label = ClaudeSessionScanner.sessionLabel(
            forTranscriptPath: "/home/alice/.claude/projects/-home-alice-code-widget-factory/session.jsonl",
            homeDirectory: "/home/alice"
        )
        XCTAssertEqual(label, "code-widget-factory")
    }

    func testSessionLabelFallsBackToRawNameWhenHomePrefixAbsent() {
        let label = ClaudeSessionScanner.sessionLabel(
            forTranscriptPath: "/home/alice/.claude/projects/some-other-machines-project/session.jsonl",
            homeDirectory: "/home/alice"
        )
        XCTAssertEqual(label, "some-other-machines-project")
    }

    func testSessionLabelTruncatesVeryLongProjectNames() {
        let longName = String(repeating: "a", count: 60)
        let label = ClaudeSessionScanner.sessionLabel(
            forTranscriptPath: "/home/alice/.claude/projects/-home-alice-\(longName)/session.jsonl",
            homeDirectory: "/home/alice"
        )
        XCTAssertTrue(label.hasPrefix("…"), label)
        XCTAssertLessThanOrEqual(label.count, 32)
    }


    func testSkipsNonAssistantAndUsagelessLines() {
        _ = writeTranscript("session.jsonl", lines: [
            assistantLine(timestamp: "2026-09-19T08:00:00.000Z", input: 10, cacheRead: 20, cacheCreate: 0),
            "{\"type\":\"user\",\"timestamp\":\"2026-09-19T08:10:00.000Z\"}",
            "{\"type\":\"assistant\",\"timestamp\":\"2026-09-19T08:10:05.000Z\"}", // no usage
        ])

        let activity = ClaudeSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        // Falls back to the earlier line with real usage since the later ones don't qualify.
        XCTAssertEqual(activity?.inputTokens, 10)
        XCTAssertEqual(activity?.cacheReadTokens, 20)
    }

    func testEmptyOrMissingRootsYieldNil() {
        XCTAssertNil(ClaudeSessionScanner.mostRecentActivity(roots: ["/nonexistent/path/xyz"]))
        XCTAssertNil(ClaudeSessionScanner.mostRecentActivity(roots: [tempRoot.path])) // no files written
    }

    func testProjectRootsHonorsClaudeConfigDirOverride() {
        let roots = ClaudeSessionScanner.projectRoots(homeDirectory: "/home/user", environment: ["CLAUDE_CONFIG_DIR": "/custom/claude"])
        XCTAssertEqual(roots, ["/custom/claude/projects"])
    }

    func testProjectRootsDefaultsToBothCommonLocations() {
        let roots = ClaudeSessionScanner.projectRoots(homeDirectory: "/home/user", environment: [:])
        XCTAssertEqual(roots, ["/home/user/.config/claude/projects", "/home/user/.claude/projects"])
    }
}
