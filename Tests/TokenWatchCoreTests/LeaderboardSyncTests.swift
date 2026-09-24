import XCTest
@testable import TokenWatchCore

@MainActor
final class LeaderboardSyncTests: XCTestCase {
    /// A local history for the fake scan, recording each `through` it's asked for.
    private final class FakeHistory: @unchecked Sendable {
        private let lock = NSLock()
        private var monthsValue: [UsageBackfill.Month] = []
        private var throughsValue: [Date] = []
        let timeZone: TimeZone

        init(timeZone: TimeZone) { self.timeZone = timeZone }

        var months: [UsageBackfill.Month] {
            get { lock.withLock { monthsValue } }
            set { lock.withLock { monthsValue = newValue } }
        }

        var throughs: [Date] { lock.withLock { throughsValue } }

        func scan(through: Date) -> [UsageBackfill.Month] {
            let lastMonth = String(UsageDay.dayID(for: through, timeZone: timeZone).prefix(7))
            return lock.withLock {
                throughsValue.append(through)
                return monthsValue.filter { $0.id <= lastMonth }
            }
        }
    }

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private let deviceID = "5d0c6f1e-8a4b-4c2d-9e3f-7a1b2c3d4e5f"
    private let token = "twd_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"
    private let start = ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z")! // 17:30 in Kolkata
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()
    private var directory: URL!
    private var http: StubHTTP!
    private var tokens: MemoryTokenStore!
    private var clock: Clock!
    private var history: FakeHistory!

