import Foundation

/// One decoded cookie from a Safari `.binarycookies` jar.
public struct SafariCookie: Sendable, Equatable {
    public let domain: String
    public let name: String
    public let value: String
}

/// Read-only parser for Safari's `~/Library/Cookies/Cookies.binarycookies` binary cookie jar
/// format (reverse-engineered, not Apple-documented). Layout:
///
/// File: `"cook"` magic (4B) + page count (4B big-endian) + page sizes (4B big-endian each) +
/// concatenated page data + trailing bplist footer (ignored).
///
/// Page (little-endian): page header (4B) + cookie count (4B) + cookie offsets (4B each,
/// relative to page start) + page footer (4B).
///
/// Cookie record (little-endian, at each offset): size (4B) + version (4B) + flags (4B) +
/// unknown (4B) + domain/name/path/value offsets (4B each, relative to record start) + end
/// marker (8B) + expiration (8B double, Mac absolute time) + creation (8B double) + NUL-
/// terminated domain/name/path/value strings.
public enum SafariCookieReader {
    public static func readCookies(path: String = NSHomeDirectory() + "/Library/Cookies/Cookies.binarycookies") -> [SafariCookie] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return parse(data)
    }

    /// Cookies whose domain matches (exactly or as a subdomain of) any of `domains`.
    public static func cookies(forDomains domains: Set<String>, path: String = NSHomeDirectory() + "/Library/Cookies/Cookies.binarycookies") -> [SafariCookie] {
        readCookies(path: path).filter { cookie in
            let normalized = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return domains.contains { target in
                normalized == target || normalized.hasSuffix("." + target)
            }
        }
    }

    static func parse(_ data: Data) -> [SafariCookie] {
        guard data.count >= 8, data.starts(with: Data("cook".utf8)) else { return [] }

        let pageCount = Int(readUInt32(data, at: 4, bigEndian: true))
        var offset = 8
        var pageSizes: [Int] = []
        for _ in 0..<pageCount {
            guard offset + 4 <= data.count else { return [] }
            pageSizes.append(Int(readUInt32(data, at: offset, bigEndian: true)))
            offset += 4
        }

        var cookies: [SafariCookie] = []
        for size in pageSizes {
            guard offset + size <= data.count, size > 0 else { break }
            let page = data.subdata(in: offset..<(offset + size))
            cookies.append(contentsOf: parsePage(page))
            offset += size
        }
        return cookies
    }

    private static func parsePage(_ page: Data) -> [SafariCookie] {
        guard page.count >= 8 else { return [] }
        let cookieCount = Int(readUInt32(page, at: 4, bigEndian: false))
        var cookies: [SafariCookie] = []
        var offsetTablePosition = 8
        for _ in 0..<cookieCount {
            guard offsetTablePosition + 4 <= page.count else { break }
            let cookieOffset = Int(readUInt32(page, at: offsetTablePosition, bigEndian: false))
            offsetTablePosition += 4
            if let cookie = parseCookieRecord(page, at: cookieOffset) {
                cookies.append(cookie)
            }
        }
        return cookies
    }

    private static func parseCookieRecord(_ page: Data, at recordStart: Int) -> SafariCookie? {
        guard recordStart >= 0, recordStart + 56 <= page.count else { return nil }

        let domainOffset = Int(readUInt32(page, at: recordStart + 16, bigEndian: false))
        let nameOffset = Int(readUInt32(page, at: recordStart + 20, bigEndian: false))
        let pathOffset = Int(readUInt32(page, at: recordStart + 24, bigEndian: false))
        let valueOffset = Int(readUInt32(page, at: recordStart + 28, bigEndian: false))

        guard let domain = readCString(page, at: recordStart + domainOffset),
              let name = readCString(page, at: recordStart + nameOffset),
              let value = readCString(page, at: recordStart + valueOffset)
        else {
            return nil
        }
        _ = pathOffset
        return SafariCookie(domain: domain, name: name, value: value)
    }

    private static func readUInt32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let bytes = data.subdata(in: offset..<(offset + 4))
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return bigEndian ? value.bigEndian : value.littleEndian
    }

    private static func readCString(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        var end = offset
        while end < data.count, data[data.startIndex + end] != 0 {
            end += 1
        }
        let slice = data.subdata(in: offset..<end)
        return String(data: slice, encoding: .utf8)
    }
}
