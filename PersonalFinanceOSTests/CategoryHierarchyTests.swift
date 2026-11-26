import XCTest
@testable import PersonalFinanceOS

final class CategoryHierarchyTests: XCTestCase {
    func testOrderedCategoriesFollowRootThenChildSortOrderAndIgnoreInactiveWhenRequested() {
        let dining = category(name: "餐饮", kind: .expense, order: 2)
        let travel = category(name: "旅行", kind: .expense, order: 0)
        let breakfast = category(
            name: "早餐",
            kind: .expense,
            parentID: dining.id,
            order: 3
        )
        let dinner = category(
            name: "晚餐",
            kind: .expense,
            parentID: dining.id,
            order: 1
        )
        let archived = category(
            name: "停用",
            kind: .expense,
            parentID: travel.id,
            order: 0
        )
        archived.archivedAt = Date()
        let hierarchy = CategoryHierarchy(
            categories: [breakfast, dining, archived, dinner, travel]
        )

        XCTAssertEqual(
            hierarchy.orderedCategories(kind: .expense).map(\.name),
            ["旅行", "停用", "餐饮", "晚餐", "早餐"]
        )
        XCTAssertEqual(
            hierarchy.orderedCategories(kind: .expense, activeOnly: true).map(\.name),
            ["旅行", "餐饮", "晚餐", "早餐"]
        )
    }
    func testUsageSummariesAggregateRootsWithoutDoubleCountingChildren() {
        let root = category(name: "餐饮", kind: .expense)
        let breakfast = category(name: "早餐", kind: .expense, parentID: root.id)
        let dinner = category(name: "晚餐", kind: .expense, parentID: root.id)
        let direct = transaction(categoryID: root.id, amount: 100, note: "本级")
        let firstBreakfast = transaction(categoryID: breakfast.id, amount: 100, note: "早餐1")
        let secondBreakfast = transaction(categoryID: breakfast.id, amount: 100, note: "早餐2")
        let deletedDinner = transaction(categoryID: dinner.id, amount: 100, note: "删除")
        deletedDinner.softDelete()

        let summaries = CategoryUsageService.summaries(
            categories: [root, breakfast, dinner],
            transactions: [direct, firstBreakfast, secondBreakfast, deletedDinner]
        )

        XCTAssertEqual(summaries[root.id], CategoryUsageSummary(directCount: 1, aggregateCount: 3))
        XCTAssertEqual(summaries[breakfast.id], CategoryUsageSummary(directCount: 2, aggregateCount: 2))
        XCTAssertEqual(summaries[dinner.id], CategoryUsageSummary(directCount: 0, aggregateCount: 0))
    }

    func testRootAndChildRelationshipProvidesStablePathAndAggregation() throws {
        let dining = category(name: "餐饮", kind: .expense, order: 0)
        let fruit = category(name: "水果", kind: .expense, parentID: dining.id, order: 1)
        let hierarchy = CategoryHierarchy(categories: [fruit, dining])

        XCTAssertNoThrow(try hierarchy.validateAll())
        XCTAssertTrue(dining.isRootCategory)
        XCTAssertTrue(fruit.isChildCategory)
        XCTAssertFalse(dining.isLeafCategory(in: [dining, fruit]))
        XCTAssertTrue(fruit.isLeafCategory(in: [dining, fruit]))
        XCTAssertEqual(hierarchy.displayPath(for: dining), "餐饮")
        XCTAssertEqual(hierarchy.displayPath(for: fruit), "餐饮 / 水果")
        XCTAssertEqual(hierarchy.rootCategory(for: fruit).id, dining.id)
        XCTAssertEqual(hierarchy.aggregateRootID(for: fruit.id), dining.id)
        XCTAssertEqual(hierarchy.descendantIDs(of: dining.id), [dining.id, fruit.id])
    }

