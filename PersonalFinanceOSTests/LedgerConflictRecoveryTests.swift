import Foundation
import SwiftData
import SwiftUI
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class LedgerConflictRecoveryTests: XCTestCase {
    private func fixture(_ count: Int = 1) throws -> ModelContainer {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        for index in 0..<count {
            context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 1,
                occurredAt: Date(timeIntervalSince1970: Double(index)), localDayKey: "2026-10-01", timeZoneIdentifier: "GMT"))
        }
        try context.save()
        return container
    }

    func testTwelveThousandRecoversAfterRealBoundaryReleaseWithoutNotification() async throws {
        let container = try fixture(12_000)
        let actor = LedgerAnalysisActor(modelContainer: container)
        let store = LedgerAnalysisStore()
        let gate = RecoveryBoundary()
        let holder = Task.detached { gate.hold() }
        let acquired = await Task.detached { gate.wait() }.value
        XCTAssertTrue(acquired)
        defer { gate.release.signal() }
        let stamp = LedgerSaveRevision.shared.contentRevision
        var stages: [LedgerAnalysisStore.ReadStage] = []
        let clock = ContinuousClock.now
        await store.reload(filter: .init(dateRange: nil), actor: actor, onConflict: { stage, attempt in
            stages.append(stage)
            XCTAssertEqual(attempt, 1)
            gate.release.signal()
        })
        await holder.value
        XCTAssertEqual(stages, [.snapshot])
        XCTAssertEqual(LedgerSaveRevision.shared.contentRevision, stamp, "Unlock must not fake a business save")
        XCTAssertEqual(store.snapshot?.totals.totalCount, 12_000)
        XCTAssertEqual(store.snapshot?.totals.netExpenseMinorUnits, 12_000)
        XCTAssertEqual(store.rows.count, 100)
        XCTAssertNil(store.errorMessage)
        print("LEDGER_RECOVERY_12K elapsed=\(clock.duration(to: .now)) retries=\(stages.count) revision=\(stamp) request=\(store.requestIdentifier) stages=\(stages.map(\.rawValue))")
    }

    func testCancellationDuringBackoffPreservesCoherentOldResult() async throws {
        let container = try fixture()
        let actor = LedgerAnalysisActor(modelContainer: container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: .init(dateRange: nil), actor: actor)
        let old = store.rows
        let context = ModelContext(container)
        context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 2, occurredAt: Date(), localDayKey: "2026-10-01", timeZoneIdentifier: "GMT"))
        try context.save()
        let conflict = expectation(description: "publication conflict")
        let task = Task {
            await store.reload(filter: .init(dateRange: nil), actor: actor,
                beforePublication: { throw LedgerAnalysisError.staleSnapshot },
                onConflict: { _, _ in conflict.fulfill() })
        }
        await fulfillment(of: [conflict], timeout: 3)
        task.cancel()
        await task.value
        XCTAssertEqual(store.rows.map(\.id), old.map(\.id))
        XCTAssertTrue(store.isPresentationStale)
        XCTAssertTrue(store.wasCancelled)
        print("LEDGER_RECOVERY_CANCEL request=\(store.requestIdentifier) revision=\(LedgerSaveRevision.shared.contentRevision) cancelled=\(store.wasCancelled)")
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.permitsPresentationActions)
        await store.reload(filter: .init(dateRange: nil), actor: actor)
        XCTAssertEqual(store.snapshot?.totals.totalCount, 2)
        XCTAssertNil(store.errorMessage)
    }

    func testNewFilterSupersedesSleepingConflictRequest() async throws {
        let container = try fixture()
        let actor = LedgerAnalysisActor(modelContainer: container)
        let store = LedgerAnalysisStore()
        let conflict = expectation(description: "old request waiting")
        let old = Task {
            await store.reload(filter: .init(dateRange: nil), actor: actor,
                beforePublication: { throw LedgerAnalysisError.staleSnapshot },
                onConflict: { _, _ in conflict.fulfill() })
        }
        await fulfillment(of: [conflict], timeout: 3)
        var income = LedgerFilter(dateRange: nil); income.mode = .income
        await store.reload(filter: income, actor: actor)
        await old.value
        XCTAssertEqual(store.snapshot?.filter.withoutRevision, income)
        XCTAssertEqual(store.snapshot?.totals.totalCount, 0)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
    }

    func testPersistentConflictKeepsEntireSameFilterPresentationUntilManualRecovery() async throws {
        let container = try fixture(305)
        let actor = LedgerAnalysisActor(modelContainer: container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: .init(dateRange: nil), actor: actor)
        await store.loadNextPage(actor: actor)
        let oldIDs = store.rows.map(\.id)
        let oldRevision = store.snapshot?.revision
        let context = ModelContext(container)
        context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 7,
            occurredAt: Date(), localDayKey: "2026-10-01", timeZoneIdentifier: "GMT"))
        try context.save()
        var conflicts = 0
        await store.reload(filter: .init(dateRange: nil), actor: actor,
            beforePublication: { throw LedgerAnalysisError.staleSnapshot }, onConflict: { stage, attempt in
                conflicts += 1
                XCTAssertEqual(stage, .anchor)
                print("LEDGER_CONFLICT request=\(store.requestIdentifier) revision=\(LedgerSaveRevision.shared.contentRevision) stage=\(stage.rawValue) retry=\(attempt)")
            })
        XCTAssertEqual(conflicts, 4)
        XCTAssertEqual(store.snapshot?.revision, oldRevision)
        XCTAssertEqual(store.snapshot?.totals.totalCount, 305)
        XCTAssertEqual(store.rows.map(\.id), oldIDs)
        XCTAssertTrue(store.isPresentationStale)
        XCTAssertFalse(store.permitsPresentationActions)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.errorMessage, "账本暂时无法完成一致读取，请重新加载。")
        await store.reload(filter: .init(dateRange: nil), actor: actor)
        XCTAssertEqual(store.snapshot?.totals.totalCount, 306)
        XCTAssertEqual(store.snapshot?.totals.netExpenseMinorUnits, 312)
        XCTAssertNil(store.errorMessage)
    }

    func testPageConflictRestoresLiveViewportRatherThanMovedFirstRow() async throws {
        let container = try fixture(305)
        let actor = LedgerAnalysisActor(modelContainer: container)
        let store = LedgerAnalysisStore()
        await store.reload(filter: .init(dateRange: nil), actor: actor)
        await store.loadNextPage(actor: actor)
        let visible = store.rows[20].id
        let first = store.rows[0].id
        let context = ModelContext(container)
        let moved = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == first })
        moved.occurredAt = Date(timeIntervalSince1970: -1)
        try context.save()
        await store.loadNextPage(actor: actor, anchorProvider: { visible })
        XCTAssertEqual(store.resolvedAnchorID, visible)
        XCTAssertTrue(store.rows.contains { $0.id == visible })
        XCTAssertEqual(store.rows.map(\.id), Array(store.snapshot!.transactionIDs[store.loadedRange]))
        XCTAssertNil(store.errorMessage)
    }

    // Call the action used by LedgerDrilldownView's actual page buttons, including
    // the binding publication, rather than directly supplying a provider to Store.
    func testDrilldownPageActionsKeepLiveRowWhenFirstRowMoves() async throws {
        for direction in [LedgerDrilldownView.PageDirection.next, .previous] {
            let (context, store, actor) = try await drilldownFixture(direction)
            let first = store.rows[0].id
            var visible: UUID? = store.rows[20].id
            let expected = visible
            let moved = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == first })
            moved.occurredAt = Date(timeIntervalSince1970: direction == .next ? -1 : 10_000)
            try context.save()
            await LedgerDrilldownView.loadPage(direction, store: store, actor: actor,
                anchor: Binding(get: { visible }, set: { visible = $0 }))
            XCTAssertEqual(visible, expected)
            XCTAssertEqual(store.resolvedAnchorID, expected)
            XCTAssertTrue(store.rows.contains { $0.id == expected })
            XCTAssertEqual(store.rows.map(\.id), Array(store.snapshot!.transactionIDs[store.loadedRange]))
            XCTAssertEqual(store.snapshot?.totals.totalCount, 305)
            XCTAssertNil(store.errorMessage)
        }
    }

    func testDrilldownPageActionsApplyDeletedVisibleRowsNeighbour() async throws {
        for direction in [LedgerDrilldownView.PageDirection.next, .previous] {
            let (context, store, actor) = try await drilldownFixture(direction)
            var visible: UUID? = store.rows[20].id
            let neighbour = store.rows[21].id
            let removed = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == visible })
            removed.deletedAt = Date()
            try context.save()
            await LedgerDrilldownView.loadPage(direction, store: store, actor: actor,
                anchor: Binding(get: { visible }, set: { visible = $0 }))
            XCTAssertEqual(visible, neighbour, "The page action must apply publication restoration to the scroll binding")
            XCTAssertTrue(store.rows.contains { $0.id == neighbour })
            XCTAssertEqual(store.snapshot?.totals.totalCount, 304)
            XCTAssertNil(store.errorMessage)
        }
    }

    func testDrilldownPageActionsKeepPinnedRevision() async throws {
        for direction in [LedgerDrilldownView.PageDirection.next, .previous] {
            let (context, store, actor) = try await drilldownFixture(direction)
            let snapshot = try XCTUnwrap(store.snapshot)
            var visible: UUID? = store.rows[20].id
            let original = visible
            await store.reload(filter: snapshot.filter, actor: actor, anchorID: visible, requiresExactRevision: true)
            context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 17,
                occurredAt: Date(), localDayKey: "2026-10-01", timeZoneIdentifier: "GMT"))
            try context.save()
            await LedgerDrilldownView.loadPage(direction, store: store, actor: actor,
                anchor: Binding(get: { visible }, set: { visible = $0 }))
            XCTAssertEqual(visible, original)
            XCTAssertEqual(store.snapshot?.revision, snapshot.revision)
            XCTAssertEqual(store.snapshot?.totals.totalCount, 305)
            XCTAssertTrue(store.isPresentationStale)
            XCTAssertNotNil(store.errorMessage)
        }
    }

    func testDrilldownPageActionSamplesBindingAfterSuspension() async throws {
        let (context, store, actor) = try await drilldownFixture(.next)
        var visible: UUID? = store.rows[20].id
        let newVisible = store.rows[50].id
        let first = store.rows[0].id
        let moved = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == first })
        moved.occurredAt = Date(timeIntervalSince1970: -1)
        try context.save()
        let gate = DrilldownReadGate()
        let blocker = Task { try await actor.snapshot(filter: .init(dateRange: nil), afterBatch: { gate.holdOnce() }) }
        let acquired = await Task.detached { gate.wait() }.value
        XCTAssertTrue(acquired)
        defer { gate.release.signal() }
        let page = Task { await LedgerDrilldownView.loadPage(.next, store: store, actor: actor,
            anchor: Binding(get: { visible }, set: { visible = $0 })) }
        await waitUntil { store.isLoadingPage }
        visible = newVisible
        gate.release.signal()
        _ = try await blocker.value
        await page.value
        XCTAssertEqual(visible, newVisible)
        XCTAssertEqual(store.resolvedAnchorID, newVisible)
        XCTAssertTrue(store.rows.contains { $0.id == newVisible })
    }

    func testDrilldownCancelledOrReplacedPageCannotRestoreOldBinding() async throws {
        for replace in [false, true] {
            let (_, store, actor) = try await drilldownFixture(.next)
            let oldIDs = store.rows.map(\.id)
            var visible: UUID? = store.rows[20].id
            let original = visible
            let gate = DrilldownReadGate()
            let blocker = Task { try await actor.snapshot(filter: .init(dateRange: nil), afterBatch: { gate.holdOnce() }) }
            let acquired = await Task.detached { gate.wait() }.value
            XCTAssertTrue(acquired)
            defer { gate.release.signal() }
            let page = Task { await LedgerDrilldownView.loadPage(.next, store: store, actor: actor,
                anchor: Binding(get: { visible }, set: { visible = $0 })) }
            await waitUntil { store.isLoadingPage }
            if replace {
                var income = LedgerFilter(dateRange: nil); income.mode = .income
                let replacement = Task { await store.reload(filter: income, actor: actor) }
                await waitUntil { store.isLoading }
                visible = nil // same reset performed by the view's filter onChange
                gate.release.signal()
                await replacement.value
                await page.value
                XCTAssertNil(visible)
                XCTAssertEqual(store.snapshot?.filter.mode, .income)
                XCTAssertTrue(store.rows.isEmpty)
            } else {
                page.cancel()
                gate.release.signal()
                await page.value
                XCTAssertEqual(visible, original)
                XCTAssertEqual(store.rows.map(\.id), oldIDs)
            }
            _ = try await blocker.value
            XCTAssertFalse(store.isLoadingPage)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Page action did not reach its suspended state")
    }

    private func drilldownFixture(_ direction: LedgerDrilldownView.PageDirection) async throws
        -> (ModelContext, LedgerAnalysisStore, LedgerAnalysisActor) {
        let container = try fixture(direction == .next ? 305 : 100)
        let context = ModelContext(container)
        let actor = LedgerAnalysisActor(modelContainer: container)
        let store = LedgerAnalysisStore()
        let filter = LedgerFilter(dateRange: nil)
        await store.reload(filter: filter, actor: actor)
        if direction == .next {
            await store.loadNextPage(actor: actor)
            XCTAssertEqual(store.loadedRange, 0..<200)
        } else {
            let anchor = store.rows[0].id
            for index in 100..<305 {
                context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 1,
                    occurredAt: Date(timeIntervalSince1970: Double(index)), localDayKey: "2026-10-01", timeZoneIdentifier: "GMT"))
            }
            try context.save()
            await store.reload(filter: filter, actor: actor, anchorID: anchor)
            XCTAssertEqual(store.loadedRange, 205..<305)
        }
        return (context, store, actor)
    }

    func testPinnedRevisionNeverSilentlyRebases() async throws {
        let container = try fixture()
        let actor = LedgerAnalysisActor(modelContainer: container)
        let context = ModelContext(container)
        var filter = LedgerFilter(dateRange: nil)
        filter.revision = try LedgerSaveRevision.shared.readContentStamp()
        context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 1, occurredAt: Date(), localDayKey: "2026-10-01", timeZoneIdentifier: "GMT"))
        try context.save()
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor, requiresExactRevision: true,
            onConflict: { _, _ in XCTFail("Pinned facts cannot be retried as a newer revision") })
        XCTAssertNil(store.snapshot)
        XCTAssertNotNil(store.errorMessage)
    }
}

private final class RecoveryBoundary: @unchecked Sendable {
    let acquired = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func hold() {
        LedgerSaveRevision.shared.withImportBoundary {
            acquired.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 15), .success)
        }
    }
    func wait() -> Bool { acquired.wait(timeout: .now() + 15) == .success }
}

private final class DrilldownReadGate: @unchecked Sendable {
    let acquired = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var held = false
    func holdOnce() {
        let shouldHold = lock.withLock { if held { return false }; held = true; return true }
        guard shouldHold else { return }
        acquired.signal()
        XCTAssertEqual(release.wait(timeout: .now() + 15), .success)
    }
    func wait() -> Bool { acquired.wait(timeout: .now() + 15) == .success }
}
