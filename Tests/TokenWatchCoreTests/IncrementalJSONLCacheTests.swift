import XCTest
@testable import TokenWatchCore

final class IncrementalJSONLCacheTests: XCTestCase {
    private struct Record: Decodable {
        let value: Int
    }

    private var root: URL!
    private var file: URL { root.appendingPathComponent("usage.jsonl") }
    private var cache: IncrementalJSONLCache<Int, Int>!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cache = IncrementalJSONLCache(makeState: { 0 }) { total, data in
            data.split(separator: 0x0A).compactMap { line in
                guard let record = try? JSONDecoder().decode(Record.self, from: line) else { return nil }
                total += record.value
                return total
            }
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
        cache = nil
    }

    private func scan() -> [Int] {
        cache.items(for: TranscriptFiles.recursive(roots: [root.path], modifiedSince: .distantPast))
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func rewrite(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testPartialRecordAndValidEOFRemainSpeculativeUntilNewline() throws {
        try Data("{\"value\":1}\n{\"value\":".utf8).write(to: file)
        XCTAssertEqual(scan(), [1])
        try append("2}")
        XCTAssertEqual(scan(), [1, 3])
        XCTAssertEqual(scan(), [1, 3])
        try append("\n{\"value\":3}\n")
        XCTAssertEqual(scan(), [1, 3, 6])
        XCTAssertEqual(scan(), [1, 3, 6])
    }

    func testValidEOFLaterBecomingMalformedDoesNotCommitState() throws {
        try Data("{\"value\":1}\n{\"value\":2}".utf8).write(to: file)
        XCTAssertEqual(scan(), [1, 3])
        try append("garbage\n{\"value\":4}\n")
        XCTAssertEqual(scan(), [1, 5])
    }

    func testTruncationAndRegrowthDiscardOldHistory() throws {
        try Data("{\"value\":1}\n{\"value\":2}\n".utf8).write(to: file)
        XCTAssertEqual(scan(), [1, 3])
        try rewrite("{\"value\":4}\n")
        XCTAssertEqual(scan(), [4])
        try rewrite("{\"value\":5}\n{\"value\":6}\n")
        XCTAssertEqual(scan(), [5, 11])
    }

    func testSameSizeRewriteWithRestoredModificationDateInvalidatesHistory() throws {
        try Data("{\"value\":1}\n".utf8).write(to: file)
        let modified = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        XCTAssertEqual(scan(), [1])
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("{\"value\":9}\n".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        XCTAssertEqual(scan(), [9])
    }

    func testAtomicReplacementWithMatchingSizeAndDateInvalidatesHistory() throws {
        try Data("{\"value\":1}\n".utf8).write(to: file)
        let modified = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        XCTAssertEqual(scan(), [1])
        try Data("{\"value\":8}\n".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        XCTAssertEqual(scan(), [8])
        try append("{\"value\":2}\n")
        XCTAssertEqual(scan(), [8, 10])
    }
}
