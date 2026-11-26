import XCTest
@testable import PersonalFinanceOS

final class FinanceInsightsServiceTests: XCTestCase {
    func testMonthSelectionChoosesNearestPointAndItsDisplayedValue() {
        let months = (1...6).map { date(year: 2026, month: $0) }
        let selection = calendar.date(from: DateComponents(
            year: 2026,
            month: 4,
            day: 10
        ))!

        let index = MonthTrendSelectionService.nearestIndex(to: selection, in: months)

        XCTAssertEqual(index, 3)
        let selected = trendPoint(month: index! + 1, expense: 12_345)
        XCTAssertEqual(selected.monthKey, "2026-04")
        XCTAssertEqual(selected.expenseMinorUnits, 12_345)
    }

    func testMonthSelectionHandlesNoSelectionAndEmptyData() {
        XCTAssertNil(MonthTrendSelectionService.nearestIndex(to: nil, in: [Date()]))
        XCTAssertNil(MonthTrendSelectionService.nearestIndex(to: Date(), in: []))
    }

    func testExpenseTrendSummaryCalculatesAverageAndDistinctExtremes() {
        let points = [100, 300, 200, 600, 400, 500].enumerated().map { index, value in
            trendPoint(month: index + 1, expense: Int64(value))
        }
        let summary = ExpenseTrendSummaryService.summarize(points)

        XCTAssertEqual(summary.averageMinorUnits, 350)
        XCTAssertEqual(summary.minimum?.expenseMinorUnits, 100)
        XCTAssertEqual(summary.maximum?.expenseMinorUnits, 600)
    }

    func testExpenseTrendSummaryAvoidsMeaninglessZeroAndEqualExtremes() {
        let zero = ExpenseTrendSummaryService.summarize(
            (1...6).map { trendPoint(month: $0, expense: 0) }
        )
        XCTAssertEqual(zero.averageMinorUnits, 0)
        XCTAssertNil(zero.minimum)
        XCTAssertNil(zero.maximum)

        let equal = ExpenseTrendSummaryService.summarize(
            (1...6).map { trendPoint(month: $0, expense: 900) }
        )
        XCTAssertEqual(equal.averageMinorUnits, 900)
        XCTAssertNil(equal.minimum)
        XCTAssertEqual(equal.maximum?.expenseMinorUnits, 900)
    }

    func testExpenseTrendSummaryAverageDoesNotOverflow() {
        let points = (1...6).map { trendPoint(month: $0, expense: .max) }
        XCTAssertEqual(
            ExpenseTrendSummaryService.summarize(points).averageMinorUnits,
            Int64.max
        )
    }

    func testMonthlyTrendKeepsSignedPointsWhenRefundExceedsExpense() {
        let july = date(year: 2026, month: 7)
        let categoryID = UUID()
        let values = FinanceInsightsService.trend(
            for: [
                transaction(type: .expense, amount: 100, day: "2026-07-01", categoryID: categoryID),
                transaction(type: .refund, amount: 300, day: "2026-07-02", categoryID: categoryID)
            ],
            endingAt: july
        )
        XCTAssertEqual(values.count, 6)
        XCTAssertTrue(values.allSatisfy { $0.incomeMinorUnits >= 0 })
        XCTAssertEqual(values.last?.expenseMinorUnits, -200)
    }

    func testCompleteTrendWindowExcludesUnknownAndUnfinishedMonthsButKeepsEmptyMonths() {
        let points = (1...6).map { trendPoint(month: $0, expense: $0 == 4 ? 0 : 100) }
        let now = date(year: 2026, month: 6)
        let complete = ExpenseTrendSummaryService.completeMonths(points, earliestKnownDay: "2026-02-20", now: now, calendar: calendar)
        XCTAssertEqual(complete.map(\.monthKey), ["2026-03", "2026-04", "2026-05"])
        XCTAssertEqual(ExpenseTrendSummaryService.summarize(complete).averageMinorUnits, 66)
        XCTAssertTrue(ExpenseTrendSummaryService.completeMonths(points, earliestKnownDay: nil, now: now, calendar: calendar).isEmpty)
    }

