import Foundation

/// Cached Safari-cookie-derived session, keyed by timestamp so it's reused for up to 24h before
/// re-parsing the binary cookie jar.
private struct CachedCursorCookie: Codable {
    let value: String
    let fetchedAt: Date
}

/// Resolves a Cursor session token: Cursor.app's local state DB first (Phase 2), falling back to
/// a Safari-imported `cursor.com`/`cursor.sh` cookie (Phase 4) only when the local path reports
/// no usable token. Cursor accepts the raw app token in the session-cookie slot, so both sources
/// feed the same `Cookie: WorkosCursorSessionToken=<value>` header.
public struct CursorAuthStore: Sendable {
    private static let cookieCacheAccount = "cursor"
    private static let cookieCacheTTL: TimeInterval = 24 * 3600

    private let databasePath: String
    private let cookieCache: KeychainStore

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.databasePath = homeDirectory + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        self.cookieCache = KeychainStore(service: KeychainStore.cookieCacheServiceName)
    }

    public func isCursorInstalled() -> Bool {
        FileManager.default.fileExists(atPath: databasePath)
    }

    /// Returns a non-expired session token, or `nil` if Cursor isn't installed, has no saved
    /// token, or the token's JWT `exp` claim is within 60s of (or past) now. Never refreshed.
    public func validAccessToken() -> String? {
        guard let data = SQLiteReader.readItemTableValue(databasePath: databasePath, key: "cursorAuth/accessToken") else {
            return nil
        }
        guard let token = decode(data) else { return nil }
        guard let expiry = JWT.expiry(token) else { return nil }
        guard expiry.timeIntervalSinceNow > 60 else { return nil }
        return token
    }

    /// The local app token if usable, else a cached or freshly-imported Safari cookie. This is
    /// what `CursorProvider.refresh()` actually sends.
    public func resolvedSessionToken() -> String? {
        validAccessToken() ?? safariCookieToken()
    }

    /// Whether *any* source (local app or a cached/importable Safari cookie) currently has a
    /// usable session -- without re-parsing Safari's cookie jar if the local path already works.
    public func hasAnyUsableSession() -> Bool {
        resolvedSessionToken() != nil
    }

    private func safariCookieToken() -> String? {
        if let cached = readCache(), Date().timeIntervalSince(cached.fetchedAt) < Self.cookieCacheTTL {
            return cached.value
        }
        guard let token = importFromSafari() else { return nil }
        writeCache(CachedCursorCookie(value: token, fetchedAt: Date()))
        return token
    }

    private func importFromSafari() -> String? {
        let cookies = SafariCookieReader.cookies(forDomains: ["cursor.com", "cursor.sh"])
        let priority = ["WorkosCursorSessionToken", "__Secure-next-auth.session-token", "next-auth.session-token"]
        for name in priority {
            if let match = cookies.first(where: { $0.name == name }) {
                return match.value
            }
        }
        return nil
    }

    private func readCache() -> CachedCursorCookie? {
        guard let json = cookieCache.get(account: Self.cookieCacheAccount) else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedCursorCookie.self, from: data)
    }

    private func writeCache(_ cached: CachedCursorCookie) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cached), let json = String(data: data, encoding: .utf8) else { return }
        try? cookieCache.set(account: Self.cookieCacheAccount, value: json)
    }

    private func decode(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
            return utf8
        }
        if let utf16 = String(data: data, encoding: .utf16LittleEndian), !utf16.isEmpty {
            return utf16
        }
        return nil
    }
}
