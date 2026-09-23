import Foundation

/// A log file found by `TranscriptFiles`, with what `ParsedFileCache` keys its reuse on.
struct TranscriptFile: Sendable {
    let path: String
    let size: Int
    let modified: Date
}

enum TranscriptFiles {
    /// Every `.jsonl` under `roots`, recursively, modified at or after `modifiedSince`.
    static func recursive(roots: [String], modifiedSince: Date) -> [TranscriptFile] {
        let fileManager = FileManager.default
        var results: [TranscriptFile] = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(atPath: root) else { continue }
            for case let relativePath as String in enumerator {
                guard relativePath.hasSuffix(".jsonl") else { continue }
                let fullPath = root + "/" + relativePath
                guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath),
                      let modified = attributes[.modificationDate] as? Date,
                      modified >= modifiedSince
                else { continue }
                results.append(TranscriptFile(path: fullPath, size: (attributes[.size] as? Int) ?? -1, modified: modified))
            }
        }
        return results
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