    func testRefundOnlyAndFullyRefundedCategoriesRemainVisibleWithoutClamping() {
        let id = UUID()
        for (gross, refund, expected) in [(0, 500, -500), (500, 500, 0), (500, 200, 300), (500, 0, 500)] {
            var values: [FinanceTransaction] = []
            if gross > 0 { values.append(transaction(type: .expense, amount: Int64(gross), day: "2026-07-01", categoryID: id)) }
            if refund > 0 { values.append(transaction(type: .refund, amount: Int64(refund), day: "2026-07-02", categoryID: id)) }
            let snapshot = FinanceInsightsService.snapshot(for: values, selectedMonth: date(year: 2026, month: 7), categories: [], calendar: calendar)
            XCTAssertEqual(snapshot.categorySpending.count, 1)
            XCTAssertEqual(snapshot.categorySpending.first?.amountMinorUnits, Int64(expected))
            XCTAssertEqual(snapshot.categorySpending.first?.transactionCount, values.count)
            XCTAssertEqual(snapshot.summary.expenseMinorUnits, Int64(expected))
            XCTAssertEqual(snapshot.trend.last?.expenseMinorUnits, Int64(expected))
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    func testSummaryUsesExactIncomeExpenseRefundAndBalanceSemantics() {
        let categoryID = UUID()
        let transactions = [
            transaction(type: .income, amount: 10_001, day: "2026-07-01", categoryID: UUID()),
            transaction(type: .expense, amount: 3_333, day: "2026-07-02", categoryID: categoryID),
            transaction(type: .refund, amount: 333, day: "2026-07-03", categoryID: categoryID),
            transaction(type: .transfer, amount: 50_000, day: "2026-07-04", categoryID: nil),
            transaction(type: .expense, amount: 9_999, day: "2026-06-30", categoryID: categoryID)
        ]
        let month = date(year: 2026, month: 7)

        XCTAssertEqual(
            FinanceInsightsService.summary(
                for: transactions,
                month: month,
                calendar: calendar
            ),
            FinanceMonthSummary(
                incomeMinorUnits: 10_001,
                expenseMinorUnits: 3_000,
                balanceMinorUnits: 7_001
            )
        )
    }

    func testCategorySpendingIncludesOtherAndExcludesDeletedAndIncome() {
        let diningID = UUID()
        let otherID = UUID()
        let deleted = transaction(
            type: .expense,
            amount: 99_999,
            day: "2026-07-04",
            categoryID: diningID
        )
        deleted.softDelete()
        let transactions = [
            transaction(type: .expense, amount: 2_500, day: "2026-07-01", categoryID: otherID),
            transaction(type: .expense, amount: 1_000, day: "2026-07-02", categoryID: diningID),
            transaction(type: .refund, amount: 200, day: "2026-07-03", categoryID: otherID),
            transaction(type: .income, amount: 50_000, day: "2026-07-03", categoryID: UUID()),
            deleted
        ]

        XCTAssertEqual(
            FinanceInsightsService.categorySpending(
                for: transactions,
                month: date(year: 2026, month: 7),
                calendar: calendar
            ),
            [
                CategorySpending(categoryID: otherID, amountMinorUnits: 2_300, transactionCount: 2),
                CategorySpending(categoryID: diningID, amountMinorUnits: 1_000, transactionCount: 1)
            ]
        )
    }

    func testTrendIsOldestToNewestAndIncludesEmptyMonths() {
        let categoryID = UUID()
        let transactions = [
            transaction(type: .expense, amount: 100, day: "2026-03-01", categoryID: categoryID),
            transaction(type: .income, amount: 500, day: "2026-05-01", categoryID: UUID()),
            transaction(type: .expense, amount: 200, day: "2026-07-01", categoryID: categoryID)
        ]

        let trend = FinanceInsightsService.trend(
            for: transactions,
            endingAt: date(year: 2026, month: 7),
            count: 6,
            calendar: calendar
        )

        XCTAssertEqual(trend.map(\.monthKey), [
            "2026-02", "2026-03", "2026-04", "2026-05", "2026-06", "2026-07"
        ])
        XCTAssertEqual(trend.map(\.expenseMinorUnits), [0, 100, 0, 0, 0, 200])
        XCTAssertEqual(trend.map(\.incomeMinorUnits), [0, 0, 0, 500, 0, 0])
    }

    func testSnapshotUsesRefundAndTransferSemanticsAcrossEveryMetric() {
        let categoryID = UUID()
        let month = date(year: 2026, month: 7)
        let snapshot = FinanceInsightsService.snapshot(
            for: [
                transaction(type: .income, amount: 5_000, day: "2026-07-01", categoryID: UUID()),
                transaction(type: .expense, amount: 2_000, day: "2026-07-02", categoryID: categoryID),
                transaction(type: .refund, amount: 500, day: "2026-07-03", categoryID: categoryID),
                transaction(type: .transfer, amount: 9_999, day: "2026-07-04", categoryID: nil)
            ],
            selectedMonth: month,
            categories: [],
            calendar: calendar
        )

        XCTAssertEqual(snapshot.summary.expenseMinorUnits, 1_500)
        XCTAssertEqual(snapshot.summary.incomeMinorUnits, 5_000)
        XCTAssertEqual(snapshot.summary.balanceMinorUnits, 3_500)
        XCTAssertEqual(snapshot.categorySpending, [
            CategorySpending(categoryID: categoryID, amountMinorUnits: 1_500, transactionCount: 2)
        ])
        XCTAssertEqual(snapshot.trend.last?.expenseMinorUnits, 1_500)
        XCTAssertEqual(snapshot.activity.totalCount, 4)
    }

    func testPopulatedMonthTransitionKeepsBoundedTrendAndTextIconAggregation() {
        let transport = Category(
            kind: .expense,
            name: "交通",
            symbolName: "car",
            colorToken: "teal",
            sortOrder: 0
        )
        let subway = Category(
            kind: .expense,
            name: "地铁",
            parentID: transport.id,
            symbolName: "text:地铁",
            colorToken: "teal",
            sortOrder: 0
        )
        let categories = [transport, subway]
        let transactions = [
            transaction(type: .income, amount: 50_000, day: "2026-08-01", categoryID: UUID()),
            transaction(type: .expense, amount: 600, day: "2026-08-02", categoryID: subway.id),
            transaction(type: .income, amount: 48_000, day: "2026-07-01", categoryID: UUID()),
            transaction(type: .expense, amount: 500, day: "2026-07-02", categoryID: subway.id)
        ]

        let august = FinanceInsightsService.snapshot(
            for: transactions,
            selectedMonth: date(year: 2026, month: 8),
            categories: categories,
            calendar: calendar
        )
        let july = FinanceInsightsService.snapshot(
            for: transactions,
            selectedMonth: date(year: 2026, month: 7),
            categories: categories,
            calendar: calendar
        )

        XCTAssertEqual(august.selectedMonth, date(year: 2026, month: 8))
        XCTAssertEqual(july.selectedMonth, date(year: 2026, month: 7))
        XCTAssertEqual(august.trend.count, 6)
        XCTAssertEqual(july.trend.count, 6)
        XCTAssertEqual(july.trend.last?.expenseMinorUnits, 500)
        XCTAssertEqual(
            july.categoryTrend(for: subway.id, categories: categories).last?.amountMinorUnits,
            500
        )
        XCTAssertEqual(
            july.categoryTrend(for: transport.id, categories: categories).last?.amountMinorUnits,
            500
        )
    }

    private func date(year: Int, month: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1))!
    }

    private func trendPoint(month: Int, expense: Int64) -> MonthlyTrendPoint {
        MonthlyTrendPoint(
            monthKey: String(format: "2026-%02d", month),
            month: date(year: 2026, month: month),
            incomeMinorUnits: 0,
            expenseMinorUnits: expense
        )
    }

    private func transaction(
        type: TransactionType,
        amount: Int64,
        day: String,
        categoryID: UUID?
    ) -> FinanceTransaction {
        let occurredAt = ISO8601DateFormatter().date(from: "\(day)T12:00:00+08:00")!
        return FinanceTransaction(
            type: type,
            amountMinorUnits: amount,
            occurredAt: occurredAt,
            localDayKey: day,
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: UUID(),
            destinationAccountID: type == .transfer ? UUID() : nil,
            categoryID: categoryID,
            createdAt: occurredAt
        )
    }
}
