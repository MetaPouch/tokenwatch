import XCTest
@testable import TokenWatchCore

final class LeaderboardPayloadBuilderTests: XCTestCase {
    private let deviceID = "5d0c6f1e-8a4b-4c2d-9e3f-7a1b2c3d4e5f"

    private func day(_ id: String, _ spends: [ModelSpend]) -> UsageDay {
        UsageDay(
            id: id, date: Date(),
            inputTokens: spends.reduce(0) { $0 + $1.inputTokens }, cacheReadTokens: spends.reduce(0) { $0 + $1.cacheReadTokens },
            cacheWriteTokens: spends.reduce(0) { $0 + $1.cacheWriteTokens }, outputTokens: spends.reduce(0) { $0 + $1.outputTokens },
            estimatedCostUSD: spends.reduce(0) { $0 + $1.costUSD }, hasApproximateRate: spends.contains { $0.hasApproximateRate },
            modelBreakdown: spends
        )
    }

    private func spend(_ model: String, input: Int = 0, read: Int = 0, write: Int = 0, output: Int = 0, cost: Double, approximate: Bool = false) -> ModelSpend {
        ModelSpend(id: model, costUSD: cost, inputTokens: input, cacheReadTokens: read, cacheWriteTokens: write, outputTokens: output, hasApproximateRate: approximate)
    }

    /// The app-side history that the contract's incremental fixture describes.
    private var incrementalHistory: [SpendSource: [UsageDay]] {
        [
            .provider(.claude): [
                day("2026-09-22", []),
                day("2026-09-23", [spend("claude-opus-4-5-20251101", input: 1200, read: 850_000, write: 42000, output: 18000, cost: 3.21), spend("<synthetic>", cost: 0)]),
            ],
            .provider(.codex): [day("2026-09-24", [spend("gpt-5.5", input: 40210, read: 1_290_000, output: 9100, cost: 1.07)])],
            .service(.devin): [day("2026-09-24", [spend("devin", cost: 4.5)])],
            .other: [day("2026-09-24", [spend("deepseek/deepseek-v4", input: 5000, output: 800, cost: 0.004, approximate: true)])],
            .provider(.gemini): [day("2026-09-24", [spend("gemini-3-pro", cost: 0)])],
        ]
    }

    private func encodedJSON(_ request: LeaderboardUsageRequest) throws -> Any {
        try JSONSerialization.jsonObject(with: LeaderboardPayloadBuilder.encode(request))
    }

    func testIncrementalPayloadMatchesTheContractFixture() throws {
        let rows = LeaderboardPayloadBuilder.rows(from: incrementalHistory)
        let request = LeaderboardPayloadBuilder.request(rows: rows, mode: .incremental, deviceID: deviceID, timeZone: "Asia/Kolkata", clientVersion: "1.9.0")
        let json = try encodedJSON(request)
        XCTAssertEqual(json as? NSDictionary, try Contract.json("fixtures/usage.v1.valid.incremental.json") as? NSDictionary)
        XCTAssertEqual(JSONSchemaCheck.errors(json, try Contract.schema("usage.v1")), [])
    }

    func testBackfillRowsMatchTheContractFixture() throws {
        let claude = spend("claude-opus-4-5-20251101", input: 1200, read: 850_000, write: 42000, output: 18000, cost: 3.21)
        func renamed(_ model: String) -> ModelSpend { claude.adding(.empty(model), as: model) }
        let history: [SpendSource: [UsageDay]] = [
            .provider(.claude): [day("2023-01-01", [renamed("claude-3-5-sonnet-20241022")]), day("2025-03-14", [renamed("anthropic/claude-haiku-4.5")])],
            .provider(.openrouter): [day("2025-03-14", [renamed("anthropic/claude-haiku-4.5")])],
        ]
        let request = LeaderboardPayloadBuilder.request(rows: LeaderboardPayloadBuilder.rows(from: history), mode: .backfill, deviceID: deviceID, timeZone: "America/Los_Angeles", clientVersion: "1.9.0")
        let json = try XCTUnwrap(encodedJSON(request) as? [String: Any])
        let fixture = try XCTUnwrap(Contract.json("fixtures/usage.v1.valid.backfill.json") as? [String: Any])
        XCTAssertEqual(json["rows"] as? NSArray, fixture["rows"] as? NSArray)
        for key in ["schemaVersion", "deviceId", "timeZone", "mode"] {
            XCTAssertEqual(json[key] as? NSObject, fixture[key] as? NSObject, key)
        }
        XCTAssertEqual(JSONSchemaCheck.errors(json, try Contract.schema("usage.v1")), [])
    }

