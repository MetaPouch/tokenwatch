import Foundation

/// A log file found by `TranscriptFiles`, with what `ParsedFileCache` keys its reuse on.
struct TranscriptFile: Sendable {
    let path: String
    let size: Int
    let modified: Date
}

enum TranscriptFiles {
    /// Every file under `roots`, recursively, whose root-relative path `matches` (by default every
    /// `.jsonl`), modified at or after `modifiedSince`.
    static func recursive(roots: [String], modifiedSince: Date, matching matches: (String) -> Bool = { $0.hasSuffix(".jsonl") }) -> [TranscriptFile] {
        let fileManager = FileManager.default
        var results: [TranscriptFile] = []
        for root in roots where !root.isEmpty {
            guard let enumerator = fileManager.enumerator(atPath: root) else { continue }
            for case let relativePath as String in enumerator {
                guard matches(relativePath) else { continue }
                if let file = file(atPath: root + "/" + relativePath), file.modified >= modifiedSince {
                    results.append(file)
                }
            }
        }
        return results
    }

    /// One file's cache signature, or `nil` if it doesn't exist.
    static func file(atPath path: String) -> TranscriptFile? {
        guard !path.isEmpty, let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return TranscriptFile(path: path, size: (attributes[.size] as? Int) ?? -1, modified: modified)
    }

    /// A SQLite database's cache signature, covering its write-ahead log too: in WAL mode new rows
    /// land in `-wal` long before the main file changes.
    static func database(atPath path: String) -> TranscriptFile? {
        guard let main = file(atPath: path) else { return nil }
        guard let wal = file(atPath: path + "-wal") else { return main }
        return TranscriptFile(path: path, size: main.size &+ wal.size &* 1_000_003, modified: max(main.modified, wal.modified))
    }
}

/// Parsed items of each log file, reused across scans while its size and modification date are
/// unchanged (as OpenUsage does) -- a rescan then only parses files that changed, instead of
/// seconds of re-decoding a month of untouched history on every refresh cycle. Holds only the
/// files of the latest request, so it never grows past the scan window. Concurrent callers are
/// serialized, so two scanners sharing one cache parse each file once.
final class ParsedFileCache<Item>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (size: Int, modified: Date, items: [Item])] = [:]

    func items(for files: [TranscriptFile], parse: (String) -> [Item]) -> [Item] {
        lock.lock()
        defer { lock.unlock() }
        var next: [String: (size: Int, modified: Date, items: [Item])] = [:]
        var all: [Item] = []
        for file in files {
            let items: [Item]
            if let cached = entries[file.path], cached.size == file.size, cached.modified == file.modified {
                items = cached.items
            } else {
                items = parse(file.path)
            }
            next[file.path] = (file.size, file.modified, items)
            all += items
        }
        entries = next
        return all
    }
}
