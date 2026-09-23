import Foundation

/// The Devin CLI's sessions: `$XDG_DATA_HOME/devin/cli/sessions.db` (default
/// `~/.local/share/...`), table `message_nodes`, one JSON `chat_message` per node, whose assistant
/// messages carry the request's `metadata.metrics`. `input_tokens` excludes cache reads, which
/// have their own field. Devin writes each assistant message twice -- the streamed node and its
/// committed copy share a `request_id` -- so each request counts once. Billed by Cognition, which
/// TokenWatch has no card for: its own `BillingService` slice.
enum DevinUsageLog {
    static func turns(databasePath: String, modifiedSince cutoff: Date) -> [LocalUsageTurn] {
        guard let database = TranscriptFiles.database(atPath: databasePath) else { return [] }
        return cache.items(for: [database]) { path in
            let rows = SQLiteReader.rows(
                databasePath: path,
                sql: "SELECT m.chat_message, m.created_at, s.model FROM message_nodes m LEFT JOIN sessions s ON s.id = m.session_id WHERE m.created_at >= ?",
                bindings: [.integer(Int64(cutoff.timeIntervalSince1970))]
            ) { statement -> (key: String?, turn: LocalUsageTurn)? in
                guard let message = SQLiteReader.text(statement, 0).flatMap(LooseJSON.parseObject),
                      message["role"] as? String == "assistant",
                      let metadata = LooseJSON.object(message["metadata"]), let metrics = LooseJSON.object(metadata["metrics"])
                else { return nil }
                let input = LooseJSON.int(metrics["input_tokens"]), output = LooseJSON.int(metrics["output_tokens"])
                let cacheRead = LooseJSON.int(metrics["cache_read_tokens"]), cacheWrite = LooseJSON.int(metrics["cache_creation_tokens"])
                guard input + output + cacheRead + cacheWrite > 0 else { return nil }
                let timestamp = LooseJSON.string(metadata["created_at"]).flatMap(FlexibleISO8601.parse)
                    ?? LooseJSON.epochDate(SQLiteReader.integer(statement, 1).map { NSNumber(value: $0) })
                guard let timestamp else { return nil }
                let model = LooseJSON.string(metadata["generation_model"]) ?? SQLiteReader.text(statement, 2) ?? "unknown"
                let turn = LocalUsageTurn(
                    timestamp: timestamp, source: .service(.devin), model: model,
                    input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output, costUSD: nil
                )
                return (LooseJSON.string(metadata["request_id"]) ?? LooseJSON.string(message["message_id"]), turn)
            } ?? []
            var seen = Set<String>()
            return rows.compactMap { row in
                if let key = row.key, !seen.insert(key).inserted { return nil }
                return row.turn
            }
        }
    }

    private static let cache = ParsedFileCache<LocalUsageTurn>()
}
