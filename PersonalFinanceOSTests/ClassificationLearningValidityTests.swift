import Foundation
import SwiftData
import XCTest
@testable import PersonalFinanceOS

private final class LearningReadGate: @unchecked Sendable {
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var paused = false
    func checkpoint() throws {
        lock.lock()
        let shouldPause = !paused
        paused = true
        lock.unlock()
        guard shouldPause else { return }
        XCTAssertFalse(Thread.isMainThread, "The production reader must not occupy the main executor")
        reached.signal()
        guard release.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
    }
    func wait() -> Bool { reached.wait(timeout: .now() + 10) == .success }
}

@MainActor
final class ClassificationLearningValidityTests: XCTestCase {
    func testChangedMissingDeletedAndUnknownEventsCannotAddStrongOrNegativeEvidence() throws {
        let id = UUID(), category = UUID(), other = UUID()
        let event = event(id: id, category: category, note: "测试用途", rejected: other)
        let changed = history(id: id, category: other, note: "测试用途")
        let deleted = history(id: id, category: category, note: "测试用途", deleted: true)
        let cases: [(ClassificationEventLookup, ClassificationEventValidity)] = [
            (.present(changed), .existsChanged), (.present(deleted), .deletedOrMissingConfirmed),
            (.missing, .deletedOrMissingConfirmed), (.unknown, .lookupUnknown)
        ]
        for (lookup, expected) in cases {
            XCTAssertEqual(ClassificationEventValidity.evaluate(event, lookup: lookup), expected)
            let profile = ClassificationProfileBuilder.build(history: [], events: [event], eventLookups: [id: lookup])
            XCTAssertEqual(profile.sampleCount, 0)
            XCTAssertTrue(profile.statistics.isEmpty)
        }
        let profile = ClassificationProfileBuilder.build(history: [changed], events: [event], eventLookups: [id: .present(changed)])
        XCTAssertEqual(profile.sampleCount, 1)
        XCTAssertTrue(profile.statistics.values.allSatisfy { $0[category] == nil })
    }

    func testFullInputFingerprintRejectsTailChangesAndLegacyTruncationDoesNotProveMatch() throws {
        let prefix = String(repeating: "说明", count: 60)
        let id = UUID(), category = UUID()
        let original = prefix + "电脑"
        let changed = prefix + "纸质笔记本"
        let event = event(id: id, category: category, note: original)
        XCTAssertEqual(event.normalizedNote.count, 96)
        XCTAssertEqual(ClassificationEventValidity.evaluate(event, lookup: .present(history(id: id, category: category, note: original))), .existsMatching)
        XCTAssertEqual(ClassificationEventValidity.evaluate(event, lookup: .present(history(id: id, category: category, note: changed))), .existsChanged)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        json.removeValue(forKey: "inputFingerprint")
        let legacy = try JSONDecoder().decode(ClassificationLearningEvent.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.inputFingerprint)
        XCTAssertEqual(ClassificationEventValidity.evaluate(legacy, lookup: .present(history(id: id, category: category, note: original))), .existsChanged)
        let oldKey = ClassificationFeatureExtractor.features(note: original, merchant: "").first { $0.kind == .exactNote }
        let changedKey = ClassificationFeatureExtractor.features(note: changed, merchant: "").first { $0.kind == .exactNote }
        XCTAssertNotEqual(oldKey, changedKey)
        XCTAssertLessThanOrEqual(try XCTUnwrap(oldKey).value.count, 96)
    }

