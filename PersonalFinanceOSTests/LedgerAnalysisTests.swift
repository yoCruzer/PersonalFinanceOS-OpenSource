import SwiftData
import XCTest
@testable import PersonalFinanceOS

private final class AnalysisReadGate: @unchecked Sendable {
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var used = false
    func checkpoint() throws {
        XCTAssertFalse(Thread.isMainThread)
        lock.lock()
        let first = !used
        used = true
        lock.unlock()
        guard first else { return }
        reached.signal()
        guard release.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
    }
    func wait() -> Bool { reached.wait(timeout: .now() + 10) == .success }
}

@MainActor
final class LedgerAnalysisTests: XCTestCase {
    private var september: LedgerFilter { LedgerFilter(dateRange: LocalDayRange(lowerBound: "2026-09-01", upperBound: "2026-10-01")) }

    func testInsightsVisibleStatesStayCoherentWhileSameRangeEditPrecedesDelayedTrend() async throws {
        let context = try fixture()
        let first = PersonalFinanceOS.Category(kind: .expense, name: "A", symbolName: "star", colorToken: "blue")
        let second = PersonalFinanceOS.Category(kind: .expense, name: "B", symbolName: "star", colorToken: "green")
        context.insert(first)
        context.insert(second)
        _ = row(.expense, 100, categoryID: first.id, in: context)
        let changed = row(.expense, 100, categoryID: second.id, in: context)
        try context.save()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = InsightsDisplayStore()
        let month = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        await store.reload(filter: september, month: month, actor: actor)
        XCTAssertEqual(store.currentTotals.netExpenseMinorUnits, 200)
        changed.deletedAt = Date()
        try context.save()
        var stages: [InsightsDisplayStore.Stage] = []
        await store.reload(filter: september, month: month, actor: actor) { stage in
            stages.append(stage)
            if let finance = store.finance {
                XCTAssertEqual(finance.categorySpending.reduce(0) { $0 + $1.amountMinorUnits }, store.currentTotals.netExpenseMinorUnits,
                    "Every visible state must use one generation, including while trend is delayed")
                XCTAssertEqual(finance.summary.expenseMinorUnits, store.currentTotals.netExpenseMinorUnits)
            }
            if stage == .trendLoading {
                // This checkpoint suspends the actual trend query after range publication.
                await Task.yield()
                XCTAssertEqual(store.currentTotals.netExpenseMinorUnits, 100)
            }
        }
        XCTAssertEqual(stages, [.rangeLoading, .rangeLoaded, .trendLoading, .trendLoaded])
        XCTAssertEqual(store.currentTotals.netExpenseMinorUnits, 100)
        changed.deletedAt = nil
        changed.amountMinorUnits = 50
        try context.save()
        await store.reload(filter: september, month: month, actor: actor) { _ in
            XCTAssertEqual(store.finance?.categorySpending.reduce(0) { $0 + $1.amountMinorUnits },
                store.currentTotals.netExpenseMinorUnits)
            XCTAssertEqual(store.finance?.summary.expenseMinorUnits, store.currentTotals.netExpenseMinorUnits)
        }
        XCTAssertEqual(store.currentTotals.netExpenseMinorUnits, 150)
        XCTAssertEqual(store.trendDisplay?.revision, store.display?.revision)
        XCTAssertEqual(store.trendDisplay?.filter.withoutRevision, LedgerFilter.sixMonths(endingAt: month).withoutRevision)
    }

    func testInsightsRangeFailureAndCancellationKeepCoherentPresentationAndTrendFailureIsExplicit() async throws {
        let context = try fixture()
        _ = row(.expense, 200, in: context)
        try context.save()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = InsightsDisplayStore()
        let month = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        await store.reload(filter: september, month: month, actor: actor)
        let oldDisplay = try XCTUnwrap(store.display)
        _ = row(.expense, 100, in: context)
        try context.save()
        await store.reload(filter: september, month: month, actor: actor) { stage in
            if stage == .rangeLoading { throw CocoaError(.fileReadUnknown) }
            if stage == .trendLoading { throw CocoaError(.fileReadUnknown) }
        }
        XCTAssertEqual(store.display?.revision, oldDisplay.revision)
        XCTAssertEqual(store.currentTotals.netExpenseMinorUnits, 200)
        XCTAssertEqual(store.finance?.summary.expenseMinorUnits, 200)
        XCTAssertNotNil(store.rangeStore.errorMessage)
        XCTAssertNil(store.trendDisplay)
        XCTAssertNil(store.trendFinance)
        guard case .failed = store.trendState else { return XCTFail("A failed trend must not become empty data") }
        let cancelled = Task {
            await store.reload(filter: september, month: month, actor: actor) { stage in
                if stage == .rangeLoading { throw CancellationError() }
            }
        }
        await cancelled.value
        XCTAssertEqual(store.currentTotals.netExpenseMinorUnits, 200)
        XCTAssertEqual(store.trendState, .cancelled)
        // Explicit task cancellation after range is available, before the trend query completes.
        _ = row(.expense, 50, in: context)
        try context.save()
        let task = Task {
            await store.reload(filter: september, month: month, actor: actor) { stage in
                if stage == .trendLoading {
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw CancellationError()
                }
            }
        }
        await task.value
        XCTAssertEqual(store.currentTotals.netExpenseMinorUnits, 350)
        XCTAssertEqual(store.finance?.categorySpending.reduce(0) { $0 + $1.amountMinorUnits }, 350)
        XCTAssertEqual(store.trendState, .cancelled)
        XCTAssertNil(store.trendFinance)
        XCTAssertFalse(store.isRefreshing)
    }

