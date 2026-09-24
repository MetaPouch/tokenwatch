import Foundation

/// Daily token usage and estimated spend for Codex, from the Codex CLI's local rollout logs in
/// every Codex home (`$CODEX_HOME` and other `~/.codex*` accounts: `sessions/**/*.jsonl` plus
/// `archived_sessions/`) and the ChatGPT-sign-in turns in other agents' logs (`LocalUsageLogs`:
/// omp/pi's `openai-codex` provider, OpenCode's `openai` with a ChatGPT sign-in -- those agents
/// call the API directly, so their turns never appear in a rollout), priced at API list rates.
/// The counterpart of `ClaudeUsageHistoryScanner`; both feed `UsageDay`s into the same Usage-tab
/// views.
///
/// Ported from OpenUsage's `CodexLogUsageScanner`/`CodexLogFileParser` (itself ccusage's Codex
/// adapter), whose rules each prevent a real miscount:
/// - A `token_count` event carries the turn's usage as `last_token_usage`, or only the running
///   `total_token_usage`, in which case the turn is the delta from the previous total.
/// - A `token_count` whose running total didn't change is a re-emitted snapshot, not a new turn.
/// - A child session (subagent spawn or fork) starts by replaying its parent's whole history with
///   rewritten timestamps. That replay only seeds the running total; counting starts at the
///   child's first live turn (`task_started` at or after the child's own creation time).
/// - The model comes from the latest `turn_context` (falling back to `gpt-5`), and the priority
///   ("fast") service tier from the session's own `thread_settings_applied` events.
/// - An identical event in two files (a copied or archived rollout) counts once.
public enum CodexUsageHistoryScanner {
    /// Every Codex home's `sessions/` and `archived_sessions/` (see `CodexAccountDiscovery.historyRoots`).
    public static func roots(homeDirectory: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        CodexAccountDiscovery.historyRoots(homeDirectory: homeDirectory, environment: environment)
    }

    public static func dailyUsage(days: Int, now: Date = Date(), calendar: Calendar = .current, roots: [String]? = nil, localLogs: LocalUsageLocations = .standard()) -> [UsageDay] {
        scan(into: UsageDayAccumulator(days: days, now: now, calendar: calendar), roots: roots, localLogs: localLogs)
    }

    /// Every local day from `start`'s through `end`'s -- the leaderboard's history backfill
    /// (`UsageBackfill`). Same files, dedup and pricing as the trailing window.
    public static func dailyUsage(from start: Date, through end: Date, calendar: Calendar = .current, roots: [String]? = nil, localLogs: LocalUsageLocations = .standard()) -> [UsageDay] {
        scan(into: UsageDayAccumulator(from: start, through: end, calendar: calendar), roots: roots, localLogs: localLogs)
    }

    private static func scan(into window: UsageDayAccumulator, roots: [String]?, localLogs: LocalUsageLocations) -> [UsageDay] {
        var accumulator = window
        var seen = Set<Event>()
        let files = (roots ?? Self.roots()).flatMap {
            TranscriptFiles.recursive(roots: [$0], modifiedSince: accumulator.cutoff).sorted { $0.path < $1.path }
        }
        // Native turn durations include tool work, so these usage events remain untimed.
        for event in cache.items(for: files) where event.timestamp >= accumulator.cutoff {
            guard seen.insert(event).inserted else { continue }
            let (cost, approximate) = ModelPricing.codexCostUSD(
                model: event.pricingModel ?? event.model,
                inputTokens: event.input, cachedInputTokens: event.cached, cacheWriteInputTokens: event.cacheWrite,
                outputTokens: event.output, priorityTier: event.isPriority
            )
            // Cached tokens and cache writes are both inside `input` (OpenAI's shape).
            accumulator.add(
                timestamp: event.timestamp, model: event.model,
                input: event.input - event.cached - event.cacheWrite, cacheRead: event.cached, cacheWrite: event.cacheWrite,
                output: event.output, costUSD: cost, approximate: approximate
            )
        }

        // Other agents' buckets are already disjoint; the agent's recorded cost wins over re-pricing.
        for turn in LocalUsageLogs.turns(localLogs, modifiedSince: accumulator.cutoff) where turn.source == .provider(.codex) {
            let repriced = ModelPricing.codexCostUSD(
                model: turn.model, inputTokens: turn.input + turn.cacheRead + turn.cacheWrite,
                cachedInputTokens: turn.cacheRead, cacheWriteInputTokens: turn.cacheWrite, outputTokens: turn.output
            )
            accumulator.add(
                timestamp: turn.timestamp, model: turn.model,
                input: turn.input, cacheRead: turn.cacheRead, cacheWrite: turn.cacheWrite, output: turn.output,
                costUSD: turn.costUSD ?? repriced.cost, approximate: turn.costUSD == nil && repriced.approximate,
                observedAt: turn.completedAt, durationMs: turn.durationMs
            )
        }
        return accumulator.build()
    }

