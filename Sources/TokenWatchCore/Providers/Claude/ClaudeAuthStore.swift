import Foundation

/// Claude OAuth credential shape written by the Claude CLI, shared by the Keychain item and the
/// file-based stores: `{"claudeAiOauth": {"accessToken": ..., "expiresAt": ..., "refreshToken":
/// ..., "refreshTokenExpiresAt": ..., "subscriptionType": ...}}`. `expiresAt`/
/// `refreshTokenExpiresAt` are epoch milliseconds, matching the JS-based CLI's own `Date.now()`
/// unit -- cross-checked against github.com/superset-sh/superset's own Claude Code reader, which
/// documents this credential shape from real-world testing across the same three local stores.
struct ClaudeCredentialsFile: Decodable {
    struct OAuth: Decodable {
        let accessToken: String
        let expiresAt: Double?
        let refreshToken: String?
        let refreshTokenExpiresAt: Double?
        let subscriptionType: String?
    }
    let claudeAiOauth: OAuth
}

/// A parsed Claude credential plus the local expiry timestamps needed to classify its usability
/// without a network call.
public struct ClaudeCredential: Sendable, Equatable {
    public let accessToken: String
    let expiresAtMs: Double?
    let refreshTokenExpiresAtMs: Double?
    public let subscriptionType: String?
}

/// Whether a credential's access token is currently usable, and if not, whether the CLI will fix
/// it silently on its own next run -- computed purely from the credential's own locally known
/// expiry timestamps, no network call.
public enum ClaudeCredentialLapse: Equatable {
    /// Not locally known to be expired -- safe to use as-is (this is also the answer when the
    /// credential carries no expiry timestamps at all, e.g. an older CLI version's Keychain item
    /// predating these fields: nothing indicates it's stale, so it's treated as live).
    case live
    /// The access token's own expiry has passed, but its refresh token hasn't. Claude Code
    /// access tokens live about 8 hours and the CLI renews them silently from the refresh token
    /// on its very next run -- this is the normal state of a credential on a machine that hasn't
    /// run `claude` recently, not a broken login. No user action needed.
    case stale
    /// The refresh token has also lapsed: the login itself needs `/login` in Claude Code again.
    case expired
}

/// Resolves a Claude Code OAuth credential from every local store the CLI is known to write to
/// (the macOS Keychain item, `~/.claude/.credentials.json`, and
/// `~/.config/claude/credentials.json`), preferring whichever is freshest. `/login` rewrites
/// whichever store the CLI prefers for this install and leaves stale copies in the others, so
/// checking a single store first -- Keychain, then falling back to one file only if Keychain has
/// nothing at all -- can silently serve a stale token when a fresher one exists in a different
/// store. Read-only: this never writes or refreshes a token. A second client refreshing a Claude
/// Code OAuth token can trip Anthropic's server-side token-reuse protection and sign the CLI out,
/// so a lapsed credential is reported as `.stale`/`.expired` rather than renewed.
public struct ClaudeAuthStore: Sendable {
    private static let keychainService = "Claude Code-credentials"

    public init() {}

    /// The freshest locally available credential across all three stores, or `nil` if none has
    /// one. The Keychain item is read without a prompt whenever its access list allows
    /// (`ExternalKeychainReader.readStringSilently`).
    public func resolvedCredential(homeDirectory: String = NSHomeDirectory()) async -> ClaudeCredential? {
        let keychain = await ExternalKeychainReader.readStringSilently(service: Self.keychainService)
        let candidates = [Self.parse(keychain)] + Self.credentialFiles(homeDirectory: homeDirectory).map { Self.parse(contentsOfFile: $0) }
        return Self.freshest(candidates.compactMap { $0 })
    }

    private static func credentialFiles(homeDirectory: String) -> [String] {
        [homeDirectory + "/.claude/.credentials.json", homeDirectory + "/.config/claude/credentials.json"]
    }

    /// Whether Claude Code has saved a sign-in, without reading it: a credentials file, or the
    /// CLI's Keychain item checked for existence only (`KeychainPresence`). Approval is needed only
    /// when the item can't be read silently through the `security` tool, which Claude Code's own
    /// writes normally allow.
    public func detect(homeDirectory: String = NSHomeDirectory()) -> ProviderDetection? {
        let inKeychain = KeychainPresence.exists(service: Self.keychainService)
        let hasFile = Self.credentialFiles(homeDirectory: homeDirectory).contains { FileManager.default.fileExists(atPath: $0) }
        guard inKeychain || hasFile else { return nil }
        let needsApproval = inKeychain && !ExternalKeychainReader.trustsSecurityTool(service: Self.keychainService)
        return ProviderDetection(source: "Signed in with Claude Code", needsKeychainApproval: needsApproval)
    }

    public static func classifyLapse(_ credential: ClaudeCredential, nowMs: Double = Date().timeIntervalSince1970 * 1000) -> ClaudeCredentialLapse {
        guard let expiresAtMs = credential.expiresAtMs, expiresAtMs <= nowMs else { return .live }
        if let refreshExpiresAtMs = credential.refreshTokenExpiresAtMs, refreshExpiresAtMs > nowMs {
            return .stale
        }
        return .expired
    }

    /// Live beats stale beats expired; among equal lapse states, the later (or unknown, treated
    /// as furthest-out) access-token expiry wins.
    static func freshest(_ candidates: [ClaudeCredential]) -> ClaudeCredential? {
        candidates.max { a, b in
            let rankA = Self.lapseRank(classifyLapse(a))
            let rankB = Self.lapseRank(classifyLapse(b))
            if rankA != rankB { return rankA < rankB }
            return (a.expiresAtMs ?? .greatestFiniteMagnitude) < (b.expiresAtMs ?? .greatestFiniteMagnitude)
        }
    }

    private static func lapseRank(_ lapse: ClaudeCredentialLapse) -> Int {
        switch lapse {
        case .live: return 2
        case .stale: return 1
        case .expired: return 0
        }
    }

    private static func parse(contentsOfFile path: String) -> ClaudeCredential? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse(String(data: data, encoding: .utf8))
    }

    static func parse(_ json: String?) -> ClaudeCredential? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let oauth = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data).claudeAiOauth else { return nil }
        return ClaudeCredential(
            accessToken: oauth.accessToken,
            expiresAtMs: oauth.expiresAt,
            refreshTokenExpiresAtMs: (oauth.refreshToken?.isEmpty == false) ? oauth.refreshTokenExpiresAt : nil,
            subscriptionType: oauth.subscriptionType
        )
    }
}
