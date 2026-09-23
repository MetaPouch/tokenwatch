import Foundation

/// One model call from a local agent log other than Claude Code's and the Codex CLI's own, in
/// disjoint token buckets: `input` excludes cache reads and writes, `output` includes reasoning.
struct LocalUsageTurn: Sendable {
    let timestamp: Date
    /// The provider the call is billed through (see `LocalUsageLogs`).
    let source: SpendSource
    let model: String
    let input: Int, cacheRead: Int, cacheWrite: Int, output: Int
    /// The part of `cacheWrite` written with a 1-hour TTL (Anthropic via omp/pi only).
    var cacheWrite1h: Int = 0
    /// The cost the agent itself recorded, in USD, when it records one.
    let costUSD: Double?
}

/// Where each coding agent keeps its local usage. `standard()` resolves them the way each agent
/// does; tests point individual fields at fixtures and leave the rest empty (read as nothing).
public struct LocalUsageLocations: Sendable {
    /// omp's and pi's session directories (`HarnessUsageLog`).
    public var harnessRoots: [String] = []
    /// OpenCode's data directory: `opencode.db` (and channel builds' `opencode-*.db`), the legacy
    /// `storage/` tree, and `auth.json`.
    public var openCodeDataDirectory: String = ""
    /// The Copilot CLI's `session-store.db`.
    public var copilotDatabase: String = ""
    /// The Devin CLI's `sessions.db`.
    public var devinDatabase: String = ""
    /// Grok CLI homes, each with `logs/unified.jsonl` and `sessions/`.
    public var grokHomes: [String] = []
    /// The Antigravity CLI's `brain/` directory of per-session transcripts.
    public var antigravityBrain: String = ""
    /// fx's `sessions/` directory.
    public var fxSessions: String = ""
    /// Muse Code's `sessions/` directory.
    public var museSessions: String = ""

    public init(harnessRoots: [String] = [], openCodeDataDirectory: String = "", copilotDatabase: String = "", devinDatabase: String = "", grokHomes: [String] = [], antigravityBrain: String = "", fxSessions: String = "", museSessions: String = "") {
        self.harnessRoots = harnessRoots
        self.openCodeDataDirectory = openCodeDataDirectory
        self.copilotDatabase = copilotDatabase
        self.devinDatabase = devinDatabase
        self.grokHomes = grokHomes
        self.antigravityBrain = antigravityBrain
        self.fxSessions = fxSessions
        self.museSessions = museSessions
    }

    public static func standard(homeDirectory: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> LocalUsageLocations {
        func env(_ key: String) -> String? {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return value
        }
        let dataHome = env("XDG_DATA_HOME") ?? homeDirectory + "/.local/share"
        var grokHomes = [homeDirectory + "/.grok"]
        if let grokHome = env("GROK_HOME"), grokHome != grokHomes[0] { grokHomes.append(grokHome) }
        return LocalUsageLocations(
            harnessRoots: HarnessUsageLog.roots(homeDirectory: homeDirectory, environment: environment),
            openCodeDataDirectory: dataHome + "/opencode",
            copilotDatabase: homeDirectory + "/.copilot/session-store.db",
            devinDatabase: dataHome + "/devin/cli/sessions.db",
            grokHomes: grokHomes,
            antigravityBrain: homeDirectory + "/.gemini/antigravity-cli/brain",
            fxSessions: homeDirectory + "/.fx/sessions",
            museSessions: dataHome + "/muse/sessions"
        )
    }
}

/// Every model call recorded in a local agent log other than Claude Code's and the Codex CLI's
/// (those have their own scanners, which fold in the turns here that belong to them). Each turn is
/// attributed to the provider it's billed through:
/// - omp/pi and OpenCode by the provider each turn was served by (`HarnessUsageLog.source`) --
///   one session can switch providers;
/// - the Copilot CLI to Copilot, the Grok CLI to Grok, the Antigravity CLI to Antigravity;
/// - Devin, fx, and Muse Code, which bill through services TokenWatch has no card for, to Other.
///
/// Every source is read defensively: a missing directory or database, or a record that doesn't
/// parse, contributes nothing. Parsed files and databases are cached by size and modification date.
enum LocalUsageLogs {
    static func turns(_ locations: LocalUsageLocations, modifiedSince cutoff: Date) -> [LocalUsageTurn] {
        var turns = HarnessUsageLog.turns(roots: locations.harnessRoots, modifiedSince: cutoff)
        turns += OpenCodeUsageLog.turns(dataDirectory: locations.openCodeDataDirectory, modifiedSince: cutoff)
        turns += CopilotCLIUsageLog.turns(databasePath: locations.copilotDatabase, modifiedSince: cutoff)
        turns += DevinUsageLog.turns(databasePath: locations.devinDatabase, modifiedSince: cutoff)
        turns += GrokCLIUsageLog.turns(homes: locations.grokHomes, modifiedSince: cutoff)
        turns += AntigravityUsageLog.turns(brainDirectory: locations.antigravityBrain, modifiedSince: cutoff)
        turns += FxUsageLog.turns(sessionsDirectory: locations.fxSessions, modifiedSince: cutoff)
        turns += MuseUsageLog.turns(sessionsDirectory: locations.museSessions, modifiedSince: cutoff)
        return turns.filter { $0.timestamp >= cutoff }
    }
}

/// Lenient accessors for the agents' loosely typed JSON records.
enum LooseJSON {
    static func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    static func int(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber: return max(0, number.intValue)
        case let string as String: return max(0, Int(string) ?? 0)
        default: return 0
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// Parses one JSON-object line; `nil` for anything else.
    static func parseObject<S: StringProtocol>(_ line: S) -> [String: Any]? {
        guard let data = String(line).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A number of seconds, milliseconds, or microseconds since the epoch, told apart by magnitude.
    static func epochDate(_ value: Any?) -> Date? {
        guard let raw = double(value), raw > 0 else { return nil }
        if raw > 1e14 { return Date(timeIntervalSince1970: raw / 1_000_000) }
        if raw > 1e11 { return Date(timeIntervalSince1970: raw / 1000) }
        return Date(timeIntervalSince1970: raw)
    }

    /// Non-empty lines of a text file, or none if it's unreadable.
    static func lines(ofFileAtPath path: String) -> [Substring] {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
    }
}
