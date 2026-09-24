import Foundation

/// Where the leaderboard lives. The two string literals below are TokenWatch's only leaderboard
/// hosts, and this is the only file that names them (SECURITY.md's `git grep -n 'URL(string:'`
/// audit) -- along with `LeaderboardAPI.avatarHost`, the one other host the leaderboard reaches.
/// A DEBUG build can point them at local servers with `TOKENWATCH_WEB_URL` and
/// `TOKENWATCH_API_URL` (README, Development); release builds ignore both variables.
public struct LeaderboardEndpoints: Sendable, Equatable {
    public let web: URL
    public let api: URL

    public init(web: URL, api: URL) {
        self.web = web
        self.api = api
    }

    public static let production = LeaderboardEndpoints(
        web: URL(string: "https://tokenwat.ch")!,
        api: URL(string: "https://api.tokenwat.ch")!
    )

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> LeaderboardEndpoints {
        #if DEBUG
        func override(_ name: String) -> URL? {
            guard let value = environment[name], let url = URL(string: value),
                  url.scheme == "http" || url.scheme == "https", url.host != nil
            else { return nil }
            return url
        }
        return LeaderboardEndpoints(web: override("TOKENWATCH_WEB_URL") ?? production.web, api: override("TOKENWATCH_API_URL") ?? production.api)
        #else
        return production
        #endif
    }

    /// The consent page `ASWebAuthenticationSession` opens.
    public var connect: URL { web.appending(path: "connect") }
    public var privacy: URL { web.appending(path: "privacy") }
    public var methodology: URL { web.appending(path: "methodology") }
    /// Where a signed-in user deletes their leaderboard account.
    public var account: URL { web.appending(path: "account") }
}

/// `POST /v1/devices/token` body: a one-time `/connect` code for a device token.
public struct LeaderboardDeviceTokenRequest: Encodable, Equatable, Sendable {
    public let code: String
    public let codeVerifier: String
    public let deviceID: String
    /// The device's IANA time zone; left out when it isn't a plain IANA name.
    public let timeZone: String?

    public init(code: String, codeVerifier: String, deviceID: String, timeZone: String?) {
        self.code = code
        self.codeVerifier = codeVerifier
        self.deviceID = deviceID
        self.timeZone = timeZone
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case codeVerifier = "code_verifier"
        case deviceID = "device_id"
        case timeZone = "time_zone"
    }
}

/// `POST /v1/devices/token` 200 body. The token is returned once; it goes straight to the Keychain.
public struct LeaderboardDeviceTokenResponse: Decodable, Sendable {
    public let token: String
    public let login: String
    public let avatarUrl: URL?
    public let profileUrl: URL
}

/// `PUT /v1/usage` 200 body. Unknown fields and rejection reasons are tolerated (the contract's
/// additive-change rule).
public struct LeaderboardIngestResponse: Decodable, Equatable, Sendable {
    public struct Rejection: Decodable, Equatable, Sendable {
        public let index: Int
        public let reason: String
    }

    public let accepted: Int
    public let rejected: [Rejection]
    public let nextSyncAfterSeconds: Int
    /// The user paused syncing on tokenwat.ch: nothing was stored.
    public let paused: Bool

    private enum CodingKeys: String, CodingKey {
        case accepted, rejected, nextSyncAfterSeconds, paused
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try container.decode(Int.self, forKey: .accepted)
        rejected = try container.decode([Rejection].self, forKey: .rejected)
        nextSyncAfterSeconds = try container.decode(Int.self, forKey: .nextSyncAfterSeconds)
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }
}

/// A leaderboard API failure, by what the app does about it.
public enum LeaderboardAPIError: Error, Equatable, Sendable {
    /// No response: offline, DNS, timeout.
    case offline
    /// 401: the token is missing, malformed or unknown -- sign in again.
    case unauthorized
    /// 403: the token belongs to another device id -- sign in again.
    case forbidden
    /// 410: this device was signed out or revoked -- drop the token and sign in again.
    case revoked
    /// 400 `invalid_grant`: the `/connect` code expired or was already used.
    case invalidGrant
    /// 426: this app's payload version is no longer accepted.
    case upgradeRequired
    /// 429.
    case rateLimited(retryAfter: TimeInterval?)
    /// 503, including the server's kill switch.
    case unavailable(retryAfter: TimeInterval?)
    /// Any other 5xx.
    case server(status: Int)
    /// Any other 4xx, e.g. 400 `invalid_request`.
    case rejected(status: Int, code: String?)
    /// A 2xx whose body isn't what the contract says.
    case malformedResponse
}

