import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class LedgerBlankScreenTests: XCTestCase {
    private let filter = LedgerFilter(dateRange: nil)

    private func fixture(count: Int = 305) throws -> ModelContext {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        for index in 0..<count {
            context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 1,
                occurredAt: Date(timeIntervalSince1970: Double(index)), localDayKey: "2026-10-01",
                timeZoneIdentifier: "GMT", accountID: nil, categoryID: nil))
        }
        try context.save()
        return context
    }

    func testPublicationConflictAutomaticallyRebuildsWithoutAnotherRefresh() async throws {
        let context = try fixture(count: 305)
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        var publications = 0
        await store.reload(filter: filter, actor: actor, beforePublication: {
            publications += 1
            if publications == 1 {
                context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 7,
                    occurredAt: Date(), localDayKey: "2026-10-01", timeZoneIdentifier: "GMT"))
                try context.save()
            }
        })
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.snapshot?.totals.totalCount, 306)
        XCTAssertEqual(store.snapshot?.totals.netExpenseMinorUnits, 312)
        XCTAssertEqual(publications, 2)
    }

    func testContinuousPublicationConflictsStopWithRecoverableError() async throws {
        let context = try fixture(count: 3)
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        var attempts = 0
        await store.reload(filter: filter, actor: actor, beforePublication: {
            attempts += 1
            context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 1,
                occurredAt: Date(), localDayKey: "2026-10-01", timeZoneIdentifier: "GMT"))
            try context.save()
        })
        XCTAssertEqual(attempts, 5)
        XCTAssertNil(store.snapshot)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
        await store.reload(filter: filter, actor: actor)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.snapshot?.totals.totalCount, 8)
    }

    func testStalePageRebuildsWholeCoherentWindowAutomatically() async throws {
        let context = try fixture(count: 305)
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 7,
            occurredAt: Date(), localDayKey: "2026-10-01", timeZoneIdentifier: "GMT"))
        try context.save()
        await store.loadNextPage(actor: actor)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.snapshot?.totals.totalCount, 306)
        XCTAssertEqual(store.rows.map(\.id), Array(store.snapshot!.transactionIDs[store.loadedRange]))
        XCTAssertTrue(store.permitsPresentationActions)
    }

    func testSameFilterRefreshKeepsCoherentLoadedContentUntilPublication() async throws {
        let context = try fixture()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        await store.loadNextPage(actor: actor)
        let previous = try XCTUnwrap(store.snapshot)
        let previousRows = store.rows.map(\.id)
        let anchor = try XCTUnwrap(store.rows.last?.id)
        context.insert(FinanceTransaction(type: .refund, amountMinorUnits: 10, occurredAt: Date(),
            localDayKey: "2026-10-01", timeZoneIdentifier: "GMT", accountID: nil, categoryID: nil))
        try context.save()
        await store.reload(filter: filter, actor: actor, anchorID: anchor, beforeQuery: {
            XCTAssertTrue(store.isLoading)
            XCTAssertEqual(store.snapshot?.revision, previous.revision)
            XCTAssertEqual(store.rows.map(\.id), previousRows)
            XCTAssertEqual(store.snapshot?.totals.totalCount, 305)
        })
        XCTAssertEqual(store.snapshot?.totals.totalCount, 306)
        XCTAssertEqual(store.snapshot?.totals.netExpenseMinorUnits, 295)
        XCTAssertEqual(store.snapshot?.revision, try LedgerSaveRevision.shared.readContentStamp())
        XCTAssertTrue(store.rows.contains { $0.id == anchor })
    }

    func testCancellationHasExplicitRecoveryInsteadOfPermanentLoadingPresentation() async throws {
        let context = try fixture(count: 0)
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor, beforeQuery: { throw CancellationError() })
        XCTAssertFalse(store.isLoading)
        XCTAssertNotNil(store.errorMessage, "Without a snapshot or error Today renders a spinner forever")
        await store.reload(filter: filter, actor: actor)
        XCTAssertNotNil(store.snapshot)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testFilterChangeClearsOldPresentationAndFailureCanRetry() async throws {
        let context = try fixture(count: 3)
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        var income = filter
        income.mode = .income
        await store.reload(filter: income, actor: actor, beforeQuery: {
            XCTAssertNil(store.snapshot)
            XCTAssertTrue(store.rows.isEmpty)
            throw CocoaError(.fileReadUnknown)
        })
        XCTAssertFalse(store.isLoading)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.snapshot)
        await store.reload(filter: income, actor: actor)
        XCTAssertEqual(store.snapshot?.filter.withoutRevision, income)
        XCTAssertEqual(store.snapshot?.totals.totalCount, 0)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testDeletedDeepAnchorFallsBackToSurvivingNeighbourAndPreservesPageExtent() async throws {
        let context = try fixture()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        await store.loadNextPage(actor: actor)
        await store.loadNextPage(actor: actor)
        let anchor = store.rows[230].id
        let neighbour = store.rows[231].id
        let value = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == anchor })
        value.deletedAt = Date()
        try context.save()
        await store.reload(filter: filter, actor: actor, anchorID: anchor)
        XCTAssertEqual(store.resolvedAnchorID, neighbour)
        XCTAssertEqual(store.rows.count, 300)
        XCTAssertFalse(store.rows.contains { $0.id == anchor })
        XCTAssertTrue(store.rows.contains { $0.id == neighbour })
        XCTAssertEqual(store.rows.map(\.id), Array(store.snapshot!.transactionIDs.prefix(300)))
        XCTAssertEqual(store.snapshot?.totals.totalCount, 304)
        await store.loadNextPage(actor: actor)
        XCTAssertEqual(store.rows.count, 304)
    }

    func testTwentySaveRefreshesKeepWholeRevisionAndMovedAnchor() async throws {
        let context = try fixture()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        await store.loadNextPage(actor: actor)
        await store.loadNextPage(actor: actor)
        let anchor = store.rows[220].id
        let value = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == anchor })
        for index in 0..<20 {
            context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 2, occurredAt: Date(),
                localDayKey: "2026-10-01", timeZoneIdentifier: "GMT", accountID: nil, categoryID: nil))
            if index == 10 { value.occurredAt = Date().addingTimeInterval(60) }
            try context.save()
            let before = store.rows.map(\.id)
            await store.reload(filter: filter, actor: actor, anchorID: anchor, beforeQuery: {
                XCTAssertEqual(store.rows.map(\.id), before)
                XCTAssertEqual(store.snapshot?.totals.totalCount, 305 + index)
            })
            XCTAssertEqual(store.snapshot?.totals.totalCount, 306 + index)
            XCTAssertEqual(store.snapshot?.totals.netExpenseMinorUnits, Int64(307 + index * 2))
            XCTAssertEqual(store.snapshot?.revision, try LedgerSaveRevision.shared.readContentStamp())
            XCTAssertEqual(store.resolvedAnchorID, anchor)
            XCTAssertTrue(store.rows.contains { $0.id == anchor })
            XCTAssertEqual(store.rows.map(\.id), Array(store.snapshot!.transactionIDs[store.loadedRange]))
        }
    }

    func testRelocatedVisibleWindowPagesBothDirectionsAndExportsCompleteResult() async throws {
        let context = try fixture()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        let target = store.rows[20].id
        let transaction = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == target })
        transaction.occurredAt = Date(timeIntervalSince1970: -10)
        try context.save()
        await store.reload(filter: filter, actor: actor, anchorID: target)
        let snapshot = try XCTUnwrap(store.snapshot)
        XCTAssertEqual(store.rows.count, 100)
        XCTAssertEqual(store.loadedRange, 205..<305)
        XCTAssertEqual(store.rows.map(\.id), Array(snapshot.transactionIDs[store.loadedRange]))
        XCTAssertTrue(store.hasPrevious)
        XCTAssertFalse(store.hasMore)
        XCTAssertTrue(store.rows.contains { $0.id == target })
        await store.loadPreviousPage(actor: actor)
        XCTAssertEqual(store.loadedRange, 105..<305)
        await store.loadPreviousPage(actor: actor)
        await store.loadPreviousPage(actor: actor)
        XCTAssertEqual(store.loadedRange, 0..<305)
        XCTAssertEqual(Set(store.rows.map(\.id)).count, 305)
        XCTAssertEqual(store.rows.map(\.id), snapshot.transactionIDs)
        XCTAssertFalse(store.hasPrevious)
        XCTAssertEqual(snapshot.totals.totalCount, 305)
        XCTAssertEqual(snapshot.totals.netExpenseMinorUnits, 305)
        let data = try await actor.exportData(snapshot: snapshot)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(text.split(whereSeparator: \.isNewline).count, 306, "Export must cover all results, independently of the materialized window")
    }

    func testDeepRefreshFaultRetainsCoherentPresentationAndRetryRange() async throws {
        for cancels in [true, false] {
            let context = try fixture()
            let actor = LedgerAnalysisActor(modelContainer: context.container)
            let store = LedgerAnalysisStore()
            await store.reload(filter: filter, actor: actor)
            await store.loadNextPage(actor: actor)
            await store.loadNextPage(actor: actor)
            let oldRevision = try XCTUnwrap(store.snapshot?.revision)
            let oldRows = store.rows.map(\.id)
            let target = oldRows[280]
            context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 1, occurredAt: Date(),
                localDayKey: "2026-10-01", timeZoneIdentifier: "GMT", accountID: nil, categoryID: nil))
            try context.save()
            var release: CheckedContinuation<Void, Never>?
            let refresh = Task {
                await store.reload(filter: filter, actor: actor, anchorID: target, beforeQuery: {
                    await withCheckedContinuation { release = $0 }
                    if cancels { throw CancellationError() }
                    throw CocoaError(.fileReadUnknown)
                })
            }
            while release == nil { await Task.yield() }
            XCTAssertEqual(store.rows.map(\.id), oldRows)
            release?.resume()
            await refresh.value
            XCTAssertNotNil(store.errorMessage)
            XCTAssertFalse(store.isLoading)
            XCTAssertEqual(store.snapshot?.revision, oldRevision)
            XCTAssertEqual(store.rows.map(\.id), oldRows, "A failed deep refresh must preserve the coherent loaded presentation")
            await store.loadNextPage(actor: actor)
            XCTAssertEqual(store.rows.map(\.id), oldRows, "Old presentation must not admit new paging until recovery")
            await store.reload(filter: filter, actor: actor, anchorID: target)
            XCTAssertGreaterThanOrEqual(store.rows.count, 300)
            XCTAssertEqual(store.snapshot?.totals.totalCount, 306)
            XCTAssertEqual(store.snapshot?.totals.netExpenseMinorUnits, 306)
            XCTAssertNil(store.errorMessage)
        }
    }

    func testLiveVisibleTargetWinsOverCapturedTargetDuringSuspendedRead() async throws {
        let context = try fixture()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        let captured = store.rows[20].id
        let current = store.rows[90].id
        let moved = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == captured })
        moved.occurredAt = Date(timeIntervalSince1970: -10)
        try context.save()
        var liveTarget = captured
        await store.reload(filter: filter, actor: actor, anchorID: captured,
            anchorProvider: { liveTarget }, beforeQuery: { liveTarget = current })
        XCTAssertEqual(store.resolvedAnchorID, current)
        XCTAssertTrue(store.rows.contains { $0.id == current })
        XCTAssertEqual(store.loadedRange, 0..<100)
        XCTAssertFalse(store.isPresentationStale)
    }

    func testTargetChangesBeyondDetailPlanBeforePublicationKeepOldCoherentView() async throws {
        let context = try fixture()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        let oldRows = store.rows.map(\.id)
        let oldRevision = store.snapshot?.revision
        let captured = oldRows[20], current = oldRows[90]
        let moved = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == captured })
        moved.occurredAt = Date(timeIntervalSince1970: -10)
        try context.save()
        var liveTarget = captured
        await store.reload(filter: filter, actor: actor, anchorID: captured,
            anchorProvider: { liveTarget }, beforePublication: { liveTarget = current })
        XCTAssertNotEqual(store.snapshot?.revision, oldRevision)
        XCTAssertEqual(store.rows.map(\.id), Array(store.snapshot!.transactionIDs[store.loadedRange]))
        XCTAssertFalse(store.isPresentationStale)
        XCTAssertTrue(store.permitsPresentationActions)
        XCTAssertTrue(store.rows.contains { $0.id == current })
        XCTAssertNil(store.errorMessage)
    }

    func testDeletedLiveTargetRestoresNeighbourWithoutOverwritingNewUserChoice() async throws {
        let context = try fixture()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        let captured = store.rows[20].id
        let live = store.rows[90].id
        let neighbour = store.rows[91].id
        let transaction = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == live })
        transaction.deletedAt = Date()
        try context.save()
        await store.reload(filter: filter, actor: actor, anchorID: captured, anchorProvider: { live })
        XCTAssertEqual(store.restorationSourceAnchorID, live)
        XCTAssertEqual(store.resolvedAnchorID, neighbour)
        XCTAssertTrue(store.rows.contains { $0.id == neighbour })
        XCTAssertEqual(store.anchorAfterPublication(current: live), neighbour)
        XCTAssertEqual(store.anchorAfterPublication(current: captured), captured)
        XCTAssertNil(store.anchorAfterPublication(current: nil))
    }

    func testSameRevisionCacheDoesNotResolveAnUnloadedTargetWithoutItsWindow() async throws {
        let context = try fixture()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        let snapshot = try XCTUnwrap(store.snapshot)
        let target = try XCTUnwrap(snapshot.transactionIDs.last)
        XCTAssertFalse(store.rows.contains { $0.id == target })
        await store.reload(filter: filter, actor: actor, anchorID: target)
        XCTAssertEqual(store.snapshot?.revision, snapshot.revision)
        XCTAssertEqual(store.loadedRange, 205..<305)
        XCTAssertEqual(store.rows.count, 100)
        XCTAssertTrue(store.rows.contains { $0.id == target })
        XCTAssertEqual(store.resolvedAnchorID, target)
    }

    func testMiddleWindowAlternatesPagesAndKeepsRangeOnCancellationOrFailure() async throws {
        let context = try fixture(count: 1005)
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        let target = store.rows[20].id
        let transaction = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == target })
        transaction.occurredAt = Date(timeIntervalSince1970: 500.5)
        try context.save()
        let oldEntries = Set(LocalDiagnostics.shared.report().entries.map(\.operationID))
        await store.reload(filter: filter, actor: actor, anchorID: target)
        let snapshot = try XCTUnwrap(store.snapshot)
        XCTAssertEqual(store.rows.count, 100)
        XCTAssertTrue(store.hasPrevious && store.hasMore)
        XCTAssertEqual(store.rows.map(\.id), Array(snapshot.transactionIDs[store.loadedRange]))
        let reads = LocalDiagnostics.shared.report().entries.filter {
            !oldEntries.contains($0.operationID) && $0.stage == .page && $0.revision == snapshot.revision
        }
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads.first?.counts["expectedRows"], 100)
        XCTAssertEqual(reads.first?.counts["actualRows"], 100)
        await store.loadNextPage(actor: actor)
        await store.loadPreviousPage(actor: actor)
        XCTAssertEqual(store.rows.count, 300)
        XCTAssertEqual(store.rows.map(\.id), Array(snapshot.transactionIDs[store.loadedRange]))
        XCTAssertEqual(Set(store.rows.map(\.id)).count, 300)
        let oldRange = store.loadedRange, oldRows = store.rows.map(\.id)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.loadNextPage(actor: actor)
        }
        await cancelled.value
        XCTAssertEqual(store.loadedRange, oldRange)
        XCTAssertEqual(store.rows.map(\.id), oldRows)
        transaction.amountMinorUnits = 2
        try context.save()
        await store.loadNextPage(actor: actor)
        XCTAssertEqual(store.loadedRange, oldRange)
        XCTAssertEqual(store.rows.map(\.id), oldRows)
        XCTAssertTrue(store.permitsPresentationActions)
        XCTAssertNil(store.errorMessage)
        await store.reload(filter: filter, actor: actor, anchorID: target)
        XCTAssertEqual(store.rows.count, 300)
        XCTAssertEqual(store.snapshot?.totals.totalCount, 1005)
        XCTAssertEqual(store.snapshot?.totals.netExpenseMinorUnits, 1006)
    }

    func testAnchorEditedOutOfSameSearchFallsBackToSurvivingMatch() async throws {
        let context = try fixture()
        let all = try context.fetch(FetchDescriptor<FinanceTransaction>())
        for transaction in all { transaction.note = "仍命中" }
        try context.save()
        var search = filter; search.query = "仍命中"
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: search, actor: actor)
        let source = store.rows[20].id, neighbour = store.rows[21].id
        let transaction = try XCTUnwrap(all.first { $0.id == source })
        transaction.note = "离开条件"
        try context.save()
        await store.reload(filter: search, actor: actor, anchorID: source)
        XCTAssertEqual(store.snapshot?.totals.totalCount, 304)
        XCTAssertFalse(store.snapshot!.transactionIDs.contains(source))
        XCTAssertEqual(store.anchorAfterPublication(current: source), neighbour)
        XCTAssertTrue(store.rows.contains { $0.id == neighbour })
        XCTAssertEqual(store.rows.map(\.id), Array(store.snapshot!.transactionIDs[store.loadedRange]))
    }

    func testSupersededFailureDoesNotClearNewGeneration() async throws {
        let context = try fixture(count: 1)
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        var resume: CheckedContinuation<Void, Never>?
        let old = Task {
            await store.reload(filter: filter, actor: actor, beforeQuery: {
                await withCheckedContinuation { resume = $0 }
                throw CocoaError(.fileReadUnknown)
            })
        }
        while resume == nil { await Task.yield() }
        var income = filter; income.mode = .income
        await store.reload(filter: income, actor: actor)
        resume?.resume(); await old.value
        XCTAssertEqual(store.snapshot?.filter.withoutRevision, income)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
    }

    func testRefreshRetainsPageTailWhenUserCanScrollDuringSuspendedQuery() async throws {
        let context = try fixture()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        await store.loadNextPage(actor: actor)
        await store.loadNextPage(actor: actor)
        let capturedAnchor = store.rows[120].id
        let pageTail = try XCTUnwrap(store.rows.last?.id)
        // Trigger a refresh; while it is suspended the user may scroll to pageTail.
        context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 1, occurredAt: Date(),
            localDayKey: "2026-10-01", timeZoneIdentifier: "GMT", accountID: nil, categoryID: nil))
        try context.save()
        await store.reload(filter: filter, actor: actor, anchorID: capturedAnchor, anchorProvider: { pageTail }, beforeQuery: {
            for _ in 0..<25 {
                context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 1, occurredAt: Date(),
                    localDayKey: "2026-10-01", timeZoneIdentifier: "GMT", accountID: nil, categoryID: nil))
            }
            try context.save()
            XCTAssertTrue(store.rows.contains { $0.id == pageTail })
        })
        XCTAssertTrue(store.rows.contains { $0.id == pageTail }, "All surviving visible scroll targets must remain loaded, even if the user moved away from the captured anchor")
        XCTAssertEqual(store.rows.count, 300)
        XCTAssertEqual(store.loadedRange, 26..<326)
        XCTAssertEqual(store.snapshot?.totals.totalCount, 331)
    }

    func testCancelledPageCanRetryAndStalePageFailureCanReload() async throws {
        let context = try fixture()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.loadNextPage(actor: actor)
        }
        await cancelled.value
        XCTAssertEqual(store.rows.count, 100)
        XCTAssertFalse(store.isLoadingPage)
        await store.loadNextPage(actor: actor)
        XCTAssertEqual(store.rows.count, 200)
        context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 1, occurredAt: Date(),
            localDayKey: "2026-10-01", timeZoneIdentifier: "GMT", accountID: nil, categoryID: nil))
        try context.save()
        await store.loadNextPage(actor: actor)
        XCTAssertNotNil(store.snapshot)
        XCTAssertEqual(store.rows.count, 200)
        XCTAssertFalse(store.isPresentationStale)
        XCTAssertTrue(store.permitsPresentationActions)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.snapshot?.totals.totalCount, 306)
        XCTAssertNil(store.errorMessage)
    }

    func testNewRequestSupersedesSuspendedDifferentFilterRequest() async throws {
        let context = try fixture(count: 1)
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        var other = filter
        other.mode = .income
        var resume: CheckedContinuation<Void, Never>?
        let old = Task {
            await store.reload(filter: other, actor: actor, beforeQuery: {
                await withCheckedContinuation { resume = $0 }
            })
        }
        while resume == nil { await Task.yield() }
        await store.reload(filter: filter, actor: actor)
        resume?.resume()
        await old.value
        XCTAssertEqual(store.snapshot?.filter.withoutRevision, filter)
        XCTAssertEqual(store.rows.count, 1)
    }
}