    override func setUp() async throws {
        directory = makeTemporaryDirectory()
        http = StubHTTP()
        tokens = MemoryTokenStore()
        clock = Clock(start)
        history = FakeHistory(timeZone: calendar.timeZone)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func makeService(version: String = "1.9.0") -> LeaderboardService {
        let clock = self.clock!, history = self.history!, calendar = self.calendar
        return LeaderboardService(
            api: LeaderboardAPI(endpoints: .production, http: http.client), tokens: tokens, directory: directory,
            clientVersion: version, deviceName: { "Test Mac" },
            environment: .init(
                now: { clock.now }, calendar: { calendar },
                sleep: { _ in try await Task.sleep(nanoseconds: 86_400 * 1_000_000_000) },
                scanHistory: { through, _ in history.scan(through: through) }
            )
        )
    }

    /// This Mac as a previous launch left it: joined, token in the store.
    private func join(historyPending: Bool) {
        LeaderboardFile<LeaderboardEnrollment>(directory: directory, name: "leaderboard.json").save(LeaderboardEnrollment(
            deviceID: deviceID,
            account: LeaderboardAccount(login: "octocat", avatarURL: nil, profileURL: URL(string: "https://tokenwat.ch/@octocat")!)
        ))
        LeaderboardFile<LeaderboardSyncState>(directory: directory, name: "leaderboard-sync.json")
            .save(LeaderboardSyncState(backfill: historyPending ? LeaderboardBackfillProgress() : nil))
        try? tokens.setToken(token)
    }

    private func day(_ id: String, models: Int = 1, input: Int) -> UsageDay {
        let spends = (0..<models).map { ModelSpend(id: "model-\($0)", costUSD: Double(input) / 1000, inputTokens: input, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 1) }
        return UsageDay(id: id, date: Date(), inputTokens: input * models, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: models,
                        estimatedCostUSD: spends.reduce(0) { $0 + $1.costUSD }, hasApproximateRate: false, modelBreakdown: spends)
    }

    /// Claude usage by day id.
    private func usage(_ inputs: [String: Int]) -> [SpendSource: [UsageDay]] {
        [.provider(.claude): inputs.keys.sorted().map { day($0, input: inputs[$0]!) }]
    }

    private func accept(nextSyncAfterSeconds: Int = 900, paused: Bool = false) {
        http.reply { request in
            request.method == "GET"
                ? .status(200, body: #"{"devices":[]}"#)
                : .status(200, body: #"{"accepted":1,"rejected":[],"serverTime":"2026-09-24T12:00:00Z","nextSyncAfterSeconds":\#(nextSyncAfterSeconds),"paused":\#(paused)}"#)
        }
    }

    private func json(_ request: StubHTTP.Request) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
    }

    private func rows(_ request: StubHTTP.Request) throws -> [[String: Any]] {
        try XCTUnwrap(json(request)["rows"] as? [[String: Any]])
    }

    private func dates(_ request: StubHTTP.Request) throws -> Set<String> {
        Set(try rows(request).compactMap { $0["date"] as? String })
    }

    /// Runs whatever the service's timer would have run by now.
    private func advance(to date: Date, _ service: LeaderboardService) async {
        clock.now = date
        if let wake = service.nextWake(), wake <= date { await service.performDueWork() }
    }

    // MARK: - Off means off

    /// The invariant: without joining, launch, provider refreshes and filesystem events (both
    /// reach the service as `SpendHistoryStore` updates) make no request and read no token --
    /// nor does the dashboard's badge or the avatar loader.
    func testNotJoinedMakesNoRequestAndNeverReadsTheToken() async {
        // Also catch anything that would bypass the injected client through URLSession.shared.
        _ = URLProtocol.registerClass(StubURLProtocol.self)
        defer { URLProtocol.unregisterClass(StubURLProtocol.self) }
        // An avatar a crash left behind is deleted, never shown.
        let avatarURL = URL(string: "https://avatars.githubusercontent.com/u/583231?v=4")!
        LeaderboardAvatarCache(directory: directory).save(Data([0x89, 0x50, 0x4E, 0x47]), for: avatarURL, now: start)
        let service = makeService()
        service.start()
        for minute in 0..<180 {
            service.usageDidChange(usage(["2026-09-24": 100 + minute, "2026-09-23": 50]))
            XCTAssertNil(service.nextWake())
            clock.now = start.addingTimeInterval(TimeInterval(minute * 60))
            await service.performDueWork()
            await service.refreshAvatarNow()
            XCTAssertEqual(service.badge, .join)
        }
        service.resyncAllHistory()
        service.setPaused(false)
        XCTAssertNil(service.nextUploadPreview())
        XCTAssertNil(service.account)
        XCTAssertNil(service.avatar)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("leaderboard-avatar").path))
        XCTAssertEqual(http.requests.count, 0)
        XCTAssertEqual(tokens.reads, 0)
        XCTAssertTrue(history.throughs.isEmpty)
    }

    func testPausedMakesNoRequestUntilResumed() async {
        join(historyPending: true)
        accept()
        let service = makeService()
        service.setPaused(true)
        service.start()
        for minute in 0..<120 {
            service.usageDidChange(usage(["2026-09-24": 100 + minute]))
            clock.now = start.addingTimeInterval(TimeInterval(minute * 60))
            await service.performDueWork()
        }
        XCTAssertTrue(service.isPaused)
        XCTAssertEqual(http.requests.count, 0)
        XCTAssertEqual(tokens.reads, 0)
        XCTAssertTrue(makeService().isPaused, "pause survives a relaunch")

        service.setPaused(false)
        await service.performDueWork()
        XCTAssertFalse(http.requests.isEmpty)
    }

    // MARK: - History

    /// Newest first: the 30 days the app shows, then August before the window, then July,
    /// packed into requests of at most 2,000 rows.
    private func olderHistory() -> [UsageBackfill.Month] {
        [
            UsageBackfill.Month(id: "2026-08", daysBySource: [.provider(.claude): (1...20).map { day(String(format: "2026-08-%02d", $0), input: 10) }]),
            UsageBackfill.Month(id: "2026-07", daysBySource: [.provider(.claude): (1...25).map { day(String(format: "2026-07-%02d", $0), models: 100, input: 5) }]),
        ]
    }