/// The leaderboard's HTTP API, through the shared `HTTPClient`. Every call but the code exchange
/// and the avatar sends the device token as `Authorization: Bearer`.
public struct LeaderboardAPI: Sendable {
    public let endpoints: LeaderboardEndpoints
    private let http: HTTPClient

    public init(endpoints: LeaderboardEndpoints = .current(), http: HTTPClient = .shared) {
        self.endpoints = endpoints
        self.http = http
    }

    /// `POST /v1/devices/token`.
    public func exchangeCode(_ request: LeaderboardDeviceTokenRequest) async throws -> LeaderboardDeviceTokenResponse {
        let body = try JSONEncoder().encode(request)
        let data = try await send("POST", "v1/devices/token", token: nil, body: body)
        return try decode(LeaderboardDeviceTokenResponse.self, from: data)
    }

    /// `DELETE /v1/devices/current`: signs this Mac out; its token gets 410 from then on.
    public func signOutDevice(token: String) async throws {
        _ = try await send("DELETE", "v1/devices/current", token: token, body: nil)
    }

    /// `GET /v1/devices`: the heartbeat when there's no usage to send (it refreshes the device's
    /// last-seen time). The device list itself isn't used.
    public func checkIn(token: String) async throws {
        _ = try await send("GET", "v1/devices", token: token, body: nil)
    }

    /// `PUT /v1/usage` with a body from `LeaderboardPayloadBuilder`.
    public func putUsage(_ body: Data, token: String) async throws -> LeaderboardIngestResponse {
        let data = try await send("PUT", "v1/usage", token: token, body: body)
        return try decode(LeaderboardIngestResponse.self, from: data)
    }

    /// The only host a joined account's avatar is downloaded from: GitHub's avatar CDN, which is
    /// where tokenwat.ch's `avatarUrl` points. Anything else is never fetched.
    public static let avatarHost = "avatars.githubusercontent.com"
    /// Avatars are drawn at most 44pt wide, so 128px covers Retina.
    static let avatarPixelSize = 128
    /// A 128px avatar is a few KB; anything this large isn't one.
    static let maxAvatarBytes = 512 * 1024

    /// Whether `url` is an HTTPS avatar on `avatarHost` (no port, no credentials).
    public static func isAllowedAvatarURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == avatarHost
            && components.port == nil
            && components.user == nil
            && components.password == nil
    }

    /// `GET` an allowed avatar URL at 128px: no token, no cookies, no redirects (a redirect off
    /// the host is refused rather than followed). `nil` for a disallowed URL, a failure, or a
    /// body that isn't a small image.
    public func avatar(at url: URL) async -> Data? {
        guard Self.isAllowedAvatarURL(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "s" } + [URLQueryItem(name: "s", value: String(Self.avatarPixelSize))]
        guard let sized = components.url else { return nil }
        var request = URLRequest(url: sized, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await http.response(for: request, delegate: RefuseRedirects()),
              response.statusCode == 200,
              data.count <= Self.maxAvatarBytes,
              LeaderboardAvatarCache.isImage(data)
        else { return nil }
        return data
    }

    private func send(_ method: String, _ path: String, token: String?, body: Data?, now: Date = Date()) async throws -> Data {
        var request = URLRequest(url: endpoints.api.appending(path: path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.response(for: request)
        } catch {
            throw LeaderboardAPIError.offline
        }
        if let error = Self.error(status: response.statusCode, body: data, retryAfter: response.value(forHTTPHeaderField: "Retry-After"), now: now) {
            throw error
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LeaderboardAPIError.malformedResponse
        }
    }

    /// The error a non-2xx response stands for, or `nil` for a 2xx.
    static func error(status: Int, body: Data, retryAfter: String?, now: Date) -> LeaderboardAPIError? {
        struct ErrorBody: Decodable { let error: String? }
        switch status {
        case 200..<300: return nil
        case 401: return .unauthorized
        case 403: return .forbidden
        case 410: return .revoked
        case 426: return .upgradeRequired
        case 429: return .rateLimited(retryAfter: retryAfterSeconds(retryAfter, now: now))
        case 503: return .unavailable(retryAfter: retryAfterSeconds(retryAfter, now: now))
        case 500..<600: return .server(status: status)
        default:
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error
            return code == "invalid_grant" ? .invalidGrant : .rejected(status: status, code: code)
        }
    }

    /// `Retry-After` as seconds from `now`: delta-seconds or an HTTP-date (RFC 9110 §10.2.3).
    static func retryAfterSeconds(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) { return TimeInterval(max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// Answers a redirect with the 3xx itself, so a request never reaches a host it didn't name.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