    /// One turn's usage. `input` includes `cached` and `cacheWrite` (OpenAI's usage shape);
    /// `output` includes reasoning tokens.
    struct Event: Hashable {
        let timestamp: Date
        let model: String
        /// The model to price as, when it differs from the one shown (see `pricingModel(for:at:)`).
        let pricingModel: String?
        let input: Int
        let cached: Int
        let cacheWrite: Int
        let output: Int
        let isPriority: Bool
    }

    private static let cache = IncrementalJSONLCache<Event, FileParser>(makeState: { FileParser() }) { parser, data in
        parser.parse(data)
    }

    /// Codex's `codex-auto-review` slug runs on whichever model was current on that date, and
    /// `gpt-reserve` (the fallback once regular usage runs out) on Luna -- priced accordingly
    /// while keeping their own names in the breakdown.
    static func pricingModel(for model: String, at timestamp: String) -> String? {
        switch model {
        case "codex-auto-review":
            let date = String(timestamp.prefix(10))
            return autoReviewModels.first { date >= $0.since }?.model ?? "gpt-5"
        case "gpt-reserve":
            return "gpt-5.6-luna"
        default:
            return nil
        }
    }

    private static let autoReviewModels: [(since: String, model: String)] = [
        ("2026-07-09", "gpt-5.6-luna"),
        ("2026-04-23", "gpt-5.5"),
        ("2026-03-05", "gpt-5.4"),
        ("2026-02-05", "gpt-5.3-codex"),
        ("2025-12-11", "gpt-5.2-codex"),
        ("2025-11-13", "gpt-5.1-codex"),
        ("2025-09-15", "gpt-5-codex"),
        ("2025-08-07", "gpt-5"),
    ]

    /// Per-file parse state: running totals, current model and tier, and the child-replay gate.
    struct FileParser {
        private var previousTotals: Usage?
        private var currentModel: String?
        private var priorityTier = false
        private var sawSessionMeta = false
        /// Set while skipping a child session's replayed parent history: the first live turn
        /// starts at or after this time (seconds since 1970). `-1` when the child's creation time
        /// is unknown, which instead compares each `task_started` to its own line timestamp.
        private var replayUntil: TimeInterval?

