import XCTest
@testable import TokenWatchCore

final class ExternalKeychainReaderTests: XCTestCase {
    private func hex(_ text: String) -> String { Data(text.utf8).map { String(format: "%02x", $0) }.joined() }

    /// The partition ACL entry's description is a hex-encoded plist; `apple-tool:` in it is what
    /// lets `/usr/bin/security` read the item without a prompt. Anything malformed must read as
    /// "no partitions" (the caller then falls back to a direct read), never as a match.
    func testPartitionListIsDecodedFromHexPlist() {
        let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Partitions</key><array><string>apple-tool:</string><string>teamid:G7W32MVLF2</string></array></dict></plist>"#
        XCTAssertEqual(ExternalKeychainReader.partitions(fromHexPlist: hex(plist)), ["apple-tool:", "teamid:G7W32MVLF2"])
        XCTAssertNil(ExternalKeychainReader.partitions(fromHexPlist: "zz"))
        XCTAssertNil(ExternalKeychainReader.partitions(fromHexPlist: hex("not a plist")))
        XCTAssertNil(ExternalKeychainReader.partitions(fromHexPlist: nil))
    }
}
