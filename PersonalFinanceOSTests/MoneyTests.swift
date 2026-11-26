import XCTest
@testable import PersonalFinanceOS

final class MoneyTests: XCTestCase {
    func testDecimalParsingUsesExactMinorUnits() throws {
        let oneTenth = try Money(decimalString: "0.1")
        let twoTenths = try Money(decimalString: "0.2")
        let largeAmount = try Money(decimalString: "123456789.09")

        XCTAssertEqual(oneTenth.minorUnits, 10)
        XCTAssertEqual(twoTenths.minorUnits, 20)
        XCTAssertEqual(oneTenth.minorUnits + twoTenths.minorUnits, 30)
        XCTAssertEqual(largeAmount.minorUnits, 12_345_678_909)
        XCTAssertEqual(largeAmount.decimalString, "123456789.09")
    }

    func testDecimalParsingRejectsInvalidAmounts() {
        XCTAssertThrowsError(try Money(decimalString: "-1.00")) { error in
            XCTAssertEqual(error as? MoneyError, .negativeAmount)
        }
        XCTAssertThrowsError(try Money(decimalString: "1.001")) { error in
            XCTAssertEqual(error as? MoneyError, .unsupportedFractionDigits)
        }
        XCTAssertThrowsError(try Money(decimalString: "one")) { error in
            XCTAssertEqual(error as? MoneyError, .invalidDecimal)
        }
        XCTAssertThrowsError(try Money(decimalString: "99999999999999999999")) { error in
            XCTAssertEqual(error as? MoneyError, .overflow)
        }
    }

    func testMinorUnitsRejectNegativeAndInvalidCurrency() {
        XCTAssertThrowsError(try Money(minorUnits: -1))
        XCTAssertThrowsError(try Money(minorUnits: 100, currencyCode: "CN"))
        XCTAssertNoThrow(try Money(minorUnits: 100, currencyCode: "cny"))
    }

    func testFormattingPreservesTwoFractionDigits() throws {
        let money = try Money(decimalString: "12.3")
        let formatted = money.formatted(locale: Locale(identifier: "en_US"))

        XCTAssertEqual(money.decimalString, "12.30")
        XCTAssertTrue(formatted.contains("12.30"))
        XCTAssertTrue(formatted.contains("CN¥") || formatted.contains("CNY"))
    }
}
