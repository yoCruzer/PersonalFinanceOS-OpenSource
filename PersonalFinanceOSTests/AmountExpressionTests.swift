import XCTest
@testable import PersonalFinanceOS

final class AmountExpressionTests: XCTestCase {
    func testFourOperationsRespectPrecedenceAndDecimalPrecision() throws {
        XCTAssertEqual(try AmountExpression.evaluateMoney("10+2×3").minorUnits, 1_600)
        XCTAssertEqual(try AmountExpression.evaluateMoney("10−2÷4").minorUnits, 950)
        XCTAssertEqual(try AmountExpression.evaluateMoney("0.1+0.2").minorUnits, 30)
        XCTAssertEqual(try AmountExpression.evaluateMoney("10÷3").minorUnits, 333)
    }

    func testInvalidAndUnsafeExpressionsAreRejected() {
        for expression in ["", "1+", "1..2", "abc", "1++2"] {
            XCTAssertThrowsError(try AmountExpression.evaluateMoney(expression))
        }
        XCTAssertThrowsError(try AmountExpression.evaluateMoney("1÷0")) { error in
            XCTAssertEqual(error as? AmountExpressionError, .divisionByZero)
        }
        XCTAssertThrowsError(try AmountExpression.evaluateMoney("1−2")) { error in
            XCTAssertEqual(error as? AmountExpressionError, .nonPositiveResult)
        }
        XCTAssertThrowsError(
            try AmountExpression.evaluateMoney("999999999999999999999999999")
        )
    }

    func testKeyboardInputPreventsMultipleDecimalPointsAndReplacesOperators() {
        var expression = ""
        expression = AmountExpression.appendingDecimalPoint(to: expression)
        expression = AmountExpression.appendingDigit("5", to: expression)
        expression = AmountExpression.appendingDecimalPoint(to: expression)
        expression = AmountExpression.appendingOperator("+", to: expression)
        expression = AmountExpression.appendingOperator("×", to: expression)
        expression = AmountExpression.appendingDigit("2", to: expression)

        XCTAssertEqual(expression, "0.5×2")
        XCTAssertEqual(
            AmountExpression.deletingLastCharacter(from: expression),
            "0.5×"
        )
    }
}
