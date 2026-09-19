import XCTest
@testable import TokenWatchCore

final class MetricLineTests: XCTestCase {
    func testProgressRatioClampsToUnitRange() {
        let overLimit = MetricLine.progress(id: "a", label: "A", used: 150, limit: 100, format: .percent, resetsAt: nil, periodDurationMs: nil)
        XCTAssertEqual(overLimit.progressRatio, 1.0)

        let normal = MetricLine.progress(id: "b", label: "B", used: 25, limit: 100, format: .percent, resetsAt: nil, periodDurationMs: nil)
        XCTAssertEqual(normal.progressRatio, 0.25)

        let zeroLimit = MetricLine.progress(id: "c", label: "C", used: 5, limit: 0, format: .percent, resetsAt: nil, periodDurationMs: nil)
        XCTAssertNil(zeroLimit.progressRatio)

        let badge = MetricLine.badge(id: "d", text: "ok", tone: .neutral)
        XCTAssertNil(badge.progressRatio)
    }

    func testMetricLineRoundTripsThroughJSON() throws {
        let lines: [MetricLine] = [
            .progress(id: "session", label: "Session", used: 42, limit: 100, format: .percent, resetsAt: Date(timeIntervalSince1970: 1_700_000_000), periodDurationMs: 18_000_000),
            .values(id: "balance", label: "Balance", values: [MetricValue(number: 12.5, kind: "credits", unit: "USD")]),
            .badge(id: "status", text: "OK", tone: .warning),
            .chart(id: "trend", label: "Trend", points: [DatedPoint(date: Date(timeIntervalSince1970: 1_700_000_000), value: 1.0)]),
            .text(id: "note", value: "hello")
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(lines)
        let decoded = try decoder.decode([MetricLine].self, from: data)
        XCTAssertEqual(lines, decoded)
    }

    func testProviderSnapshotRoundTripsThroughJSON() throws {
        let snapshot = ProviderSnapshot(
            provider: .claude,
            plan: "Max",
            lines: [.badge(id: "s", text: "hi", tone: .critical)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            error: nil,
            lastActivityAt: Date(timeIntervalSince1970: 1_699_999_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(ProviderSnapshot.self, from: data)
        XCTAssertEqual(snapshot, decoded)
    }

    func testProviderSnapshotDecodesMissingLastActivityAtAsNil() throws {
        // Old cache.json files predate this field; decoding must not fail.
        let json = """
        {"provider":"claude","lines":[],"fetchedAt":"2023-11-14T22:13:20Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProviderSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(decoded.lastActivityAt)
    }

    func testCacheTemperatureToneFindsBadgeByID() {
        let warm = ProviderSnapshot(provider: .claude, lines: [
            .progress(id: "session", label: "S", used: 1, limit: 100, format: .percent, resetsAt: nil, periodDurationMs: nil),
            .badge(id: "cacheTemperature", text: "Cache warm", tone: .neutral)
        ])
        XCTAssertEqual(warm.cacheTemperatureTone, .neutral)

        let cold = ProviderSnapshot(provider: .claude, lines: [.badge(id: "cacheTemperature", text: "Cache cold", tone: .warning)])
        XCTAssertEqual(cold.cacheTemperatureTone, .warning)

        let absent = ProviderSnapshot(provider: .claude, lines: [.badge(id: "other", text: "x", tone: .neutral)])
        XCTAssertNil(absent.cacheTemperatureTone)

        let empty = ProviderSnapshot(provider: .claude, lines: [])
        XCTAssertNil(empty.cacheTemperatureTone)
    }


    func testProviderErrorRoundTripsThroughJSON() throws {
        let errors: [ProviderError] = [
            .notConfigured, .credentialsMissing, .network("timeout"),
            .http(status: 429, message: "rate limited"), .parse("bad json")
        ]
        let data = try JSONEncoder().encode(errors)
        let decoded = try JSONDecoder().decode([ProviderError].self, from: data)
        XCTAssertEqual(errors, decoded)
    }
}
