import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class RemediationEndToEndTests: XCTestCase {
    func testUpgradeImportCorrectionProjectionEditRollbackRestoreAndRejoin() async throws {
        let a = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: a)
        let original = try LedgerSnapshotCodec.capture(in: a)
        let sync = ICloudSyncController()
        await sync.disable()
        let preview = try await CategoryCatalogService.preview(in: a, sync: sync)
        _ = try CategoryCatalogService.commit(preview, selected: Set(preview.plan.entries.filter(\.selectedByDefault).map(\.id)),
            in: a, sync: sync, changes: LedgerChangeCenter())
        let upgraded = try LedgerSnapshotCodec.capture(in: ModelContext(a.container))
        XCTAssertEqual(upgraded.categories.count, 267)
        for category in original.categories {
            XCTAssertEqual(upgraded.categories.first { $0.id == category.id }?.defaultDefinitionKey, category.defaultDefinitionKey)
        }
        let first = try await request(in: a, force: false)
        let imported = try await ImportCommitActor(modelContainer: a.container).commit(first)
        XCTAssertEqual(imported.importedCount, 2)
        let second = try await request(in: a, force: true)
        XCTAssertTrue(second.transactions.allSatisfy { $0.explicitDuplicateInstance != nil })
        let repeated = try await ImportCommitActor(modelContainer: a.container).commit(second)
        XCTAssertEqual(repeated.importedCount, 2)
        let replay = try await ImportCommitActor(modelContainer: a.container).commit(second)
        XCTAssertEqual(replay.importedCount, 0)
        let importedPackage = try LedgerSnapshotCodec.capture(in: ModelContext(a.container))
        XCTAssertEqual(importedPackage.categories.count, 267)
        XCTAssertEqual(importedPackage.transactions.count, 4)
        XCTAssertEqual(importedPackage.importBatches.count, 2)
        let firstIDs = Set(importedPackage.transactions.filter { $0.importBatchID == first.batchID }.map(\.id))
        let secondIDs = Set(importedPackage.transactions.filter { $0.importBatchID == second.batchID }.map(\.id))
        XCTAssertEqual(firstIDs.count, 2)
        XCTAssertEqual(secondIDs.count, 2)
        XCTAssertTrue(firstIDs.isDisjoint(with: secondIDs))
        let target = try XCTUnwrap(upgraded.categories.first { $0.defaultDefinitionKey == "expense.dining.dinner" }?.id)
        let writer = LedgerBatchOperationActor(modelContainer: a.container)
        let plan = try await writer.plan(selectedIDs: firstIDs, operation: .category(target), revision: LedgerSaveRevision.shared.readContentStamp())
        XCTAssertEqual(plan.totals.grossExpenseMinorUnits, 3234)
        let correction = try await writer.execute(plan)
        XCTAssertEqual(correction.summary.count, 2)
        XCTAssertEqual(correction.learningEvents.count, 2)
        XCTAssertEqual(Set(correction.learningEvents.map(\.transactionID)), firstIDs)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let learningA = ClassificationProfileStore(fileURL: directory.appendingPathComponent("a.json"))
        try await learningA.record(correction.learningEvents, generation: learningA.generation)

        var identityA = LedgerSyncIdentity()
        var replicaA = ProtectedLedgerReplica(accountIdentifier: "synthetic-chain")
        try replicaA.captureLocal(identityA.capture(LedgerSnapshotCodec.capture(in: ModelContext(a.container))))
        let b = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        var identityB = LedgerSyncIdentity()
        var replicaB = ProtectedLedgerReplica(accountIdentifier: "synthetic-chain")
        try replicaB.merge(replicaA)
        try LedgerSnapshotCodec.apply(identityB.localPackage(from: replicaB), in: b)
        replicaB.acknowledgeLocalProjection(try identityB.capture(LedgerSnapshotCodec.capture(in: b)))
        XCTAssertEqual(try identityA.capture(LedgerSnapshotCodec.capture(in: ModelContext(a.container))),
            try identityB.capture(LedgerSnapshotCodec.capture(in: b)))
        let historyB = try await ClassificationHistoryActor(modelContainer: b.container).fetchProfileInputs(cutoff: .distantPast, eventIDs: [])
        XCTAssertEqual(historyB.history.filter { $0.decisionSource == .manualConfirmed }.count, 2)

        let categoriesB = try b.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let targetB = try XCTUnwrap(categoriesB.first { $0.defaultDefinitionKey == "expense.dining.dinner" })
        var filter = LedgerFilter(dateRange: nil)
        filter.category = .node(targetB.id)
        let drilldown = try await LedgerAnalysisActor(modelContainer: b.container).snapshot(filter: filter)
        XCTAssertEqual(drilldown.totals.totalCount, 2)
        XCTAssertEqual(drilldown.totals.grossExpenseMinorUnits, 3234)
        let editing = try XCTUnwrap(b.fetch(FetchDescriptor<FinanceTransaction>()).first {
            drilldown.transactionIDs.contains($0.id) && $0.externalTransactionID == "chain-X"
        })
        var draft = TransactionDraft(transaction: editing)
        draft.amountText = "15.00"
        draft.note = "长链路下钻编辑"
        _ = try TransactionLifecycleService.save(draft: draft, editing: editing,
            accounts: b.fetch(FetchDescriptor<Account>()), categories: categoriesB, in: b)
        try replicaB.captureLocal(identityB.capture(LedgerSnapshotCodec.capture(in: b)))
        try replicaA.merge(replicaB)
        try LedgerSnapshotCodec.apply(identityA.localPackage(from: replicaA), in: ModelContext(a.container))
        replicaA.acknowledgeLocalProjection(try identityA.capture(LedgerSnapshotCodec.capture(in: ModelContext(a.container))))

        let preserved = try await ImportRollbackActor(modelContainer: a.container).rollback(batchID: first.batchID)
        XCTAssertEqual(preserved.preservedEditedCount, 2)
        XCTAssertEqual(preserved.deletedCount, 0)
        let removed = try await ImportRollbackActor(modelContainer: a.container).rollback(batchID: second.batchID, includeUncertain: true, reviewedRevision: LedgerSaveRevision.shared.contentRevision)
        XCTAssertEqual(removed.deletedCount, 2)
        let finalA = try LedgerSnapshotCodec.capture(in: ModelContext(a.container))
        XCTAssertEqual(Set(finalA.transactions.filter { $0.deletedAt == nil }.map(\.id)), firstIDs)
        XCTAssertEqual(Set(finalA.transactions.filter { $0.deletedAt != nil }.map(\.id)), secondIDs)
        XCTAssertEqual(finalA.transactions.filter { $0.deletedAt == nil }.reduce(Int64(0)) { $0 + $1.amountMinorUnits }, 3500)
        XCTAssertEqual(finalA.transactions.filter { $0.deletedAt == nil && $0.note == draft.note }.count, 1)
        XCTAssertEqual(finalA.categories.count, 267)
        XCTAssertNoThrow(try NativeBackupService.validate(finalA))
        let events = try await learningA.events()
        let inputs = try await ClassificationHistoryActor(modelContainer: a.container).fetchProfileInputs(cutoff: .distantPast, eventIDs: events.map(\.transactionID))
        let validity = events.map { ClassificationEventValidity.evaluate($0, lookup: inputs.eventLookups[$0.transactionID] ?? .unknown) }
        XCTAssertEqual(validity.filter { $0 == .existsMatching }.count, 1)
        XCTAssertEqual(validity.filter { $0 == .existsChanged }.count, 1)
        XCTAssertEqual(inputs.history.count, 2)
        let profileA = ClassificationProfileBuilder.build(history: inputs.history, events: events, eventLookups: inputs.eventLookups)
        XCTAssertEqual(profileA.sampleCount, 2, "Sidecar evidence replaces, rather than doubles, its ledger sample")

        let data = try await NativeBackupActor(modelContainer: a.container).exportData()
        let c = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        let learningC = ClassificationProfileStore(fileURL: directory.appendingPathComponent("c.json"))
        let restored = try await NativeBackupActor(modelContainer: c.container).restore(data: data,
            admission: offlineRestoreTicket(for: c.container), learningStore: learningC)
        XCTAssertEqual(restored.insertedTransactionCount, 4)
        let finalC = try LedgerSnapshotCodec.capture(in: ModelContext(c.container))
        XCTAssertEqual(try LedgerSnapshotCodec.records(finalA), try LedgerSnapshotCodec.records(finalC))
        let restoredEvents = try await learningC.events()
        XCTAssertTrue(restoredEvents.isEmpty, "Local sidecar does not travel through ledger backup")
        let inputsC = try await ClassificationHistoryActor(modelContainer: c.container).fetchProfileInputs(cutoff: .distantPast, eventIDs: [])
        XCTAssertEqual(inputsC.history.filter { $0.decisionSource == .manualConfirmed }.count, 2)
        XCTAssertEqual(ClassificationProfileBuilder.build(history: inputsC.history, events: []).sampleCount, 2)
        var identityC = LedgerSyncIdentity()
        var replicaC = ProtectedLedgerReplica(accountIdentifier: "synthetic-chain")
        try replicaC.captureLocal(identityC.capture(finalC))
        try replicaA.captureLocal(identityA.capture(finalA))
        try replicaC.merge(replicaA)
        try replicaA.merge(replicaC)
        XCTAssertEqual(replicaA.records, replicaC.records)
        try LedgerSnapshotCodec.apply(identityC.localPackage(from: replicaC), in: ModelContext(c.container))
        let rejoined = try await LedgerAnalysisActor(modelContainer: c.container).snapshot(filter: LedgerFilter(dateRange: nil))
        XCTAssertEqual(rejoined.totals.totalCount, 2)
        XCTAssertEqual(rejoined.totals.grossExpenseMinorUnits, 3500)
        XCTAssertEqual(try ModelContext(c.container).fetchCount(FetchDescriptor<PersonalFinanceOS.Category>()), 267)
        XCTAssertEqual(try identityC.capture(LedgerSnapshotCodec.capture(in: ModelContext(c.container))),
            try identityA.capture(finalA), "Rejoin preserves every canonical record, including tombstones and import provenance")
    }

    private func request(in context: ModelContext, force: Bool) async throws -> ImportCommitRequest {
        let csv = "transaction_id,type,amount,date_time,category,note\nchain-X,expense,12.34,2026-09-01 10:00,餐饮 / 午餐,合成长链路甲\nchain-Y,expense,20.00,2026-09-01 11:00,餐饮 / 午餐,合成长链路乙"
        let document = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: "chain.csv")
        let parsed = try FinanceCSVService.parsePlan(document: document, mapping: FinanceCSVService.autoMapping(headers: document.headers), fileName: "chain.csv")
        let existing = try await ImportPlanningActor(modelContainer: context.container).duplicateRecords(for: parsed)
        let plan = FinanceCSVService.assessDuplicates(parsed, existingRecords: existing)
        let fresh = ModelContext(context.container)
        let snapshot = FinanceCSVService.makeImportModelSnapshot(accounts: try fresh.fetch(FetchDescriptor<Account>()),
            categories: try fresh.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), tags: [])
        return try FinanceCSVService.makeBackgroundCommitRequest(plan: plan, modelSnapshot: snapshot,
            includeConfirmedDuplicates: force, rememberedCategoryMappings: [:])
    }
}
