import Foundation

/// Reads the coding-agent harnesses' own local session transcripts (`omp`, the CLI behind
/// Superset, at `~/.omp/agent/sessions/<encoded-cwd>/<timestamp>_<ulid>.jsonl`, and `pi`, which omp
/// forked, in the same format) as a supplementary local-activity source for Claude's and Codex's
/// cache-temperature/session lists -- each taking the turns served through its own provider
/// (`HarnessUsageLog.source(forHarnessProvider:)`).
///
/// Why this exists: a harness like `omp` calls the Anthropic API directly -- confirmed on a live
/// machine via `ps aux` (the process is `omp --model anthropic/...`, never `claude`) -- so it never
/// shells out to the real Claude CLI and never writes a Claude Code-format transcript under
/// `~/.claude/projects`. Without this, any Claude usage that happens through such a harness is
/// completely invisible to `ClaudeSessionScanner`: on the machine this was built against, 69 Claude
/// Code project directories existed, but zero for the harness's own actively-in-use project,
/// despite hours of continuous activity in it.
///
/// `omp`'s session format is not a stable, documented public contract the way Claude Code's or
/// Codex's are -- it's this specific closed-source tool's internal storage, reverse-engineered by
/// inspecting a real live session file (`strings` on the `omp` binary confirmed the path pattern;
/// the JSON shape was read directly off disk), and it could change without notice in a future `omp`
/// release. Every read here is defensive: a missing file, unexpected shape, or parse failure yields
/// `nil`/empty, never a crash or a stuck refresh -- the same failure posture as every other scanner
/// in this app. Produces the same `ClaudeSessionActivity` type `ClaudeSessionScanner` does (omp's
/// disjoint input/cache buckets have the same shape for every provider), so `ClaudeProvider`
/// merges both sources into one list with no special-casing downstream; `CodexProvider` converts.
enum OmpSessionScanner {
    static func projectRoots(homeDirectory: String = NSHomeDirectory()) -> [String] {
        HarnessUsageLog.roots(homeDirectory: homeDirectory)
    }

    /// Matches `ClaudeSessionScanner`'s window so a merged "active sessions" list has one
    /// consistent recency cutoff regardless of which scanner found which entry.
    static let activeSessionWindowSeconds: TimeInterval = ClaudeSessionScanner.activeSessionWindowSeconds

    /// The newest turn `provider` served in an omp session written within `lookbackSeconds`. One
    /// omp session can switch providers, so the newest file isn't necessarily the right one: files
    /// are checked newest first, stopping once the next file was last written before the best turn
    /// found (it can't hold a newer one). Bounded to the day the menu bar considers "recent", so a
    /// provider never used through omp doesn't read the tail of every omp session ever written.
    static func mostRecentActivity(provider: ProviderID = .claude, roots: [String] = projectRoots(), now: Date = Date(), lookbackSeconds: TimeInterval = 24 * 3600) -> ClaudeSessionActivity? {
        let source = SpendSource.provider(provider)
        var best: ClaudeSessionActivity?
        let files = transcriptFiles(roots: roots, modifiedSince: now.addingTimeInterval(-lookbackSeconds))
        for file in files.sorted(by: { $0.modified > $1.modified }) {
            if let best, file.modified < best.timestamp { break }
            if let activity = lastActivity(inFileAtPath: file.path, source: source), activity.timestamp > best?.timestamp ?? .distantPast {
                best = activity
            }
        }
        return best
    }

    static func allRecentActivity(provider: ProviderID = .claude, roots: [String] = projectRoots(), now: Date = Date(), windowSeconds: TimeInterval = activeSessionWindowSeconds) -> [ClaudeSessionActivity] {
        let source = SpendSource.provider(provider)
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let files = transcriptFiles(roots: roots, modifiedSince: cutoff)
        let activities = files.compactMap { lastActivity(inFileAtPath: $0.path, source: source) }
        return activities.sorted { $0.timestamp > $1.timestamp }
    }

