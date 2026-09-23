import Foundation

/// The GitHub Copilot CLI's per-request usage: `~/.copilot/session-store.db`, table
/// `assistant_usage_events`. Cache reads and writes have their own columns (Anthropic-style), so
/// `input_tokens` is the uncached part. `created_at` is SQLite's `datetime('now')` -- UTC text
/// without a zone. The CLI records no cost (usage is billed as premium requests), so calls are
/// priced at the served model's list rate; all of it counts toward Copilot.
enum CopilotCLIUsageLog {
    static func turns(databasePath: String, modifiedSince cutoff: Date) -> [LocalUsageTurn] {
        guard let database = TranscriptFiles.database(atPath: databasePath) else { return [] }
        return cache.items(for: [database]) { path in
            SQLiteReader.rows(
                databasePath: path,
                sql: "SELECT model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, created_at FROM assistant_usage_events WHERE created_at >= ?",
                bindings: [.text(sqliteUTC.string(from: cutoff))]
            ) { statement in
                guard let created = SQLiteReader.text(statement, 5), let timestamp = sqliteUTC.date(from: created) else { return nil }
                let input = Int(SQLiteReader.integer(statement, 1) ?? 0), output = Int(SQLiteReader.integer(statement, 2) ?? 0)
                let cacheRead = Int(SQLiteReader.integer(statement, 3) ?? 0), cacheWrite = Int(SQLiteReader.integer(statement, 4) ?? 0)
                guard input + output + cacheRead + cacheWrite > 0 else { return nil }
                return LocalUsageTurn(
                    timestamp: timestamp, source: .provider(.copilot), model: SQLiteReader.text(statement, 0) ?? "unknown",
                    input: max(0, input), cacheRead: max(0, cacheRead), cacheWrite: max(0, cacheWrite), output: max(0, output),
                    costUSD: nil
                )
            } ?? []
        }
    }

    private static let cache = ParsedFileCache<LocalUsageTurn>()

    private static let sqliteUTC: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
