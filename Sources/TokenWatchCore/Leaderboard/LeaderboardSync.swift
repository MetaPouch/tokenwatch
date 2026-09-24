import Foundation

/// Why the last upload didn't go through, in plain words for Settings. Retried on its own.
public enum LeaderboardSyncIssue: String, Codable, Sendable {
    case offline
    case unavailable
    case rejected

    public var message: String {
        switch self {
        case .offline: return "Offline. TokenWatch will retry."
        case .unavailable: return "tokenwat.ch is busy. TokenWatch will retry."
        case .rejected: return "tokenwat.ch rejected an upload. TokenWatch will retry."
        }
    }
}

/// Where the history upload is.
public enum LeaderboardHistoryProgress: Equatable, Sendable {
    /// Pending: waiting for local history to load or for a retry.
    case waiting
    /// Reading local logs older than the 30-day window.
    case reading
    /// Uploading this month (`yyyy-MM`).
    case uploading(month: String)
}

/// `leaderboard-sync.json`: what the server has acknowledged, when to try next, and how far
/// the history upload got. Reset on sign-in and sign-out.
struct LeaderboardSyncState: Codable, Equatable {
    /// A fingerprint of each recent local day's rows as the server last acknowledged them.
    var acknowledgedDays: [String: String] = [:]
    var lastSuccessAt: Date?
    /// Any request's start, for the hourly heartbeat.
    var lastAttemptAt: Date?
    /// The server's `nextSyncAfterSeconds`, `Retry-After` or the backoff: nothing is sent before.
    var nextAllowedAt: Date?
    var failures = 0
    var issue: LeaderboardSyncIssue?
    var pausedOnWeb = false
    /// `nil` once the history upload finished (or before the first sign-in).
    var backfill: LeaderboardBackfillProgress?
}

struct LeaderboardBackfillProgress: Codable, Equatable {
    /// The history scan's last day: the day before the 30-day window, fixed when it started.
    var through: Date?
    /// Whether the 30 days `SpendHistoryStore` already holds went up.
    var recentUploaded = false
    /// The oldest month fully uploaded; a resumed scan stops before it.
    var oldestUploadedMonth: String?
}

/// The sync's timing and error rules.
enum LeaderboardSyncPolicy {
    /// A local change is sent this long after it first arrives (bursts of writes coalesce).
    static let debounce: TimeInterval = 60
    /// With nothing to send, a check-in this often keeps the device's last-seen time fresh.
    static let heartbeat: TimeInterval = 3600
    /// `nextSyncAfterSeconds` before the server has said otherwise.
    static let defaultInterval: TimeInterval = 900
    /// Incremental syncs cover today and the two days before.
    static let recentDays = 3
    /// `SpendHistoryStore`'s window; the history upload scans only what's older.
    static let historyWindowDays = 30
    static let maxRetryAfter: TimeInterval = 86_400

    /// 1 minute after the first failure, doubling up to an hour.
    static func backoff(failures: Int) -> TimeInterval {
        min(60 * pow(2, Double(max(failures, 1) - 1)), 3600)
    }

    enum Reaction: Equatable {
        /// 401, 403, 410: the token is no good; sign out here and ask to sign in again.
        case signOut
        /// 426: stop until TokenWatch is updated.
        case stop
        case retry(after: TimeInterval, issue: LeaderboardSyncIssue)
    }

    /// `failures` counts this one.
    static func reaction(to error: LeaderboardAPIError, failures: Int) -> Reaction {
        switch error {
        case .unauthorized, .forbidden, .revoked:
            return .signOut
        case .upgradeRequired:
            return .stop
        case let .rateLimited(retryAfter), let .unavailable(retryAfter):
            return .retry(after: min(retryAfter ?? backoff(failures: failures), maxRetryAfter), issue: .unavailable)
        case .server:
            return .retry(after: backoff(failures: failures), issue: .unavailable)
        case .offline:
            return .retry(after: backoff(failures: failures), issue: .offline)
        case .rejected, .malformedResponse, .invalidGrant:
            return .retry(after: backoff(failures: failures), issue: .rejected)
        }
    }
}