        private static let markers = ["turn_context", "session_meta", "token_count", "task_started", "thread_settings_applied"]
            .map { Data(#""type":"\#($0)""#.utf8) }

        mutating func parse(_ data: Data) -> [Event] {
            var events: [Event] = []
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard Self.markers.contains(where: { line.range(of: $0) != nil }),
                      let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                else { continue }
                let payload = object["payload"] as? [String: Any]
                let timestampRaw = (object["timestamp"] as? String)?.trimmingCharacters(in: .whitespaces)

                switch object["type"] as? String {
                case "turn_context":
                    if let model = payload.flatMap(Self.modelName) { currentModel = model }
                case "session_meta" where !sawSessionMeta:
                    // A child rollout also replays its parent's metadata; only its first is its own.
                    sawSessionMeta = true
                    if let payload, Self.isChildSession(payload) {
                        replayUntil = timestampRaw.flatMap(FlexibleISO8601.parse).map { $0.timeIntervalSince1970.rounded(.down) } ?? -1
                    }
                case "event_msg":
                    guard let payload else { continue }
                    if let event = handleEvent(payload, timestampRaw: timestampRaw) { events.append(event) }
                default:
                    continue
                }
            }
            return events
        }

        private mutating func handleEvent(_ payload: [String: Any], timestampRaw: String?) -> Event? {
            switch payload["type"] as? String {
            case "thread_settings_applied":
                let settings = payload["thread_settings"] as? [String: Any]
                if let tier = [settings?["service_tier"], payload["service_tier"]].lazy.compactMap({ ($0 as? String)?.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
                    priorityTier = tier == "fast" || tier == "priority"
                }
                return nil
            case "task_started":
                // A replayed task start keeps the parent's older start time; the first live one clears the gate.
                if let gate = replayUntil, let startedAt = (payload["started_at"] as? NSNumber)?.doubleValue {
                    let threshold = gate >= 0 ? gate : timestampRaw.flatMap(FlexibleISO8601.parse).map { $0.timeIntervalSince1970.rounded(.down) }
                    if let threshold, startedAt >= threshold { replayUntil = nil }
                }
                return nil
            case "token_count":
                guard let timestampRaw, let timestamp = FlexibleISO8601.parse(timestampRaw) else { return nil }
                let info = payload["info"] as? [String: Any]
                let totals = (info?["total_token_usage"] as? [String: Any]).map(Usage.init(json:))
                // Parent history seeds the running total but is never the child's own usage.
                if replayUntil != nil {
                    if let totals { previousTotals = totals }
                    return nil
                }
                if let totals, let previous = previousTotals, totals == previous { return nil }

                let usage: Usage
                if let last = (info?["last_token_usage"] as? [String: Any]).map(Usage.init(json:)) {
                    usage = last
                } else if let totals {
                    usage = totals.subtracting(previousTotals)
                } else {
                    return nil
                }
                if let totals { previousTotals = totals }
                guard usage.input > 0 || usage.cached > 0 || usage.output > 0 else { return nil }

                // An explicit model on the line also becomes the session's current model.
                currentModel = Self.modelName(payload) ?? info.flatMap(Self.modelName) ?? currentModel ?? "gpt-5"
                let model = currentModel ?? "gpt-5"
                return Event(
                    timestamp: timestamp, model: model,
                    pricingModel: CodexUsageHistoryScanner.pricingModel(for: model, at: timestampRaw),
                    input: usage.input, cached: min(usage.cached, usage.input),
                    cacheWrite: min(usage.cacheWrite, max(0, usage.input - min(usage.cached, usage.input))), output: usage.output,
                    isPriority: priorityTier
                )
            default:
                return nil
            }
        }

        private static func modelName(_ json: [String: Any]) -> String? {
            [json["model"], json["model_name"], (json["metadata"] as? [String: Any])?["model"]].lazy
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
        }

        /// A subagent spawn or fork. JSON `null` and blank strings count as absent, so a root
        /// session declaring `"forked_from_id": null` isn't misread as a child.
        private static func isChildSession(_ payload: [String: Any]) -> Bool {
            func present(_ value: Any?) -> Bool {
                switch value {
                case nil, is NSNull: return false
                case let text as String: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                default: return true
                }
            }
            return present(payload["forked_from_id"]) || present(payload["parent_thread_id"])
                || payload["thread_source"] as? String == "subagent"
                || present((payload["source"] as? [String: Any])?["subagent"])
        }
    }

    /// A `token_count` usage object, tolerating older field spellings.
    struct Usage: Equatable {
        var input: Int, cached: Int, cacheWrite: Int, output: Int, reasoning: Int, total: Int

        init(input: Int, cached: Int, cacheWrite: Int, output: Int, reasoning: Int, total: Int) {
            (self.input, self.cached, self.cacheWrite, self.output, self.reasoning, self.total) = (input, cached, cacheWrite, output, reasoning, total)
        }

        init(json: [String: Any]) {
            func int(_ keys: String...) -> Int? { keys.lazy.compactMap { (json[$0] as? NSNumber)?.intValue }.first }
            input = int("input_tokens", "prompt_tokens", "input") ?? 0
            cached = int("cached_input_tokens", "cache_read_input_tokens", "cached_tokens") ?? 0
            cacheWrite = int("cache_write_input_tokens") ?? 0
            output = int("output_tokens", "completion_tokens", "output") ?? 0
            reasoning = int("reasoning_output_tokens", "reasoning_tokens") ?? 0
            total = int("total_tokens") ?? 0
        }

        func subtracting(_ previous: Usage?) -> Usage {
            Usage(
                input: max(0, input - (previous?.input ?? 0)), cached: max(0, cached - (previous?.cached ?? 0)),
                cacheWrite: max(0, cacheWrite - (previous?.cacheWrite ?? 0)),
                output: max(0, output - (previous?.output ?? 0)), reasoning: max(0, reasoning - (previous?.reasoning ?? 0)),
                total: max(0, total - (previous?.total ?? 0))
            )
        }
    }
}