    func testHierarchyRejectsThirdLevelWrongKindSelfParentAndCycle() {
        let dining = category(name: "餐饮", kind: .expense)
        let fruit = category(name: "水果", kind: .expense, parentID: dining.id)
        let income = category(name: "工作收入", kind: .income)
        let cycleParent = category(name: "循环", kind: .expense)
        cycleParent.parentID = fruit.id
        let hierarchy = CategoryHierarchy(categories: [dining, fruit, income, cycleParent])

        XCTAssertThrowsError(try hierarchy.validate(kind: .expense, parentID: fruit.id)) {
            XCTAssertEqual($0 as? CategoryHierarchyError, .parentIsChild)
        }
        XCTAssertThrowsError(try hierarchy.validate(kind: .expense, parentID: income.id)) {
            XCTAssertEqual($0 as? CategoryHierarchyError, .kindMismatch)
        }
        XCTAssertThrowsError(try hierarchy.validate(
            kind: .expense,
            parentID: dining.id,
            categoryID: dining.id
        )) {
            XCTAssertEqual($0 as? CategoryHierarchyError, .selfParent)
        }
        XCTAssertThrowsError(try hierarchy.validate(
            kind: .expense,
            parentID: cycleParent.id,
            categoryID: fruit.id
        )) {
            XCTAssertEqual($0 as? CategoryHierarchyError, .cycle)
        }
    }

    func testSelectableCategoriesPreferChildrenButKeepUndividedAndLegacyRoots() {
        let dining = category(name: "餐饮", kind: .expense, order: 0)
        let fruit = category(name: "水果", kind: .expense, parentID: dining.id, order: 0)
        let legacy = category(name: "旧分类", kind: .expense, order: 1)
        let income = category(name: "工资", kind: .income)
        let hidden = category(name: "隐藏", kind: .expense, order: 2)
        hidden.isHidden = true
        let hierarchy = CategoryHierarchy(categories: [dining, fruit, legacy, income, hidden])

        XCTAssertEqual(
            hierarchy.selectableCategories(kind: .expense).map(\.name),
            ["水果", "旧分类"]
        )
        XCTAssertTrue(hierarchy.matches(fruit, query: "餐饮 / 水果"))
        XCTAssertTrue(hierarchy.matches(fruit, query: "餐饮"))
        XCTAssertFalse(hierarchy.matches(fruit, query: "交通"))
    }

    func testSelectableCategoriesPreserveParentGroupsWithSiblingLocalOrders() {
        let rootA = category(name: "大类 A", kind: .expense, order: 0)
        let childA1 = category(name: "A1", kind: .expense, parentID: rootA.id, order: 0)
        let childA2 = category(name: "A2", kind: .expense, parentID: rootA.id, order: 1)
        let rootB = category(name: "大类 B", kind: .expense, order: 1)
        let childB1 = category(name: "B1", kind: .expense, parentID: rootB.id, order: 0)
        let childB2 = category(name: "B2", kind: .expense, parentID: rootB.id, order: 1)
        let leafRoot = category(name: "独立", kind: .expense, order: 2)
        let hidden = category(name: "隐藏", kind: .expense, parentID: rootA.id, order: 2)
        hidden.isHidden = true
        let archived = category(name: "归档", kind: .expense, parentID: rootB.id, order: 2)
        archived.archivedAt = Date()

        let hierarchy = CategoryHierarchy(categories: [
            childB2, rootB, hidden, childA2, archived, leafRoot, childA1, rootA, childB1
        ])

        XCTAssertEqual(
            hierarchy.selectableCategories(kind: .expense).map(\.name),
            ["A1", "A2", "B1", "B2", "独立"]
        )
        XCTAssertEqual(
            hierarchy.orderedCategories(kind: .expense, activeOnly: true).map(\.name),
            ["大类 A", "A1", "A2", "大类 B", "B1", "B2", "独立"]
        )
        XCTAssertEqual(hierarchy.displayPath(for: childA1), "大类 A / A1")
    }

    func testLegacyRootTransactionKeepsItsOriginalCategoryID() {
        let root = category(name: "历史分类", kind: .expense)
        let transaction = FinanceTransaction(
            type: .expense,
            amountMinorUnits: 1_288,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            localDayKey: "2023-11-15",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: UUID(),
            categoryID: root.id
        )

        XCTAssertNil(root.parentID)
        XCTAssertEqual(transaction.categoryID, root.id)
        XCTAssertEqual(CategoryHierarchy(categories: [root]).displayPath(for: root), "历史分类")
    }

