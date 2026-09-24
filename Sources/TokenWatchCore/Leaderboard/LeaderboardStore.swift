import Foundation

/// The GitHub account this Mac joined the leaderboard as.
public struct LeaderboardAccount: Codable, Equatable, Sendable {
    public let login: String
    public let avatarURL: URL?
    public let profileURL: URL

    public init(login: String, avatarURL: URL?, profileURL: URL) {
        self.login = login
        self.avatarURL = avatarURL
        self.profileURL = profileURL
    }
}

/// Why syncing stopped without the user asking; Settings shows it until they act.
public enum LeaderboardNotice: String, Codable, Sendable {
    /// A 401, 403 or 410 signed this Mac out.
    case disconnected
    /// A 426: this version's uploads are no longer accepted.
    case updateRequired

    public var message: String {
        switch self {
        case .disconnected: return "Disconnected, sign in again."
        case .updateRequired: return "Update TokenWatch to keep syncing."
        }
    }
}

/// `leaderboard.json`: the device id (kept across sign-outs, so signing back in reconnects the
/// same device), the account, pause, and any notice. Never the token: that's in the Keychain.
struct LeaderboardEnrollment: Codable, Equatable {
    var deviceID: String?
    var account: LeaderboardAccount?
    var isPaused = false
    var notice: LeaderboardNotice?
    /// The app version a 426 came back for; any other version tries again.
    var updateRequiredVersion: String?
}

/// Where the device token lives.
public protocol LeaderboardTokenStore: Sendable {
    func token() -> String?
    func setToken(_ token: String) throws
    func deleteToken() throws
}

/// The device token in TokenWatch's own Keychain service (`dev.tokenwatch.credentials`), under
/// account `leaderboard.deviceToken`, like the API keys users save.
public struct KeychainLeaderboardTokenStore: LeaderboardTokenStore {
    public static let account = "leaderboard.deviceToken"
    private let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    public func token() -> String? { keychain.get(account: Self.account) }
    public func setToken(_ token: String) throws { try keychain.set(account: Self.account, value: token) }
    public func deleteToken() throws { try keychain.delete(account: Self.account) }
}

/// One JSON file in TokenWatch's Application Support directory. A missing or unreadable file
/// reads as `nil`.
struct LeaderboardFile<Value: Codable> {
    let url: URL

    init(directory: URL, name: String) {
        url = directory.appendingPathComponent(name)
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
