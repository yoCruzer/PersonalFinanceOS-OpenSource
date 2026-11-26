import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class LedgerSearchActorTests: XCTestCase {
    func testGlobalSearchMatchesEverySupportedFieldExcludesDeletedAndCombinesFilters() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let daily = Account(name: "日常账户", type: .cash)
        let travel = Account(name: "旅行金库", type: .other)
        let dining = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let transport = Category(
            kind: .expense,
            name: "停车交通",
            symbolName: "car",
            colorToken: "blue"
        )
        let reimbursed = Tag(name: "报销")
        let note = transaction(day: "2018-01-02", accountID: daily.id, categoryID: dining.id, note: "新疆自驾")
        let merchant = transaction(day: "2019-02-03", accountID: daily.id, categoryID: dining.id, merchant: "星巴克")
        let category = transaction(day: "2020-03-04", accountID: daily.id, categoryID: transport.id)
        let account = transaction(day: "2021-04-05", accountID: travel.id, categoryID: dining.id)
        let tag = transaction(day: "2022-05-06", accountID: daily.id, categoryID: dining.id, tags: [reimbursed])
        let deleted = transaction(day: "2023-06-07", accountID: daily.id, categoryID: dining.id, note: "只在已删除")
        deleted.softDelete()
        context.insert(daily)
        context.insert(travel)
        context.insert(dining)
        context.insert(transport)
        context.insert(reimbursed)
        [note, merchant, category, account, tag, deleted].forEach(context.insert)
        try context.save()
        let worker = LedgerSearchActor(modelContainer: container)

        let noteResults = try await worker.page(request: request(query: "新疆"))
        XCTAssertEqual(noteResults.transactionIDs, [note.id])
        let merchantResults = try await worker.page(request: request(query: "星巴克"))
        XCTAssertEqual(merchantResults.transactionIDs, [merchant.id])
        let categoryResults = try await worker.page(request: request(
            query: "停车",
            queryCategoryIDs: [transport.id]
        ))
        XCTAssertEqual(categoryResults.transactionIDs, [category.id])
        let accountResults = try await worker.page(request: request(
            query: "旅行金库",
            queryAccountIDs: [travel.id]
        ))
        XCTAssertEqual(accountResults.transactionIDs, [account.id])
        let tagResults = try await worker.page(request: request(
            query: "报销",
            queryTagIDs: [reimbursed.id]
        ))
        XCTAssertEqual(tagResults.transactionIDs, [tag.id])
        let tagWithoutResolvedIDs = try await worker.page(request: request(query: "报销"))
        XCTAssertTrue(tagWithoutResolvedIDs.transactionIDs.isEmpty)
        let deletedResults = try await worker.page(request: request(query: "只在已删除"))
        XCTAssertTrue(deletedResults.transactionIDs.isEmpty)

        let combined = try await worker.page(request: request(
            query: "餐饮",
            type: .expense,
            categoryFilterIDs: [dining.id],
            accountID: daily.id,
            tagID: reimbursed.id,
            queryCategoryIDs: [dining.id]
        ))
        XCTAssertEqual(combined.transactionIDs, [tag.id])
    }

    func testEmptyQueryDoesNoWorkAndPaginationKeepsEachPageBounded() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let transactions = (0..<7).map { index in
            transaction(
                day: "2026-08-0\(index + 1)",
                accountID: UUID(),
                categoryID: UUID(),
                note: "停车"
            )
        }
        transactions.forEach(context.insert)
        try context.save()
        let worker = LedgerSearchActor(modelContainer: container)

        let empty = try await worker.page(request: request(query: "  "))
        XCTAssertEqual(empty.scannedRecordCount, 0)
        XCTAssertEqual(empty.maximumBatchCount, 0)
        XCTAssertTrue(empty.transactionIDs.isEmpty)

        let first = try await worker.page(request: request(query: "停车"), pageSize: 3, batchSize: 2)
        XCTAssertEqual(first.transactionIDs.count, 3)
        XCTAssertNotNil(first.nextCursor)
        XCTAssertLessThanOrEqual(first.maximumBatchCount, 2)
        let second = try await worker.page(
            request: request(query: "停车"),
            cursor: try XCTUnwrap(first.nextCursor),
            pageSize: 3,
            batchSize: 2
        )
        XCTAssertEqual(second.transactionIDs.count, 3)
        XCTAssertTrue(Set(first.transactionIDs).isDisjoint(with: second.transactionIDs))
    }

    func testStaleGenerationCannotReplaceLatestSearch() {
        var gate = SearchRequestGenerationGate()
        let first = gate.begin()
        let second = gate.begin()

        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
    }

    func testOffsetPaginationUsesUniqueTotalOrderForEverySortMode() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let date = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-20T12:00:00+08:00")
        )
        let transactions = (0..<17).map { _ in
            FinanceTransaction(
                type: .expense,
                amountMinorUnits: 100,
                occurredAt: date,
                localDayKey: "2026-08-20",
                timeZoneIdentifier: "Asia/Shanghai",
                note: "相同排序键",
                createdAt: date
            )
        }
        transactions.forEach(context.insert)
        try context.save()
        let expectedIDs = Set(transactions.map(\.id))
        let worker = LedgerSearchActor(modelContainer: container)

        for sortOrder in TransactionSortOrder.allCases {
            var cursor = 0
            var collectedIDs: [UUID] = []
            while true {
                let page = try await worker.page(
                    request: request(query: "相同排序键", sortOrder: sortOrder),
                    cursor: cursor,
                    pageSize: 4,
                    batchSize: 3
                )
                collectedIDs.append(contentsOf: page.transactionIDs)
                guard let nextCursor = page.nextCursor else { break }
                cursor = nextCursor
            }

            XCTAssertEqual(collectedIDs.count, transactions.count, "sort=\(sortOrder)")
            XCTAssertEqual(Set(collectedIDs).count, transactions.count, "sort=\(sortOrder)")
            XCTAssertEqual(Set(collectedIDs), expectedIDs, "sort=\(sortOrder)")
        }
    }

    func testNewSearchReallyCancelsInFlightPaginationTask() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let store = LedgerSearchStore()
        let initialLoader: LedgerSearchPageLoader = { _, _ in
            LedgerSearchPage(
                transactionIDs: [],
                nextCursor: 1,
                scannedRecordCount: 1,
                maximumBatchCount: 1
            )
        }
        await store.search(
            request: request(query: "旧查询"),
            modelContainer: container,
            modelContext: context,
            debounce: false,
            pageLoader: initialLoader
        )
        XCTAssertTrue(store.hasNextPage)

        let probe = PagingCancellationProbe()
        let blockingLoader: LedgerSearchPageLoader = { _, _ in
            try await probe.loadUntilCancelled()
        }
        store.loadNext(
            modelContainer: container,
            modelContext: context,
            pageLoader: blockingLoader
        )
        let didStart = await waitForProbe(probe, keyPath: \.started)
        XCTAssertTrue(didStart)

        await store.search(
            request: request(query: "新查询"),
            modelContainer: container,
            modelContext: context,
            debounce: false,
            pageLoader: initialLoader
        )

        let didCancel = await waitForProbe(probe, keyPath: \.cancelled)
        XCTAssertTrue(didCancel)
    }

    func testCancelledSearchStopsBeforePersistenceWork() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let worker = LedgerSearchActor(modelContainer: container)
        let task = Task {
            try await worker.page(request: request(query: "不会执行"))
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled search must not publish a result")
        } catch is CancellationError {
            // Expected: the worker checks cancellation before its first batch fetch.
        }
    }

    private func request(
        query: String,
        type: TransactionType? = nil,
        categoryFilterIDs: Set<UUID> = [],
        accountID: UUID? = nil,
        tagID: UUID? = nil,
        queryCategoryIDs: Set<UUID> = [],
        queryAccountIDs: Set<UUID> = [],
        queryTagIDs: Set<UUID> = [],
        sortOrder: TransactionSortOrder = .timeNewest
    ) -> LedgerSearchRequest {
        LedgerSearchRequest(
            query: query,
            typeRawValue: type?.rawValue,
            categoryFilterIDs: categoryFilterIDs,
            accountID: accountID,
            tagID: tagID,
            queryCategoryIDs: queryCategoryIDs,
            queryAccountIDs: queryAccountIDs,
            queryTagIDs: queryTagIDs,
            matchesUncategorized: false,
            sortOrder: sortOrder
        )
    }

    private func waitForProbe(
        _ probe: PagingCancellationProbe,
        keyPath: KeyPath<PagingCancellationProbe.State, Bool>
    ) async -> Bool {
        for _ in 0..<100 {
            let state = await probe.state
            if state[keyPath: keyPath] { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func transaction(
        day: String,
        accountID: UUID,
        categoryID: UUID,
        note: String = "",
        merchant: String = "",
        tags: [Tag] = []
    ) -> FinanceTransaction {
        let date = ISO8601DateFormatter().date(from: "\(day)T12:00:00+08:00")!
        return FinanceTransaction(
            type: .expense,
            amountMinorUnits: 100,
            occurredAt: date,
            localDayKey: day,
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: accountID,
            categoryID: categoryID,
            rawMerchantText: merchant,
            note: note,
            createdAt: date,
            tags: tags
        )
    }
}

private actor PagingCancellationProbe {
    struct State: Sendable {
        let started: Bool
        let cancelled: Bool
    }

    private var started = false
    private var cancelled = false

    var state: State { State(started: started, cancelled: cancelled) }

    func loadUntilCancelled() async throws -> LedgerSearchPage {
        started = true
        do {
            try await Task.sleep(for: .seconds(60))
            return LedgerSearchPage(
                transactionIDs: [],
                nextCursor: nil,
                scannedRecordCount: 0,
                maximumBatchCount: 0
            )
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }
}
