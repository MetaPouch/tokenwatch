import Foundation

/// Gemini OAuth auth type read from `~/.gemini/settings.json` (`security.auth.selectedType`).
enum GeminiAuthType: String {
    case oauthPersonal = "oauth-personal"
    case apiKey = "gemini-api-key"
    case vertexAI = "vertex-ai"
    case unknown
}

/// `~/.gemini/oauth_creds.json` shape.
struct GeminiOAuthCredentials: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?
    let expiryDate: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiryDate = "expiry_date"
    }
}

/// Reads Gemini CLI's OAuth credentials from disk. TokenWatch never refreshes an expired token
/// (that requires extracting the Gemini CLI's bundled OAuth client id/secret, out of scope for
/// v1) -- an expired token surfaces as `.credentialsMissing` with guidance to re-run `gemini`.
public struct GeminiAuthStore: Sendable {
    private let homeDirectory: String

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    /// `nil` when the configured auth type is explicitly unsupported (`api-key`, `vertex-ai`).
    func currentAuthType() -> GeminiAuthType {
        let url = URL(fileURLWithPath: homeDirectory + "/.gemini/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let security = json["security"] as? [String: Any],
              let auth = security["auth"] as? [String: Any],
              let selectedType = auth["selectedType"] as? String
        else {
            return .unknown
        }
        return GeminiAuthType(rawValue: selectedType) ?? .unknown
    }

    /// Returns a non-expired access token, or `nil` if credentials are missing/expired.
    public func validAccessToken() -> String? {
        let url = URL(fileURLWithPath: homeDirectory + "/.gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: url),
              let creds = try? JSONDecoder().decode(GeminiOAuthCredentials.self, from: data),
              let token = creds.accessToken, !token.isEmpty
        else {
            return nil
        }
        if let expiryMillis = creds.expiryDate {
            let expiry = Date(timeIntervalSince1970: expiryMillis / 1000)
            guard expiry > Date() else { return nil }
        }
        return token
    }

    public func hasCredentialsFile() -> Bool {
        FileManager.default.fileExists(atPath: homeDirectory + "/.gemini/oauth_creds.json")
    }

    /// A Gemini CLI Google sign-in TokenWatch can use -- not an API-key or Vertex AI setup, which
    /// `refresh()` reports as not configured.
    public func hasUsableSignIn() -> Bool {
        let authType = currentAuthType()
        return hasCredentialsFile() && authType != .apiKey && authType != .vertexAI
    }
}
