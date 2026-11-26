import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class CategoryTransactionQueryTests: XCTestCase {
    func testRootAndChildScopesExcludeOtherAndDeletedTransactions() throws {
        let setup = try makeSetup()
        let rootTransaction = transaction(categoryID: setup.root.id, day: 4)
        let childTransaction = transaction(categoryID: setup.child.id, day: 3)
        let otherTransaction = transaction(categoryID: setup.otherRoot.id, day: 2)
        let deletedTransaction = transaction(categoryID: setup.child.id, day: 1, deleted: true)
        [rootTransaction, childTransaction, otherTransaction, deletedTransaction]
            .forEach(setup.context.insert)
        try setup.context.save()

        let hierarchy = CategoryHierarchy(categories: [setup.root, setup.child, setup.otherRoot])
        let rootPage = try LedgerQueryService.fetchActiveCategoryPage(
            categoryIDs: hierarchy.descendantIDs(of: setup.root.id),
            in: setup.context
        )
        XCTAssertEqual(rootPage.transactions.map(\.id), [rootTransaction.id, childTransaction.id])
        XCTAssertFalse(rootPage.hasMore)

        let childPage = try LedgerQueryService.fetchActiveCategoryPage(
            categoryIDs: [setup.child.id],
            in: setup.context
        )
        XCTAssertEqual(childPage.transactions.map(\.id), [childTransaction.id])
        XCTAssertEqual(
            try LedgerQueryService.countActiveForCategory(setup.child.id, in: setup.context),
            1
        )
    }

    func testCategoryPaginationIsBoundedStableAndCompleteForLargeLedger() throws {
        let setup = try makeSetup()
        let included = (0..<503).map { index in
            transaction(categoryID: setup.child.id, day: index % 28 + 1, sequence: index)
        }
        let unrelated = (0..<300).map { index in
            transaction(categoryID: setup.otherRoot.id, day: index % 28 + 1, sequence: 1_000 + index)
        }
        (included + unrelated).forEach(setup.context.insert)
        try setup.context.save()

        var fetched: [FinanceTransaction] = []
        var hasMore = true
        while hasMore {
            let page = try LedgerQueryService.fetchActiveCategoryPage(
                categoryIDs: [setup.child.id],
                offset: fetched.count,
                limit: 40,
                in: setup.context
            )
            XCTAssertLessThanOrEqual(page.transactions.count, 40)
            fetched.append(contentsOf: page.transactions)
            hasMore = page.hasMore
        }

        XCTAssertEqual(fetched.count, included.count)
        XCTAssertEqual(Set(fetched.map(\.id)).count, included.count)
        XCTAssertEqual(Set(fetched.compactMap(\.categoryID)), [setup.child.id])
        XCTAssertEqual(
            fetched.map(\.id),
            included.sorted(by: transactionOrder).map(\.id)
        )
    }

    func testRootPaginationGloballyMergesDirectAndDescendantTransactionsWithoutLoss() throws {
        let setup = try makeSetup()
        let lunch = PersonalFinanceOS.Category(
            kind: .expense,
            name: "午餐",
            parentID: setup.root.id,
            symbolName: "takeoutbag.and.cup.and.straw",
            colorToken: "orange"
        )
        let dinner = PersonalFinanceOS.Category(
            kind: .expense,
            name: "晚餐",
            parentID: setup.root.id,
            symbolName: "moon.stars",
            colorToken: "purple"
        )
        [lunch, dinner].forEach(setup.context.insert)

        let includedCategoryIDs = [setup.root.id, setup.child.id, lunch.id, dinner.id]
        let included = (0..<41).map { index in
            tiedTransaction(
                categoryID: includedCategoryIDs[index % includedCategoryIDs.count],
                occurredRank: index % 3,
                createdRank: index % 2
            )
        }
        let unrelated = (0..<11).map { index in
            tiedTransaction(
                categoryID: setup.otherRoot.id,
                occurredRank: index % 3,
                createdRank: index % 2
            )
        }
        let deleted = (0..<9).map { index in
            tiedTransaction(
                categoryID: includedCategoryIDs[index % includedCategoryIDs.count],
                occurredRank: index % 3,
                createdRank: index % 2,
                deleted: true
            )
        }
        (included + unrelated + deleted).forEach(setup.context.insert)
        try setup.context.save()

        let hierarchy = CategoryHierarchy(categories: [
            setup.root, setup.child, lunch, dinner, setup.otherRoot
        ])
        let rootScope = hierarchy.descendantIDs(of: setup.root.id)
        XCTAssertEqual(rootScope, Set(includedCategoryIDs))

        let pageSize = 5
        let expectedPageCount = (included.count + pageSize - 1) / pageSize
        var fetched: [FinanceTransaction] = []
        var hasMoreValues: [Bool] = []
        while true {
            let page = try LedgerQueryService.fetchActiveCategoryPage(
                categoryIDs: rootScope,
                offset: fetched.count,
                limit: pageSize,
                in: setup.context
            )
            fetched.append(contentsOf: page.transactions)
            hasMoreValues.append(page.hasMore)
            if !page.hasMore { break }
            if hasMoreValues.count > expectedPageCount {
                XCTFail("Pagination did not terminate at the expected final page")
                break
            }
        }

        let fetchedIDs = fetched.map(\.id)
        let expectedIDs = included.sorted(by: transactionOrder).map(\.id)
        XCTAssertEqual(Set(fetched.compactMap(\.categoryID)), Set(includedCategoryIDs))
        XCTAssertTrue(Set(fetchedIDs).isDisjoint(with: unrelated.map(\.id)))
        XCTAssertTrue(Set(fetchedIDs).isDisjoint(with: deleted.map(\.id)))
        XCTAssertEqual(fetchedIDs.count, Set(fetchedIDs).count)
        XCTAssertEqual(Set(fetchedIDs), Set(included.map(\.id)))
        XCTAssertEqual(fetchedIDs, expectedIDs)
        XCTAssertEqual(
            hasMoreValues,
            Array(repeating: true, count: expectedPageCount - 1) + [false]
        )

        for (earlier, later) in zip(fetched, fetched.dropFirst()) {
            XCTAssertTrue(
                earlier.occurredAt > later.occurredAt ||
                (earlier.occurredAt == later.occurredAt && earlier.createdAt > later.createdAt) ||
                (earlier.occurredAt == later.occurredAt &&
                    earlier.createdAt == later.createdAt &&
                    earlier.id.uuidString > later.id.uuidString)
            )
        }
    }

    private func makeSetup() throws -> Setup {
        let configuration = ModelConfiguration(
            "CategoryTransactions-\(UUID().uuidString)",
            schema: AppSchema.schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AppSchema.schema,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let root = PersonalFinanceOS.Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let child = PersonalFinanceOS.Category(
            kind: .expense,
            name: "早餐",
            parentID: root.id,
            symbolName: "sunrise",
            colorToken: "yellow"
        )
        let otherRoot = PersonalFinanceOS.Category(
            kind: .expense,
            name: "交通",
            symbolName: "bus",
            colorToken: "blue"
        )
        [root, child, otherRoot].forEach(context.insert)
        try context.save()
        return Setup(context: context, root: root, child: child, otherRoot: otherRoot)
    }

    private func transaction(
        categoryID: UUID,
        day: Int,
        sequence: Int = 0,
        deleted: Bool = false
    ) -> FinanceTransaction {
        let date = Date(timeIntervalSince1970: TimeInterval(day * 86_400 + sequence))
        return FinanceTransaction(
            id: UUID(),
            type: .expense,
            amountMinorUnits: 100,
            occurredAt: date,
            localDayKey: String(format: "2026-08-%02d", day),
            timeZoneIdentifier: "Asia/Shanghai",
            categoryID: categoryID,
            createdAt: date,
            updatedAt: date,
            deletedAt: deleted ? date : nil
        )
    }

    private func tiedTransaction(
        categoryID: UUID,
        occurredRank: Int,
        createdRank: Int,
        deleted: Bool = false
    ) -> FinanceTransaction {
        let occurredAt = Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(occurredRank))
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(createdRank))
        return FinanceTransaction(
            id: UUID(),
            type: .expense,
            amountMinorUnits: 100,
            occurredAt: occurredAt,
            localDayKey: "2027-01-15",
            timeZoneIdentifier: "Asia/Shanghai",
            categoryID: categoryID,
            createdAt: createdAt,
            updatedAt: createdAt,
            deletedAt: deleted ? createdAt : nil
        )
    }

    private func transactionOrder(_ left: FinanceTransaction, _ right: FinanceTransaction) -> Bool {
        if left.occurredAt != right.occurredAt { return left.occurredAt > right.occurredAt }
        if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
        return left.id.uuidString > right.id.uuidString
    }
}

@MainActor
private struct Setup {
    let context: ModelContext
    let root: PersonalFinanceOS.Category
    let child: PersonalFinanceOS.Category
    let otherRoot: PersonalFinanceOS.Category
}
