import XCTest
@testable import TokenWatchCore

final class ClaudeAccountDiscoveryTests: XCTestCase {
    private var tempHome: URL!

    override func setUp() {
        super.setUp()
        tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempHome)
        super.tearDown()
    }

    private func makeDir(_ relativePath: String) -> URL {
        let url = tempHome.appendingPathComponent(relativePath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCredentials(in dir: URL, accessToken: String = "tok") {
        let json = #"{"claudeAiOauth":{"accessToken":"\#(accessToken)"}}"#
        try? json.write(to: dir.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
    }

    func testDiscoversProfileDirWithOwnCredentials() {
        let profile = makeDir(".claude-work")
        writeCredentials(in: profile, accessToken: "work-token")

        let accounts = ClaudeAccountDiscovery.discoverAdditionalAccounts(homeDirectory: tempHome.path)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.credential.accessToken, "work-token")
        XCTAssertEqual(accounts.first?.sourceLabel, "~/.claude-work")
    }

    func testExcludesDefaultClaudeConfigLocations() {
        let defaultDotClaude = makeDir(".claude")
        writeCredentials(in: defaultDotClaude)
        let defaultConfigClaude = makeDir(".config/claude")
        writeCredentials(in: defaultConfigClaude)

        let accounts = ClaudeAccountDiscovery.discoverAdditionalAccounts(homeDirectory: tempHome.path)
        XCTAssertTrue(accounts.isEmpty)
    }

    func testSkipsCandidateDirsWithoutCredentials() {
        _ = makeDir(".not-a-claude-profile")
        let accounts = ClaudeAccountDiscovery.discoverAdditionalAccounts(homeDirectory: tempHome.path)
        XCTAssertTrue(accounts.isEmpty)
    }

    func testReadsEmailFromProfileOwnStateFile() {
        let profile = makeDir(".claude-personal")
        writeCredentials(in: profile)
        let stateJSON = #"{"oauthAccount":{"emailAddress":"me@example.com"}}"#
        try? stateJSON.write(to: profile.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let accounts = ClaudeAccountDiscovery.discoverAdditionalAccounts(homeDirectory: tempHome.path)
        XCTAssertEqual(accounts.first?.email, "me@example.com")
    }

    func testScansBothDotDirsAndConfigSubdirectories() {
        let dotDirProfile = makeDir(".claude-a")
        writeCredentials(in: dotDirProfile, accessToken: "a")
        let configProfile = makeDir(".config/claude-b")
        writeCredentials(in: configProfile, accessToken: "b")

        let accounts = ClaudeAccountDiscovery.discoverAdditionalAccounts(homeDirectory: tempHome.path)
        XCTAssertEqual(Set(accounts.map(\.credential.accessToken)), ["a", "b"])
    }

    func testEmptyHomeYieldsNoAccounts() {
        XCTAssertTrue(ClaudeAccountDiscovery.discoverAdditionalAccounts(homeDirectory: tempHome.path).isEmpty)
    }
}
