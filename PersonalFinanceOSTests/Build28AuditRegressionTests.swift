import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class Build28AuditRegressionTests: XCTestCase {
    func testReceiptOnlySaveDoesNotRejectUsagePublication() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        context.insert(AppMetadata())
        context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 100,
            occurredAt: Date(), localDayKey: "2026-10-01", timeZoneIdentifier: "GMT"))
        try context.save()
        let computation = try await LedgerUsageMetricsActor(modelContainer: context.container).compute()
        let content = try LedgerSaveRevision.shared.readContentStamp()
        let receipts = ModelContext(context.container)
        receipts.insert(SyncProjectionReceipt(projectionID: UUID()))
        try receipts.save()
        XCTAssertEqual(try LedgerSaveRevision.shared.readContentStamp(), content)
        let store = LedgerUsageMetricsStore()
        await store.refreshIfNeeded(revision: 1) { computation }
        XCTAssertEqual(store.metrics?.activeTransactionCount, 1)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.revisionAtComputation, 1)
    }

    func testUsageRejectsMissingOrAmbiguousStartDateAndCanRetryAfterBootstrap() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        let actor = LedgerUsageMetricsActor(modelContainer: context.container)
        do { _ = try await actor.compute(); XCTFail("Missing date must not become today") }
        catch { XCTAssertTrue(error is LedgerUsageMetricsError) }
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let valid = try await actor.compute()
        XCTAssertEqual(valid.metrics.activeTransactionCount, 0)
        XCTAssertNil(valid.metrics.earliestLocalDayKey)
        context.insert(AppMetadata(createdAt: .distantPast))
        try context.save()
        do { _ = try await actor.compute(); XCTFail("Ambiguous date must not use first row") }
        catch { XCTAssertTrue(error is LedgerUsageMetricsError) }
    }

    func testAllFourMetricsRefreshAfterInsertDateEditDeleteAndRemoteStyleContextSave() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(AppMetadata(createdAt: created))
        let reader = LedgerUsageMetricsActor(modelContainer: container)
        let store = LedgerUsageMetricsStore()
        let center = LedgerChangeCenter()
        center.observeSaves(in: container)
        try context.save()
        let one = FinanceTransaction(type: .income, amountMinorUnits: 123,
            occurredAt: Date(), localDayKey: "2026-10-01", timeZoneIdentifier: "Asia/Shanghai")
        let two = FinanceTransaction(type: .transfer, amountMinorUnits: 456,
            occurredAt: Date(), localDayKey: "2026-10-02", timeZoneIdentifier: "America/New_York")
        context.insert(one); context.insert(two); try context.save()
        center.recordMutation()
        await store.refreshIfNeeded(revision: center.revision) { try await reader.compute(batchSize: 1) }
        XCTAssertEqual(store.metrics, .init(appCreatedAt: created, activeTransactionCount: 2,
            earliestLocalDayKey: "2026-10-01", distinctActiveDayCount: 2))
        one.localDayKey = "2026-10-02"; try context.save(); center.recordMutation()
        await store.refreshIfNeeded(revision: center.revision) { try await reader.compute() }
        XCTAssertEqual(store.metrics?.distinctActiveDayCount, 1)
        XCTAssertEqual(store.metrics?.earliestLocalDayKey, "2026-10-02")
        one.softDelete(); two.softDelete(); try context.save(); center.recordMutation()
        await store.refreshIfNeeded(revision: center.revision) { try await reader.compute() }
        XCTAssertEqual(store.metrics?.activeTransactionCount, 0)
        XCTAssertNil(store.metrics?.earliestLocalDayKey)
        XCTAssertEqual(store.metrics?.distinctActiveDayCount, 0)
        // Another ModelContext models the save boundary used by import/sync application.
        // This is not a real CloudKit test or a substitute for import parsing tests.
        let remote = ModelContext(container)
        remote.insert(FinanceTransaction(type: .refund, amountMinorUnits: 1,
            occurredAt: Date(), localDayKey: "2010-01-01", timeZoneIdentifier: "GMT"))
        try remote.save(); center.recordMutation()
        await store.refreshIfNeeded(revision: center.revision) { try await reader.compute() }
        XCTAssertEqual(store.metrics, .init(appCreatedAt: created, activeTransactionCount: 1,
            earliestLocalDayKey: "2010-01-01", distinctActiveDayCount: 1))
    }

    func testOlderUsageRequestCannotOverwriteNewerRevision() async {
        let store = LedgerUsageMetricsStore()
        let gate = Build28UsageGate()
        let first = Task { await store.refreshIfNeeded(revision: 1) { await gate.load() } }
        while !(await gate.started) { await Task.yield() }
        let newer = LedgerUsageMetricsComputation(metrics: .init(appCreatedAt: .distantPast,
            activeTransactionCount: 2, earliestLocalDayKey: "2026-10-01", distinctActiveDayCount: 1),
            scannedRecordCount: 2, maximumBatchCount: 2)
        await store.refreshIfNeeded(revision: 2) { newer }
        await gate.release()
        await first.value
        XCTAssertEqual(store.metrics?.activeTransactionCount, 2)
        XCTAssertEqual(store.revisionAtComputation, 2)
        XCTAssertFalse(store.isLoading)
    }

    func testCancelledAndFailedUsageRefreshPreservesValuesAndAllowsRetry() async {
        let store = LedgerUsageMetricsStore()
        let value = LedgerUsageMetricsComputation(metrics: .init(appCreatedAt: .distantPast,
            activeTransactionCount: 1, earliestLocalDayKey: "2026-10-01", distinctActiveDayCount: 1),
            scannedRecordCount: 1, maximumBatchCount: 1)
        await store.refreshIfNeeded(revision: 1) { value }
        await store.refreshIfNeeded(revision: 2) { throw CancellationError() }
        XCTAssertEqual(store.metrics, value.metrics)
        XCTAssertEqual(store.revisionAtComputation, 1)
        XCTAssertFalse(store.isLoading)
        await store.refreshIfNeeded(revision: 2) { throw CocoaError(.fileReadUnknown) }
        XCTAssertEqual(store.metrics, value.metrics)
        XCTAssertNotNil(store.errorMessage)
        await store.refreshIfNeeded(revision: 2) { value }
        XCTAssertEqual(store.revisionAtComputation, 2)
        XCTAssertNil(store.errorMessage)
    }

    func testLegacyDeletionMappingIsCompleteAndTargetsExistingSemantics() throws {
        let catalog = try CategoryCatalog.load()
        let semantics = Set(catalog.definitions.map(\.semanticKey))
        XCTAssertEqual(Set(CategoryCatalogPlanner.legacyDeletionSuccessors.keys),
            Set(catalog.legacyMappings.filter { $0.action != .reuse }.map(\.oldKey)))
        for target in CategoryCatalogPlanner.legacyDeletionSuccessors.values.flatMap({ $0 }) {
            XCTAssertTrue(semantics.contains(target), target)
        }
    }

    func testDeletionProtectionSurvivesCustomizedParentAndOtherwiseCompleteCatalog() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let rows = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let root = try XCTUnwrap(rows.first { $0.defaultDefinitionKey == "expense.dining" })
        root.name = "我的饮食"
        for row in rows where ["expense.dining.coffee", "expense.dining.tea-drink"].contains(row.defaultDefinitionKey) {
            context.delete(row)
        }
        let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<AppMetadata>()).first)
        metadata.deletedDefaultCategoryKeys.insert("expense.dining.coffee-tea")
        try context.save()
        let plan = CategoryCatalogPlanner.additions(catalog: try CategoryCatalog.load(),
            snapshot: try CategoryCatalogService.capture(in: ModelContext(context.container)), readiness: .offline)
        XCTAssertTrue(plan.entries.filter(\.selectedByDefault).isEmpty)
        for key in ["expense.dining.coffee", "expense.dining.tea-drink"] {
            XCTAssertEqual(plan.entries.first { $0.id == key }?.reason, .legacyDeletionNeedsReview)
        }
        XCTAssertEqual(root.name, "我的饮食")
    }

    func testDeletedLegacyBlendDoesNotReappearAsAutomaticSplitCategories() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: context)
        let deleted = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first {
            $0.defaultDefinitionKey == "expense.dining.coffee-tea"
        })
        _ = try await MetadataMutationActor(modelContainer: context.container).deleteCategory(id: deleted.id, targetID: nil)
        let snapshot = try CategoryCatalogService.capture(in: ModelContext(context.container))
        let plan = CategoryCatalogPlanner.additions(catalog: try CategoryCatalog.load(), snapshot: snapshot, readiness: .offline)
        for key in ["expense.dining.coffee", "expense.dining.tea-drink"] {
            let entry = try XCTUnwrap(plan.entries.first { $0.id == key })
            XCTAssertFalse(entry.selectedByDefault, key)
            XCTAssertNotNil(entry.reason, key)
        }
        let sync = ICloudSyncController()
        await sync.disable()
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: ModelContext(context.container)))
        for _ in 0..<2 {
            _ = try await CategoryCatalogService.completeMissing(in: ModelContext(context.container), sync: sync, changes: LedgerChangeCenter())
        }
        let after = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: ModelContext(context.container)))
        for (key, value) in before where key.hasPrefix("categories:") || key.hasPrefix("transactions:") {
            XCTAssertEqual(after[key], value, "Safe additions must not rewrite existing rows")
        }
        let installed = try ModelContext(context.container).fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertFalse(installed.contains { ["expense.dining.coffee", "expense.dining.tea-drink"].contains($0.defaultDefinitionKey) })
        XCTAssertTrue(installed.contains { $0.defaultDefinitionKey == "expense.health.medicine" })
        // Paired positive: no deletion intent allows ordinary safe completion.
        let clean = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: clean)
        let positive = CategoryCatalogPlanner.additions(catalog: try CategoryCatalog.load(),
            snapshot: try CategoryCatalogService.capture(in: clean), readiness: .offline)
        XCTAssertEqual(positive.entries.filter(\.selectedByDefault).count, 190)
    }
}

private actor Build28UsageGate {
    private var continuation: CheckedContinuation<LedgerUsageMetricsComputation, Never>?
    private(set) var started = false
    func load() async -> LedgerUsageMetricsComputation {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }
    func release() {
        continuation?.resume(returning: .init(metrics: .init(appCreatedAt: .distantPast,
            activeTransactionCount: 1, earliestLocalDayKey: "2026-10-01", distinctActiveDayCount: 1),
            scannedRecordCount: 1, maximumBatchCount: 1))
        continuation = nil
    }
}
