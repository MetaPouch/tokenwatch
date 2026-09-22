import XCTest
@testable import TokenWatchCore

final class OmpSessionScannerTests: XCTestCase {
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
    private func writeSession(_ name: String, projectDir: String = "-Users-alice--superset-projects-widget", lines: [String], modifiedSecondsAgo: TimeInterval = 0) -> URL {
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

    private func sessionLine(cwd: String) -> String {
        #"{"type":"session","version":3,"id":"abc","timestamp":"2026-01-01T00:00:00.000Z","cwd":"\#(cwd)"}"#
    }

    private func messageLine(timestamp: String, provider: String, role: String = "assistant", input: Int, cacheRead: Int, cacheWrite: Int) -> String {
        #"{"type":"message","id":"m1","timestamp":"\#(timestamp)","message":{"role":"\#(role)","api":"anthropic-messages","provider":"\#(provider)","model":"claude-sonnet-5","usage":{"input":\#(input),"cacheRead":\#(cacheRead),"cacheWrite":\#(cacheWrite),"totalTokens":\#(input+cacheRead+cacheWrite)}}}"#
    }

    func testFindsLastAnthropicUsageInMostRecentFile() {
        writeSession("older.jsonl", lines: [
            sessionLine(cwd: "/Users/alice/.superset/projects/old-project"),
            messageLine(timestamp: "2026-01-01T00:00:00.000Z", provider: "anthropic", input: 1, cacheRead: 1, cacheWrite: 0),
        ], modifiedSecondsAgo: 3600)

        writeSession("newer.jsonl", projectDir: "-Users-alice--superset-projects-widget", lines: [
            sessionLine(cwd: "/Users/alice/.superset/projects/widget"),
            messageLine(timestamp: "2026-01-01T00:10:05.039Z", provider: "anthropic", input: 18193, cacheRead: 10624, cacheWrite: 0),
        ], modifiedSecondsAgo: 0)

        let activity = OmpSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity?.inputTokens, 18193)
        XCTAssertEqual(activity?.cacheReadTokens, 10624)
        XCTAssertEqual(activity?.sessionLabel, "widget")
        XCTAssertEqual(activity?.timestamp, FlexibleISO8601.parse("2026-01-01T00:10:05.039Z"))
    }

