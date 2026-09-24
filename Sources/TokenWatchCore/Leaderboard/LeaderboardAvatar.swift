import Foundation
import ImageIO

/// The joined account's GitHub avatar on disk, next to `leaderboard.json`: the image
/// (`leaderboard-avatar`) and which URL it came from and when (`leaderboard-avatar.json`). It is
/// fetched again when the account's avatar URL changes or a day after the last download, and
/// deleted on sign-out.
struct LeaderboardAvatarCache {
    struct Record: Codable, Equatable {
        var url: URL
        var fetchedAt: Date
    }

    static let refreshInterval: TimeInterval = 86_400

    private let imageURL: URL
    private let recordFile: LeaderboardFile<Record>

    init(directory: URL) {
        imageURL = directory.appendingPathComponent("leaderboard-avatar")
        recordFile = LeaderboardFile(directory: directory, name: "leaderboard-avatar.json")
    }

    /// The cached image for `url`; `nil` when there's none or it came from another URL.
    func image(for url: URL) -> Data? {
        guard recordFile.load()?.url == url, let data = try? Data(contentsOf: imageURL), Self.isImage(data) else { return nil }
        return data
    }

    /// Whether `url`'s image is cached and less than a day old.
    func isFresh(for url: URL, now: Date) -> Bool {
        guard let record = recordFile.load(), record.url == url, image(for: url) != nil else { return false }
        return now.timeIntervalSince(record.fetchedAt) < Self.refreshInterval
    }

    func save(_ data: Data, for url: URL, now: Date) {
        try? FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: imageURL, options: .atomic)) != nil else { return }
        recordFile.save(Record(url: url, fetchedAt: now))
    }

    func delete() {
        try? FileManager.default.removeItem(at: imageURL)
        recordFile.delete()
    }

    /// Whether `data` decodes as an image (PNG, JPEG, GIF, WebP...).
    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceGetStatus(source) == .statusComplete
    }
}

/// What the dashboard's top-right leaderboard button shows.
public enum LeaderboardBadge: Equatable, Sendable {
    /// Not joined: an invitation to join.
    case join
    /// A 401/403/410 signed this Mac out: a warning to sign in again.
    case signInAgain
    /// Joined: the avatar and `@login`, with how syncing is going.
    case joined(login: String, status: Status)

    public enum Status: Equatable, Sendable {
        case syncing
        /// Paused here or on tokenwat.ch: nothing new reaches the leaderboard.
        case paused
        /// Syncing stopped until the user acts (an app update). Transient sync issues retry on
        /// their own and don't count.
        case needsAttention
    }

    public init(account: LeaderboardAccount?, notice: LeaderboardNotice?, isPaused: Bool, isPausedOnWeb: Bool) {
        guard let account else {
            self = notice == .disconnected ? .signInAgain : .join
            return
        }
        let status: Status
        if notice == .updateRequired {
            status = .needsAttention
        } else if isPaused || isPausedOnWeb {
            status = .paused
        } else {
            status = .syncing
        }
        self = .joined(login: account.login, status: status)
    }
}
