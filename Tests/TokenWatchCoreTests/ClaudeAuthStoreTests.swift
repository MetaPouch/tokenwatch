import XCTest
@testable import TokenWatchCore

final class ClaudeAuthStoreTests: XCTestCase {
    private func credential(expiresInMs: Double?, refreshExpiresInMs: Double?, nowMs: Double = 1_000_000) -> ClaudeCredential {
        ClaudeCredential(
            accessToken: "tok",
            expiresAtMs: expiresInMs.map { nowMs + $0 },
            refreshTokenExpiresAtMs: refreshExpiresInMs.map { nowMs + $0 },
            subscriptionType: nil
        )
    }

    // MARK: classifyLapse

    func testLiveWhenExpiresAtInFuture() {
        let cred = credential(expiresInMs: 3600_000, refreshExpiresInMs: nil)
        XCTAssertEqual(ClaudeAuthStore.classifyLapse(cred, nowMs: 1_000_000), .live)
    }

    func testLiveWhenExpiresAtAbsent() {
        let cred = credential(expiresInMs: nil, refreshExpiresInMs: nil)
        XCTAssertEqual(ClaudeAuthStore.classifyLapse(cred, nowMs: 1_000_000), .live)
    }

    func testStaleWhenAccessExpiredButRefreshStillValid() {
        let cred = credential(expiresInMs: -1000, refreshExpiresInMs: 3600_000)
        XCTAssertEqual(ClaudeAuthStore.classifyLapse(cred, nowMs: 1_000_000), .stale)
    }

    func testExpiredWhenBothAccessAndRefreshLapsed() {
        let cred = credential(expiresInMs: -1000, refreshExpiresInMs: -500)
        XCTAssertEqual(ClaudeAuthStore.classifyLapse(cred, nowMs: 1_000_000), .expired)
    }

    func testExpiredWhenAccessLapsedAndNoRefreshTokenAtAll() {
        let cred = credential(expiresInMs: -1000, refreshExpiresInMs: nil)
        XCTAssertEqual(ClaudeAuthStore.classifyLapse(cred, nowMs: 1_000_000), .expired)
    }

    // MARK: freshest

    func testFreshestPrefersLiveOverStaleOverExpired() {
        let expired = credential(expiresInMs: -1000, refreshExpiresInMs: -500)
        let stale = credential(expiresInMs: -1000, refreshExpiresInMs: 3600_000)
        let live = credential(expiresInMs: 3600_000, refreshExpiresInMs: nil)
        XCTAssertEqual(ClaudeAuthStore.freshest([expired, stale, live]), live)
        XCTAssertEqual(ClaudeAuthStore.freshest([live, stale, expired]), live)
    }

    func testFreshestBreaksTiesByLaterExpiry() {
        let soonerLive = credential(expiresInMs: 1000, refreshExpiresInMs: nil)
        let laterLive = credential(expiresInMs: 5000, refreshExpiresInMs: nil)
        XCTAssertEqual(ClaudeAuthStore.freshest([soonerLive, laterLive]), laterLive)
    }

    func testFreshestOfEmptyIsNil() {
        XCTAssertNil(ClaudeAuthStore.freshest([]))
    }

    // MARK: parse

    func testParsesFullCredentialShape() {
        let json = #"{"claudeAiOauth":{"accessToken":"tok123","expiresAt":1700000000000,"refreshToken":"rtok","refreshTokenExpiresAt":1800000000000,"subscriptionType":"max"}}"#
        let credential = ClaudeAuthStore.parse(json)
        XCTAssertEqual(credential?.accessToken, "tok123")
        XCTAssertEqual(credential?.expiresAtMs, 1700000000000)
        XCTAssertEqual(credential?.refreshTokenExpiresAtMs, 1800000000000)
        XCTAssertEqual(credential?.subscriptionType, "max")
    }

    func testParsesMinimalCredentialShapeWithOnlyAccessToken() {
        let json = #"{"claudeAiOauth":{"accessToken":"tok123"}}"#
        let credential = ClaudeAuthStore.parse(json)
        XCTAssertEqual(credential?.accessToken, "tok123")
        XCTAssertNil(credential?.expiresAtMs)
        XCTAssertNil(credential?.refreshTokenExpiresAtMs)
    }

    func testRefreshTokenExpiryIgnoredWhenRefreshTokenStringEmpty() {
        let json = #"{"claudeAiOauth":{"accessToken":"tok123","refreshToken":"","refreshTokenExpiresAt":1800000000000}}"#
        let credential = ClaudeAuthStore.parse(json)
        XCTAssertNil(credential?.refreshTokenExpiresAtMs)
    }

    func testParseReturnsNilForMalformedJSON() {
        XCTAssertNil(ClaudeAuthStore.parse("not json"))
        XCTAssertNil(ClaudeAuthStore.parse(nil))
        XCTAssertNil(ClaudeAuthStore.parse(#"{"somethingElse": true}"#))
    }
}