    func testAmountsCountsHistoricalCategoriesAndDirectParentAddUp() async throws {
        let context = try fixture()
        let root = PersonalFinanceOS.Category(kind: .expense, name: "历史餐饮", symbolName: "fork.knife", colorToken: "orange")
        let child = PersonalFinanceOS.Category(kind: .expense, name: "旧混合类", parentID: root.id, symbolName: "fork.knife", colorToken: "orange")
        root.isHidden = true
        child.archivedAt = Date()
        context.insert(root)
        context.insert(child)
        _ = row(.expense, 100, categoryID: root.id, in: context)
        _ = row(.expense, 200, categoryID: child.id, in: context)
        _ = row(.refund, 500, categoryID: child.id, in: context)
        _ = row(.income, 700, in: context)
        _ = row(.transfer, 900, in: context)
        _ = row(.expense, 50, in: context)
        try context.save()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let result = try await actor.snapshot(filter: september)
        XCTAssertEqual(result.totals.grossExpenseMinorUnits, 350)
        XCTAssertEqual(result.totals.refundMinorUnits, 500)
        XCTAssertEqual(result.totals.netExpenseMinorUnits, -150)
        XCTAssertEqual(result.totals.incomeMinorUnits, 700)
        XCTAssertEqual(result.totals.balanceMinorUnits, 850)
        XCTAssertEqual(result.totals.expenseCount, 3)
        XCTAssertEqual(result.totals.refundCount, 1)
        XCTAssertEqual(result.totals.transferCount, 1)
        XCTAssertEqual(result.totals.totalCount, 6)
        XCTAssertEqual(result.totals.averageExpenseMinorUnits, 116)
        XCTAssertEqual(result.rootTotals[root.id]?.grossExpenseMinorUnits, 300)
        XCTAssertEqual(result.directCategoryTotals[root.id]?.grossExpenseMinorUnits, 100)
        XCTAssertEqual(result.directCategoryTotals[child.id]?.grossExpenseMinorUnits, 200)
        var filter = september
        filter.category = .node(root.id)
        let node = try await actor.snapshot(filter: filter)
        XCTAssertEqual(node.totals.totalCount, 3)
        filter.category = .direct(root.id)
        let direct = try await actor.snapshot(filter: filter)
        XCTAssertEqual(direct.totals.totalCount, 1)
        filter.category = .uncategorized
        let uncategorized = try await actor.snapshot(filter: filter)
        XCTAssertEqual(uncategorized.totals.totalCount, 3)
    }

    func testStoredLocalDaysModesMultiTagAndTransferAccountAreShared() async throws {
        let context = try fixture()
        let account = UUID(), destination = UUID()
        let first = Tag(name: "工作", colorToken: "blue"), second = Tag(name: "差旅", colorToken: "green")
        context.insert(first)
        context.insert(second)
        let included = row(.expense, 100, day: "2026-09-01", in: context)
        included.timeZoneIdentifier = "Pacific/Honolulu"
        included.rawMerchantText = "车站"
        included.note = "出差票据"
        included.tags = [first, second]
        _ = row(.expense, 999, day: "2026-10-01", in: context)
        _ = row(.expense, 888, day: "2026-08-31", in: context)
        let deleted = row(.expense, 777, in: context)
        deleted.deletedAt = Date()
        let transfer = row(.transfer, 400, in: context)
        transfer.accountID = account
        transfer.destinationAccountID = destination
        try context.save()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        var filter = september
        filter.tagIDs = [first.id, second.id]
        filter.query = "票据"
        filter.merchant = "车站"
        let result = try await actor.snapshot(filter: filter)
        XCTAssertEqual(result.transactionIDs, [included.id])
        XCTAssertEqual(result.totals.grossExpenseMinorUnits, 100)
        filter = september
        filter.mode = .transfer
        filter.accountID = destination
        let transfers = try await actor.snapshot(filter: filter)
        XCTAssertEqual(transfers.transactionIDs, [transfer.id])
        XCTAssertEqual(transfers.totals.balanceMinorUnits, 0)
        filter = september
        filter.deletion = .deleted
        let removed = try await actor.snapshot(filter: filter)
        XCTAssertEqual(removed.transactionIDs, [deleted.id])
    }

