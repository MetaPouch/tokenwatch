import XCTest
@testable import TokenWatchCore

/// Exercises the Phase 4 Safari-cookie cache: a cached value within the 24h TTL is returned
/// without re-parsing Safari's cookie jar. Writes/deletes a real (but disposable) Keychain item
/// under the app's own cookie-cache service, since `KeychainStore` has no in-memory test double.
final class CursorAuthStoreCookieCacheTests: XCTestCase {
    private let cache = KeychainStore(service: KeychainStore.cookieCacheServiceName)
    private let account = "cursor"

    override func tearDown() {
        _ = try? cache.delete(account: account)
        super.tearDown()
    }

    func testResolvedSessionTokenReturnsFreshCachedCookieWithoutSafari() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = ["value": "cached-session-token", "fetchedAt": ISO8601DateFormatter().string(from: Date())]
        let json = try JSONSerialization.data(withJSONObject: payload)
        try cache.set(account: account, value: String(data: json, encoding: .utf8)!)

        // No Cursor.app install at this throwaway home directory, and this sandboxed test
        // environment has no readable Safari cookie jar either -- so a non-nil result here can
        // only have come from the cache.
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let authStore = CursorAuthStore(homeDirectory: tempHome)

        XCTAssertEqual(authStore.resolvedSessionToken(), "cached-session-token")
    }

    func testExpiredCacheIsNotReused() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let staleDate = Date().addingTimeInterval(-25 * 3600) // 25h old, past the 24h TTL
        let payload = ["value": "stale-token", "fetchedAt": ISO8601DateFormatter().string(from: staleDate)]
        let json = try JSONSerialization.data(withJSONObject: payload)
        try cache.set(account: account, value: String(data: json, encoding: .utf8)!)

        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let authStore = CursorAuthStore(homeDirectory: tempHome)

        // Stale cache must not be returned; Safari re-import also fails in this environment, so
        // the result is nil -- proving the TTL boundary is enforced, not just "cache present".
        XCTAssertNil(authStore.resolvedSessionToken())
    }

    /// cursor.com answers a bare access token in the session cookie with 401; the cookie must be
    /// `<WorkOS user id>%3A%3A<jwt>`, the user id being the JWT subject after its provider prefix.
    func testAppTokenIsWrappedIntoUserIdSessionCookie() {
        func base64URL(_ json: String) -> String {
            Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let token = base64URL(#"{"alg":"HS256"}"#) + "." + base64URL(#"{"sub":"google-oauth2|user_01ABC","exp":4102444800}"#) + ".sig"
        XCTAssertEqual(CursorAuthStore.sessionCookieValue(forAccessToken: token), "user_01ABC%3A%3A" + token)
        XCTAssertNil(CursorAuthStore.sessionCookieValue(forAccessToken: "not-a-jwt"))
    }
}
