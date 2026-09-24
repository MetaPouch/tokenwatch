import XCTest
@testable import TokenWatchCore

@MainActor
final class LeaderboardSignInTests: XCTestCase {
    private var directory: URL!
    private var http: StubHTTP!
    private var tokens: MemoryTokenStore!
    private let token = "twd_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"
    private let code = "m7k91GbRKi-2618MxYJCbWyzxU0sby69gqnZ4e11uc4"

    override func setUp() async throws {
        directory = makeTemporaryDirectory()
        http = StubHTTP()
        tokens = MemoryTokenStore()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeService() -> LeaderboardService {
        LeaderboardService(api: LeaderboardAPI(endpoints: .production, http: http.client), tokens: tokens, directory: directory, clientVersion: "1.9.0", deviceName: { "Test Mac" })
    }

    /// Plays tokenwat.ch: answers the consent page with this attempt's state and a code.
    private func approving() -> FakeAuthenticator {
        FakeAuthenticator { [code] url in
            URL(string: "tokenwatch://auth/callback?code=\(code)&state=\(FakeAuthenticator.query(url, "state")!)")!
        }
    }

    private func replyWithToken() {
        http.reply { [token] _ in
            .status(200, body: #"{"token":"\#(token)","login":"octocat","avatarUrl":null,"profileUrl":"https://tokenwat.ch/@octocat"}"#)
        }
    }

    func testSignInExchangesThePKCECodeAndKeepsTheTokenOnlyInTheTokenStore() async throws {
        replyWithToken()
        let service = makeService()
        let authenticator = approving()
        await service.signIn(with: authenticator)

        XCTAssertEqual(service.signInState, .idle)
        XCTAssertEqual(service.account?.login, "octocat")
        XCTAssertEqual(tokens.token(), token)
        let opened = try XCTUnwrap(authenticator.openedURL)
        let exchange = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(exchange.method, "POST")
        XCTAssertEqual(exchange.url.absoluteString, "https://api.tokenwat.ch/v1/devices/token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exchange.body)) as? [String: Any])
        XCTAssertEqual(body["code"] as? String, code)
        XCTAssertEqual(body["device_id"] as? String, FakeAuthenticator.query(opened, "device_id"))
        XCTAssertEqual(LeaderboardAuth.PKCE.challenge(for: try XCTUnwrap(body["code_verifier"] as? String)), FakeAuthenticator.query(opened, "challenge"))
        XCTAssertEqual(FakeAuthenticator.query(opened, "device_name"), "Test Mac")

        // The account survives a relaunch; the token is nowhere on disk.
        XCTAssertEqual(makeService().account, service.account)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for file in files {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains(token), file)
        }
    }

    func testMismatchedStateCancelAndDenialNeverExchangeACode() async {
        replyWithToken()
        let cases: [(FakeAuthenticator, LeaderboardService.SignInState)] = [
            (FakeAuthenticator { [code] _ in URL(string: "tokenwatch://auth/callback?code=\(code)&state=forged-state-0123456789abcdef")! }, .failed(.stateMismatch)),
            (FakeAuthenticator { _ in throw LeaderboardSignInError.cancelled }, .idle),
            (FakeAuthenticator { url in URL(string: "tokenwatch://auth/callback?error=access_denied&state=\(FakeAuthenticator.query(url, "state")!)")! }, .failed(.denied)),
            (FakeAuthenticator { url in URL(string: "tokenwatch://auth/callback?state=\(FakeAuthenticator.query(url, "state")!)")! }, .failed(.missingCode)),
        ]
        for (authenticator, expected) in cases {
            let service = makeService()
            await service.signIn(with: authenticator)
            XCTAssertEqual(service.signInState, expected)
            XCTAssertNil(service.account)
        }
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertNil(tokens.token())
    }

    func testExpiredCodeAsksToStartOver() async {
        http.reply { _ in .status(400, body: #"{"error":"invalid_grant","message":"This code has expired"}"#) }
        let service = makeService()
        await service.signIn(with: approving())
        XCTAssertEqual(service.signInState, .failed(.expired))
        XCTAssertNil(service.account)
        XCTAssertNil(tokens.token())
    }

    func testSignOutRevokesThisMacThenForgetsTokenButKeepsTheDeviceID() async throws {
        replyWithToken()
        let service = makeService()
        let first = approving()
        await service.signIn(with: first)
        http.reply { _ in .status(204) }
        await service.signOut()

        let revoke = try XCTUnwrap(http.requests.last)
        XCTAssertEqual(revoke.method, "DELETE")
        XCTAssertEqual(revoke.url.path, "/v1/devices/current")
        XCTAssertEqual(revoke.headers["Authorization"], "Bearer \(token)")
        XCTAssertNil(service.account)
        XCTAssertNil(service.notice)
        XCTAssertNil(tokens.token())
        XCTAssertNil(makeService().account)

        // Joining again reconnects the same device.
        replyWithToken()
        let second = approving()
        await service.signIn(with: second)
        XCTAssertEqual(FakeAuthenticator.query(try XCTUnwrap(second.openedURL), "device_id"), FakeAuthenticator.query(try XCTUnwrap(first.openedURL), "device_id"))
    }

    func testSignOutWhileOfflineStillSignsOutLocally() async {
        replyWithToken()
        let service = makeService()
        await service.signIn(with: approving())
        http.reply { _ in .offline }
        await service.signOut()
        XCTAssertNil(service.account)
        XCTAssertNil(tokens.token())
    }
}
