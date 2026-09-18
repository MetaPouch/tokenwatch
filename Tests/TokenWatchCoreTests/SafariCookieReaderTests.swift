import XCTest
@testable import TokenWatchCore

final class SafariCookieReaderTests: XCTestCase {
    /// Builds a minimal, spec-shaped `.binarycookies` blob (one page, one cookie record) to
    /// verify the parser round-trips real-format bytes, since no live Safari cookie jar is
    /// available in this environment to test against.
    private func makeBinaryCookiesBlob(domain: String, name: String, value: String) -> Data {
        func u32LE(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u32BE(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
        func f64LE(_ v: Double) -> Data { withUnsafeBytes(of: v.bitPattern.littleEndian) { Data($0) } }
        func cString(_ s: String) -> Data { Data(s.utf8) + Data([0]) }

        let domainBytes = cString(domain)
        let nameBytes = cString(name)
        let pathBytes = cString("/")
        let valueBytes = cString(value)

        let headerSize = 56
        let domainOffset = UInt32(headerSize)
        let nameOffset = domainOffset + UInt32(domainBytes.count)
        let pathOffset = nameOffset + UInt32(nameBytes.count)
        let valueOffset = pathOffset + UInt32(pathBytes.count)
        let recordSize = UInt32(headerSize) + UInt32(domainBytes.count + nameBytes.count + pathBytes.count + valueBytes.count)

        var record = Data()
        record += u32LE(recordSize)
        record += u32LE(0) // version
        record += u32LE(0) // flags
        record += u32LE(0) // unknown
        record += u32LE(domainOffset)
        record += u32LE(nameOffset)
        record += u32LE(pathOffset)
        record += u32LE(valueOffset)
        record += Data(repeating: 0, count: 8) // end marker
        record += f64LE(700_000_000) // expiration
        record += f64LE(699_000_000) // creation
        record += domainBytes + nameBytes + pathBytes + valueBytes

        var page = Data()
        page += u32LE(0x0000_0100) // page header
        page += u32LE(1) // cookie count
        page += u32LE(16) // cookie offset within page: header(4) + count(4) + offsetTable(4) + footer(4)
        page += u32LE(0) // page footer
        page += record

        var file = Data("cook".utf8)
        file += u32BE(1) // page count
        file += u32BE(UInt32(page.count)) // page size
        file += page
        return file
    }

    func testParsesDomainNameValueFromSyntheticBlob() {
        let blob = makeBinaryCookiesBlob(domain: ".cursor.com", name: "WorkosCursorSessionToken", value: "abc123")
        let cookies = SafariCookieReader.parse(blob)

        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies[0].domain, ".cursor.com")
        XCTAssertEqual(cookies[0].name, "WorkosCursorSessionToken")
        XCTAssertEqual(cookies[0].value, "abc123")
    }

    func testDomainFilterMatchesSubdomainAndExactDomain() {
        let blob = makeBinaryCookiesBlob(domain: ".cursor.com", name: "WorkosCursorSessionToken", value: "abc123")
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? blob.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let matched = SafariCookieReader.cookies(forDomains: ["cursor.com", "cursor.sh"], path: tempFile.path)
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched.first?.name, "WorkosCursorSessionToken")

        let unmatched = SafariCookieReader.cookies(forDomains: ["example.com"], path: tempFile.path)
        XCTAssertTrue(unmatched.isEmpty)
    }

    func testEmptyForMissingOrMalformedFile() {
        XCTAssertTrue(SafariCookieReader.readCookies(path: "/nonexistent/path/Cookies.binarycookies").isEmpty)
        XCTAssertTrue(SafariCookieReader.parse(Data("not a cookie jar".utf8)).isEmpty)
    }
}
