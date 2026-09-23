import Foundation

/// fx's sessions: `~/.fx/sessions/<id>/events.jsonl`, whose `usage_checkpointed` events carry
/// *cumulative* per-model totals and cost for the session -- consecutive checkpoints are diffed
/// into per-call deltas. fx fronts OpenAI-style APIs: `input_tokens` includes cache reads. Billed by
/// fx, which TokenWatch has no card for: Other.
enum FxUsageLog {
    static func turns(sessionsDirectory: String, modifiedSince cutoff: Date) -> [LocalUsageTurn] {
        guard !sessionsDirectory.isEmpty else { return [] }
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDirectory)) ?? []
        let files = sessions.compactMap { TranscriptFiles.file(atPath: "\(sessionsDirectory)/\($0)/events.jsonl") }.filter { $0.modified >= cutoff }
        return cache.items(for: files, parse: parse)
    }

    private static let cache = ParsedFileCache<LocalUsageTurn>()

    private struct Totals {
        var input = 0, cacheRead = 0, cacheWrite = 0, output = 0
        var cost = 0.0
    }

    static func parse(_ path: String) -> [LocalUsageTurn] {
        var previous: [String: Totals] = [:]
        var turns: [LocalUsageTurn] = []
        for line in LooseJSON.lines(ofFileAtPath: path) where line.contains("\"usage_checkpointed\"") {
            guard let event = LooseJSON.parseObject(line), event["kind"] as? String == "usage_checkpointed",
                  let models = LooseJSON.object(LooseJSON.object(event["payload"])?["usage"])?["models"] as? [Any]
            else { continue }
            let timestamp = LooseJSON.epochDate(event["timestamp_ms"])
            for case let entry as [String: Any] in models {
                guard let model = LooseJSON.string(entry["model"]) else { continue }
                let current = Totals(
                    input: LooseJSON.int(entry["input_tokens"]), cacheRead: LooseJSON.int(entry["cache_read_tokens"]),
                    cacheWrite: LooseJSON.int(entry["cache_write_tokens"]), output: LooseJSON.int(entry["output_tokens"]),
                    cost: LooseJSON.double(entry["total_cost"]) ?? 0
                )
                let before = previous[model] ?? Totals()
                previous[model] = current
                let input = max(0, current.input - before.input), cacheRead = max(0, current.cacheRead - before.cacheRead)
                let cacheWrite = max(0, current.cacheWrite - before.cacheWrite), output = max(0, current.output - before.output)
                let cost = max(0, current.cost - before.cost)
                guard let timestamp, input + cacheRead + cacheWrite + output > 0 else { continue }
                turns.append(LocalUsageTurn(
                    timestamp: timestamp, source: .other, model: model,
                    input: max(0, input - cacheRead), cacheRead: min(cacheRead, input), cacheWrite: cacheWrite, output: output,
                    costUSD: cost > 0 ? cost : nil
                ))
            }
        }
        return turns
    }
}
