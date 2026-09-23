import Foundation

/// Token usage from the most recent turn in a local Codex CLI rollout transcript -- the raw
/// material for cache-temperature (see `CodexCacheTemperature`). Structurally identical to
/// Claude's `ClaudeSessionActivity`; kept as a separate type because the two providers' cache
/// semantics differ enough that conflating them would blur an honest "we don't know precisely"
/// signal (Codex) with a precise one (Claude) -- see `CodexCacheTemperature`'s doc comment.
struct CodexSessionActivity: Equatable {
    let filePath: String
    let timestamp: Date
    let inputTokens: Int
    /// OpenAI's prompt-cache hit count for this turn (`cached_input_tokens`, or the older
    /// `cache_read_input_tokens` name some Codex builds used) -- the equivalent of Claude's
    /// `cache_read_input_tokens`.
    let cachedInputTokens: Int
    /// Best-effort session label. Codex has no Claude-Code-style directory-per-project encoding
    /// to read a project name from; this prefers the session's own recorded working directory
    /// when present, falling back to a short fragment of the rollout file's own UUID so
    /// concurrent sessions are at least visually distinguishable.
    let sessionLabel: String
}

/// Finds the single most recently written line across every local Codex CLI rollout transcript
/// and extracts its token usage. Mirrors `ClaudeSessionScanner`'s structure and the same
/// read-only, best-effort contract: any I/O or parse failure yields `nil`, never a thrown error.
enum CodexSessionScanner {
    /// Codex CLI writes JSONL rollout files to `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`
    /// (default `$CODEX_HOME` is `~/.codex`), confirmed against the `codex-rs/rollout` source
    /// (`SESSIONS_SUBDIR = "sessions"`) and cross-checked against independent parsers built
    /// against real rollout files.
    static func projectRoots(homeDirectory: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return [codexHome + "/sessions"]
        }
        return [homeDirectory + "/.codex/sessions"]
    }

    /// The most recent turn's usage across every `.jsonl` rollout under the project roots, or
    /// `nil` if no roots exist, none contain a transcript, or none contain a parseable
    /// `token_count` event. Unbounded by age, like Claude's equivalent -- recency gating for
    /// display purposes happens at the call site (`CodexProvider`/`StatusItemController`).
    static func mostRecentActivity(roots: [String] = projectRoots()) -> CodexSessionActivity? {
        guard let newestFile = newestTranscriptFile(roots: roots) else { return nil }
        return lastTokenCountActivity(inFileAtPath: newestFile, sessionLabel: sessionLabel(forTranscriptPath: newestFile))
    }

    /// Window used by `allRecentActivity` to decide whether a session still counts as "active"
    /// for listing purposes. Codex's own rate-limit "Session" window duration isn't published
    /// the way Anthropic's 5-hour window is, so this reuses the same 5 hours as a reasonable,
    /// consistent default rather than a value tied to a specific documented Codex window.
    static let activeSessionWindowSeconds: TimeInterval = 5 * 3600

    /// Every distinct local rollout transcript modified within `windowSeconds` of `now`, newest
    /// first -- the "what do I currently have open" list, bounded so a user's entire history
    /// isn't scanned or shown. Mirrors `ClaudeSessionScanner.allRecentActivity` exactly.
    static func allRecentActivity(roots: [String] = projectRoots(), now: Date = Date(), windowSeconds: TimeInterval = activeSessionWindowSeconds) -> [CodexSessionActivity] {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let files = transcriptFiles(roots: roots, modifiedSince: cutoff)
        let activities = files.compactMap { file in
            lastTokenCountActivity(inFileAtPath: file.path, sessionLabel: sessionLabel(forTranscriptPath: file.path))
        }
        return activities.sorted { $0.timestamp > $1.timestamp }
    }

    /// Best-effort session label: tries the rollout file's own first line (`session_meta`, which
    /// some Codex builds stamp with the working directory) for a `cwd` field; falls back to a
    /// short fragment of the file's own UUID (from `rollout-<timestamp>-<uuid>.jsonl`) so
    /// concurrent sessions are still distinguishable even without a project name.
    static func sessionLabel(forTranscriptPath path: String) -> String {
        if let cwd = sessionMetaCwd(atPath: path), !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        let filename = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if let uuidRange = filename.range(of: "[0-9a-f]{8}-[0-9a-f]{4}", options: .regularExpression) {
            return "session-" + filename[uuidRange].prefix(8)
        }
        return filename
    }

    private struct SessionMetaLine: Decodable {
        struct Payload: Decodable {
            let cwd: String?
        }
        let type: String?
        let payload: Payload?
    }

    /// Upper bound on how far `sessionMetaCwd` reads looking for the end of the first line.
    /// Codex CLI 0.155 embeds the full `base_instructions` prompt in `session_meta`, putting that
    /// line at ~18-23 KB in real rollouts -- a fixed 8 KB prefix truncated it on every session,
    /// so every label fell back to the UUID fragment. 1 MiB leaves ample headroom without ever
    /// reading a whole multi-megabyte transcript just to find a label.
    static let sessionMetaMaxBytes = 1 << 20

    /// Reads only the first line of the file (the `session_meta` record is always first) rather
    /// than the whole file, since this is called once per candidate file during scanning.
    private static func sessionMetaCwd(atPath path: String, maxBytes: Int = sessionMetaMaxBytes) -> String? {
        guard let lineData = firstLine(ofFileAtPath: path, maxBytes: maxBytes) else { return nil }
        guard let meta = try? JSONDecoder().decode(SessionMetaLine.self, from: lineData), meta.type == "session_meta" else { return nil }
        return meta.payload?.cwd
    }

    /// The file's first non-empty line as raw bytes, read in chunks until its newline; `nil` if
    /// it doesn't end within `maxBytes`. Works on bytes rather than decoding a fixed-size prefix
    /// as UTF-8, which fails outright whenever the cut lands mid-character.
    private static func firstLine(ofFileAtPath path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                return line.isEmpty ? nil : line // EOF: the file is a single unterminated line
            }
            var rest = chunk[...]
            while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
                line.append(contentsOf: rest[rest.startIndex..<newline])
                if !line.isEmpty { return line }
                rest = rest[rest.index(after: newline)...]
            }
            line.append(contentsOf: rest)
            if line.count > maxBytes { return nil }
        }
    }

    /// Every `.jsonl` transcript under `roots` modified at or after `modifiedSince`, with its
    /// modification date. Shared enumeration logic behind both `newestTranscriptFile` (unbounded,
    /// `modifiedSince: .distantPast`) and `allRecentActivity` (bounded to the active window) --
    /// identical shape to Claude's equivalent, since `FileManager.enumerator` already recurses
    /// through Codex's YYYY/MM/DD date-partitioned tree without needing to know its depth.
    private static func transcriptFiles(roots: [String], modifiedSince: Date) -> [(path: String, modified: Date)] {
        let fileManager = FileManager.default
        var results: [(path: String, modified: Date)] = []

        for root in roots {
            guard let enumerator = fileManager.enumerator(atPath: root) else { continue }
            for case let relativePath as String in enumerator {
                guard relativePath.hasSuffix(".jsonl") else { continue }
                let fullPath = root + "/" + relativePath
                guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath),
                      let modified = attributes[.modificationDate] as? Date,
                      modified >= modifiedSince
                else { continue }
                results.append((fullPath, modified))
            }
        }
        return results
    }

    private static func newestTranscriptFile(roots: [String]) -> String? {
        transcriptFiles(roots: roots, modifiedSince: .distantPast).max { $0.modified < $1.modified }?.path
    }

    /// Scans `path` from the end for the last `event_msg`/`token_count` line, matching the shape
    /// confirmed against `openai/codex`'s `codex-rs/protocol/src/protocol.rs` `TokenUsage`
    /// struct and cross-checked against independently captured real rollout files:
    /// `{"timestamp":..., "type":"event_msg", "payload":{"type":"token_count",
    /// "info":{"last_token_usage":{"input_tokens":N,"cached_input_tokens":N,...}}}}`. Some older
    /// Codex builds spelled the cache field `cache_read_input_tokens` instead -- both are read.
    private static func lastTokenCountActivity(inFileAtPath path: String, sessionLabel: String) -> CodexSessionActivity? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let entry = try? JSONDecoder().decode(RolloutLine.self, from: lineData) else { continue }
            guard entry.type == "event_msg",
                  entry.payload?.type == "token_count",
                  let usage = entry.payload?.info?.lastTokenUsage,
                  let timestampString = entry.timestamp
            else { continue }
            guard let timestamp = FlexibleISO8601.parse(timestampString) else { continue }
            return CodexSessionActivity(
                filePath: path,
                timestamp: timestamp,
                inputTokens: usage.inputTokens ?? 0,
                cachedInputTokens: usage.cachedInputTokens ?? usage.cacheReadInputTokens ?? 0,
                sessionLabel: sessionLabel
            )
        }
        return nil
    }

    private struct RolloutLine: Decodable {
        struct Payload: Decodable {
            struct Info: Decodable {
                struct Usage: Decodable {
                    let inputTokens: Int?
                    let cachedInputTokens: Int?
                    let cacheReadInputTokens: Int?

                    enum CodingKeys: String, CodingKey {
                        case inputTokens = "input_tokens"
                        case cachedInputTokens = "cached_input_tokens"
                        case cacheReadInputTokens = "cache_read_input_tokens"
                    }
                }
                let lastTokenUsage: Usage?
                enum CodingKeys: String, CodingKey {
                    case lastTokenUsage = "last_token_usage"
                }
            }
            let type: String?
            let info: Info?
        }
        let type: String?
        let timestamp: String?
        let payload: Payload?
    }
}
