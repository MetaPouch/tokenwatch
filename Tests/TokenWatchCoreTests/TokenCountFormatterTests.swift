import XCTest
@testable import TokenWatchCore

final class TokenCountFormatterTests: XCTestCase {
    func testBelowOneThousandIsRawInteger() {
        XCTAssertEqual(TokenCountFormatter.compact(0), "0")
        XCTAssertEqual(TokenCountFormatter.compact(999), "999")
    }

    func testThousandsRoundToOneDecimalWithKSuffix() {
        XCTAssertEqual(TokenCountFormatter.compact(1_000), "1.0K")
        XCTAssertEqual(TokenCountFormatter.compact(5_000), "5.0K")
        XCTAssertEqual(TokenCountFormatter.compact(651_000), "651.0K")
        XCTAssertEqual(TokenCountFormatter.compact(999_999), "1000.0K")
    }

    func testMillionsRoundToOneDecimalWithMSuffix() {
        XCTAssertEqual(TokenCountFormatter.compact(1_000_000), "1.0M")
        XCTAssertEqual(TokenCountFormatter.compact(7_400_000), "7.4M")
        XCTAssertEqual(TokenCountFormatter.compact(999_999_999), "1000.0M")
    }

    /// The actual improvement: past a billion, roll over to a "B" suffix instead of an
    /// ever-growing millions figure ("1234.5M").
    func testBillionsRollOverInsteadOfStayingInMillions() {
        XCTAssertEqual(TokenCountFormatter.compact(1_000_000_000), "1.0B")
        XCTAssertEqual(TokenCountFormatter.compact(1_234_500_000), "1.2B")
        XCTAssertEqual(TokenCountFormatter.compact(52_000_000_000), "52.0B")
    }

    func testIntOverloadMatchesDoubleOverload() {
        XCTAssertEqual(TokenCountFormatter.compact(1_500_000_000), TokenCountFormatter.compact(1_500_000_000.0))
    }
}
