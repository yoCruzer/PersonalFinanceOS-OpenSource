import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class LedgerRefundDrilldownTests: XCTestCase {
    func testCalendarCellAmountAndLabelFollowActualQueryMode() {
        let day = BillCalendarDay(date: Date(timeIntervalSince1970: 0), localDayKey: "1970-01-01",
            incomeMinorUnits: 50000, expenseMinorUnits: -1000, incomeCount: 1, expenseCount: 3,
            refundCount: 3, transferCount: 1, grossExpenseMinorUnits: 13000, refundMinorUnits: 14000)
        XCTAssertEqual(day.displayedAmount(for: .all), -1000)
        XCTAssertEqual(day.displayedAmount(for: .netExpense), -1000)
        XCTAssertEqual(day.displayedAmount(for: .expense), 13000)
        XCTAssertEqual(day.displayedAmount(for: .refund), 14000)
        XCTAssertEqual(day.displayedAmountTitle(for: .refund), "退款")
        XCTAssertEqual(day.displayedAmount(for: .income), 50000)
        XCTAssertNil(day.displayedAmount(for: .transfer))
    }

    func testLocalDayRangeTitleUsesMonthAndInclusiveEndWithoutTimezoneShift() {
        let locale = Locale(identifier: "zh_CN")
        let month = LedgerFilter(dateRange: LocalDayRange(lowerBound: "2026-10-01", upperBound: "2026-11-01"))
        XCTAssertFalse(month.dateTitle(locale: locale).contains("至"))
        XCTAssertTrue(month.dateTitle(locale: locale).contains("10月"))
        let custom = LedgerFilter(dateRange: LocalDayRange(lowerBound: "2026-10-02", upperBound: "2026-10-06"))
        XCTAssertTrue(custom.dateTitle(locale: locale).contains("5日"))
        XCTAssertFalse(custom.dateTitle(locale: locale).contains("6日"))
        XCTAssertEqual(LedgerFilter(dateRange: nil).dateTitle(locale: locale), "全部历史")
    }

    func testRefundEditCategoryAndCopiedDraftSaveKeepRefundSemantics() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        let account = Account(name: "合成现金", type: .cash, currencyCode: "CNY")
        let first = Category(kind: .expense, name: "合成旧类", symbolName: "bag", colorToken: "blue")
        let second = Category(kind: .expense, name: "合成新类", symbolName: "bag", colorToken: "green")
        context.insert(account)
        [first, second].forEach { context.insert($0) }
        try context.save()
        var draft = TransactionDraft()
        draft.type = .refund
        draft.amountText = "30"
        draft.accountID = account.id
        draft.categoryID = first.id
        draft.occurredAt = ISO8601DateFormatter().date(from: "2026-10-02T12:00:00Z")!
        draft.timeZoneIdentifier = "GMT"
        let refund = try TransactionLifecycleService.save(draft: draft, accounts: [account], categories: [first, second], in: context)
        var edit = TransactionDraft(transaction: refund)
        edit.note = "合成退款修改"
        edit.categoryID = second.id
        _ = try TransactionLifecycleService.save(draft: edit, editing: refund, accounts: [account], categories: [first, second], in: context)
        struct FixedDate: DateProvider { let date: Date; func now() -> Date { date } }
        let copy = TransactionDuplicationService.makeDraft(from: refund, dateProvider: FixedDate(date: draft.occurredAt), timeZone: TimeZone(secondsFromGMT: 0)!)
        let copied = try TransactionLifecycleService.save(draft: copy, accounts: [account], categories: [first, second], in: context)
        XCTAssertNotEqual(copied.id, refund.id)
        XCTAssertEqual(copied.type, .refund)
        XCTAssertEqual(refund.type, .refund)
        XCTAssertEqual(copied.categoryID, second.id)
        XCTAssertEqual(copied.note, edit.note)
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let result = try await actor.snapshot(filter: LedgerFilter.month(draft.occurredAt))
        XCTAssertEqual(result.totals.grossExpenseMinorUnits, 0)
        XCTAssertEqual(result.totals.refundMinorUnits, 6_000)
        XCTAssertEqual(result.totals.netExpenseMinorUnits, -6_000)
        XCTAssertNil(result.directCategoryTotals[first.id])
        XCTAssertEqual(result.directCategoryTotals[second.id]?.refundCount, 2)
    }

    func testBuild21SignedAnalysisAgreesWithCompleteDetailsAndOriginalMonth() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        let dining = Category(kind: .expense, name: "合成餐饮", symbolName: "fork.knife", colorToken: "orange")
        let meal = Category(kind: .expense, name: "合成正餐", parentID: dining.id, symbolName: "fork.knife", colorToken: "orange")
        let transit = Category(kind: .expense, name: "合成交通", symbolName: "bus", colorToken: "blue")
        let shopping = Category(kind: .expense, name: "合成购物", symbolName: "bag", colorToken: "green")
        shopping.isHidden = true
        shopping.archivedAt = Date(timeIntervalSince1970: 1)
        [dining, meal, transit, shopping].forEach { context.insert($0) }
        let rows: [(String, TransactionType, UUID?, Int64)] = [
            ("2026-09-20", .expense, meal.id, 10_000),
            ("2026-10-02", .refund, meal.id, 3_000),
            ("2026-10-03", .expense, meal.id, 8_000),
            ("2026-10-03", .refund, meal.id, 2_000),
            ("2026-10-04", .expense, transit.id, 4_000),
            ("2026-10-04", .refund, shopping.id, 9_000),
            ("2026-10-05", .income, nil, 50_000),
            ("2026-10-05", .transfer, nil, 30_000),
            ("2026-10-02", .expense, dining.id, 1_000)
        ]
        for (day, type, category, amount) in rows {
            let date = ISO8601DateFormatter().date(from: day + "T12:00:00Z")!
            context.insert(FinanceTransaction(type: type, amountMinorUnits: amount, occurredAt: date,
                localDayKey: day, timeZoneIdentifier: "GMT", accountID: UUID(),
                destinationAccountID: type == .transfer ? UUID() : nil, categoryID: category))
        }
        try context.save()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let october = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let analysis = try await actor.snapshot(filter: .sixMonths(endingAt: october, calendar: calendar), pageSize: 1)
        let display = FinanceInsightsSnapshot.from(analysis, selectedMonth: october, calendar: calendar)
        let totals = try XCTUnwrap(analysis.monthTotals["2026-10"])
        XCTAssertEqual(totals.grossExpenseMinorUnits, 13_000)
        XCTAssertEqual(totals.refundMinorUnits, 14_000)
        XCTAssertEqual(totals.netExpenseMinorUnits, -1_000)
        XCTAssertEqual(totals.balanceMinorUnits, 51_000)
        XCTAssertEqual(totals.averageExpenseMinorUnits, 4_333)
        XCTAssertEqual(totals.totalCount, 8)
        XCTAssertEqual(display.categorySpending.reduce(0) { $0 + $1.amountMinorUnits }, -1_000)
        XCTAssertEqual(display.categorySpending.first { $0.categoryID == dining.id }?.amountMinorUnits, 4_000)
        XCTAssertEqual(display.categorySpending.first { $0.categoryID == shopping.id }?.amountMinorUnits, -9_000)
        XCTAssertEqual(display.categorySpending.reduce(0) { $0 + $1.transactionCount }, 6)
        XCTAssertEqual(display.trend.last?.expenseMinorUnits, -1_000)
        XCTAssertEqual(analysis.monthTotals["2026-09"]?.netExpenseMinorUnits, 10_000)
        for item in display.categorySpending {
            var filter = LedgerFilter.month(october, calendar: calendar)
            filter.mode = .netExpense
            filter.category = item.categoryID.map { .node($0) } ?? .uncategorized
            let details = try await actor.snapshot(filter: filter, pageSize: 1)
            XCTAssertEqual(details.totals.netExpenseMinorUnits, item.amountMinorUnits)
            XCTAssertEqual(details.totals.totalCount, item.transactionCount)
            let csv = try await actor.exportData(snapshot: details)
            XCTAssertEqual(String(decoding: csv, as: UTF8.self).components(separatedBy: "\r\n").count, details.totals.totalCount + 1)
        }
    }

    func testOriginalExpenseEditDoesNotMoveLinkedRefundCategoryOrMonth() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        let account = Account(name: "合成账户", type: .cash, currencyCode: "CNY")
        let oldRoot = Category(kind: .expense, name: "旧组", symbolName: "folder", colorToken: "blue")
        let oldChild = Category(kind: .expense, name: "旧子类", parentID: oldRoot.id, symbolName: "folder", colorToken: "blue")
        let newRoot = Category(kind: .expense, name: "新组", symbolName: "folder", colorToken: "green")
        let newChild = Category(kind: .expense, name: "新子类", parentID: newRoot.id, symbolName: "folder", colorToken: "green")
        let legacyIncome = Category(kind: .income, name: "退款", symbolName: "arrow.uturn.backward", colorToken: "green")
        let categories = [oldRoot, oldChild, newRoot, newChild, legacyIncome]
        context.insert(account)
        categories.forEach { context.insert($0) }
        try context.save()
        func save(_ type: TransactionType, _ amount: String, _ date: String, _ categoryID: UUID) throws -> FinanceTransaction {
            var draft = TransactionDraft()
            draft.type = type
            draft.amountText = amount
            draft.accountID = account.id
            draft.categoryID = categoryID
            draft.occurredAt = ISO8601DateFormatter().date(from: date)!
            draft.timeZoneIdentifier = "GMT"
            return try TransactionLifecycleService.save(draft: draft, accounts: [account], categories: categories,
                categoryDecisionSource: .manualConfirmed, in: context)
        }
        let expense = try save(.expense, "300", "2026-09-10T12:00:00Z", oldChild.id)
        let sameMonth = try save(.refund, "80", "2026-09-20T12:00:00Z", oldChild.id)
        let nextMonth = try save(.refund, "50", "2026-10-01T12:00:00Z", oldChild.id)
        let income = try save(.income, "80", "2026-09-20T12:00:00Z", legacyIncome.id)
        // Related identity is a valid existing/imported link; calculation must not inherit its category/date.
        sameMonth.relatedTransactionID = expense.id
        nextMonth.relatedTransactionID = expense.id
        try context.save()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let september = LedgerFilter(dateRange: LocalDayRange(lowerBound: "2026-09-01", upperBound: "2026-10-01"))
        let before = try await actor.snapshot(filter: september)
        XCTAssertEqual(before.rootTotals[oldRoot.id]?.grossExpenseMinorUnits, 30_000)
        XCTAssertEqual(before.rootTotals[oldRoot.id]?.refundMinorUnits, 8_000)
        XCTAssertEqual(before.rootTotals[oldRoot.id]?.netExpenseMinorUnits, 22_000)
        var edit = TransactionDraft(transaction: expense)
        edit.categoryID = newChild.id
        _ = try TransactionLifecycleService.save(draft: edit, editing: expense, accounts: [account], categories: categories,
            categoryDecisionSource: .manualConfirmed, in: context)
        let after = try await actor.snapshot(filter: september)
        XCTAssertEqual(Set(after.transactionIDs), [expense.id, sameMonth.id, income.id])
        XCTAssertEqual(after.totals.grossExpenseMinorUnits, 30_000)
        XCTAssertEqual(after.totals.refundMinorUnits, 8_000)
        XCTAssertEqual(after.totals.netExpenseMinorUnits, 22_000)
        XCTAssertEqual(after.totals.incomeMinorUnits, 8_000)
        XCTAssertEqual(after.totals.totalCount, 3)
        XCTAssertEqual(after.rootTotals[oldRoot.id]?.netExpenseMinorUnits, -8_000)
        XCTAssertEqual(after.rootTotals[oldRoot.id]?.totalCount, 1)
        XCTAssertEqual(after.rootTotals[newRoot.id]?.grossExpenseMinorUnits, 30_000)
        XCTAssertEqual(after.directCategoryTotals[oldChild.id]?.refundMinorUnits, 8_000)
        var oldGroup = september
        oldGroup.category = .node(oldRoot.id)
        let oldDetails = try await actor.snapshot(filter: oldGroup)
        XCTAssertEqual(oldDetails.transactionIDs, [sameMonth.id])
        XCTAssertEqual(oldDetails.totals, after.rootTotals[oldRoot.id])
        var newGroup = september
        newGroup.category = .direct(newChild.id)
        let newDetails = try await actor.snapshot(filter: newGroup)
        XCTAssertEqual(newDetails.transactionIDs, [expense.id])
        let october = try await actor.snapshot(filter: LedgerFilter(dateRange: LocalDayRange(lowerBound: "2026-10-01", upperBound: "2026-11-01")))
        XCTAssertEqual(october.transactionIDs, [nextMonth.id])
        XCTAssertEqual(october.totals.grossExpenseMinorUnits, 0)
        XCTAssertEqual(october.totals.refundMinorUnits, 5_000)
        XCTAssertEqual(october.totals.netExpenseMinorUnits, -5_000)
        XCTAssertEqual(october.totals.refundCount, 1)
        XCTAssertEqual(october.totals.expenseCount, 0)
        let persisted = try ModelContext(context.container).fetch(FetchDescriptor<FinanceTransaction>())
        for id in [sameMonth.id, nextMonth.id] {
            let refund = try XCTUnwrap(persisted.first { $0.id == id })
            XCTAssertEqual(refund.relatedTransactionID, expense.id)
            XCTAssertEqual(refund.categoryID, oldChild.id)
        }
        XCTAssertEqual(persisted.first { $0.id == income.id }?.type, .income)
    }
}
