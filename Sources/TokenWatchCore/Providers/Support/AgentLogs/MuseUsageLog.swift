import Foundation

/// Muse Code's sessions: append-only event logs at
/// `$XDG_DATA_HOME/muse/sessions/YYYY/MM/DD/<session>/session.jsonl` (default
/// `~/.local/share/...`; subagent logs nest under their parent's directory, and dot-directories
/// hold view caches, not logs). Each line is an envelope -- `recorded_at` in microseconds, a
/// `payload_type`, the `payload` -- and a run's `model_completed` event carries the call's usage;
/// `input_tokens` includes cached tokens, as with Codex. A child run is mirrored into both its own
/// and its parent's log, so a call counts once per run record id. Billed by Meta, which TokenWatch
/// has no card for: its own `BillingService` slice.
enum MuseUsageLog {
    static func turns(sessionsDirectory: String, modifiedSince cutoff: Date) -> [LocalUsageTurn] {
        guard !sessionsDirectory.isEmpty else { return [] }
        let files = TranscriptFiles.recursive(roots: [sessionsDirectory], modifiedSince: cutoff) { relativePath in
            (relativePath as NSString).lastPathComponent == "session.jsonl"
                && !relativePath.split(separator: "/").contains { $0.hasPrefix(".") }
        }.sorted { $0.path < $1.path }
        var seen = Set<String>()
        return cache.items(for: files, parse: parse).compactMap { record in
            if let id = record.id, !seen.insert(id).inserted { return nil }
            return record.turn
        }
    }

    struct Record: Sendable {
        let id: String?
        let turn: LocalUsageTurn
    }

    private static let cache = ParsedFileCache<Record>()

    static func parse(_ path: String) -> [Record] {
        let fileModified = TranscriptFiles.file(atPath: path)?.modified ?? Date()
        var sessionModel: String?
        var pending: [(id: String?, timestamp: Date, model: String?, usage: [String: Any])] = []
        for line in LooseJSON.lines(ofFileAtPath: path)
            where line.contains("\"model_completed\"") || line.contains("\"runtime.session.metadata\"") {
            guard let envelope = LooseJSON.parseObject(line), let payload = LooseJSON.object(envelope["payload"]) else { continue }
            if envelope["payload_type"] as? String == "runtime.session.metadata" {
                sessionModel = sessionModel ?? LooseJSON.string(LooseJSON.object(payload["record"])?["model_id"])
            }
            guard payload["kind"] as? String == "run", let event = LooseJSON.object(payload["event"]),
                  event["kind"] as? String == "model_completed", let usage = LooseJSON.object(event["usage"])
            else { continue }
            pending.append((
                LooseJSON.string(payload["source_run_record_id"]) ?? LooseJSON.string(envelope["id"]),
                LooseJSON.epochDate(envelope["recorded_at"]) ?? fileModified,
                LooseJSON.string(event["model"]), usage
            ))
        }
        // The session's metadata precedes its first call but can be re-stamped later; settle
        // models once the whole file is read.
        return pending.compactMap { entry in
            let usage = entry.usage
            let input = LooseJSON.int(usage["input_tokens"] ?? usage["prompt_tokens"])
            let cached = min(input, LooseJSON.int(usage["cached_tokens"] ?? usage["cache_read_tokens"]))
            let cacheWrite = LooseJSON.int(usage["cache_write_tokens"]), output = LooseJSON.int(usage["output_tokens"])
            guard input + cacheWrite + output > 0 else { return nil }
            let costMicros = LooseJSON.int(usage["cost_micros"])
            return Record(id: entry.id, turn: LocalUsageTurn(
                timestamp: entry.timestamp, source: .service(.muse), model: entry.model ?? sessionModel ?? "unknown",
                input: input - cached, cacheRead: cached, cacheWrite: cacheWrite, output: output,
                costUSD: costMicros > 0 ? Double(costMicros) / 1_000_000 : nil
            ))
        }
    }
}
