import XCTest
@testable import PersonalFinanceOS

final class TransactionDiscoveryServiceTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    func testBoundedMonthScopeNeverReturnsAnotherMonth() {
        let account = Account(name: "账户", type: .cash)
        let category = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let july = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        let current = transaction(
            type: .expense,
            amount: 100,
            day: "2026-07-18",
            accountID: account.id,
            categoryID: category.id,
            note: "同一关键词"
        )
        let otherMonth = transaction(
            type: .expense,
            amount: 100,
            day: "2025-02-18",
            accountID: account.id,
            categoryID: category.id,
            note: "同一关键词"
        )

        let results = TransactionDiscoveryService.filter(
            [otherMonth, current],
            criteria: TransactionDiscoveryCriteria(month: july, searchText: "同一关键词"),
            categoriesByID: [category.id: category],
            accountsByID: [account.id: account],
            calendar: calendar
        )
        XCTAssertEqual(results.map(\.id), [current.id])
    }

    func testMonthTypeCategoryAccountAndSearchFiltersCombine() {
        let account = Account(name: "日常账户", type: .cash)
        let otherAccount = Account(name: "旅行账户", type: .other)
        let dining = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let salary = Category(
            kind: .income,
            name: "薪资",
            symbolName: "banknote",
            colorToken: "green"
        )
        let julyExpense = transaction(
            type: .expense,
            amount: 1_280,
            day: "2026-07-18",
            accountID: account.id,
            categoryID: dining.id,
            note: "午餐"
        )
        let julyIncome = transaction(
            type: .income,
            amount: 500_000,
            day: "2026-07-01",
            accountID: otherAccount.id,
            categoryID: salary.id,
            note: "七月工资"
        )
        let juneExpense = transaction(
            type: .expense,
            amount: 2_000,
            day: "2026-06-30",
            accountID: account.id,
            categoryID: dining.id
        )

        let categories = [dining.id: dining, salary.id: salary]
        let accounts = [account.id: account, otherAccount.id: otherAccount]
        let july = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!

        XCTAssertEqual(
            TransactionDiscoveryService.filter(
                [juneExpense, julyExpense, julyIncome],
                criteria: TransactionDiscoveryCriteria(month: july, type: .expense),
                categoriesByID: categories,
                accountsByID: accounts,
                calendar: calendar
            ).map(\.id),
            [julyExpense.id]
        )
        XCTAssertEqual(
            TransactionDiscoveryService.filter(
                [julyExpense, julyIncome],
                criteria: TransactionDiscoveryCriteria(
                    month: july,
                    categoryID: salary.id,
                    accountID: otherAccount.id,
                    searchText: "工资"
                ),
                categoriesByID: categories,
                accountsByID: accounts,
                calendar: calendar
            ).map(\.id),
            [julyIncome.id]
        )
        XCTAssertEqual(
            TransactionDiscoveryService.filter(
                [julyExpense, julyIncome],
                criteria: TransactionDiscoveryCriteria(month: july, searchText: "餐饮"),
                categoriesByID: categories,
                accountsByID: accounts,
                calendar: calendar
            ).map(\.id),
            [julyExpense.id]
        )
    }

    func testSoftDeletedTransactionsAreExcludedAndResultsAreNewestFirst() {
        let account = Account(name: "账户", type: .cash)
        let category = Category(
            kind: .expense,
            name: "其他",
            symbolName: "ellipsis",
            colorToken: "teal"
        )
        let old = transaction(
            type: .expense,
            amount: 100,
            day: "2026-07-01",
            accountID: account.id,
            categoryID: category.id
        )
        let new = transaction(
            type: .expense,
            amount: 200,
            day: "2026-07-20",
            accountID: account.id,
            categoryID: category.id
        )
        let deleted = transaction(
            type: .expense,
            amount: 300,
            day: "2026-07-30",
            accountID: account.id,
            categoryID: category.id
        )
        deleted.softDelete()
        let july = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!

        XCTAssertEqual(
            TransactionDiscoveryService.filter(
                [old, deleted, new],
                criteria: TransactionDiscoveryCriteria(month: july),
                categoriesByID: [category.id: category],
                accountsByID: [account.id: account],
                calendar: calendar
            ).map(\.id),
            [new.id, old.id]
        )
    }

    func testUncategorizedImportedTransactionCanBeFoundByVirtualCategoryName() {
        let account = Account(name: "账户", type: .cash)
        let uncategorized = transaction(
            type: .expense,
            amount: 100,
            day: "2026-07-03",
            accountID: account.id,
            categoryID: UUID()
        )
        uncategorized.categoryID = nil
        uncategorized.reviewStatus = .needsReview
        uncategorized.reviewReasons = [.uncategorized, .importUncertain]
        let july = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!

        let results = TransactionDiscoveryService.filter(
            [uncategorized],
            criteria: TransactionDiscoveryCriteria(month: july, searchText: "待分类"),
            categoriesByID: [:],
            accountsByID: [account.id: account],
            calendar: calendar
        )
        XCTAssertEqual(results.map(\.id), [uncategorized.id])
    }

    func testTimeAndAmountSortOrdersAreStableAcrossIncomeAndExpense() {
        let account = Account(name: "账户", type: .cash)
        let expense = Category(
            kind: .expense,
            name: "支出",
            symbolName: "minus.circle",
            colorToken: "orange"
        )
        let income = Category(
            kind: .income,
            name: "收入",
            symbolName: "plus.circle",
            colorToken: "green"
        )
        let small = transaction(
            type: .expense,
            amount: 100,
            day: "2026-07-03",
            accountID: account.id,
            categoryID: expense.id
        )
        let olderLarge = transaction(
            type: .income,
            amount: 500,
            day: "2026-07-01",
            accountID: account.id,
            categoryID: income.id
        )
        let newerLarge = transaction(
            type: .expense,
            amount: 500,
            day: "2026-07-02",
            accountID: account.id,
            categoryID: expense.id
        )
        let july = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        let categories = [expense.id: expense, income.id: income]
        let accounts = [account.id: account]

        func ids(_ order: TransactionSortOrder, type: TransactionType? = nil) -> [UUID] {
            TransactionDiscoveryService.filter(
                [small, olderLarge, newerLarge],
                criteria: TransactionDiscoveryCriteria(month: july, type: type, sortOrder: order),
                categoriesByID: categories,
                accountsByID: accounts,
                calendar: calendar
            ).map(\.id)
        }

        XCTAssertEqual(ids(.timeNewest), [small.id, newerLarge.id, olderLarge.id])
        XCTAssertEqual(ids(.timeOldest), [olderLarge.id, newerLarge.id, small.id])
        XCTAssertEqual(ids(.amountHigh), [newerLarge.id, olderLarge.id, small.id])
        XCTAssertEqual(ids(.amountLow), [small.id, newerLarge.id, olderLarge.id])
        XCTAssertEqual(ids(.amountHigh, type: .expense), [newerLarge.id, small.id])
    }

    private func transaction(
        type: TransactionType,
        amount: Int64,
        day: String,
        accountID: UUID,
        categoryID: UUID,
        note: String = ""
    ) -> FinanceTransaction {
        let date = ISO8601DateFormatter().date(from: "\(day)T12:00:00+08:00")!
        return FinanceTransaction(
            type: type,
            amountMinorUnits: amount,
            occurredAt: date,
            localDayKey: day,
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: accountID,
            categoryID: categoryID,
            note: note,
            createdAt: date
        )
    }
}
