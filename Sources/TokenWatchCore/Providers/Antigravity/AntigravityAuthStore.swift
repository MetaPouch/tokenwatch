import Foundation

/// `~/.gemini/antigravity-cli/antigravity-oauth-token` shape, confirmed against
/// github.com/wakamex/agy-usage (a real, independent reader of this exact file): either a
/// top-level `access_token`/`AccessToken`, or a nested `token: {access_token, expiry}` object.
struct AntigravityTokenFile: Decodable {
    struct TokenPayload: Decodable {
        let accessToken: String?
        let expiry: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiry
        }
    }
    let accessToken: String?
    let token: TokenPayload?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case token
    }

    var resolvedAccessToken: String? {
        token?.accessToken ?? accessToken
    }

    var expiry: Date? {
        token?.expiry.flatMap(FlexibleISO8601.parse)
    }
}

/// Reads Antigravity CLI's own OAuth token file directly rather than shelling out to `agy -p
/// /usage`, whose JSON output shape is documented but not independently confirmed. This file
/// path and shape are confirmed via a real third-party reader (agy-usage). TokenWatch never
/// refreshes an expired token (same scope cut as the Gemini provider) -- `hasLocalCredentials()`
/// only checks the file exists; `validAccessToken()` checks expiry.
public struct AntigravityAuthStore: Sendable {
    private let path: String

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.path = homeDirectory + "/.gemini/antigravity-cli/antigravity-oauth-token"
    }

    public func hasTokenFile() -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func validAccessToken() -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let file = try? JSONDecoder().decode(AntigravityTokenFile.self, from: data) else { return nil }
        guard let token = file.resolvedAccessToken, !token.isEmpty else { return nil }
        if let expiry = file.expiry, expiry <= Date() { return nil }
        return token
    }
}
