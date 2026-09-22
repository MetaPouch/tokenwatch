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

    private func claudeCodeLine(timestamp: String, model: String, input: Int, cacheRead: Int, cacheCreate: Int, output: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","message":{"model":"\#(model)","usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreate),"output_tokens":\#(output)}}}"#
    }

    private func ompLine(timestamp: String, model: String, input: Int, cacheRead: Int, cacheWrite: Int, output: Int) -> String {
        #"{"type":"message","timestamp":"\#(timestamp)","message":{"role":"assistant","provider":"anthropic","model":"\#(model)","usage":{"input":\#(input),"cacheRead":\#(cacheRead),"cacheWrite":\#(cacheWrite),"output":\#(output)}}}"#
    }

    func testSumsClaudeCodeTurnsOnSameDay() {
        writeClaudeTranscript("session.jsonl", lines: [
            claudeCodeLine(timestamp: "2026-06-15T08:00:00.000Z", model: "claude-sonnet-5", input: 100, cacheRead: 0, cacheCreate: 0, output: 50),
            claudeCodeLine(timestamp: "2026-06-15T09:00:00.000Z", model: "claude-sonnet-5", input: 200, cacheRead: 0, cacheCreate: 0, output: 75),
        ])
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], ompRoots: [ompRoot.path])
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
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], ompRoots: [ompRoot.path])
        let day = days.first { $0.id == "2026-06-15" }
        XCTAssertEqual(day?.inputTokens, 500)
        XCTAssertEqual(day?.outputTokens, 70)
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
        }(), claudeRoots: [claudeRoot.path], ompRoots: [ompRoot.path])
        XCTAssertEqual(days.first { $0.id == "2026-06-14" }?.inputTokens, 10)
        XCTAssertEqual(days.first { $0.id == "2026-06-15" }?.inputTokens, 20)
    }

    func testExcludesTurnsOutsideWindow() {
        writeClaudeTranscript("session.jsonl", lines: [
            claudeCodeLine(timestamp: "2026-01-01T00:00:00.000Z", model: "claude-sonnet-5", input: 999, cacheRead: 0, cacheCreate: 0, output: 999),
        ])
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 7, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], ompRoots: [ompRoot.path])
        XCTAssertEqual(days.reduce(0) { $0 + $1.inputTokens }, 0)
    }

    func testEstimatesCostUsingModelPricing() {
        writeClaudeTranscript("session.jsonl", lines: [
            claudeCodeLine(timestamp: "2026-06-15T08:00:00.000Z", model: "claude-sonnet-5", input: 1_000_000, cacheRead: 0, cacheCreate: 0, output: 1_000_000),
        ])
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], ompRoots: [ompRoot.path])
        let day = days.first { $0.id == "2026-06-15" }
        XCTAssertEqual(day?.estimatedCostUSD ?? -1, 12, accuracy: 0.01) // $2/M input + $10/M output
    }

    func testFlagsApproximateRateForUnknownModel() {
        writeClaudeTranscript("session.jsonl", lines: [
            claudeCodeLine(timestamp: "2026-06-15T08:00:00.000Z", model: "claude-mystery-model", input: 100, cacheRead: 0, cacheCreate: 0, output: 100),
        ])
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], ompRoots: [ompRoot.path])
        XCTAssertEqual(days.first { $0.id == "2026-06-15" }?.hasApproximateRate, true)
    }

    func testReturnsEveryDayInWindowIncludingZeroUsageDays() {
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 7, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], ompRoots: [ompRoot.path])
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
        let days = ClaudeUsageHistoryScanner.dailyUsage(days: 30, now: Date(timeIntervalSince1970: 1_781_937_000), claudeRoots: [claudeRoot.path], ompRoots: [ompRoot.path])
        XCTAssertEqual(days.reduce(0) { $0 + $1.totalTokens }, 0)
    }
}
