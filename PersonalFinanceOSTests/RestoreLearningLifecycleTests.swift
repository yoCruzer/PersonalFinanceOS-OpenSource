import Foundation
import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class RestoreLearningLifecycleTests: XCTestCase {
    func testSuccessfulMetadataOnlyRestoreRejectsOldDraftAndDelayedLearningThenAcceptsNewWork() async throws {
        let context = try fixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.json")
        let store = ClassificationProfileStore(fileURL: url)
        let event = learningEvent()
        let delayedGeneration = store.generation
        try await store.record(event, generation: delayedGeneration)
        let profileGeneration = try await store.snapshot().generation
        let oldDraft = try draft(in: context)
        let oldMappingGeneration = ImportCategoryMappingStore.generation()
        let oldImport = try importRequest(in: context)
        let beforeEpoch = LedgerSaveRevision.shared.restoreGeneration
        let actor = NativeBackupActor(modelContainer: context.container)
        let data = try await actor.exportData()
        let result = try await actor.restore(data: data, admission: offlineRestoreTicket(for: context.container), learningStore: store)
        XCTAssertEqual(result.insertedTransactionCount, 0)
        XCTAssertFalse(result.learningResetFailed)
        XCTAssertNotEqual(LedgerSaveRevision.shared.restoreGeneration, beforeEpoch)
        XCTAssertNotEqual(ImportCategoryMappingStore.generation(), oldMappingGeneration)
        do {
            _ = try await ImportCommitActor(modelContainer: context.container).commit(oldImport)
            XCTFail("Restore must invalidate an import prepared against even identical old metadata")
        } catch { XCTAssertTrue(error is ImportCommitError) }
        XCTAssertNotEqual(store.generation, profileGeneration)
        let accepted = try await store.record(event, generation: delayedGeneration)
        XCTAssertFalse(accepted)
        let reopened = ClassificationProfileStore(fileURL: url)
        let persistedEvents = try await reopened.events()
        XCTAssertTrue(persistedEvents.isEmpty)
        let fresh = ModelContext(context.container)
        XCTAssertThrowsError(try save(oldDraft, in: fresh)) { XCTAssertEqual($0 as? TransactionDraftError, .staleDraft) }
        XCTAssertEqual(oldDraft.note, "草稿保留")
        let saved = try save(draft(in: fresh), in: fresh)
        XCTAssertEqual(saved.note, "草稿保留")
        let newEvent = ClassificationLearningEvent(transactionID: saved.id, recordedAt: Date(), type: saved.type,
            note: saved.note, merchant: saved.rawMerchantText, categoryID: try XCTUnwrap(saved.categoryID),
            rejectedCategoryID: nil, source: .manualChoice)
        try await store.record(newEvent, generation: store.generation)
        let events = try await store.events()
        XCTAssertEqual(events, [newEvent])
    }

    func testRejectedRestorePreservesDraftAndLearningGenerations() async throws {
        let context = try fixture()
        let actor = NativeBackupActor(modelContainer: context.container)
        let data = try await actor.exportData()
        _ = try save(draft(in: context), in: context)
        let oldDraft = try draft(in: context)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClassificationProfileStore(fileURL: directory.appendingPathComponent("memory.json"))
        try await store.record(learningEvent(), generation: store.generation)
        let snapshot = try await store.snapshot()
        let epoch = LedgerSaveRevision.shared.restoreGeneration
        do {
            _ = try await actor.restore(data: data, admission: offlineRestoreTicket(for: context.container), learningStore: store)
            XCTFail("Nonempty ledger must reject restore")
        } catch { XCTAssertEqual(error as? NativeBackupError, .destinationContainsUserLedger) }
        XCTAssertEqual(epoch, LedgerSaveRevision.shared.restoreGeneration)
        XCTAssertEqual(store.generation, snapshot.generation)
        let events = try await store.events()
        XCTAssertEqual(events, snapshot.events)
        XCTAssertNoThrow(try save(oldDraft, in: context))
    }

    func testLearningClearFailureIsReportedWithoutUndoingRestoredLedger() async throws {
        let context = try fixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("not-a-directory")
        let store = ClassificationProfileStore(fileURL: blocker.appendingPathComponent("memory.json"))
        _ = try await store.snapshot()
        try Data("blocker".utf8).write(to: blocker)
        let before = try LedgerSnapshotCodec.capture(in: ModelContext(context.container))
        let actor = NativeBackupActor(modelContainer: context.container)
        let data = try await actor.exportData()
        let result = try await actor.restore(data: data, admission: offlineRestoreTicket(for: context.container), learningStore: store)
        XCTAssertTrue(result.learningResetFailed)
        let after = try LedgerSnapshotCodec.capture(in: ModelContext(context.container))
        XCTAssertEqual(try LedgerSnapshotCodec.records(before), try LedgerSnapshotCodec.records(after))
        let snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    private func fixture() throws -> ModelContext {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: context)
        return context
    }

    private func importRequest(in context: ModelContext) throws -> ImportCommitRequest {
        let csv = "type,amount,date_time,category,note\nexpense,12.34,2026-01-01 10:00,餐饮 / 午餐,恢复前导入"
        let document = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: "before-restore.csv")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let parsed = try FinanceCSVService.parsePlan(document: document, mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "before-restore.csv", calendar: calendar)
        let plan = FinanceCSVService.assessDuplicates(parsed, existingRecords: [])
        let snapshot = FinanceCSVService.makeImportModelSnapshot(accounts: try context.fetch(FetchDescriptor<Account>()),
            categories: try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), tags: [])
        return try FinanceCSVService.makeBackgroundCommitRequest(plan: plan, modelSnapshot: snapshot, rememberedCategoryMappings: [:])
    }

    private func draft(in context: ModelContext) throws -> TransactionDraft {
        var draft = TransactionDraft()
        draft.amountText = "12.34"
        draft.accountID = try context.fetch(FetchDescriptor<Account>()).first?.id
        draft.categoryID = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining.lunch" }?.id
        draft.note = "草稿保留"
        return draft
    }

    @discardableResult
    private func save(_ draft: TransactionDraft, in context: ModelContext) throws -> FinanceTransaction {
        try TransactionLifecycleService.save(draft: draft, accounts: context.fetch(FetchDescriptor<Account>()),
            categories: context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), in: context)
    }

    private func learningEvent() -> ClassificationLearningEvent {
        .init(transactionID: UUID(), recordedAt: Date(), type: .expense, note: "恢复前", merchant: "",
              categoryID: UUID(), rejectedCategoryID: nil, source: .manualChoice)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("restore-learning-\(UUID().uuidString)")
    }
}
