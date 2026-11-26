import XCTest
@testable import PersonalFinanceOS

final class BillCalendarAmountFormatterTests: XCTestCase {
    func testCalendarAmountsKeepModeAndRefundSemantics() {
        let day = BillCalendarDay(date: Date(timeIntervalSince1970: 0), localDayKey: "1970-01-01",
            incomeMinorUnits: 5_000, expenseMinorUnits: -2_000, incomeCount: 1, expenseCount: 1,
            refundCount: 1, transferCount: 2, grossExpenseMinorUnits: 1_000, refundMinorUnits: 3_000)
        let expectations: [(LedgerFilter.Mode, Int64?, String)] = [
            (.all, -2_000, "支出"), (.netExpense, -2_000, "支出"),
            (.expense, 1_000, "原始支出"), (.refund, 3_000, "退款"),
            (.income, 5_000, "收入"), (.transfer, nil, "转账")
        ]
        for (mode, amount, title) in expectations {
            XCTAssertEqual(day.displayedAmount(for: mode), amount, "\(mode)")
            XCTAssertEqual(day.displayedAmountTitle(for: mode), title, "\(mode)")
        }
        XCTAssertEqual(day.transactionCount, 5)
        XCTAssertEqual(day.transferCount, 2)
        XCTAssertEqual(BillCalendarAmountFormatter.presentation(for: day.expenseMinorUnits).text, "−¥20")
        XCTAssertEqual(BillCalendarHeatmap.levels(for: [day.expenseMinorUnits]), [.none])

        let incomeDay = BillCalendarDay(date: day.date, localDayKey: day.localDayKey,
            incomeMinorUnits: 5_000, expenseMinorUnits: 0, incomeCount: 1, expenseCount: 0)
        XCTAssertEqual(incomeDay.displayedAmount(for: .all), 5_000)
        XCTAssertEqual(incomeDay.displayedAmountTitle(for: .all), "收入")
    }

    func testCalendarDistinguishesZeroAmountTransferAndEmptyDay() {
        let date = Date(timeIntervalSince1970: 0)
        let zero = BillCalendarDay(date: date, localDayKey: "1970-01-01",
            incomeMinorUnits: 0, expenseMinorUnits: 0, incomeCount: 0, expenseCount: 1,
            refundCount: 1, grossExpenseMinorUnits: 1_000, refundMinorUnits: 1_000)
        let transfer = BillCalendarDay(date: date, localDayKey: "1970-01-02",
            incomeMinorUnits: 0, expenseMinorUnits: 0, incomeCount: 0, expenseCount: 0, transferCount: 2)
        let empty = BillCalendarDay(date: date, localDayKey: "1970-01-03",
            incomeMinorUnits: 0, expenseMinorUnits: 0, incomeCount: 0, expenseCount: 0)

        XCTAssertEqual(zero.displayedAmount(for: .all), 0)
        XCTAssertEqual(zero.displayedAmount(for: .netExpense), 0)
        XCTAssertEqual(zero.transactionCount, 2)
        XCTAssertEqual(BillCalendarAmountFormatter.presentation(for: 0).text, "¥0")
        XCTAssertNil(transfer.displayedAmount(for: .all))
        XCTAssertNil(transfer.displayedAmount(for: .transfer))
        XCTAssertEqual(transfer.transferCount, 2)
        XCTAssertEqual(transfer.transactionCount, 2)
        // Net-expense mode keeps its existing zero amount even for transfer-only days.
        XCTAssertEqual(transfer.displayedAmount(for: .netExpense), 0)
        let modes: [LedgerFilter.Mode] = [.all, .netExpense, .expense, .income, .refund, .transfer]
        for mode in modes {
            XCTAssertNil(empty.displayedAmount(for: mode), "\(mode)")
        }
        XCTAssertEqual(empty.transactionCount, 0)
        XCTAssertEqual(BillCalendarHeatmap.levels(for: [0, 0, 0]), [.none, .none, .none])
    }

    func testHeatmapLeavesZeroExpensesUncolored() {
        XCTAssertEqual(BillCalendarHeatmap.levels(for: [0, 0, 0]), [.none, .none, .none])
    }

    func testHeatmapHandlesOneToThreeNonzeroDays() {
        XCTAssertEqual(BillCalendarHeatmap.levels(for: [0, 500]), [.none, .mediumLow])
        XCTAssertEqual(BillCalendarHeatmap.levels(for: [100, 200]), [.mediumLow, .high])
        XCTAssertEqual(BillCalendarHeatmap.levels(for: [100, 200, 300]), [.low, .mediumLow, .high])
    }

    func testHeatmapUsesFourDeterministicRelativeLevels() {
        XCTAssertEqual(
            BillCalendarHeatmap.levels(for: [100, 200, 300, 400]),
            [.low, .mediumLow, .mediumHigh, .high]
        )
    }

    func testHeatmapAssignsEqualExpensesTheSameVisibleLevel() {
        XCTAssertEqual(
            BillCalendarHeatmap.levels(for: [700, 700, 700]),
            [.mediumLow, .mediumLow, .mediumLow]
        )
    }

    func testHeatmapOutlierDoesNotFlattenOrdinaryExpenseDifferences() {
        let levels = BillCalendarHeatmap.levels(for: [100, 200, 300, 400, 9_999_999])
        XCTAssertEqual(levels, [.low, .low, .mediumLow, .mediumHigh, .high])
        XCTAssertGreaterThan(Set(levels.dropLast()).count, 1)
    }

    func testRoundedAndCompactAmountsAreMarkedApproximate() {
        XCTAssertEqual(BillCalendarAmountFormatter.presentation(for: 53_983).text, "≈¥540")
        XCTAssertEqual(BillCalendarAmountFormatter.presentation(for: 48_927).text, "≈¥489")
        XCTAssertEqual(BillCalendarAmountFormatter.presentation(for: 183_367).text, "≈¥1.8K")
    }

    func testLosslesslyDisplayedWholeYuanIsNotMarkedApproximate() {
        let presentation = BillCalendarAmountFormatter.presentation(for: 54_000)

        XCTAssertEqual(presentation.text, "¥540")
        XCTAssertFalse(presentation.isApproximate)
    }

    func testNegativeAmountKeepsItsSignAndDoesNotChangeMinorUnits() {
        let minorUnits: Int64 = -53_983
        let presentation = BillCalendarAmountFormatter.presentation(for: minorUnits)

        XCTAssertEqual(presentation.text, "−≈¥540")
        XCTAssertEqual(minorUnits, -53_983)
    }
}