    /// Keeps the schema check honest: the server's own fixtures pass or fail it as `index.json` says.
    func testSchemaCheckAgreesWithTheContractsFixtureIndex() throws {
        let schema = try Contract.schema("usage.v1")
        let index = try XCTUnwrap(Contract.json("fixtures/index.json") as? [String: Any])
        let fixtures = try XCTUnwrap(index["requests"] as? [[String: Any]]).filter { $0["schema"] as? String == "usage.v1" }
        XCTAssertGreaterThan(fixtures.count, 10)
        for fixture in fixtures {
            let file = try XCTUnwrap(fixture["file"] as? String)
            let errors = JSONSchemaCheck.errors(try Contract.json("fixtures/\(file)"), schema)
            let shouldPass = file.contains(".valid.") || fixture["passesJsonSchema"] as? Bool == true
            XCTAssertEqual(errors.isEmpty, shouldPass, "\(file): \(errors)")
        }
    }

    func testRowsMergeTheSameModelAndStayWithinTheContractsLimits() throws {
        let long = String(repeating: "m", count: 130)
        let history: [SpendSource: [UsageDay]] = [
            .provider(.claude): [day("2026-09-24", [
                spend(long + "a", input: 1, cost: 0.5),
                spend(long + "b", input: 2, cost: .nan),
                spend("", input: 3, cost: 0.25),
                spend("  ", output: 4, cost: 0.25, approximate: true),
            ])],
        ]
        let rows = LeaderboardPayloadBuilder.rows(from: history)
        XCTAssertEqual(rows.map(\.model), [String(repeating: "m", count: 128), "unknown"])
        XCTAssertEqual(rows[0].input, 3)
        XCTAssertEqual(rows[0].costUSD, 0.5)
        XCTAssertTrue(rows[0].approximate, "a cost that couldn't be counted makes the row approximate")
        XCTAssertEqual(rows[1].input + rows[1].output, 7)
        XCTAssertEqual(rows[1].costUSD, 0.5)
        XCTAssertTrue(rows[1].approximate)
        let json = try encodedJSON(LeaderboardPayloadBuilder.request(rows: rows, mode: .incremental, deviceID: deviceID, timeZone: "UTC", clientVersion: "0.0.0-dev"))
        XCTAssertEqual(JSONSchemaCheck.errors(json, try Contract.schema("usage.v1")), [])
    }

    func testRowsCanBeLimitedToSomeDays() {
        let rows = LeaderboardPayloadBuilder.rows(from: incrementalHistory, dates: ["2026-09-23"])
        XCTAssertEqual(rows.map(\.date), ["2026-09-23"])
    }

    func testRequestsStayUnderTheRowAndByteLimits() {
        func rows(_ count: Int, model: String) -> [LeaderboardUsageRow] {
            (0..<count).map { LeaderboardUsageRow(date: "2026-09-24", source: "claude", model: "\(model)\($0)", input: 1, cacheRead: 0, cacheWrite: 0, output: 1, costUSD: 0.01, approximate: false) }
        }
        XCTAssertEqual(LeaderboardPayloadBuilder.leadingRowsPerRequest(rows(2500, model: "m"), mode: .backfill, deviceID: deviceID, timeZone: "UTC", clientVersion: "1.9.0"), 2000)
        XCTAssertEqual(LeaderboardPayloadBuilder.leadingRowsPerRequest(rows(3, model: "m"), mode: .backfill, deviceID: deviceID, timeZone: "UTC", clientVersion: "1.9.0"), 3)
        // 2,000 rows of 120-character CJK model ids (3 bytes each in UTF-8) pass the 1 MB limit.
        let wide = rows(2000, model: String(repeating: "模", count: 120))
        let count = LeaderboardPayloadBuilder.leadingRowsPerRequest(wide, mode: .backfill, deviceID: deviceID, timeZone: "UTC", clientVersion: "1.9.0")
        XCTAssertLessThan(count, 2000)
        let body = LeaderboardPayloadBuilder.encode(LeaderboardPayloadBuilder.request(rows: Array(wide.prefix(count)), mode: .backfill, deviceID: deviceID, timeZone: "UTC", clientVersion: "1.9.0"))
        XCTAssertLessThanOrEqual(body.count, LeaderboardPayloadBuilder.maxBodyBytes)
    }

    func testDecodesTheContractsUsageResponse() throws {
        let response = try JSONDecoder().decode(LeaderboardIngestResponse.self, from: Contract.data("fixtures/usage-response.v1.valid.partial.json"))
        XCTAssertEqual(response.accepted, 1)
        XCTAssertEqual(response.rejected, [.init(index: 1, reason: "unknown_source")])
        XCTAssertEqual(response.nextSyncAfterSeconds, 900)
        XCTAssertFalse(response.paused)
        let paused = try JSONDecoder().decode(LeaderboardIngestResponse.self, from: Data(#"{"accepted":0,"rejected":[],"serverTime":"2026-09-24T12:00:00Z","nextSyncAfterSeconds":900,"paused":true,"future":1}"#.utf8))
        XCTAssertTrue(paused.paused)
    }
}
