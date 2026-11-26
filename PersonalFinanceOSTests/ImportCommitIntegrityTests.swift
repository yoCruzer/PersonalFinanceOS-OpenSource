import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class ImportCommitIntegrityTests: XCTestCase {
    func testConcurrentCommitActorsSerializeFinalDuplicateCheck() async throws {
        let local = try context()
        let first = try request(in: local, rows: ["X"])
        let second = try request(in: local, rows: ["X"])
        let firstActor = ImportCommitActor(modelContainer: local.container)
        let secondActor = ImportCommitActor(modelContainer: local.container)
        async let a = firstActor.commit(first)
        async let b = secondActor.commit(second)
        let results = try await [a, b]
        XCTAssertEqual(results.map(\.importedCount).sorted(), [0, 1])
        XCTAssertEqual(results.map(\.duplicateCount).sorted(), [0, 1])
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<FinanceTransaction>()), 1)
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<ImportBatch>()), 1)
    }

    func testPreparedProjectionRejectsAnInterveningImportAtTheWriteBoundary() throws {
        let local = try context()
        let old = try ValidatedLedgerSnapshot(LedgerSnapshotCodec.capture(in: local))
        let revision = LedgerSaveRevision.shared.revision
        _ = try ImportCommitWriter(modelContext: local).commit(try request(in: local, rows: ["X"]))
        XCTAssertThrowsError(try LedgerSnapshotCodec.apply(old, in: local, expectedRevision: revision)) {
            guard case ReconcileRevision.Failure.stalePlan = $0 else { return XCTFail("Expected stale projection rejection, got \($0)") }
        }
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<FinanceTransaction>()), 1)
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<ImportBatch>()), 1)
    }

    func testStalePreviewSkipsRemoteDuplicateWithoutGhostBatchOrOrigins() async throws {
        let local = try context()
        let request = try request(in: local, rows: ["X"])
        let remote = try context()
        try LedgerSnapshotCodec.apply(LedgerSnapshotCodec.capture(in: local), in: remote)
        _ = try await ImportCommitActor(modelContainer: remote.container).commit(try self.request(in: remote, rows: ["X"]))
        try LedgerSnapshotCodec.apply(LedgerSnapshotCodec.capture(in: remote), in: local)
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: local))
        let result = try await ImportCommitActor(modelContainer: local.container).commit(request)
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(result.expenseMinorUnits, 0)
        XCTAssertEqual(result.createdAccountCount, 0)
        XCTAssertEqual(result.createdCategoryCount, 0)
        XCTAssertEqual(result.createdTagCount, 0)
        XCTAssertEqual(try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: local)), before)
        var identity = LedgerSyncIdentity()
        XCTAssertNoThrow(try identity.capture(LedgerSnapshotCodec.capture(in: local)))
    }

    func testPartialStalePreviewCommitsExactCountsAmountsAndRollback() async throws {
        let local = try context()
        let request = try request(in: local, rows: ["X", "Y"])
        _ = try await ImportCommitActor(modelContainer: local.container).commit(try self.request(in: local, rows: ["X"]))
        let result = try await ImportCommitActor(modelContainer: local.container).commit(request)
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(result.expenseMinorUnits, 1234)
        let batch = try XCTUnwrap(local.fetch(FetchDescriptor<ImportBatch>()).first { $0.id == request.batchID })
        XCTAssertEqual(batch.importedRowCount, 1)
        XCTAssertEqual(batch.duplicateRowCount, 1)
        XCTAssertEqual(batch.expenseMinorUnits, 1234)
        let rollback = try await ImportRollbackActor(modelContainer: local.container).rollback(batchID: batch.id, includeUncertain: true, reviewedRevision: LedgerSaveRevision.shared.contentRevision)
        XCTAssertEqual(rollback.deletedCount, 1)
        let rows = try ModelContext(local.container).fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(rows.filter { $0.deletedAt == nil }.map(\.externalTransactionID), ["X"])
        var identity = LedgerSyncIdentity()
        XCTAssertNoThrow(try identity.capture(LedgerSnapshotCodec.capture(in: ModelContext(local.container))))
    }

    func testLedgerChangeAfterRecheckForcesAnotherCheckAtSaveBoundary() throws {
        let local = try context()
        let request = try request(in: local, rows: ["X", "Y"])
        let incoming = try context()
        try LedgerSnapshotCodec.apply(LedgerSnapshotCodec.capture(in: local), in: incoming)
        _ = try ImportCommitWriter(modelContext: incoming).commit(try self.request(in: incoming, rows: ["X"]))
        let remote = try LedgerSnapshotCodec.capture(in: incoming)
        let result = try ImportCommitWriter(modelContext: ModelContext(local.container)).commit(request, afterRecheck: {
            try LedgerSnapshotCodec.apply(remote, in: ModelContext(local.container))
        })
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<FinanceTransaction>()), 2)
        let counts = Dictionary(grouping: try local.fetch(FetchDescriptor<FinanceTransaction>()), by: \.externalTransactionID)
        XCTAssertEqual(counts["X"]?.count, 1)
        XCTAssertEqual(counts["Y"]?.count, 1)
    }

    func testExplicitInstancesSurviveTwoDeviceSyncBackupAndRollback() async throws {
        let first = try context()
        _ = try await ImportCommitActor(modelContainer: first.container).commit(try request(in: first, rows: ["X"]))
        var identityA = LedgerSyncIdentity()
        var replicaA = ProtectedLedgerReplica(accountIdentifier: "A")
        try replicaA.captureLocal(identityA.capture(LedgerSnapshotCodec.capture(in: first)))
        let second = try context()
        var identityB = LedgerSyncIdentity()
        try LedgerSnapshotCodec.apply(identityB.localPackage(from: replicaA), in: second)
        var replicaB = ProtectedLedgerReplica(accountIdentifier: "A")
        try replicaB.merge(replicaA)
        replicaB.acknowledgeLocalProjection(try identityB.capture(LedgerSnapshotCodec.capture(in: second)))
        // Each explicit confirmation is a distinct user-created ledger record and batch.
        let duplicateA = try request(in: first, rows: ["X"], force: true)
        let duplicateB = try request(in: second, rows: ["X"], force: true)
        XCTAssertNotNil(duplicateA.transactions.first?.explicitDuplicateInstance)
        _ = try await ImportCommitActor(modelContainer: first.container).commit(duplicateA)
        let replay = try await ImportCommitActor(modelContainer: first.container).commit(duplicateA)
        XCTAssertEqual(replay.importedCount, 0)
        XCTAssertEqual(replay.duplicateCount, 1)
        try replicaA.captureLocal(identityA.capture(LedgerSnapshotCodec.capture(in: first)))
        let receiver = try context()
        let receiverIdentity = LedgerSyncIdentity()
        try LedgerSnapshotCodec.apply(receiverIdentity.localPackage(from: replicaA), in: receiver)
        XCTAssertEqual(try receiver.fetchCount(FetchDescriptor<FinanceTransaction>()), 2)
        // B has not received A's explicit instance: both replicas independently advance.
        _ = try await ImportCommitActor(modelContainer: second.container).commit(duplicateB)
        try replicaB.captureLocal(identityB.capture(LedgerSnapshotCodec.capture(in: ModelContext(second.container))))
        try replicaA.merge(replicaB)
        let merged = try identityA.localPackage(from: replicaA)
        XCTAssertEqual(merged.transactions.count, 3)
        XCTAssertEqual(merged.importBatches.count, 3)
        XCTAssertEqual(Set(merged.transactions.compactMap(\.importSemanticOrigin)).count, 3)
        try LedgerSnapshotCodec.apply(merged, in: first)
        try LedgerSnapshotCodec.apply(identityB.localPackage(from: replicaA), in: second)
        XCTAssertEqual(try second.fetchCount(FetchDescriptor<FinanceTransaction>()), 3)
        let restored = try context()
        let backup = try JSONDecoder().decode(NativeBackupPackage.self, from: JSONEncoder().encode(merged))
        try LedgerSnapshotCodec.apply(backup, in: restored)
        var restoredIdentity = LedgerSyncIdentity()
        XCTAssertEqual(try restoredIdentity.capture(LedgerSnapshotCodec.capture(in: restored)), try identityA.capture(merged))
        let rollback = try await ImportRollbackActor(modelContainer: first.container).rollback(batchID: duplicateA.batchID, includeUncertain: true, reviewedRevision: LedgerSaveRevision.shared.contentRevision)
        XCTAssertEqual(rollback.deletedCount, 1)
        let after = try LedgerSnapshotCodec.capture(in: ModelContext(first.container))
        XCTAssertEqual(after.transactions.filter { $0.deletedAt == nil }.count, 2)
        XCTAssertNoThrow(try identityA.capture(after))
    }

    func testUnconfirmedRowsDoNotGainDuplicateIdentityFromGlobalToggle() throws {
        let local = try context()
        let request = try request(in: local, rows: ["X"], force: true)
        XCTAssertNil(request.transactions.first?.explicitDuplicateInstance)
        _ = try ImportCommitWriter(modelContext: local).commit(try self.request(in: local, rows: ["X"]))
        let result = try ImportCommitWriter(modelContext: local).commit(request)
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.duplicateCount, 1)
    }

    private func context() throws -> ModelContext {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: context)
        return context
    }

    private func request(in context: ModelContext, rows: [String], force: Bool = false) throws -> ImportCommitRequest {
        let csv = "transaction_id,type,amount,date_time,category,account,tags\n" + rows.map {
            "\($0),expense,12.34,2026-01-01 10:00,餐饮 / 修复早餐,修复账户,修复标签"
        }.joined(separator: "\n")
        let document = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: "fixture.csv")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let parsed = try FinanceCSVService.parsePlan(document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers), fileName: "fixture.csv", calendar: calendar)
        let plan = FinanceCSVService.assessDuplicates(parsed, existingRecords: try context.fetch(FetchDescriptor<FinanceTransaction>()).map(ImportDuplicateRecord.init))
        let model = FinanceCSVService.makeImportModelSnapshot(accounts: try context.fetch(FetchDescriptor<Account>()),
            categories: try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), tags: try context.fetch(FetchDescriptor<Tag>()))
        return try FinanceCSVService.makeBackgroundCommitRequest(plan: plan, modelSnapshot: model,
            createMissingCategories: true, createMissingAccounts: true, createMissingTags: true,
            includeConfirmedDuplicates: force, rememberedCategoryMappings: [:])
    }
}