    func testJoiningUploadsTheAppsDaysThenOlderMonthsNewestFirst() async throws {
        join(historyPending: true)
        accept()
        history.months = olderHistory()
        let recent = usage(["2026-09-10": 300, "2026-09-24": 100])
        let service = makeService()
        service.start()
        service.usageDidChange(recent)
        XCTAssertEqual(service.history, .waiting)
        XCTAssertEqual(service.nextWake(), start)
        await service.performDueWork()

        let requests = http.requests
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            XCTAssertEqual(request.method, "PUT")
            XCTAssertEqual(request.url.absoluteString, "https://api.tokenwat.ch/v1/usage")
            XCTAssertEqual(request.headers["Authorization"], "Bearer \(token)")
            XCTAssertEqual(try json(request)["mode"] as? String, "backfill")
            XCTAssertLessThanOrEqual(try rows(request).count, 2000)
        }
        XCTAssertEqual(try dates(requests[0]), ["2026-09-10", "2026-09-24"])
        XCTAssertEqual(try rows(requests[1]).count, 2000)
        XCTAssertEqual(try rows(requests[1]).first?["date"] as? String, "2026-08-01")
        XCTAssertEqual(try rows(requests[2]).count, 520)
        XCTAssertEqual(try rows(requests[2]).last?["date"] as? String, "2026-07-25")
        // The scan covers only what's older than the 30-day window (which starts 2026-08-26).
        XCTAssertEqual(history.throughs.count, 1)
        XCTAssertEqual(history.throughs.first.map { UsageDay.dayID(for: $0, timeZone: calendar.timeZone) }, "2026-08-25")
        XCTAssertEqual(history.throughs.first.map { UsageDay.dayID(for: $0.addingTimeInterval(1), timeZone: calendar.timeZone) }, "2026-08-26")
        XCTAssertNil(service.history)
        XCTAssertNotNil(service.lastSyncAt)
        XCTAssertNil(makeService().history, "done for good")
    }

    func testHistoryUploadResumesAfterAQuitFromTheLastFinishedMonth() async throws {
        join(historyPending: true)
        history.months = olderHistory()
        var served = 0
        http.reply { _ in
            served += 1
            return served <= 2
                ? .status(200, body: #"{"accepted":1,"rejected":[],"serverTime":"2026-09-24T12:00:00Z","nextSyncAfterSeconds":900}"#)
                : .offline
        }
        let first = makeService()
        first.start()
        first.usageDidChange(usage(["2026-09-24": 100]))
        await first.performDueWork()
        XCTAssertEqual(http.requests.count, 3)
        XCTAssertEqual(first.syncIssue, .offline)
        XCTAssertEqual(first.history, .waiting)

        // Relaunch a minute later, online again.
        accept()
        clock.now = start.addingTimeInterval(61)
        let second = makeService()
        second.start()
        second.usageDidChange(usage(["2026-09-24": 100]))
        await second.performDueWork()

        // August finished before the quit: the scan resumes at July's end and resends all of July.
        XCTAssertEqual(history.throughs.count, 2)
        XCTAssertEqual(history.throughs.last.map { UsageDay.dayID(for: $0, timeZone: calendar.timeZone) }, "2026-07-31")
        let resumed = Array(http.requests.dropFirst(3))
        XCTAssertEqual(try resumed.map { try rows($0).count }, [2000, 500])
        XCTAssertEqual(try Set(resumed.flatMap { try dates($0) }).count, 25)
        XCTAssertTrue(try resumed.allSatisfy { try dates($0).allSatisfy { $0.hasPrefix("2026-07") } })
        XCTAssertNil(second.history)
        XCTAssertNil(second.syncIssue)
    }

    // MARK: - Incremental

    func testIncrementalSendsOnlyChangedRecentDaysAtTheServersPace() async throws {
        join(historyPending: false)
        accept()
        let service = makeService()
        service.start()
        service.usageDidChange(usage(["2026-09-10": 999, "2026-09-23": 50, "2026-09-24": 100]))
        await service.performDueWork()
        // First contact sends today and the two days before, not older days.
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(try dates(http.requests[0]), ["2026-09-23", "2026-09-24"])
        XCTAssertEqual(try json(http.requests[0])["mode"] as? String, "incremental")

        // A change to yesterday: debounced, then held back until nextSyncAfterSeconds.
        clock.now = start.addingTimeInterval(10)
        service.usageDidChange(usage(["2026-09-10": 999, "2026-09-23": 80, "2026-09-24": 100]))
        XCTAssertEqual(service.nextWake(), start.addingTimeInterval(900))
        await advance(to: start.addingTimeInterval(300), service)
        XCTAssertEqual(http.requests.count, 1)
        let preview = try XCTUnwrap(service.nextUploadPreview())
        await advance(to: start.addingTimeInterval(900), service)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(try dates(http.requests[1]), ["2026-09-23"])
        // Settings' preview showed exactly these bytes.
        XCTAssertEqual(preview, String(decoding: try XCTUnwrap(http.requests[1].body), as: UTF8.self))

        // Changes to older days wait for the hourly heartbeat, which resends the recent days.
        service.usageDidChange(usage(["2026-09-10": 5, "2026-09-23": 80, "2026-09-24": 100]))
        XCTAssertEqual(service.nextWake(), start.addingTimeInterval(900 + 3600))
        await advance(to: start.addingTimeInterval(900 + 3600), service)
        XCTAssertEqual(http.requests.count, 3)
        XCTAssertEqual(try dates(http.requests[2]), ["2026-09-23", "2026-09-24"])
    }

    func testAnHourOfActivityMakesAtMostFiveRequests() async {
        join(historyPending: false)
        accept()
        let service = makeService()
        service.start()
        for second in stride(from: 0, to: 3600, by: 15) {
            clock.now = start.addingTimeInterval(TimeInterval(second))
            service.usageDidChange(usage(["2026-09-24": 100 + second]))
            await advance(to: clock.now, service)
        }
        XCTAssertLessThanOrEqual(http.requests.count, 5)
        XCTAssertGreaterThanOrEqual(http.requests.count, 3)
    }

    func testHeartbeatChecksInWhenThereIsNoRecentUsage() async {
        join(historyPending: false)
        accept()
        let service = makeService()
        service.start()
        service.usageDidChange([:])
        await service.performDueWork()
        XCTAssertEqual(http.requests.map(\.method), ["GET"])
        XCTAssertEqual(http.requests.first?.url.path, "/v1/devices")
        XCTAssertEqual(service.nextWake(), start.addingTimeInterval(3600))
        await advance(to: start.addingTimeInterval(1800), service)
        XCTAssertEqual(http.requests.count, 1)
        await advance(to: start.addingTimeInterval(3600), service)
        XCTAssertEqual(http.requests.count, 2)
    }

    func testPausedOnTheWebKeepsSyncingWithoutAcknowledging() async throws {
        join(historyPending: false)
        accept(paused: true)
        let service = makeService()
        service.start()
        service.usageDidChange(usage(["2026-09-24": 100]))
        await service.performDueWork()
        XCTAssertTrue(service.isPausedOnWeb)
        // Nothing was stored, so the same day goes again at the next allowed time.
        accept()
        await advance(to: start.addingTimeInterval(900), service)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(try dates(http.requests[1]), ["2026-09-24"])
        XCTAssertFalse(service.isPausedOnWeb)
    }

    // MARK: - Errors

    func testRejectedTokenSignsOutAndStops() async {
        for status in [401, 403, 410] {
            directory = makeTemporaryDirectory()
            tokens = MemoryTokenStore()
            http = StubHTTP()
            join(historyPending: false)
            http.reply { _ in .status(status, body: #"{"error":"unauthorized","message":"x"}"#) }
            let service = makeService()
            service.start()
            service.usageDidChange(usage(["2026-09-24": 100]))
            await service.performDueWork()
            XCTAssertNil(service.account, "\(status)")
            XCTAssertEqual(service.notice, .disconnected, "\(status)")
            XCTAssertNil(tokens.token(), "\(status)")
            service.usageDidChange(usage(["2026-09-24": 200]))
            await advance(to: start.addingTimeInterval(7200), service)
            XCTAssertEqual(http.requests.count, 1, "\(status)")
            XCTAssertEqual(makeService().notice, .disconnected, "\(status)")
        }
    }

    func testUpgradeRequiredStopsUntilTheAppIsUpdated() async {
        join(historyPending: false)
        http.reply { _ in .status(426, body: #"{"error":"unsupported_schema_version","message":"update"}"#) }
        let service = makeService()
        service.start()
        service.usageDidChange(usage(["2026-09-24": 100]))
        await service.performDueWork()
        XCTAssertEqual(service.notice, .updateRequired)
        XCTAssertNotNil(service.account)
        service.usageDidChange(usage(["2026-09-24": 200]))
        XCTAssertNil(service.nextWake())
        await advance(to: start.addingTimeInterval(7200), service)

        let relaunched = makeService()
        relaunched.start()
        relaunched.usageDidChange(usage(["2026-09-24": 300]))
        await relaunched.performDueWork()
        XCTAssertEqual(http.requests.count, 1)

        accept()
        let updated = makeService(version: "1.9.1")
        XCTAssertNil(updated.notice)
        updated.start()
        updated.usageDidChange(usage(["2026-09-24": 300]))
        await updated.performDueWork()
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual((try? json(http.requests[1])["client"] as? [String: String])?["version"], "1.9.1")
    }

    func testRetryAfterAndBackoffDelayTheNextAttempt() async {
        join(historyPending: false)
        http.reply { _ in .status(429, headers: ["Retry-After": "120"], body: #"{"error":"rate_limited","message":"slow down"}"#) }
        let service = makeService()
        service.start()
        service.usageDidChange(usage(["2026-09-24": 100]))
        await service.performDueWork()
        XCTAssertEqual(service.syncIssue, .unavailable)
        XCTAssertEqual(service.nextWake(), start.addingTimeInterval(120))
        await service.performDueWork()
        XCTAssertEqual(http.requests.count, 1, "nothing before Retry-After")

        http.reply { _ in .offline }
        await advance(to: start.addingTimeInterval(120), service)
        XCTAssertEqual(service.syncIssue, .offline)
        XCTAssertEqual(service.nextWake(), start.addingTimeInterval(120 + 120), "second failure: 2 minutes")

        http.reply { _ in .status(503, body: #"{"error":"unavailable","message":"maintenance"}"#) }
        await advance(to: start.addingTimeInterval(240), service)
        XCTAssertEqual(service.nextWake(), start.addingTimeInterval(240 + 240), "third failure: 4 minutes")

        accept()
        await advance(to: start.addingTimeInterval(480), service)
        XCTAssertNil(service.syncIssue)
        XCTAssertEqual(http.requests.count, 4)
        XCTAssertEqual(service.nextWake(), start.addingTimeInterval(480 + 3600), "caught up: next is the heartbeat")
    }

    func testBackoffDoublesFromAMinuteToAnHour() {
        XCTAssertEqual((1...8).map { LeaderboardSyncPolicy.backoff(failures: $0) }, [60, 120, 240, 480, 960, 1920, 3600, 3600])
        XCTAssertEqual(LeaderboardSyncPolicy.reaction(to: .unavailable(retryAfter: 1_000_000), failures: 1), .retry(after: 86_400, issue: .unavailable))
        XCTAssertEqual(LeaderboardSyncPolicy.reaction(to: .server(status: 502), failures: 3), .retry(after: 240, issue: .unavailable))
        XCTAssertEqual(LeaderboardSyncPolicy.reaction(to: .rejected(status: 400, code: "invalid_request"), failures: 1), .retry(after: 60, issue: .rejected))
    }
}