    func testChildAmountsAggregateToRootAndRootFilterIncludesChildren() throws {
        let dining = category(name: "餐饮", kind: .expense)
        let fruit = category(name: "水果", kind: .expense, parentID: dining.id)
        let account = Account(name: "现金", type: .cash)
        let rootTransaction = transaction(categoryID: dining.id, amount: 1_000, note: "聚餐")
        let childTransaction = transaction(categoryID: fruit.id, amount: 2_500, note: "火龙果")
        let month = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00+08:00")!

        let spending = FinanceInsightsService.categorySpending(
            for: [rootTransaction, childTransaction],
            month: month,
            categories: [dining, fruit]
        )
        XCTAssertEqual(
            spending,
            [CategorySpending(categoryID: dining.id, amountMinorUnits: 3_500, transactionCount: 2)]
        )

        let categoriesByID = [dining.id: dining, fruit.id: fruit]
        let accountsByID = [account.id: account]
        let filtered = TransactionDiscoveryService.filter(
            [rootTransaction, childTransaction],
            criteria: TransactionDiscoveryCriteria(month: month, categoryID: dining.id),
            categoriesByID: categoriesByID,
            accountsByID: accountsByID
        )
        XCTAssertEqual(Set(filtered.map(\.id)), Set([rootTransaction.id, childTransaction.id]))

        let pathSearch = TransactionDiscoveryService.filter(
            [rootTransaction, childTransaction],
            criteria: TransactionDiscoveryCriteria(month: month, searchText: "餐饮 / 水果"),
            categoriesByID: categoriesByID,
            accountsByID: accountsByID
        )
        XCTAssertEqual(pathSearch.map(\.id), [childTransaction.id])
    }

    func testIncomeHierarchyAndCategoryTrendRespectRootAndChildBoundaries() {
        let root = category(name: "工作收入", kind: .income)
        let salary = category(name: "工资", kind: .income, parentID: root.id)
        let bonus = category(name: "奖金", kind: .income, parentID: root.id)
        let expenseRoot = category(name: "餐饮", kind: .expense)
        let breakfast = category(name: "早餐", kind: .expense, parentID: expenseRoot.id)
        let dinner = category(name: "晚餐", kind: .expense, parentID: expenseRoot.id)
        let salaryTransaction = transaction(categoryID: salary.id, amount: 8_000, note: "工资", type: .income)
        let bonusTransaction = transaction(categoryID: bonus.id, amount: 2_000, note: "奖金", type: .income)
        let breakfastTransaction = transaction(categoryID: breakfast.id, amount: 300, note: "早餐")
        let dinnerTransaction = transaction(categoryID: dinner.id, amount: 700, note: "晚餐")
        let categories = [root, salary, bonus, expenseRoot, breakfast, dinner]
        let transactions = [salaryTransaction, bonusTransaction, breakfastTransaction, dinnerTransaction]

        let usage = CategoryUsageService.summaries(categories: categories, transactions: transactions)
        XCTAssertEqual(usage[root.id], CategoryUsageSummary(directCount: 0, aggregateCount: 2))
        XCTAssertEqual(usage[salary.id], CategoryUsageSummary(directCount: 1, aggregateCount: 1))

        let month = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00+08:00")!
        let rootTrend = FinanceInsightsService.categoryTrend(
            for: transactions,
            categoryID: expenseRoot.id,
            endingAt: month,
            count: 1,
            categories: categories
        )
        let childTrend = FinanceInsightsService.categoryTrend(
            for: transactions,
            categoryID: breakfast.id,
            endingAt: month,
            count: 1,
            categories: categories
        )
        XCTAssertEqual(rootTrend.first?.amountMinorUnits, 1_000)
        XCTAssertEqual(rootTrend.first?.transactionCount, 2)
        XCTAssertEqual(childTrend.first?.amountMinorUnits, 300)
        XCTAssertEqual(childTrend.first?.transactionCount, 1)
    }

    private func category(
        name: String,
        kind: CategoryKind,
        parentID: UUID? = nil,
        order: Int = 0
    ) -> PersonalFinanceOS.Category {
        PersonalFinanceOS.Category(
            kind: kind,
            name: name,
            parentID: parentID,
            symbolName: "square.grid.2x2",
            colorToken: "teal",
            sortOrder: order
        )
    }

    private func transaction(
        categoryID: UUID,
        amount: Int64,
        note: String,
        type: TransactionType = .expense
    ) -> FinanceTransaction {
        let date = ISO8601DateFormatter().date(from: "2026-08-02T12:00:00+08:00")!
        return FinanceTransaction(
            type: type,
            amountMinorUnits: amount,
            occurredAt: date,
            localDayKey: "2026-08-02",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: UUID(),
            categoryID: categoryID,
            note: note
        )
    }
}
