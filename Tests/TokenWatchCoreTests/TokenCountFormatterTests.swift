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
    }

    /// A count whose K-notation would round up to a full 1000 escalates to the next unit instead
    /// of ever displaying "1000.0K" -- the boundary bug this rollover check exists to prevent.
    func testCountsThatWouldRoundUpToAThousandKEscalateToMInstead() {
        XCTAssertEqual(TokenCountFormatter.compact(999_999), "1.00M")
        XCTAssertEqual(TokenCountFormatter.compact(999_950), "1.00M")
    }

    func testMillionsRoundToTwoDecimalsWithMSuffix() {
        XCTAssertEqual(TokenCountFormatter.compact(1_000_000), "1.00M")
        XCTAssertEqual(TokenCountFormatter.compact(7_400_000), "7.40M")
    }

    /// The actual improvement: past a billion, roll over to a "B" suffix instead of an
    /// ever-growing millions figure ("1234.50M") -- including a count whose M-notation would
    /// itself round up to a full 1000.
    func testBillionsRollOverInsteadOfStayingInMillions() {
        XCTAssertEqual(TokenCountFormatter.compact(1_000_000_000), "1.00B")
        XCTAssertEqual(TokenCountFormatter.compact(1_234_500_000), "1.23B")
        XCTAssertEqual(TokenCountFormatter.compact(52_000_000_000), "52.00B")
        XCTAssertEqual(TokenCountFormatter.compact(999_999_999), "1.00B")
    }

    func testIntOverloadMatchesDoubleOverload() {
        XCTAssertEqual(TokenCountFormatter.compact(1_500_000_000), TokenCountFormatter.compact(1_500_000_000.0))
    }

    func testSpelledOutTierBelowOneThousandIsRawIntegerWithTokensUnit() {
        let tier = TokenCountFormatter.spelledOutTier(350)
        XCTAssertEqual(tier.value, "350")
        XCTAssertEqual(tier.unit, "tokens")
    }

    func testSpelledOutTierPicksThousandMillionBillionByMagnitude() {
        XCTAssertEqual(TokenCountFormatter.spelledOutTier(350_000).unit, "thousand")
        XCTAssertEqual(TokenCountFormatter.spelledOutTier(350_000).value, "350.00")
        XCTAssertEqual(TokenCountFormatter.spelledOutTier(2_500_000).unit, "million")
        XCTAssertEqual(TokenCountFormatter.spelledOutTier(2_500_000).value, "2.50")
        XCTAssertEqual(TokenCountFormatter.spelledOutTier(2_500_000_000).unit, "billion")
        XCTAssertEqual(TokenCountFormatter.spelledOutTier(2_500_000_000).value, "2.50")
    }
}
