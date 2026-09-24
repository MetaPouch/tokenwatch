import XCTest
@testable import TokenWatchCore

@MainActor
final class LeaderboardAvatarTests: XCTestCase {
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private let token = "twd_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"
    private let avatarURL = URL(string: "https://avatars.githubusercontent.com/u/583231?v=4")!
    private let start = ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z")!
    /// A 1x1 PNG.
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
    private var directory: URL!
    private var http: StubHTTP!
    private var tokens: MemoryTokenStore!
    private var clock: Clock!

    override func setUp() async throws {
        directory = makeTemporaryDirectory()
        http = StubHTTP()
        tokens = MemoryTokenStore()
        clock = Clock(start)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeService() -> LeaderboardService {
        let clock = self.clock!
        return LeaderboardService(
            api: LeaderboardAPI(endpoints: .production, http: http.client), tokens: tokens, directory: directory,
            clientVersion: "1.9.0", deviceName: { "Test Mac" },
            environment: .init(now: { clock.now }, sleep: { _ in try await Task.sleep(nanoseconds: 86_400 * 1_000_000_000) })
        )
    }

    /// This Mac as a previous launch left it: joined as octocat with `avatar`.
    private func join(avatar: URL?, paused: Bool = false) {
        LeaderboardFile<LeaderboardEnrollment>(directory: directory, name: "leaderboard.json").save(LeaderboardEnrollment(
            deviceID: "5d0c6f1e-8a4b-4c2d-9e3f-7a1b2c3d4e5f",
            account: LeaderboardAccount(login: "octocat", avatarURL: avatar, profileURL: URL(string: "https://tokenwat.ch/@octocat")!),
            isPaused: paused
        ))
        try? tokens.setToken(token)
    }

    private func serveAvatar() {
        http.reply { [png] request in
            request.url.host == LeaderboardAPI.avatarHost ? .bytes(200, png) : .status(204)
        }
    }

    private var avatarRequests: [StubHTTP.Request] {
        http.requests.filter { $0.url.host == LeaderboardAPI.avatarHost }
    }

    private var cachedFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("leaderboard-avatar") }.sorted()
    }

    // MARK: - Host allowlist

    func testOnlyHTTPSAvatarsOnGitHubsAvatarHostAreAllowed() {
        let allowed = [
            "https://avatars.githubusercontent.com/u/583231?v=4",
            "https://AVATARS.githubusercontent.com/u/1",
        ]
        let refused = [
            "http://avatars.githubusercontent.com/u/583231?v=4",
            "https://avatars.githubusercontent.com.evil.example/u/1",
            "https://evil.avatars.githubusercontent.com/u/1",
            "https://avatars.githubusercontent.com:8443/u/1",
            "https://user:pass@avatars.githubusercontent.com/u/1",
            "https://github.com/octocat.png",
            "https://tokenwat.ch/avatar.png",
            "file:///tmp/avatar.png",
        ]
        for string in allowed { XCTAssertTrue(LeaderboardAPI.isAllowedAvatarURL(URL(string: string)!), string) }
        for string in refused { XCTAssertFalse(LeaderboardAPI.isAllowedAvatarURL(URL(string: string)!), string) }
    }

    func testAvatarOffTheAllowedHostIsNeverFetched() async {
        join(avatar: URL(string: "https://evil.example/octocat.png")!)
        serveAvatar()
        let service = makeService()
        await service.refreshAvatarNow()
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertNil(service.avatar)
    }

    // MARK: - Download and cache

    func testJoinedDownloadsTheAvatarWithoutTheTokenThenReusesItForADay() async throws {
        join(avatar: avatarURL)
        serveAvatar()
        let service = makeService()
        await service.refreshAvatarNow()

        let request = try XCTUnwrap(avatarRequests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(request.method, "GET")
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertEqual(FakeAuthenticator.query(request.url, "s"), "128")
        XCTAssertEqual(FakeAuthenticator.query(request.url, "v"), "4")
        XCTAssertEqual(service.avatar, png)
        XCTAssertEqual(cachedFiles, ["leaderboard-avatar", "leaderboard-avatar.json"])

        // A relaunch shows the cached image straight away and doesn't download it again that day.
        clock.now = start.addingTimeInterval(23 * 3600)
        let relaunched = makeService()
        XCTAssertEqual(relaunched.avatar, png)
        await relaunched.refreshAvatarNow()
        XCTAssertEqual(http.requests.count, 1)

        clock.now = start.addingTimeInterval(24 * 3600)
        await relaunched.refreshAvatarNow()
        XCTAssertEqual(avatarRequests.count, 2)
    }

    func testAChangedAvatarURLIsDownloadedAgain() async {
        join(avatar: avatarURL)
        serveAvatar()
        await makeService().refreshAvatarNow()

        let newURL = URL(string: "https://avatars.githubusercontent.com/u/583231?v=5")!
        join(avatar: newURL)
        let service = makeService()
        XCTAssertNil(service.avatar, "the cached image belongs to the old URL")
        await service.refreshAvatarNow()
        XCTAssertEqual(avatarRequests.count, 2)
        XCTAssertEqual(FakeAuthenticator.query(avatarRequests[1].url, "v"), "5")
        XCTAssertEqual(service.avatar, png)
    }

    func testAFailedDownloadIsRetriedAfterAnHourAndKeepsNothing() async {
        join(avatar: avatarURL)
        http.reply { _ in .status(404) }
        let service = makeService()
        await service.refreshAvatarNow()
        clock.now = start.addingTimeInterval(59 * 60)
        await service.refreshAvatarNow()
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertNil(service.avatar)
        XCTAssertTrue(cachedFiles.isEmpty)

        // Not an image: refused like a failure.
        http.reply { _ in .status(200, body: "<html>not an avatar</html>") }
        clock.now = start.addingTimeInterval(60 * 60)
        await service.refreshAvatarNow()
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertNil(service.avatar)
        XCTAssertTrue(cachedFiles.isEmpty)
    }

    func testARedirectOffTheAvatarHostIsNotFollowed() async throws {
        join(avatar: avatarURL)
        let elsewhere = URL(string: "https://evil.example/octocat.png")!
        http.reply { [png] request in
            request.url.host == LeaderboardAPI.avatarHost ? .redirect(elsewhere) : .bytes(200, png)
        }
        // The stub does follow redirects for a caller that doesn't refuse them.
        _ = try await http.client.response(for: URLRequest(url: avatarURL))
        XCTAssertEqual(http.requests.map(\.url.host), [LeaderboardAPI.avatarHost, "evil.example"])

        let service = makeService()
        await service.refreshAvatarNow()
        XCTAssertEqual(http.requests.map(\.url.host), [LeaderboardAPI.avatarHost, "evil.example", LeaderboardAPI.avatarHost])
        XCTAssertNil(service.avatar)
        XCTAssertTrue(cachedFiles.isEmpty)
    }

    func testPausedNeverDownloadsTheAvatar() async {
        join(avatar: avatarURL, paused: true)
        serveAvatar()
        let service = makeService()
        await service.refreshAvatarNow()
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testSigningOutDeletesTheCachedAvatar() async {
        join(avatar: avatarURL)
        serveAvatar()
        let service = makeService()
        await service.refreshAvatarNow()
        XCTAssertFalse(cachedFiles.isEmpty)

        await service.signOut()
        XCTAssertNil(service.avatar)
        XCTAssertTrue(cachedFiles.isEmpty)
        await service.refreshAvatarNow()
        XCTAssertEqual(avatarRequests.count, 1)
        XCTAssertNil(makeService().avatar)
    }

    func testBeingSignedOutByTheServerDeletesTheCachedAvatar() async {
        join(avatar: avatarURL)
        serveAvatar()
        let service = makeService()
        await service.refreshAvatarNow()
        service.signOutLocally(notice: .disconnected)
        XCTAssertNil(service.avatar)
        XCTAssertTrue(cachedFiles.isEmpty)
    }

    // MARK: - Badge

    func testBadgeState() {
        let account = LeaderboardAccount(login: "octocat", avatarURL: avatarURL, profileURL: URL(string: "https://tokenwat.ch/@octocat")!)
        let cases: [(LeaderboardAccount?, LeaderboardNotice?, Bool, Bool, LeaderboardBadge)] = [
            (nil, nil, false, false, .join),
            (nil, .disconnected, false, false, .signInAgain),
            (account, nil, false, false, .joined(login: "octocat", status: .syncing)),
            (account, nil, true, false, .joined(login: "octocat", status: .paused)),
            (account, nil, false, true, .joined(login: "octocat", status: .paused)),
            (account, .updateRequired, true, false, .joined(login: "octocat", status: .needsAttention)),
        ]
        for (account, notice, paused, pausedOnWeb, expected) in cases {
            XCTAssertEqual(LeaderboardBadge(account: account, notice: notice, isPaused: paused, isPausedOnWeb: pausedOnWeb), expected, "\(String(describing: notice)) \(paused) \(pausedOnWeb)")
        }
    }

    func testBadgeFollowsTheServiceThroughPauseAndDisconnect() {
        join(avatar: avatarURL)
        http.reply { _ in .offline }
        let service = makeService()
        XCTAssertEqual(service.badge, .joined(login: "octocat", status: .syncing))
        service.setPaused(true)
        XCTAssertEqual(service.badge, .joined(login: "octocat", status: .paused))
        service.signOutLocally(notice: .disconnected)
        XCTAssertEqual(service.badge, .signInAgain)
    }
}
