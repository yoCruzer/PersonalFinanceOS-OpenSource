import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class ImportRollbackEditEvidenceTests: XCTestCase {
    func testRealOrdinaryEditWithClockRollbackIsPreserved() async throws {
        let (context, batchID) = try await importedContext()
        let transaction = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first)
        let completion = try XCTUnwrap(context.fetch(FetchDescriptor<ImportBatch>()).first?.completedAt)
        var draft = TransactionDraft(transaction: transaction)
        draft.note = "时钟回拨后的人工编辑"
        _ = try TransactionLifecycleService.save(draft: draft, editing: transaction,
            accounts: context.fetch(FetchDescriptor<Account>()), categories: context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()),
            in: context, now: completion.addingTimeInterval(-60))
        let actor = ImportRollbackActor(modelContainer: context.container)
        let summary = try await actor.summary(batchID: batchID)
        XCTAssertEqual(summary.editedCount, 0)
        XCTAssertEqual(summary.uncertainCount, 1)
        let result = try await actor.rollback(batchID: batchID)
        XCTAssertEqual(result.preservedUncertainCount, 1)
        XCTAssertEqual(result.deletedCount, 0)
        let current = try XCTUnwrap(ModelContext(context.container).fetch(FetchDescriptor<FinanceTransaction>()).first)
        XCTAssertEqual(current.note, draft.note)
        XCTAssertNil(current.deletedAt)
    }

    func testSameTimestampManualCategoryCorrectionIsPreserved() async throws {
        let (context, batchID) = try await importedContext()
        let transaction = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first)
        let completion = try XCTUnwrap(context.fetch(FetchDescriptor<ImportBatch>()).first?.completedAt)
        let target = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining.dinner" })
        _ = try await LedgerBatchOperationActor(modelContainer: context.container).correctCategory(
            selectedIDs: [transaction.id], targetID: target.id, now: completion)
        let result = try await ImportRollbackActor(modelContainer: context.container).rollback(batchID: batchID)
        XCTAssertEqual(result.preservedEditedCount, 1)
        XCTAssertEqual(result.deletedCount, 0)
    }

    // Equal clocks carry no edit history; the real rollback must retain uncertainty.
    func testSameTimestampNoteEditLeavesAllExistingImportEvidenceUnchanged() async throws {
        let (context, batchID) = try await importedContext()
        let transaction = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first)
        let before = try XCTUnwrap(LedgerSnapshotCodec.capture(in: ModelContext(context.container)).transactions.first)
        var draft = TransactionDraft(transaction: transaction)
        draft.note = "相同时间戳的新备注"
        _ = try TransactionLifecycleService.save(draft: draft, editing: transaction,
            accounts: context.fetch(FetchDescriptor<Account>()), categories: context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()),
            in: context, now: before.updatedAt)
        let after = try XCTUnwrap(LedgerSnapshotCodec.capture(in: ModelContext(context.container)).transactions.first)
        XCTAssertNotEqual(before.note, after.note)
        XCTAssertEqual(before.updatedAt, after.updatedAt)
        XCTAssertEqual(before.createdAt, after.createdAt)
        XCTAssertEqual(before.importFingerprint, after.importFingerprint)
        XCTAssertEqual(before.externalTransactionID, after.externalTransactionID)
        XCTAssertEqual(before.importBatchID, after.importBatchID)
        XCTAssertEqual(before.categoryDecisionSource, after.categoryDecisionSource)
        let result = try await ImportRollbackActor(modelContainer: context.container).rollback(batchID: batchID)
        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertEqual(result.preservedUncertainCount, 1)
        XCTAssertNil(try ModelContext(context.container).fetch(FetchDescriptor<FinanceTransaction>()).first?.deletedAt)
    }

    func testUnchangedImportRequiresExplicitUncertaintyChoiceAndCanStillRollback() async throws {
        let (context, batchID) = try await importedContext()
        let actor = ImportRollbackActor(modelContainer: context.container)
        let summary = try await actor.summary(batchID: batchID)
        XCTAssertEqual(summary.editedCount, 0)
        XCTAssertEqual(summary.uncertainCount, 1)
        XCTAssertEqual(summary.safelyUnmodifiedCount, 0)
        let kept = try await actor.rollback(batchID: batchID)
        XCTAssertEqual(kept.deletedCount, 0)
        XCTAssertEqual(kept.preservedUncertainCount, 1)
        XCTAssertEqual(try ModelContext(context.container).fetch(FetchDescriptor<ImportBatch>()).first?.status, .completed)
        do {
            _ = try await actor.rollback(batchID: batchID, includeUncertain: true)
            XCTFail("Unreviewed uncertainty must not be deleted")
        } catch { XCTAssertEqual(error as? ImportBatchHistoryError, .reviewRequired) }
        let removed = try await actor.rollback(batchID: batchID, includeUncertain: true, reviewedRevision: summary.reviewRevision)
        XCTAssertEqual(removed.deletedCount, 1)
        XCTAssertEqual(removed.preservedUncertainCount, 0)
    }

    func testChangedNoteAfterReviewRejectsPreviouslyApprovedDeletion() async throws {
        let (context, batchID) = try await importedContext()
        let actor = ImportRollbackActor(modelContainer: context.container)
        let summary = try await actor.summary(batchID: batchID)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first)
        var draft = TransactionDraft(transaction: row)
        draft.note = "确认期间同时间戳编辑"
        _ = try TransactionLifecycleService.save(draft: draft, editing: row,
            accounts: context.fetch(FetchDescriptor<Account>()), categories: context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()),
            in: context, now: row.updatedAt)
        do {
            _ = try await actor.rollback(batchID: batchID, includeUncertain: true, reviewedRevision: summary.reviewRevision)
            XCTFail("A changed reviewed generation must require renewed consent")
        } catch { XCTAssertEqual(error as? ImportBatchHistoryError, .staleReview) }
        let current = try XCTUnwrap(ModelContext(context.container).fetch(FetchDescriptor<FinanceTransaction>()).first)
        XCTAssertEqual(current.note, draft.note)
        XCTAssertNil(current.deletedAt)
    }

    func testMaintenanceMigrationIsUncertainNotManualEditing() async throws {
        let (context, batchID) = try await importedContext()
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first)
        let target = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining.dinner" })
        _ = try await MetadataMutationActor(modelContainer: context.container).deleteCategory(
            id: try XCTUnwrap(row.categoryID), targetID: target.id, now: row.updatedAt.addingTimeInterval(10))
        let actor = ImportRollbackActor(modelContainer: context.container)
        let summary = try await actor.summary(batchID: batchID)
        XCTAssertEqual(summary.editedCount, 0)
        XCTAssertEqual(summary.uncertainCount, 1)
        let result = try await actor.rollback(batchID: batchID)
        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertEqual(result.preservedUncertainCount, 1)
    }

    func testRemoteOrdinaryNoteEditRemainsUncertainAfterActualReplicaProjection() async throws {
        let (local, batchID) = try await importedContext()
        var aIdentity = LedgerSyncIdentity(), bIdentity = LedgerSyncIdentity()
        var aReplica = ProtectedLedgerReplica(accountIdentifier: "rollback-contract-a")
        var bReplica = ProtectedLedgerReplica(accountIdentifier: "rollback-contract-a")
        try aReplica.captureLocal(aIdentity.capture(LedgerSnapshotCodec.capture(in: local)))
        try bReplica.merge(aReplica)
        let remote = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try LedgerSnapshotCodec.apply(bIdentity.localPackage(from: bReplica), in: remote)
        bReplica.acknowledgeLocalProjection(try bIdentity.capture(LedgerSnapshotCodec.capture(in: remote)))
        let row = try XCTUnwrap(remote.fetch(FetchDescriptor<FinanceTransaction>()).first)
        var draft = TransactionDraft(transaction: row)
        draft.note = "远端人工备注"
        _ = try TransactionLifecycleService.save(draft: draft, editing: row,
            accounts: remote.fetch(FetchDescriptor<Account>()), categories: remote.fetch(FetchDescriptor<PersonalFinanceOS.Category>()),
            in: remote, now: row.updatedAt)
        try bReplica.captureLocal(bIdentity.capture(LedgerSnapshotCodec.capture(in: remote)))
        try aReplica.merge(bReplica)
        try LedgerSnapshotCodec.apply(aIdentity.localPackage(from: aReplica), in: local)
        let actor = ImportRollbackActor(modelContainer: local.container)
        let summary = try await actor.summary(batchID: batchID)
        XCTAssertEqual(summary.editedCount, 0)
        XCTAssertEqual(summary.uncertainCount, 1)
        let result = try await actor.rollback(batchID: batchID)
        XCTAssertEqual(result.preservedUncertainCount, 1)
        let current = try XCTUnwrap(ModelContext(local.container).fetch(FetchDescriptor<FinanceTransaction>()).first)
        XCTAssertEqual(current.note, draft.note)
        XCTAssertNil(current.deletedAt)
    }

    func testCatalogUpgradeDoesNotBecomeHumanEditEvidence() async throws {
        let initial = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: initial)
        let (context, batchID) = try await importedContext(context: initial)
        let before = try LedgerSnapshotCodec.capture(in: context)
        let sync = ICloudSyncController()
        await sync.disable()
        let preview = try await CategoryCatalogService.preview(in: context, sync: sync)
        _ = try CategoryCatalogService.commit(preview,
            selected: Set(preview.plan.entries.filter(\.selectedByDefault).map(\.id)),
            in: context, sync: sync, changes: LedgerChangeCenter())
        let after = try LedgerSnapshotCodec.capture(in: ModelContext(context.container))
        XCTAssertEqual(after.categories.count, 267)
        XCTAssertEqual(try LedgerSnapshotCodec.records(before).filter { $0.key.hasPrefix("transactions:") },
            try LedgerSnapshotCodec.records(after).filter { $0.key.hasPrefix("transactions:") })
        let actor = ImportRollbackActor(modelContainer: context.container)
        let summary = try await actor.summary(batchID: batchID)
        XCTAssertEqual(summary.editedCount, 0)
        XCTAssertEqual(summary.uncertainCount, 1)
        let result = try await actor.rollback(batchID: batchID)
        XCTAssertEqual(result.preservedUncertainCount, 1)
        XCTAssertEqual(result.deletedCount, 0)
    }

    func testAutomaticSourcesAndEveryClockDirectionRemainUncertain() async throws {
        let (context, _) = try await importedContext()
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first)
        for source in [CategoryDecisionSource.unchanged, .automaticAccepted, .timePrior] {
            for time in [Date.distantPast, row.createdAt, Date.distantFuture] {
                row.categoryDecisionSource = source
                row.updatedAt = time
                XCTAssertEqual(ImportBatchEditEvidence.assess(row), .uncertain)
            }
        }
    }

    func testPrepareExplicitlyArmedSyntheticRollbackUIFixture() async throws {
        #if targetEnvironment(simulator)
        let control = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PFOSRemediationFixturesV3/rollback-ui-control.txt")
        try XCTSkipUnless((try? String(contentsOf: control, encoding: .utf8)) == "prepare-rollback-a-ui",
            "Only an explicitly armed synthetic Simulator is eligible")
        try FileManager.default.removeItem(at: control)
        let context = ModelContext(try ModelContainerFactory.make())
        XCTAssertFalse(try context.fetch(FetchDescriptor<ImportBatch>()).contains { $0.sourceDisplayName == "合成回滚契约A.csv" })
        let (_, batchID) = try await importedContext(context: context, fileName: "合成回滚契约A.csv")
        let summary = try await ImportRollbackActor(modelContainer: context.container).summary(batchID: batchID)
        XCTAssertEqual(summary.uncertainCount, 1)
        #else
        throw XCTSkip("Synthetic Simulator fixture only")
        #endif
    }

    private func importedContext(context existing: ModelContext? = nil, fileName: String = "clock.csv") async throws -> (ModelContext, UUID) {
        let context = try existing ?? ModelContext(ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let account = try XCTUnwrap(accounts.first)
        let csv = "transaction_id,type,amount,date_time,category,account,note\nclock-case,expense,12.34,2026-01-01 10:00,餐饮 / 午餐,\(account.name),原始备注"
        let document = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: fileName)
        let plan = try FinanceCSVService.makePlan(document: document, mapping: FinanceCSVService.autoMapping(headers: document.headers), fileName: fileName, existingTransactions: [])
        let model = FinanceCSVService.makeImportModelSnapshot(accounts: accounts, categories: categories, tags: [])
        let request = try FinanceCSVService.makeBackgroundCommitRequest(plan: plan, modelSnapshot: model, createMissingCategories: false, rememberedCategoryMappings: [:])
        let result = try await ImportCommitActor(modelContainer: context.container).commit(request)
        XCTAssertEqual(result.importedCount, 1)
        return (ModelContext(context.container), request.batchID)
    }
}
