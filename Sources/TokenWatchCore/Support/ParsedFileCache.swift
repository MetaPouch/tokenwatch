import Foundation
import Darwin

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

/// Incremental JSONL history, serialized across callers and bounded to the latest scan's files.
/// State must have value semantics: an unterminated final record is parsed against a copy, so a
/// valid EOF record remains visible without committing parser state until its newline arrives.
final class ParsedFileCache<Item, State>: @unchecked Sendable {
    private struct Snapshot: Equatable {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int
        let size: Int
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init?(_ descriptor: Int32) {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_size >= 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            birthSeconds = info.st_birthtimespec.tv_sec
            birthNanoseconds = info.st_birthtimespec.tv_nsec
            size = Int(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }

        func isSameFile(as other: Snapshot) -> Bool {
            device == other.device && inode == other.inode
                && birthSeconds == other.birthSeconds && birthNanoseconds == other.birthNanoseconds
        }
    }

    private struct Entry {
        var snapshot: Snapshot
        var state: State
        var items: [Item] = []
        var tail = Data()
        var provisionalItems: [Item] = []
        var prefix = Data()
        var suffix = Data()
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let makeState: () -> State
    private let parse: (inout State, Data) -> [Item]
    private static var anchorSize: Int { 4096 }

    init(makeState: @escaping () -> State, parse: @escaping (inout State, Data) -> [Item]) {
        self.makeState = makeState
        self.parse = parse
    }

    func items(for files: [TranscriptFile]) -> [Item] {
        lock.lock()
        defer { lock.unlock() }
        let paths = Set(files.map(\.path))
        entries = entries.filter { paths.contains($0.key) }
        var all: [Item] = []
        for file in files {
            refresh(path: file.path)
            if let entry = entries[file.path] {
                all += entry.items
                all += entry.provisionalItems
            }
        }
        return all
    }

    private func refresh(path: String) {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
        defer { try? handle.close() }
        guard let snapshot = Snapshot(handle.fileDescriptor) else { return }
        if entries[path]?.snapshot == snapshot { return }

        do {
            var append = false
            if let previous = entries[path], snapshot.isSameFile(as: previous.snapshot),
               snapshot.size > previous.snapshot.size {
                // A truncate-and-regrow between scans can look like an append. Check bounded
                // anchors rather than rereading the entire historical prefix on every write.
                // An in-place middle edit combined with growth and unchanged anchors cannot be
                // distinguished from an append without rereading history; these logs append.
                let prefix = try read(handle, offset: 0, count: previous.prefix.count)
                let suffix = try read(handle, offset: previous.snapshot.size - previous.suffix.count, count: previous.suffix.count)
                append = prefix == previous.prefix && suffix == previous.suffix
            }
            let offset = append ? entries[path]!.snapshot.size : 0
            let bytes = try read(handle, offset: offset, count: snapshot.size - offset)
            let prefix: Data
            let suffix: Data
            if append, let previous = entries[path] {
                prefix = previous.prefix.count == Self.anchorSize
                    ? previous.prefix
                    : previous.prefix + bytes.prefix(Self.anchorSize - previous.prefix.count)
                suffix = bytes.count >= Self.anchorSize
                    ? Data(bytes.suffix(Self.anchorSize))
                    : Data(previous.suffix.suffix(Self.anchorSize - bytes.count)) + bytes
            } else {
                prefix = Data(bytes.prefix(Self.anchorSize))
                suffix = Data(bytes.suffix(Self.anchorSize))
            }

            // Do not advance the cursor or parser after short reads, a concurrent write, or a
            // rename over this path. The next scan retries from the last committed snapshot.
            guard Snapshot(handle.fileDescriptor) == snapshot,
                  let current = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            else { return }
            let currentSnapshot = Snapshot(current.fileDescriptor)
            try? current.close()
            guard currentSnapshot == snapshot else { return }

            var entry = append ? entries.removeValue(forKey: path)! : Entry(snapshot: snapshot, state: makeState())
            var pending = entry.tail
            pending.append(bytes)
            if let newline = pending.lastIndex(of: 0x0A) {
                entry.items += parse(&entry.state, Data(pending[...newline]))
                entry.tail = Data(pending[pending.index(after: newline)...])
            } else {
                entry.tail = pending
            }
            var previewState = entry.state
            entry.provisionalItems = entry.tail.isEmpty ? [] : parse(&previewState, entry.tail)
            entry.snapshot = snapshot
            entry.prefix = prefix
            entry.suffix = suffix
            entries[path] = entry
        } catch {
            // Keep the prior cursor and results so transient read failures cannot lose turns.
        }
    }

    private func read(_ handle: FileHandle, offset: Int, count: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        var result = Data()
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                throw CocoaError(.fileReadUnknown)
            }
            result.append(chunk)
        }
        return result
    }
}
