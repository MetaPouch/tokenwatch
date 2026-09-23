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

    private func writeTranscript(_ name: String, projectDir: String = "some-project", lines: [String], modifiedSecondsAgo: TimeInterval = 0) -> URL {
        let projectDirURL = tempRoot.appendingPathComponent(projectDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: projectDirURL, withIntermediateDirectories: true)
        let fileURL = projectDirURL.appendingPathComponent(name)
        try? lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        if modifiedSecondsAgo != 0 {
            let date = Date().addingTimeInterval(-modifiedSecondsAgo)
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
        }
        return fileURL
    }

    private func assistantLine(timestamp: String, input: Int, cacheRead: Int, cacheCreate: Int, cwd: String? = nil) -> String {
        let cwdField = cwd.map { #","cwd":"\#($0)""# } ?? ""
        return #"{"type":"assistant","timestamp":"\#(timestamp)","message":{"usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreate)}}\#(cwdField)}"#
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

    private func assistantLine(timestamp: String, write5m: Int, write1h: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":1000,"cache_creation_input_tokens":\#(write5m + write1h),"cache_creation":{"ephemeral_5m_input_tokens":\#(write5m),"ephemeral_1h_input_tokens":\#(write1h)}}}}"#
    }

    /// The newest turn was a pure cache hit (no writes), so the TTL comes from the newest turn
    /// that wrote cache entries; a turn with any 5-minute writes reads as 5 minutes.
    func testCacheTTLComesFromNewestTurnThatWroteCache() {
        _ = writeTranscript("hour.jsonl", lines: [
            assistantLine(timestamp: "2026-09-19T08:00:00.000Z", write5m: 500, write1h: 0),
            assistantLine(timestamp: "2026-09-19T08:10:00.000Z", write5m: 0, write1h: 800),
            assistantLine(timestamp: "2026-09-19T08:20:00.000Z", write5m: 0, write1h: 0),
        ])
        let hour = ClaudeSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(hour?.timestamp, FlexibleISO8601.parse("2026-09-19T08:20:00.000Z"))
        XCTAssertEqual(hour?.cacheTTLSeconds, 3600)

        _ = writeTranscript("mixed.jsonl", projectDir: "other", lines: [
            assistantLine(timestamp: "2026-09-19T09:00:00.000Z", write5m: 10, write1h: 800),
        ])
        XCTAssertEqual(ClaudeSessionScanner.allRecentActivity(roots: [tempRoot.path]).first { $0.sessionLabel == "other" }?.cacheTTLSeconds, 300)
    }

    func testCacheTTLIsNilWhenLogDoesNotSplitWritesByTTL() {
        _ = writeTranscript("old.jsonl", lines: [
            assistantLine(timestamp: "2026-09-19T08:25:34.039Z", input: 2, cacheRead: 100, cacheCreate: 50),
        ])
        XCTAssertNil(ClaudeSessionScanner.mostRecentActivity(roots: [tempRoot.path])?.cacheTTLSeconds)
    }

    func testPrefersRealCwdLeafOverEncodedDirectoryName() {
        // The on-disk project directory encodes the whole nested path since home (a worktree
        // manager placing this under ~/.tool/worktrees/<id>/<repo>), which would otherwise leak
        // every intermediate directory name (tool, org, repo) into the dashboard. The real `cwd`
        // Claude Code stamps on the line lets us show just the leaf instead.
        _ = writeTranscript(
            "session.jsonl",
            projectDir: "-Users-alice--tool-worktrees-worktrees-abcd1234-git-github-com-someorg-somerepo",
            lines: [
                assistantLine(
                    timestamp: "2026-09-19T08:25:34.039Z", input: 2, cacheRead: 10, cacheCreate: 0,
                    cwd: "/Users/alice/.tool/worktrees/worktrees/abcd1234/git-github.com-someorg-somerepo"
                ),
            ]
        )

        let activity = ClaudeSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity?.sessionLabel, "git-github.com-someorg-somerepo")
    }

    func testCwdLeafForSimpleWorktreeShowsJustTheWorktreeName() {
        _ = writeTranscript(
            "session.jsonl",
            projectDir: "-Users-alice-code-myrepo-worktrees-feature-x",
            lines: [
                assistantLine(
                    timestamp: "2026-09-19T08:25:34.039Z", input: 2, cacheRead: 10, cacheCreate: 0,
                    cwd: "/Users/alice/code/myrepo-worktrees/feature-x"
                ),
            ]
        )

        let activity = ClaudeSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity?.sessionLabel, "feature-x")
    }

    func testCwdLeafIsTruncatedWhenVeryLong() {
        let longLeaf = String(repeating: "a", count: 60)
        _ = writeTranscript("session.jsonl", lines: [
            assistantLine(timestamp: "2026-09-19T08:25:34.039Z", input: 1, cacheRead: 0, cacheCreate: 0, cwd: "/Users/alice/code/\(longLeaf)"),
        ])

        let activity = ClaudeSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity?.sessionLabel, "…" + longLeaf.suffix(31))
    }

    func testEmptyCwdFallsBackToEncodedDirectoryName() {
        _ = writeTranscript("session.jsonl", projectDir: "some-project", lines: [
            assistantLine(timestamp: "2026-09-19T08:25:34.039Z", input: 1, cacheRead: 0, cacheCreate: 0, cwd: ""),
        ])

        let activity = ClaudeSessionScanner.mostRecentActivity(roots: [tempRoot.path])
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

    func testAllRecentActivityExcludesSessionsOutsideWindowAndSortsNewestFirst() {
        _ = writeTranscript("session.jsonl", projectDir: "stale-project", lines: [
            assistantLine(timestamp: "2026-09-19T00:00:00.000Z", input: 1, cacheRead: 0, cacheCreate: 0)
        ], modifiedSecondsAgo: 6 * 3600) // outside the default 5h window

        _ = writeTranscript("session.jsonl", projectDir: "older-active-project", lines: [
            assistantLine(timestamp: "2026-09-19T07:00:00.000Z", input: 2, cacheRead: 0, cacheCreate: 0)
        ], modifiedSecondsAgo: 3 * 3600)

        _ = writeTranscript("session.jsonl", projectDir: "newest-active-project", lines: [
            assistantLine(timestamp: "2026-09-19T09:00:00.000Z", input: 3, cacheRead: 0, cacheCreate: 0)
        ], modifiedSecondsAgo: 60)

        let activity = ClaudeSessionScanner.allRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity.map(\.sessionLabel), ["newest-active-project", "older-active-project"])
        XCTAssertEqual(activity.map(\.inputTokens), [3, 2])
    }

    func testAllRecentActivityHonorsCustomWindow() {
        _ = writeTranscript("session.jsonl", projectDir: "hour-old-project", lines: [
            assistantLine(timestamp: "2026-09-19T08:00:00.000Z", input: 1, cacheRead: 0, cacheCreate: 0)
        ], modifiedSecondsAgo: 3600)

        XCTAssertTrue(ClaudeSessionScanner.allRecentActivity(roots: [tempRoot.path], windowSeconds: 1800).isEmpty)
        XCTAssertEqual(ClaudeSessionScanner.allRecentActivity(roots: [tempRoot.path], windowSeconds: 7200).count, 1)
    }

    func testAllRecentActivityEmptyWhenNoTranscripts() {
        XCTAssertTrue(ClaudeSessionScanner.allRecentActivity(roots: [tempRoot.path]).isEmpty)
        XCTAssertTrue(ClaudeSessionScanner.allRecentActivity(roots: ["/nonexistent/path/xyz"]).isEmpty)
    }
}