    func testLegacyShortEventsRemainVerifiableAndV1FileIsNotSilentlyCleared() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let event = event(id: UUID(), category: UUID(), note: "短备注")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        json.removeValue(forKey: "inputFingerprint")
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "events": [json]])
        let url = directory.appendingPathComponent("memory.json")
        try data.write(to: url)
        let store = ClassificationProfileStore(fileURL: url)
        let snapshot = try await store.snapshot()
        let legacy = try XCTUnwrap(snapshot.events.first)
        XCTAssertEqual(ClassificationEventValidity.evaluate(legacy, lookup: .present(history(id: legacy.transactionID, category: legacy.categoryID, note: "短备注"))), .existsMatching)
        XCTAssertEqual(try Data(contentsOf: url), data)
        try await store.record(event, generation: store.generation)
        XCTAssertEqual(try JSONDecoder().decode(ClassificationMemoryDocument.self, from: Data(contentsOf: url)).version, 2)
    }

    func testClearInvalidatesDelayedRecordAndOldProfileSnapshotButPreservesPostClearRecord() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClassificationProfileStore(fileURL: directory.appendingPathComponent("memory.json"))
        let old = event(id: UUID(), category: UUID(), note: "清空前")
        let delayedGeneration = store.generation
        try await store.record(old, generation: delayedGeneration)
        let oldSnapshot = try await store.snapshot()
        let clear = store.beginClear()
        XCTAssertNotEqual(store.generation, oldSnapshot.generation)
        let accepted = try await store.record(old, generation: delayedGeneration)
        XCTAssertFalse(accepted)
        let new = event(id: UUID(), category: UUID(), note: "清空后")
        try await store.record(new, generation: store.generation)
        try await store.reset(generation: clear)
        let events = try await store.events()
        XCTAssertEqual(events, [new])
        let reopened = ClassificationProfileStore(fileURL: directory.appendingPathComponent("memory.json"))
        let stored = try await reopened.events()
        XCTAssertEqual(stored, [new])
    }

    func testEventOutsideRollingWindowIsVerifiedThenInvalidatedByRealBatchEditAndDeletion() async throws {
        let context = try makeContext()
        let saved = try save(in: context, note: "窗口外人工纠正", occurredAt: Date().addingTimeInterval(-200 * 86400))
        let id = saved.id
        let event = event(id: id, category: try XCTUnwrap(saved.categoryID), note: saved.note)
        let reader = ClassificationHistoryActor(modelContainer: context.container)
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        let before = try await reader.fetchProfileInputs(cutoff: cutoff, eventIDs: [id])
        XCTAssertTrue(before.history.isEmpty)
        XCTAssertEqual(ClassificationEventValidity.evaluate(event, lookup: try XCTUnwrap(before.eventLookups[id])), .existsMatching)
        XCTAssertEqual(ClassificationProfileBuilder.build(history: before.history, events: [event], eventLookups: before.eventLookups).sampleCount, 1)
        let target = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining.dinner" })
        let actor = LedgerBatchOperationActor(modelContainer: context.container)
        _ = try await actor.migrateCategory(selectedIDs: [id], targetID: target.id)
        let changed = try await reader.fetchProfileInputs(cutoff: cutoff, eventIDs: [id])
        XCTAssertEqual(ClassificationEventValidity.evaluate(event, lookup: try XCTUnwrap(changed.eventLookups[id])), .existsChanged)
        XCTAssertEqual(ClassificationProfileBuilder.build(history: changed.history, events: [event], eventLookups: changed.eventLookups).sampleCount, 0)
        _ = try await actor.softDelete(selectedIDs: [id])
        let deleted = try await reader.fetchProfileInputs(cutoff: cutoff, eventIDs: [id])
        XCTAssertEqual(ClassificationEventValidity.evaluate(event, lookup: try XCTUnwrap(deleted.eventLookups[id])), .deletedOrMissingConfirmed)
        let missingID = UUID()
        let missing = try await reader.fetchProfileInputs(cutoff: cutoff, eventIDs: [missingID])
        if case .missing = missing.eventLookups[missingID] {} else { XCTFail("A successful ID query must distinguish missing from unreadable") }
    }

    func testHistoryAndEventReadsRetryTogetherAfterRealSaveBetweenBatches() async throws {
        let context = try makeContext()
        let first = try save(in: context, note: "旧内容", occurredAt: Date())
        _ = try save(in: context, note: "另一笔", occurredAt: Date().addingTimeInterval(-1))
        let id = first.id
        let gate = LearningReadGate()
        let reader = ClassificationHistoryActor(modelContainer: context.container)
        let reading = Task {
            try await reader.fetchProfileInputs(cutoff: .distantPast, eventIDs: [id], batchSize: 1, afterHistoryBatch: { try gate.checkpoint() })
        }
        let reached = await Task.detached { gate.wait() }.value
        XCTAssertTrue(reached)
        var draft = TransactionDraft(transaction: first)
        draft.note = "新内容"
        _ = try TransactionLifecycleService.save(draft: draft, editing: first,
            accounts: context.fetch(FetchDescriptor<Account>()), categories: context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), in: context)
        gate.release.signal()
        let result = try await reading.value
        XCTAssertEqual(result.attemptCount, 2)
        XCTAssertEqual(result.history.first { $0.id == id }?.note, "新内容")
        guard case let .present(current) = result.eventLookups[id] else { return XCTFail("Expected the current transaction") }
        XCTAssertEqual(current.note, "新内容")
        XCTAssertEqual(result.contentRevision, try LedgerSaveRevision.shared.readContentStamp())
    }

    func testHiddenParentInvalidatesPersonalEvidenceAndTimePrior() {
        let rootID = UUID(), childID = UUID(), id = UUID()
        let categories = [
            SuggestionCategory(id: rootID, name: "餐饮", kind: .expense, isActive: false),
            SuggestionCategory(id: childID, name: "早餐", kind: .expense, isActive: true, parentID: rootID, defaultDefinitionKey: "expense.dining.breakfast")
        ]
        XCTAssertTrue(SuggestionCategoryEligibility.active(categories).isEmpty)
        let event = event(id: id, category: childID, note: "个人用途")
        let profile = ClassificationProfileBuilder.build(history: [], events: [event],
            eventLookups: [id: .present(history(id: id, category: childID, note: "个人用途"))],
            eligibleCategoryIDs: Set(SuggestionCategoryEligibility.active(categories).map(\.id)))
        XCTAssertTrue(profile.statistics.isEmpty)
        let date = Date(timeIntervalSince1970: 8 * 3600)
        XCTAssertNil(QuickAddTimePriorService.categoryID(occurredAt: date, timeZone: TimeZone(secondsFromGMT: 0)!, categories: categories))
    }

    func testImportedManualConfirmationRemainsStrongAndOrdinaryImportRemainsWeak() {
        let category = UUID()
        let manual = history(id: UUID(), category: category, note: "报销用途", imported: true, source: .manualConfirmed)
        let ordinary = history(id: UUID(), category: category, note: "普通导入", imported: true, source: .unchanged)
        let strong = ClassificationProfileBuilder.build(history: [manual], events: [])
        let weak = ClassificationProfileBuilder.build(history: [ordinary], events: [])
        XCTAssertTrue(strong.statistics.values.allSatisfy { $0[category]?.strongSupport == 1 })
        XCTAssertTrue(weak.statistics.values.allSatisfy { $0[category]?.strongSupport == 0 })
    }

    func testRealImportThenUserBatchCorrectionIsStrongButMetadataMigrationIsNot() async throws {
        let context = try makeContext()
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let account = try XCTUnwrap(accounts.first)
        let source = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.dining.lunch" })
        let target = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.dining.dinner" })
        let csv = "type,amount,date_time,category,account,note\nexpense,12.34,2026-01-01 10:00,餐饮 / 午餐,\(account.name),导入用途甲\nexpense,13.45,2026-01-02 10:00,餐饮 / 午餐,\(account.name),导入用途乙"
        let document = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: "learning.csv")
        let plan = try FinanceCSVService.makePlan(document: document, mapping: FinanceCSVService.autoMapping(headers: document.headers), fileName: "learning.csv", existingTransactions: [])
        let model = FinanceCSVService.makeImportModelSnapshot(accounts: accounts, categories: categories, tags: [])
        let request = try FinanceCSVService.makeBackgroundCommitRequest(plan: plan, modelSnapshot: model, createMissingCategories: false, rememberedCategoryMappings: [:])
        let imported = try await ImportCommitActor(modelContainer: context.container).commit(request)
        XCTAssertEqual(imported.importedCount, 2)
        let rows = try ModelContext(context.container).fetch(FetchDescriptor<FinanceTransaction>())
        let ids = Set(rows.map(\.id))
        let actor = LedgerBatchOperationActor(modelContainer: context.container)
        let changed = try await actor.correctCategory(selectedIDs: ids, targetID: target.id)
        XCTAssertEqual(changed.summary.count, 2)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClassificationProfileStore(fileURL: directory.appendingPathComponent("memory.json"))
        try await store.record(changed.learningEvents, generation: store.generation)
        let events = try await store.events()
        let reader = ClassificationHistoryActor(modelContainer: context.container)
        let inputs = try await reader.fetchProfileInputs(cutoff: Date().addingTimeInterval(-90 * 86400), eventIDs: Array(ids))
        XCTAssertTrue(inputs.history.isEmpty)
        let profile = ClassificationProfileBuilder.build(history: inputs.history, events: events, eventLookups: inputs.eventLookups)
        XCTAssertEqual(profile.sampleCount, 2)
        XCTAssertTrue(profile.statistics.values.allSatisfy { ($0[target.id]?.strongSupport ?? 0) > 0 })
        let revision = try LedgerSaveRevision.shared.readStamp()
        let repeated = try await actor.correctCategory(selectedIDs: ids, targetID: target.id)
        XCTAssertEqual(repeated.summary.count, 0)
        XCTAssertTrue(repeated.learningEvents.isEmpty)
        XCTAssertEqual(try LedgerSaveRevision.shared.readStamp(), revision)
        _ = try await MetadataMutationActor(modelContainer: context.container).deleteCategory(id: target.id, targetID: source.id)
        let migrated = try await reader.fetchProfileInputs(cutoff: .distantPast, eventIDs: [])
        XCTAssertTrue(migrated.history.allSatisfy { $0.decisionSource == .unchanged && $0.categoryID == source.id })
        let weak = ClassificationProfileBuilder.build(history: migrated.history, events: [])
        XCTAssertTrue(weak.statistics.values.allSatisfy { $0[source.id]?.strongSupport == 0 })
        XCTAssertNoThrow(try NativeBackupService.validate(LedgerSnapshotCodec.capture(in: ModelContext(context.container))))
    }

    func testSidecarWriteFailureDoesNotUndoCommittedLedger() async throws {
        let context = try makeContext()
        let saved = try save(in: context, note: "账本已保存", occurredAt: Date())
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("parent")
        let store = ClassificationProfileStore(fileURL: blocker.appendingPathComponent("memory.json"))
        _ = try await store.snapshot()
        try Data("not a directory".utf8).write(to: blocker)
        let event = event(id: saved.id, category: try XCTUnwrap(saved.categoryID), note: saved.note)
        let beforeGeneration = store.generation
        do { try await store.record(event, generation: beforeGeneration); XCTFail("Expected a sidecar write failure") }
        catch { XCTAssertEqual(error as? ClassificationProfileStore.Failure, .unwritableDocument) }
        let persisted = try ModelContext(context.container).fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(persisted.map(\.id), [saved.id])
        XCTAssertEqual(persisted.first?.amountMinorUnits, 1234)
        let events = try await store.events()
        XCTAssertEqual(events, [event], "Committed correction remains available in session memory")
        XCTAssertNotEqual(store.generation, beforeGeneration)
        let memoryGeneration = store.generation
        try FileManager.default.removeItem(at: blocker)
        try await store.record(event, generation: memoryGeneration)
        XCTAssertEqual(store.generation, memoryGeneration, "Retrying identical evidence does not invalidate profiles twice")
        let reopened = ClassificationProfileStore(fileURL: blocker.appendingPathComponent("memory.json"))
        let reopenedEvents = try await reopened.events()
        XCTAssertEqual(reopenedEvents, [event])
    }

    func testFailedClearKeepsMemoryEmptyAndRetriesWithoutRestoringOldEvidence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("parent")
        let url = parent.appendingPathComponent("memory.json")
        let store = ClassificationProfileStore(fileURL: url)
        let value = event(id: UUID(), category: UUID(), note: "合成纠正")
        try await store.record(value, generation: store.generation)
        try FileManager.default.removeItem(at: parent)
        try Data("not a directory".utf8).write(to: parent)
        let clear = store.beginClear()
        do { try await store.reset(generation: clear); XCTFail("Disk clear must fail") }
        catch { XCTAssertEqual(error as? ClassificationProfileStore.Failure, .unwritableDocument) }
        let empty = try await store.events()
        XCTAssertTrue(empty.isEmpty)
        try FileManager.default.removeItem(at: parent)
        try await store.reset(generation: clear)
        let reopened = ClassificationProfileStore(fileURL: url)
        let afterRetry = try await reopened.events()
        XCTAssertTrue(afterRetry.isEmpty)
    }

    func testReadFailureDoesNotPruneStoredEventOrPretendItWasMissing() async throws {
        let context = try makeContext()
        let saved = try save(in: context, note: "读取失败仍保留事件", occurredAt: Date())
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.json")
        let store = ClassificationProfileStore(fileURL: url)
        let event = event(id: saved.id, category: try XCTUnwrap(saved.categoryID), note: saved.note)
        try await store.record(event, generation: store.generation)
        let bytes = try Data(contentsOf: url)
        do {
            _ = try await ClassificationHistoryActor(modelContainer: context.container).fetchProfileInputs(
                cutoff: .distantPast, eventIDs: [saved.id], afterHistoryBatch: { throw CocoaError(.fileReadNoPermission) }
            )
            XCTFail("A failed read must not return confirmed-missing results")
        } catch { XCTAssertEqual(try Data(contentsOf: url), bytes) }
        let profile = ClassificationProfileBuilder.build(history: [], events: [event], eventLookups: [saved.id: .unknown])
        XCTAssertTrue(profile.statistics.isEmpty)
        let events = try await store.events()
        XCTAssertEqual(events, [event])
    }

    func testProjectionChangeAndHardDeletionInvalidatePersistedEventsAfterReopeningSidecar() async throws {
        let context = try makeContext()
        let saved = try save(in: context, note: "投影前用途", occurredAt: Date())
        let id = saved.id
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.json")
        let store = ClassificationProfileStore(fileURL: url)
        let event = event(id: id, category: try XCTUnwrap(saved.categoryID), note: saved.note)
        try await store.record(event, generation: store.generation)
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(context.container))
        var records = try LedgerSnapshotCodec.records(package)
        var payload = try XCTUnwrap(package.transactions.first)
        payload.note = "同步后的新用途"
        let key = "transactions:\(id.uuidString)"
        records[key] = try JSONEncoder().encode(payload)
        try LedgerSnapshotCodec.apply(LedgerSnapshotCodec.package(from: records), in: ModelContext(context.container))
        let reader = ClassificationHistoryActor(modelContainer: context.container)
        let changed = try await reader.fetchProfileInputs(cutoff: .distantPast, eventIDs: [id])
        XCTAssertEqual(ClassificationEventValidity.evaluate(event, lookup: try XCTUnwrap(changed.eventLookups[id])), .existsChanged)
        records.removeValue(forKey: key)
        try LedgerSnapshotCodec.apply(LedgerSnapshotCodec.package(from: records), in: ModelContext(context.container))
        let reopened = ClassificationProfileStore(fileURL: url)
        let events = try await reopened.events()
        XCTAssertEqual(events, [event])
        let removed = try await reader.fetchProfileInputs(cutoff: .distantPast, eventIDs: [id])
        XCTAssertEqual(ClassificationEventValidity.evaluate(event, lookup: try XCTUnwrap(removed.eventLookups[id])), .deletedOrMissingConfirmed)
        XCTAssertTrue(ClassificationProfileBuilder.build(history: removed.history, events: events, eventLookups: removed.eventLookups).statistics.isEmpty)
    }

    private func event(id: UUID, category: UUID, note: String, rejected: UUID? = nil) -> ClassificationLearningEvent {
        .init(transactionID: id, recordedAt: Date(), type: .expense, note: note, merchant: "", categoryID: category, rejectedCategoryID: rejected, source: .explicitCorrection)
    }

    private func history(id: UUID, category: UUID, note: String, deleted: Bool = false, imported: Bool = false, source: CategoryDecisionSource = .manualConfirmed) -> SuggestionHistory {
        .init(id: id, type: .expense, note: note, merchant: "", categoryID: category, tagIDs: [], updatedAt: Date(), isDeleted: deleted, isImported: imported, decisionSource: source)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("learning-validity-\(UUID().uuidString)")
    }

    private func makeContext() throws -> ModelContext {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: context)
        return context
    }

    private func save(in context: ModelContext, note: String, occurredAt: Date) throws -> FinanceTransaction {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        var draft = TransactionDraft()
        draft.amountText = "12.34"
        draft.accountID = accounts.first?.id
        draft.categoryID = categories.first { $0.defaultDefinitionKey == "expense.dining.lunch" }?.id
        draft.note = note
        draft.occurredAt = occurredAt
        return try TransactionLifecycleService.save(draft: draft, accounts: accounts, categories: categories,
            categoryDecisionSource: .manualConfirmed, in: context)
    }
}
