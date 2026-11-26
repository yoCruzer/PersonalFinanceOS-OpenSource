import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class ImportRequestReviewTests: XCTestCase {
    func testCategoryRepurposedAfterPreviewIsRejectedByRealActorWithoutPartialRows() async throws {
        let context = try fixture()
        let (_, request) = try prepare(in: context)
        let other = ModelContext(context.container)
        try XCTUnwrap(other.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first).name = "设备投资"
        try other.save()
        do {
            _ = try await ImportCommitActor(modelContainer: context.container).commit(request)
            XCTFail("Prepared classification must be reviewed after its target purpose changes")
        } catch { XCTAssertTrue(error is ImportCommitError) }
        let fresh = ModelContext(context.container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<FinanceTransaction>()), 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<ImportBatch>()), 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<ImportEntityOrigin>()), 0)
    }

    func testWithinFileIdenticalFingerprintsRetainPreviewCountAmountAndWireIdentity() async throws {
        let context = try fixture()
        let (plan, request) = try prepare(in: context, count: 2)
        XCTAssertEqual(plan.effectiveRowsToImport(includeSuspectedDuplicates: true).count, 2)
        XCTAssertEqual(plan.candidates.filter { $0.duplicateAssessment == .withinFile }.count, 1)
        XCTAssertEqual(Set(plan.candidates.map(\.fingerprint)).count, 1)
        XCTAssertTrue(plan.candidates.allSatisfy { $0.externalTransactionID.isEmpty })
        let result = try await ImportCommitActor(modelContainer: context.container).commit(request)
        XCTAssertEqual(result.importedCount, 2)
        XCTAssertEqual(result.duplicateCount, 0)
        XCTAssertEqual(result.expenseMinorUnits, 2468)
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(context.container))
        XCTAssertEqual(package.transactions.count, 2)
        XCTAssertEqual(package.transactions.reduce(0) { $0 + $1.amountMinorUnits }, 2468)
        var identity = LedgerSyncIdentity()
        XCTAssertEqual(try identity.capture(package).keys.filter { $0.hasPrefix("transactions:") }.count, 2)
    }

    func testSameFileOnIndependentDevicesConvergesToTwoOccurrencesAndOneBatch() async throws {
        let a = try fixture()
        let b = try fixture()
        try LedgerSnapshotCodec.apply(LedgerSnapshotCodec.capture(in: a), in: b)
        let (_, requestA) = try prepare(in: a, count: 2, filename: "A.csv", now: Date(timeIntervalSince1970: 100))
        let (_, requestB) = try prepare(in: b, count: 2, filename: "renamed-B.csv", now: Date(timeIntervalSince1970: 200))
        _ = try await ImportCommitActor(modelContainer: a.container).commit(requestA)
        _ = try await ImportCommitActor(modelContainer: b.container).commit(requestB)
        var identityA = LedgerSyncIdentity()
        var identityB = LedgerSyncIdentity()
        var replicaA = ProtectedLedgerReplica(accountIdentifier: "review")
        var replicaB = ProtectedLedgerReplica(accountIdentifier: "review")
        try replicaA.captureLocal(identityA.capture(LedgerSnapshotCodec.capture(in: ModelContext(a.container))))
        try replicaB.captureLocal(identityB.capture(LedgerSnapshotCodec.capture(in: ModelContext(b.container))))
        try replicaA.merge(replicaB)
        try replicaB.merge(replicaA)
        for (context, identity, replica) in [(a, identityA, replicaA), (b, identityB, replicaB)] {
            let merged = try identity.localPackage(from: replica)
            XCTAssertEqual(merged.transactions.count, 2)
            XCTAssertEqual(merged.transactions.reduce(0) { $0 + $1.amountMinorUnits }, 2468)
            XCTAssertEqual(merged.importBatches.count, 1)
            XCTAssertEqual(merged.importBatches.first?.importedRowCount, 2)
            XCTAssertEqual(Set(merged.transactions.compactMap(\.importBatchID)), Set(merged.importBatches.map(\.id)))
            try LedgerSnapshotCodec.apply(merged, in: context)
            let restored = try fixture()
            try LedgerSnapshotCodec.apply(JSONDecoder().decode(NativeBackupPackage.self, from: JSONEncoder().encode(merged)), in: restored)
            var restoredIdentity = LedgerSyncIdentity()
            var savedIdentity = identity
            XCTAssertEqual(try restoredIdentity.capture(LedgerSnapshotCodec.capture(in: restored)), try savedIdentity.capture(merged))
        }
    }

    func testStalePreviewWithOnlyOccurrenceZeroOnLedgerKeepsOccurrenceOne() async throws {
        let local = try fixture()
        let (_, old) = try prepare(in: local, count: 2)
        let remote = try fixture()
        try LedgerSnapshotCodec.apply(LedgerSnapshotCodec.capture(in: local), in: remote)
        _ = try await ImportCommitActor(modelContainer: remote.container).commit(try prepare(in: remote, count: 1).1)
        try LedgerSnapshotCodec.apply(LedgerSnapshotCodec.capture(in: ModelContext(remote.container)), in: local)
        let result = try await ImportCommitActor(modelContainer: local.container).commit(old)
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(result.expenseMinorUnits, 1234)
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(local.container))
        XCTAssertEqual(package.transactions.count, 2)
        let batch = try XCTUnwrap(package.importBatches.first { $0.id == old.batchID })
        XCTAssertEqual(batch.importedRowCount, 1)
        XCTAssertEqual(batch.duplicateRowCount, 1)
        var identity = LedgerSyncIdentity()
        XCTAssertEqual(try identity.capture(package).keys.filter { $0.hasPrefix("transactions:") }.count, 2)
    }

    func testDeletedParentRejectsRequestWithoutOrphansOrGhosts() throws {
        let context = try fixture()
        let (_, request) = try prepare(in: context, category: "餐饮 / Review child")
        XCTAssertEqual(request.categoriesToCreate.count, 1)
        let parent = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first)
        XCTAssertEqual(request.categoriesToCreate.first?.parentID, parent.id)
        context.delete(parent)
        try context.save()
        try assertRejected(request, in: context)
    }

    func testInvalidSelectedCategoryIsNeverSilentlyDropped() throws {
        for change in ["delete", "archive", "hide", "kind"] {
            let context = try fixture()
            let (_, request) = try prepare(in: context)
            let category = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first)
            XCTAssertEqual(request.transactions.first?.categoryID, category.id)
            switch change {
            case "delete": context.delete(category)
            case "archive": category.archivedAt = Date()
            case "hide": category.isHidden = true
            default: category.kind = .income
            }
            try context.save()
            try assertRejected(request, in: context)
        }
    }

    func testInvalidAccountIsNeverReplacedWithDefault() throws {
        for change in ["delete", "archive", "currency"] {
            let context = try fixture()
            let (_, request) = try prepare(in: context)
            let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first { $0.name == "Review account" })
            XCTAssertEqual(request.transactions.first?.accountID, account.id)
            switch change {
            case "delete": context.delete(account)
            case "archive": account.archivedAt = Date()
            default: account.currencyCode = "USD"
            }
            try context.save()
            try assertRejected(request, in: context)
        }
    }

    func testInvalidSelectedTagIsNeverSilentlyDropped() throws {
        for deleted in [true, false] {
            let context = try fixture()
            let (_, request) = try prepare(in: context)
            let tag = try XCTUnwrap(context.fetch(FetchDescriptor<Tag>()).first)
            XCTAssertEqual(request.transactions.first?.tagIDs, [tag.id])
            if deleted { context.delete(tag) } else { tag.archivedAt = Date() }
            try context.save()
            try assertRejected(request, in: context)
        }
    }

    func testUnrelatedMetadataAndSelectedCategoryColorChangesDoNotBlockImport() throws {
        let context = try fixture()
        let (_, request) = try prepare(in: context)
        context.insert(Tag(name: "Unrelated", colorToken: "green"))
        try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first).colorToken = "blue"
        try context.save()
        let result = try ImportCommitWriter(modelContext: context).commit(request)
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertNoThrow(try NativeBackupService.validate(LedgerSnapshotCodec.capture(in: context)))
    }

    func testInvalidParentStateRejectsPlannedChild() throws {
        for change in ["archive", "hide", "kind", "hierarchy"] {
            let context = try fixture()
            let (_, request) = try prepare(in: context, category: "餐饮 / Review child")
            XCTAssertEqual(request.categoriesToCreate.count, 1)
            let parent = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first)
            switch change {
            case "archive": parent.archivedAt = Date()
            case "hide": parent.isHidden = true
            case "kind": parent.kind = .income
            default:
                let root = PersonalFinanceOS.Category(kind: .expense, name: "Other root", symbolName: "folder", colorToken: "blue")
                context.insert(root)
                parent.parentID = root.id
            }
            try context.save()
            try assertRejected(request, in: context)
        }
    }

    func testOtherContextMetadataChangeAfterRecheckIsRejectedAtWriteBoundary() throws {
        let context = try fixture()
        let (_, request) = try prepare(in: context)
        // Prime the writer context with the previously valid selected tag.
        _ = try context.fetch(FetchDescriptor<Tag>())
        let writer = ImportCommitWriter(modelContext: context)
        XCTAssertThrowsError(try writer.commit(request, afterRecheck: {
            let remote = ModelContext(context.container)
            try XCTUnwrap(remote.fetch(FetchDescriptor<Tag>()).first).archivedAt = Date()
            try remote.save()
        })) { error in
            XCTAssertTrue(error is ImportCommitError)
        }
        let fresh = ModelContext(context.container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<FinanceTransaction>()), 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<ImportBatch>()), 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<ImportEntityOrigin>()), 0)
        XCTAssertNoThrow(try NativeBackupService.validate(LedgerSnapshotCodec.capture(in: fresh)))
    }

    func testEntirelyStaleRowsDoNotValidateUnusedMetadataOrCreateGhosts() throws {
        let context = try fixture()
        let (_, first) = try prepare(in: context)
        let (_, old) = try prepare(in: context)
        _ = try ImportCommitWriter(modelContext: context).commit(first)
        try XCTUnwrap(context.fetch(FetchDescriptor<Tag>()).first).archivedAt = Date()
        try context.save()
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context))
        let result = try ImportCommitWriter(modelContext: context).commit(old)
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.confirmedDuplicateSkippedCount, 0)
        XCTAssertEqual(result.staleDuplicateCount, 1)
        XCTAssertEqual(try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context)), before)
    }

    private func assertRejected(_ request: ImportCommitRequest, in context: ModelContext,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context))
        XCTAssertThrowsError(try ImportCommitWriter(modelContext: context).commit(request), file: file, line: line)
        XCTAssertFalse(context.hasChanges, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FinanceTransaction>()), 0, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ImportBatch>()), 0, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ImportEntityOrigin>()), 0, file: file, line: line)
        XCTAssertEqual(try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context)), before, file: file, line: line)
        XCTAssertNoThrow(try NativeBackupService.validate(LedgerSnapshotCodec.capture(in: context)), file: file, line: line)
    }

    private func fixture() throws -> ModelContext {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        context.insert(AppMetadata())
        context.insert(Account(name: "Other default", type: .cash, isDefault: true))
        context.insert(Account(name: "Review account", type: .cash))
        context.insert(PersonalFinanceOS.Category(kind: .expense, name: "餐饮", symbolName: "fork.knife", colorToken: "orange"))
        context.insert(Tag(name: "Review tag", colorToken: "blue"))
        try context.save()
        return context
    }

    private func prepare(in context: ModelContext, count: Int = 1, category: String = "餐饮",
                         filename: String = "review.csv", now: Date = Date()) throws -> (ImportPlan, ImportCommitRequest) {
        let csv = "type,amount,date_time,category,account,tags,note\n" + Array(repeating:
            "expense,12.34,2026-01-01 10:00,\(category),Review account,Review tag,同一内容", count: count).joined(separator: "\n")
        let document = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: filename)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let parsed = try FinanceCSVService.parsePlan(document: document, mapping: FinanceCSVService.autoMapping(headers: document.headers), fileName: filename, calendar: calendar)
        let plan = FinanceCSVService.assessDuplicates(parsed, existingRecords: try context.fetch(FetchDescriptor<FinanceTransaction>()).map(ImportDuplicateRecord.init))
        let model = FinanceCSVService.makeImportModelSnapshot(accounts: try context.fetch(FetchDescriptor<Account>()), categories: try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), tags: try context.fetch(FetchDescriptor<Tag>()))
        let request = try FinanceCSVService.makeBackgroundCommitRequest(plan: plan, modelSnapshot: model, createMissingCategories: true, rememberedCategoryMappings: [:], now: now)
        return (plan, request)
    }
}