    func testStablePagingAndExportUseEveryFilteredRow() async throws {
        let context = try fixture()
        for index in 0..<305 {
            let value = row(.expense, 1, in: context)
            value.note = "完整导出-\(index)"
        }
        try context.save()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let snapshot = try await actor.snapshot(filter: september, pageSize: 100)
        XCTAssertEqual(snapshot.firstPage.count, 100)
        XCTAssertEqual(snapshot.totals.grossExpenseMinorUnits, 305)
        XCTAssertEqual(snapshot.maximumBatchCount, 256)
        let second = try await actor.page(snapshot: snapshot, offset: 100)
        let third = try await actor.page(snapshot: snapshot, offset: 200, limit: 200)
        let ids = (snapshot.firstPage + second + third).map(\.id)
        XCTAssertEqual(ids, snapshot.transactionIDs)
        XCTAssertEqual(Set(ids).count, 305)
        let csv = String(decoding: try await actor.exportData(snapshot: snapshot), as: UTF8.self)
        XCTAssertEqual(csv.components(separatedBy: "\r\n").count, 306)
        XCTAssertTrue(csv.contains("完整导出-304"))
        let first = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first)
        first.deletedAt = Date()
        try context.save()
        do { _ = try await actor.page(snapshot: snapshot, offset: 100); XCTFail("Old pages must not mix revisions") }
        catch { XCTAssertTrue(error is LedgerAnalysisError) }
        do { _ = try await actor.exportData(snapshot: snapshot); XCTFail("Old exports must not mix revisions") }
        catch { XCTAssertTrue(error is LedgerAnalysisError) }
    }

    func testConcurrentMainActorSaveDiscardsPartialScanAndRebuildsTotalsAndIDsTogether() async throws {
        let context = try fixture()
        for _ in 0..<260 { _ = row(.expense, 1, in: context) }
        try context.save()
        let gate = AnalysisReadGate()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let filter = september
        let reading = Task { try await actor.snapshot(filter: filter, afterBatch: { try gate.checkpoint() }) }
        let reached = await Task.detached { gate.wait() }.value
        XCTAssertTrue(reached)
        _ = row(.refund, 500, in: context)
        try context.save()
        gate.release.signal()
        let result = try await reading.value
        XCTAssertEqual(result.totals.netExpenseMinorUnits, -240)
        XCTAssertEqual(result.transactionIDs.count, 261)
        XCTAssertEqual(result.revision, try LedgerSaveRevision.shared.readContentStamp())
    }

    func testOverflowFailsInsteadOfPublishingSaturatedAmount() async throws {
        let context = try fixture()
        _ = row(.expense, .max, in: context)
        _ = row(.expense, 1, in: context)
        try context.save()
        do { _ = try await LedgerAnalysisActor(modelContainer: context.container).snapshot(filter: september); XCTFail("Overflow must fail") }
        catch { XCTAssertTrue(error is LedgerAnalysisError) }
    }

    func testStoreRejectsSaveBetweenReadAndPublicationThenRefreshesSameFilter() async throws {
        let context = try fixture()
        _ = row(.expense, 100, in: context)
        try context.save()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        var writes = 0
        await store.reload(filter: september, actor: actor, beforePublication: {
            writes += 1
            _ = self.row(.refund, 200, in: context)
            try context.save()
        })
        XCTAssertEqual(writes, 5)
        XCTAssertNil(store.snapshot)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        await store.reload(filter: september, actor: actor)
        XCTAssertEqual(store.snapshot?.totals.netExpenseMinorUnits, -900)
        XCTAssertEqual(store.rows.count, 6)
    }

    func testStorePreservesLoadedRowsWithoutMutationAndReloadsThroughExistingAnchor() async throws {
        let context = try fixture()
        for _ in 0..<205 { _ = row(.expense, 1, in: context) }
        try context.save()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: september, actor: actor)
        await store.loadNextPage(actor: actor)
        XCTAssertEqual(store.rows.count, 200)
        let anchor = try XCTUnwrap(store.rows.last?.id)
        await store.reload(filter: september, actor: actor)
        XCTAssertEqual(store.rows.count, 200)
        _ = row(.refund, 300, in: context)
        try context.save()
        await store.reload(filter: september, actor: actor, anchorID: anchor)
        XCTAssertTrue(store.rows.contains { $0.id == anchor })
        XCTAssertEqual(store.snapshot?.totals.netExpenseMinorUnits, -95)
        XCTAssertEqual(store.snapshot?.totals.totalCount, 206)
    }

    func testDashboardAdapterUsesNetCategoriesSignedTrendAndOriginalIncomeType() async throws {
        let context = try fixture()
        let incomeCategory = PersonalFinanceOS.Category(kind: .income, name: "退款", symbolName: "arrow.uturn.backward", colorToken: "green")
        context.insert(incomeCategory)
        _ = row(.expense, 100, in: context)
        _ = row(.refund, 300, in: context)
        _ = row(.income, 50, categoryID: incomeCategory.id, in: context)
        _ = row(.transfer, 999, in: context)
        try context.save()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let month = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let analysis = try await LedgerAnalysisActor(modelContainer: context.container).snapshot(filter: .sixMonths(endingAt: month, calendar: calendar))
        let view = FinanceInsightsSnapshot.from(analysis, selectedMonth: month, calendar: calendar)
        XCTAssertEqual(view.summary.expenseMinorUnits, -200)
        XCTAssertEqual(view.summary.incomeMinorUnits, 50)
        XCTAssertEqual(view.summary.balanceMinorUnits, 250)
        XCTAssertEqual(view.categorySpending.map(\.amountMinorUnits), [-200])
        XCTAssertEqual(view.categorySpending.map(\.transactionCount), [2])
        XCTAssertEqual(view.activity.totalCount, 4)
        XCTAssertEqual(view.activity.expenseCount, 1)
        XCTAssertEqual(view.activity.averageExpenseMinorUnits, 100)
        XCTAssertEqual(view.trend.last?.expenseMinorUnits, -200)
        XCTAssertEqual(ExpenseTrendSummaryService.summarize(view.trend).averageMinorUnits, -33)
    }

    func testCalendarCountsAllTypesAndDayDetailsUseStoredDayAndSameRevision() async throws {
        let context = try fixture()
        let expense = row(.expense, 100, day: "2026-09-10", in: context)
        let refund = row(.refund, 300, day: "2026-09-10", in: context)
        let income = row(.income, 50, day: "2026-09-10", in: context)
        let transfer = row(.transfer, 900, day: "2026-09-10", in: context)
        _ = row(.expense, 500, day: "2026-09-11", in: context)
        try context.save()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let month = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let snapshot = try await actor.snapshot(filter: september)
        let days = BillCalendarService.days(in: month, totalsByDay: snapshot.dayTotals, calendar: calendar)
        let day = try XCTUnwrap(days.compactMap { $0 }.first { $0.localDayKey == "2026-09-10" })
        XCTAssertEqual(day.transactionCount, 4)
        XCTAssertEqual(day.expenseCount, 1)
        XCTAssertEqual(day.refundCount, 1)
        XCTAssertEqual(day.transferCount, 1)
        XCTAssertEqual(day.grossExpenseMinorUnits, 100)
        XCTAssertEqual(day.refundMinorUnits, 300)
        XCTAssertEqual(day.expenseMinorUnits, -200)
        XCTAssertEqual(day.balanceMinorUnits, 250)
        var filter = LedgerFilter.day(day.date, calendar: calendar)
        filter.revision = snapshot.revision
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor, requiresExactRevision: true)
        XCTAssertEqual(Set(store.rows.map(\.id)), [expense.id, refund.id, income.id, transfer.id])
        XCTAssertEqual(store.snapshot?.totals, snapshot.dayTotals[day.localDayKey])
        _ = row(.refund, 700, day: "2026-09-10", in: context)
        try context.save()
        await store.reload(filter: filter, actor: actor, requiresExactRevision: true)
        XCTAssertNil(store.snapshot, "Day rows cannot refresh against an old calendar total")
        XCTAssertNotNil(store.errorMessage)
        let updated = try await actor.snapshot(filter: september)
        filter.revision = updated.revision
        await store.reload(filter: filter, actor: actor, requiresExactRevision: true)
        XCTAssertEqual(store.snapshot?.totals.netExpenseMinorUnits, -900)
        XCTAssertEqual(store.rows.count, 5)
    }

    private func fixture() throws -> ModelContext { ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true)) }

    @discardableResult
    private func row(_ type: TransactionType, _ amount: Int64, day: String = "2026-09-10", categoryID: UUID? = nil,
                     in context: ModelContext) -> FinanceTransaction {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let value = FinanceTransaction(type: type, amountMinorUnits: amount, occurredAt: date, localDayKey: day,
            timeZoneIdentifier: "Asia/Shanghai", accountID: nil, categoryID: categoryID, createdAt: date, updatedAt: date)
        context.insert(value)
        return value
    }
}