    /// Every top-level `.jsonl` session transcript under `roots`, modified at or after
    /// `modifiedSince`. Deliberately does not recurse into each session's same-named artifacts
    /// subdirectory (`omp` nests one per session, holding subagent transcripts/attachments) --
    /// only the session's own top-level file is a candidate, keeping this bounded on a machine
    /// with a long history of sessions (69 Claude Code project dirs alone were observed on the
    /// machine this was built against; unbounded recursion here would multiply that considerably).
    private static func transcriptFiles(roots: [String], modifiedSince: Date) -> [(path: String, modified: Date)] {
        let fileManager = FileManager.default
        var results: [(path: String, modified: Date)] = []

        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for projectDir in entries {
                let projectPath = root + "/" + projectDir
                guard let files = try? fileManager.contentsOfDirectory(atPath: projectPath) else { continue }
                for file in files {
                    guard file.hasSuffix(".jsonl") else { continue }
                    let fullPath = projectPath + "/" + file
                    guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath),
                          let modified = attributes[.modificationDate] as? Date,
                          modified >= modifiedSince
                    else { continue }
                    results.append((fullPath, modified))
                }
            }
        }
        return results
    }

    /// Scans the tail of `path` for the last assistant message served through `source`.
    /// A single omp session can mix providers/models turn to turn (switching models mid-conversation
    /// is a normal user action), so this looks past any trailing turns from other providers rather
    /// than stopping at the very last line. Bounded to the last `tailReadBytes` of the file -- an
    /// actively-used omp session observed during implementation was 10+ MB after a few days, and a
    /// handful of the most recent messages are always well within a couple hundred KB of the tail.
    private static func lastActivity(inFileAtPath path: String, source: SpendSource) -> ClaudeSessionActivity? {
        guard let text = tailText(ofFileAtPath: path) else { return nil }
        let sessionLabel = ompSessionCwd(atPath: path).map { ($0 as NSString).lastPathComponent }
            ?? ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent

        return ClaudeSessionScanner.newestActivity(in: text.split(separator: "\n", omittingEmptySubsequences: true)) { line in
            guard let lineData = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(OmpMessageLine.self, from: lineData),
                  entry.type == "message",
                  let message = entry.message,
                  message.role == "assistant",
                  message.provider.map(HarnessUsageLog.source(forHarnessProvider:)) == source,
                  let usage = message.usage,
                  let timestampString = entry.timestamp,
                  let timestamp = FlexibleISO8601.parse(timestampString)
            else { return nil }

            let activity = ClaudeSessionActivity(
                filePath: path,
                timestamp: timestamp,
                inputTokens: usage.input ?? 0,
                cacheReadTokens: usage.cacheRead ?? 0,
                cacheCreationTokens: usage.cacheWrite ?? 0,
                sessionLabel: sessionLabel
            )
            let ttl = ClaudeCacheTemperature.ttlSeconds(
                fiveMinuteWrites: usage.cttl?.ephemeral5m ?? 0,
                oneHourWrites: usage.cttl?.ephemeral1h ?? 0
            )
            return (activity, ttl)
        }
    }

    /// The session's real working directory, read from its own `type: "session"` line -- always
    /// near the start of the file, so read from the front rather than the tail this scanner
    /// otherwise reads from.
    private static func ompSessionCwd(atPath path: String, maxBytes: Int = 8192) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let entry = try? JSONDecoder().decode(OmpSessionMetaLine.self, from: lineData) else { continue }
            if entry.type == "session", let cwd = entry.cwd, !cwd.isEmpty { return cwd }
        }
        return nil
    }

    /// The last `maxBytes` of the file, starting at the first full line inside that window. The
    /// cut is dropped as raw bytes before decoding: it can land mid-way through a multi-byte UTF-8
    /// character, and decoding a fixed byte window as-is would then fail for the whole session.
    private static func tailText(ofFileAtPath path: String, maxBytes: Int = 2_000_000) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return nil }
        let readSize = min(Int(fileSize), maxBytes)
        do {
            try handle.seek(toOffset: fileSize - UInt64(readSize))
        } catch {
            return nil
        }
        guard var data = try? handle.read(upToCount: readSize) else { return nil }
        if readSize < Int(fileSize) {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            data = data[data.index(after: newline)...]
        }
        return String(data: data, encoding: .utf8)
    }

    private struct OmpSessionMetaLine: Decodable {
        let type: String?
        let cwd: String?
    }

    private struct OmpMessageLine: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                /// omp's per-TTL split of this turn's cache writes.
                struct CacheTTL: Decodable {
                    let ephemeral5m: Int?
                    let ephemeral1h: Int?
                }
                let input: Int?
                let cacheRead: Int?
                let cacheWrite: Int?
                let cttl: CacheTTL?
            }
            let role: String?
            let provider: String?
            let usage: Usage?
        }
        let type: String?
        let timestamp: String?
        let message: Message?
    }
}
