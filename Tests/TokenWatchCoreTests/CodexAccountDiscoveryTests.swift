import XCTest
@testable import TokenWatchCore

final class CodexAccountDiscoveryTests: XCTestCase {
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

    private func writeAuth(in dir: URL, accessToken: String) {
        let json = #"{"tokens":{"access_token":"\#(accessToken)"}}"#
        try? json.write(to: dir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
    }

    func testDiscoversAdditionalCodexHomeDotDir() {
        let home = makeDir(".codex-work")
        writeAuth(in: home, accessToken: "work-token")

        let accounts = CodexAccountDiscovery.discoverAdditionalAccounts(homeDirectory: tempHome.path, environment: [:])
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.accessToken, "work-token")
        XCTAssertEqual(accounts.first?.sourceLabel, "~/.codex-work")
    }

    func testExcludesDefaultCodexHome() {
        let home = makeDir(".codex")
        writeAuth(in: home, accessToken: "default-token")

        let accounts = CodexAccountDiscovery.discoverAdditionalAccounts(homeDirectory: tempHome.path, environment: [:])
        XCTAssertTrue(accounts.isEmpty)
    }

    func testExcludesCodexHomeEnvOverriddenDefault() {
        let overriddenDefault = makeDir(".codex-custom-default")
        writeAuth(in: overriddenDefault, accessToken: "default-token")
        let secondHome = makeDir(".codex-second")
        writeAuth(in: secondHome, accessToken: "second-token")

        let accounts = CodexAccountDiscovery.discoverAdditionalAccounts(
            homeDirectory: tempHome.path,
            environment: ["CODEX_HOME": overriddenDefault.path]
        )
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.accessToken, "second-token")
    }

    func testIgnoresNonCodexPrefixedDotDirs() {
        let unrelated = makeDir(".claude-work")
        writeAuth(in: unrelated, accessToken: "irrelevant")

        let accounts = CodexAccountDiscovery.discoverAdditionalAccounts(homeDirectory: tempHome.path, environment: [:])
        XCTAssertTrue(accounts.isEmpty)
    }

    func testSkipsCodexHomeWithoutUsableToken() {
        _ = makeDir(".codex-empty")

        let accounts = CodexAccountDiscovery.discoverAdditionalAccounts(homeDirectory: tempHome.path, environment: [:])
        XCTAssertTrue(accounts.isEmpty)
    }
}