    func testSkipsTrailingNonAnthropicMessagesAndFindsLastAnthropicOne() {
        writeSession("mixed.jsonl", lines: [
            sessionLine(cwd: "/Users/alice/.superset/projects/widget"),
            messageLine(timestamp: "2026-01-01T00:00:00.000Z", provider: "anthropic", input: 500, cacheRead: 200, cacheWrite: 0),
            messageLine(timestamp: "2026-01-01T00:05:00.000Z", provider: "openai", input: 999, cacheRead: 999, cacheWrite: 0),
        ])

        let activity = OmpSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity?.inputTokens, 500)
        XCTAssertEqual(activity?.cacheReadTokens, 200)
    }

    func testSkipsNonAssistantRoleMessages() {
        writeSession("session.jsonl", lines: [
            sessionLine(cwd: "/Users/alice/.superset/projects/widget"),
            messageLine(timestamp: "2026-01-01T00:00:00.000Z", provider: "anthropic", input: 42, cacheRead: 7, cacheWrite: 0),
            messageLine(timestamp: "2026-01-01T00:05:00.000Z", provider: "anthropic", role: "user", input: 0, cacheRead: 0, cacheWrite: 0),
        ])

        let activity = OmpSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity?.inputTokens, 42)
    }

    func testSessionLabelUsesCwdFromSessionLine() {
        writeSession("session.jsonl", projectDir: "-Users-alice-anything", lines: [
            sessionLine(cwd: "/Users/alice/Documents/metapouch/billing-service"),
            messageLine(timestamp: "2026-01-01T00:00:00.000Z", provider: "anthropic", input: 10, cacheRead: 0, cacheWrite: 0),
        ])

        let activity = OmpSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity?.sessionLabel, "billing-service")
    }

    func testSessionLabelFallsBackToDirectoryNameWhenNoSessionLine() {
        writeSession("session.jsonl", projectDir: "-Users-alice--superset-projects-widget", lines: [
            messageLine(timestamp: "2026-01-01T00:00:00.000Z", provider: "anthropic", input: 10, cacheRead: 0, cacheWrite: 0),
        ])

        let activity = OmpSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity?.sessionLabel, "-Users-alice--superset-projects-widget")
    }

    func testDoesNotRecurseIntoPerSessionArtifactSubdirectory() {
        let sessionURL = writeSession("2026-01-01T00-00-00_abc.jsonl", lines: [
            sessionLine(cwd: "/Users/alice/.superset/projects/widget"),
            messageLine(timestamp: "2026-01-01T00:00:00.000Z", provider: "anthropic", input: 10, cacheRead: 0, cacheWrite: 0),
        ])
        let artifactsDir = sessionURL.deletingLastPathComponent().appendingPathComponent("2026-01-01T00-00-00_abc")
        try? FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        let nestedFile = artifactsDir.appendingPathComponent("subagent.jsonl")
        try? messageLine(timestamp: "2026-06-01T00:00:00.000Z", provider: "anthropic", input: 99999, cacheRead: 0, cacheWrite: 0).write(to: nestedFile, atomically: true, encoding: .utf8)

        // If the nested file were scanned, its much-later timestamp would win as "most recent".
        let activity = OmpSessionScanner.mostRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity?.inputTokens, 10)
    }

    func testEmptyOrMissingRootsYieldNil() {
        XCTAssertNil(OmpSessionScanner.mostRecentActivity(roots: ["/nonexistent/path/xyz"]))
        XCTAssertNil(OmpSessionScanner.mostRecentActivity(roots: [tempRoot.path]))
    }

    func testAllRecentActivityExcludesSessionsOutsideWindowAndSortsNewestFirst() {
        writeSession("stale.jsonl", projectDir: "-Users-alice--superset-projects-stale", lines: [
            sessionLine(cwd: "/Users/alice/.superset/projects/stale"),
            messageLine(timestamp: "2026-01-01T00:00:00.000Z", provider: "anthropic", input: 10, cacheRead: 0, cacheWrite: 0),
        ], modifiedSecondsAgo: 6 * 3600)

        writeSession("older-active.jsonl", projectDir: "-Users-alice--superset-projects-older", lines: [
            sessionLine(cwd: "/Users/alice/.superset/projects/older"),
            messageLine(timestamp: "2026-01-01T07:00:00.000Z", provider: "anthropic", input: 20, cacheRead: 0, cacheWrite: 0),
        ], modifiedSecondsAgo: 3 * 3600)

        writeSession("newest-active.jsonl", projectDir: "-Users-alice--superset-projects-newest", lines: [
            sessionLine(cwd: "/Users/alice/.superset/projects/newest"),
            messageLine(timestamp: "2026-01-01T09:00:00.000Z", provider: "anthropic", input: 30, cacheRead: 0, cacheWrite: 0),
        ], modifiedSecondsAgo: 60)

        let activity = OmpSessionScanner.allRecentActivity(roots: [tempRoot.path])
        XCTAssertEqual(activity.map(\.sessionLabel), ["newest", "older"])
    }

    func testAllRecentActivityHonorsCustomWindow() {
        writeSession("hourold.jsonl", lines: [
            sessionLine(cwd: "/Users/alice/.superset/projects/widget"),
            messageLine(timestamp: "2026-01-01T00:00:00.000Z", provider: "anthropic", input: 10, cacheRead: 0, cacheWrite: 0),
        ], modifiedSecondsAgo: 3600)

        XCTAssertTrue(OmpSessionScanner.allRecentActivity(roots: [tempRoot.path], windowSeconds: 1800).isEmpty)
        XCTAssertEqual(OmpSessionScanner.allRecentActivity(roots: [tempRoot.path], windowSeconds: 7200).count, 1)
    }

    func testAllRecentActivityEmptyWhenNoTranscripts() {
        XCTAssertTrue(OmpSessionScanner.allRecentActivity(roots: [tempRoot.path]).isEmpty)
        XCTAssertTrue(OmpSessionScanner.allRecentActivity(roots: ["/nonexistent/path/xyz"]).isEmpty)
    }

    func testProjectRootsDefaultsToOmpAgentSessions() {
        let roots = OmpSessionScanner.projectRoots(homeDirectory: "/home/alice")
        XCTAssertEqual(roots, ["/home/alice/.omp/agent/sessions"])
    }
}
