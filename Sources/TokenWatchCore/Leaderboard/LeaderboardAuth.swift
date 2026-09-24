import Foundation
import CryptoKit
import Security

/// Why joining the leaderboard didn't finish. `cancelled` is the user closing the sign-in
/// window and needs no message.
public enum LeaderboardSignInError: Error, Equatable, Sendable {
    case cancelled
    /// Cancel on tokenwat.ch's consent page (`error=access_denied`).
    case denied
    /// The callback's `state` isn't this attempt's: it's dropped unread.
    case stateMismatch
    case missingCode
    /// Any other `error` the callback carried, or a callback that isn't `tokenwatch://auth/callback`.
    case unexpectedCallback
    /// The code expired or was already used (`invalid_grant`); starting over fixes it.
    case expired
    case couldNotStart
    case keychain
    case api(LeaderboardAPIError)

    public var message: String {
        switch self {
        case .cancelled: return "Sign-in cancelled."
        case .denied: return "You cancelled on tokenwat.ch. Nothing was shared."
        case .stateMismatch, .missingCode, .unexpectedCallback: return "The sign-in didn't come back as expected. Try again."
        case .expired: return "That sign-in link expired. Try again."
        case .couldNotStart: return "Couldn't open the sign-in window."
        case .keychain: return "Couldn't save the sign-in to your Keychain."
        case .api(.offline): return "tokenwat.ch is unreachable. Check your connection and try again."
        case .api(.upgradeRequired): return "Update TokenWatch to join the leaderboard."
        case .api: return "tokenwat.ch couldn't finish the sign-in. Try again later."
        }
    }
}

/// The app side of the leaderboard's device sign-in (the contract README's "Device sign-in"):
/// PKCE S256, a fresh `state` per attempt, the `/connect` URL, and the callback. UI-agnostic;
/// the app opens the URL in `ASWebAuthenticationSession`.
public enum LeaderboardAuth {
    public static let callbackScheme = "tokenwatch"
    /// The longest `device_name` the server accepts, in UTF-16 code units.
    public static let deviceNameMaxLength = 64

    /// RFC 7636 proof key: a random 256-bit `code_verifier` and its S256 `code_challenge`.
    public struct PKCE: Sendable, Equatable {
        public let verifier: String
        public let challenge: String

        public init(verifier: String) {
            self.verifier = verifier
            challenge = Self.challenge(for: verifier)
        }

        public static func generate() -> PKCE {
            PKCE(verifier: randomToken())
        }

        /// base64url(SHA-256(ASCII(verifier))) without padding.
        public static func challenge(for verifier: String) -> String {
            base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    /// A fresh `state`: 256 random bits, base64url (43 characters).
    public static func makeState() -> String { randomToken() }

    /// `https://tokenwat.ch/connect?challenge&state&device_id&device_name&client_version`, or
    /// `nil` when a parameter would get tokenwat.ch's error page instead of a callback.
    public static func connectURL(_ connect: URL, challenge: String, state: String, deviceID: String, deviceName: String, clientVersion: String) -> URL? {
        guard matches(challenge, #"^[A-Za-z0-9_-]{43}$"#),
              matches(state, #"^[A-Za-z0-9._~-]{16,128}$"#),
              isValidDeviceID(deviceID),
              !deviceName.isEmpty, deviceName == self.deviceName(from: deviceName),
              isValidClientVersion(clientVersion),
              var components = URLComponents(url: connect, resolvingAgainstBaseURL: false)
        else { return nil }
        // Every value percent-encoded but unreserved characters: a bare `+` would read as a space.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query: [(String, String)] = [
            ("challenge", challenge), ("state", state), ("device_id", deviceID),
            ("device_name", deviceName), ("client_version", clientVersion),
        ]
        components.percentEncodedQuery = query
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
        return components.url
    }

    /// The one-time code from `tokenwatch://auth/callback?code=…&state=…`. A callback for any
    /// other `state` is rejected before anything else in it is looked at.
    public static func code(fromCallback url: URL, expectedState: String) throws -> String {
        guard url.scheme?.lowercased() == callbackScheme, url.host?.lowercased() == "auth", url.path == "/callback",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { throw LeaderboardSignInError.unexpectedCallback }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let state = value("state"), state == expectedState else {
            throw LeaderboardSignInError.stateMismatch
        }
        if let error = value("error") {
            throw error == "access_denied" ? LeaderboardSignInError.denied : LeaderboardSignInError.unexpectedCallback
        }
        guard let code = value("code"), matches(code, #"^[A-Za-z0-9_-]{43}$"#) else {
            throw LeaderboardSignInError.missingCode
        }
        return code
    }

    /// The Mac's name as `/connect` accepts it: control characters become spaces, bidi
    /// overrides and byte-order marks go, surrounding whitespace is trimmed, and it's cut to 64
    /// UTF-16 code units at a character boundary. "Mac" if nothing is left.
    public static func deviceName(from raw: String?) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in (raw ?? "").unicodeScalars {
            switch scalar.value {
            case 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: continue
            default: scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.utf16.count > deviceNameMaxLength {
            var cut = ""
            for character in name {
                guard cut.utf16.count + character.utf16.count <= deviceNameMaxLength else { break }
                cut.append(character)
            }
            name = cut.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty ? "Mac" : name
    }

    /// A lowercase UUID, as the API's `deviceId`/`device_id` requires.
    public static func isValidDeviceID(_ value: String) -> Bool {
        matches(value, #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#)
    }

    /// The contract's `client.version`: e.g. `1.9.0` or `0.0.0-dev`, at most 32 characters.
    public static func isValidClientVersion(_ value: String) -> Bool {
        value.count <= 32 && matches(value, #"^\d+(\.\d+){0,3}([-+][0-9A-Za-z.-]+)?$"#)
    }

    /// The contract's `timeZone`: a plain IANA name such as `Asia/Kolkata`.
    public static func isValidTimeZone(_ value: String) -> Bool {
        value.count <= 64 && matches(value, #"^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$"#)
    }

    /// Whether `pattern` matches all of `value` (ICU's `$` would also match before a final newline).
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
