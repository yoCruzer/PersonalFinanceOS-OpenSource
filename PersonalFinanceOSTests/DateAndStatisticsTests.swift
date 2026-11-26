import XCTest
@testable import PersonalFinanceOS

final class DateAndStatisticsTests: XCTestCase {
    func testLocalDayCapturesHistoricalTimeZoneSemantics() {
        let instant = Date(timeIntervalSince1970: 1_704_067_800)
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

        let historicalKey = LocalDayKey.make(for: instant, timeZone: shanghai)
        let otherZoneKey = LocalDayKey.make(for: instant, timeZone: losAngeles)

        XCTAssertEqual(historicalKey, "2024-01-01")
        XCTAssertEqual(otherZoneKey, "2023-12-31")
        XCTAssertEqual(historicalKey, "2024-01-01")
        XCTAssertTrue(LocalDayKey.isValid(historicalKey))
        XCTAssertFalse(LocalDayKey.isValid("2024-02-30"))
    }

    func testStatisticsFollowFrozenNetExpenseRules() {
        let accountID = UUID()
        let categoryID = UUID()
        let expense = makeTransaction(
            type: .expense,
            amount: 10_000,
            currency: "CNY",
            accountID: accountID,
            categoryID: categoryID
        )
        let refund = makeTransaction(
            type: .refund,
            amount: 2_500,
            currency: "CNY",
            accountID: accountID,
            categoryID: categoryID
        )
        let income = makeTransaction(
            type: .income,
            amount: 50_000,
            currency: "CNY",
            accountID: accountID,
            categoryID: UUID()
        )
        let transfer = makeTransaction(
            type: .transfer,
            amount: 3_000,
            currency: "CNY",
            accountID: accountID
        )
        let usdExpense = makeTransaction(
            type: .expense,
            amount: 99_000,
            currency: "USD",
            accountID: UUID(),
            categoryID: categoryID
        )
        let deletedExpense = makeTransaction(
            type: .expense,
            amount: 8_000,
            currency: "CNY",
            accountID: accountID,
            categoryID: categoryID
        )
        deletedExpense.softDelete()

        let transactions = [
            expense,
            refund,
            income,
            transfer,
            usdExpense,
            deletedExpense
        ]

        XCTAssertEqual(
            StatisticsFoundation.netExpenseMinorUnits(for: transactions),
            7_500
        )
        XCTAssertEqual(
            StatisticsFoundation.netExpenseMinorUnits(
                for: transactions,
                categoryID: categoryID
            ),
            7_500
        )
        XCTAssertEqual(
            StatisticsFoundation.netExpenseMinorUnits(
                for: transactions,
                localDayKey: "2099-01-01"
            ),
            0
        )
    }

    func testCalendarUsesNetExpenseIncludingRefundAndExcludesTransfer() {
        let date = Date(timeIntervalSince1970: 1_704_067_800)
        let accountID = UUID()
        let days = BillCalendarService.days(
            in: date,
            transactions: [
                FinanceTransaction(type: .expense, amountMinorUnits: 1_000, occurredAt: date, localDayKey: "2024-01-01", timeZoneIdentifier: "Asia/Shanghai", accountID: accountID),
                FinanceTransaction(type: .refund, amountMinorUnits: 250, occurredAt: date, localDayKey: "2024-01-01", timeZoneIdentifier: "Asia/Shanghai", accountID: accountID),
                FinanceTransaction(type: .transfer, amountMinorUnits: 9_999, occurredAt: date, localDayKey: "2024-01-01", timeZoneIdentifier: "Asia/Shanghai", accountID: accountID, destinationAccountID: UUID())
            ]
        )
        let day = try! XCTUnwrap(days.compactMap { $0 }.first { $0.localDayKey == "2024-01-01" })

        XCTAssertEqual(day.expenseMinorUnits, 750)
        XCTAssertEqual(day.transactionCount, 2)
        XCTAssertEqual(day.balanceMinorUnits, -750)
    }

    private func makeTransaction(
        type: TransactionType,
        amount: Int64,
        currency: String,
        accountID: UUID,
        categoryID: UUID? = nil
    ) -> FinanceTransaction {
        let date = Date(timeIntervalSince1970: 1_704_067_800)
        return FinanceTransaction(
            type: type,
            amountMinorUnits: amount,
            currencyCode: currency,
            occurredAt: date,
            localDayKey: "2024-01-01",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: accountID,
            destinationAccountID: type == .transfer ? UUID() : nil,
            categoryID: categoryID
        )
    }
}
