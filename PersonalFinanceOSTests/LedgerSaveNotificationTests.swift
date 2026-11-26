import SwiftData
import XCTest
@testable import PersonalFinanceOS

private final class SaveNotificationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSave: Notification?
    private var values: [(entities: Set<String>, keys: [String: String], isContext: Bool, isWillSave: Bool)] = []
    func receive(_ notification: Notification) {
        let keys = (notification.userInfo ?? [:]).reduce(into: [String: String]()) {
            $0[String(describing: $1.key)] = String(describing: type(of: $1.value))
        }
        var entities: Set<String> = []
        for key in [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers] {
            let value = notification.userInfo?[key] ?? notification.userInfo?[key.rawValue]
            let ids = (value as? [PersistentIdentifier]) ?? Array((value as? Set<PersistentIdentifier>) ?? [])
            entities.formUnion(ids.map(\.entityName))
        }
        lock.lock()
        values.append((entities, keys, notification.object is ModelContext, notification.name == ModelContext.willSave))
        if notification.name == ModelContext.didSave { lastSave = notification }
        lock.unlock()
    }
    func lastNotification() -> Notification? { lock.lock(); defer { lock.unlock() }; return lastSave }
    func snapshot() -> [(entities: Set<String>, keys: [String: String], isContext: Bool, isWillSave: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

@MainActor
final class LedgerSaveNotificationTests: XCTestCase {
    func testMetadataOnlyRestoreNotifiesOnceAndReceiptSavesReachFixedPoint() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let actor = NativeBackupActor(modelContainer: context.container)
        let data = try await actor.exportData()
        let center = LedgerChangeCenter()
        center.observeSaves(in: context.container)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let learning = ClassificationProfileStore(fileURL: directory.appendingPathComponent("learning.json"))
        let result = try await actor.restore(data: data, admission: offlineRestoreTicket(for: context.container), learningStore: learning)
        XCTAssertEqual(result.insertedTransactionCount, 0)
        center.recordMutation()
        try await waitForRevision(center, atLeast: 1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(center.revision, 1)
        let contentRevision = LedgerSaveRevision.shared.contentRevision
        let receipts = ModelContext(context.container)
        for _ in 0..<4 {
            receipts.insert(SyncProjectionReceipt(projectionID: UUID()))
            try receipts.save()
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(center.revision, 1)
        XCTAssertEqual(LedgerSaveRevision.shared.contentRevision, contentRevision)
    }

    func testReceiptOnlySaveAndDuplicateDeliveryDoNotInvalidateAnalysisOrLearningInputs() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        let category = Category(kind: .expense, name: "合成父级", symbolName: "folder", colorToken: "blue")
        context.insert(category)
        try context.save()
        let center = LedgerChangeCenter()
        center.observeSaves(in: context.container)
        let reader = LedgerAnalysisActor(modelContainer: context.container)
        let store = LedgerAnalysisStore()
        let filter = LedgerFilter(dateRange: nil)
        var computationCount = 0
        await store.reload(filter: filter, actor: reader, beforePublication: { computationCount += 1 })
        let history = try await ClassificationHistoryActor(modelContainer: context.container).fetchProfileInputs(cutoff: .distantPast, eventIDs: [])
        let content = try LedgerSaveRevision.shared.readContentStamp()
        let saved = try LedgerSaveRevision.shared.readStamp()
        let capture = SaveNotificationCapture()
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { capture.receive($0) }
        defer { NotificationCenter.default.removeObserver(observer) }
        let receipt = SyncProjectionReceipt(projectionID: UUID())
        context.insert(receipt)
        try context.save()
        XCTAssertGreaterThan(try LedgerSaveRevision.shared.readStamp(), saved)
        XCTAssertEqual(try LedgerSaveRevision.shared.readContentStamp(), content)
        let afterReceipt = try LedgerSaveRevision.shared.readStamp()
        let notification = try XCTUnwrap(capture.lastNotification())
        for _ in 0..<3 { NotificationCenter.default.post(notification) }
        XCTAssertEqual(try LedgerSaveRevision.shared.readStamp(), afterReceipt)
        XCTAssertEqual(try LedgerSaveRevision.shared.readContentStamp(), history.contentRevision)
        await store.reload(filter: filter, actor: reader, beforePublication: { computationCount += 1 })
        await Task.yield()
        XCTAssertEqual(center.revision, 0)
        XCTAssertEqual(computationCount, 1, "Receipt and duplicate notifications cannot rescan a current filter")

        try FinanceDataManagementService.rename(category: category, to: "改名后父级", in: context)
        try await waitForRevision(center, atLeast: 1)
        XCTAssertEqual(center.revision, 1)
        await store.reload(filter: filter, actor: reader, beforePublication: { computationCount += 1 })
        XCTAssertEqual(computationCount, 2)
        XCTAssertEqual(store.snapshot?.totals.totalCount, 0)
        XCTAssertEqual(store.snapshot?.metadata.path(category.id), "改名后父级")
        let refreshed = try await ClassificationHistoryActor(modelContainer: context.container).fetchProfileInputs(cutoff: .distantPast, eventIDs: [])
        XCTAssertNotEqual(refreshed.contentRevision, history.contentRevision)
        XCTAssertEqual(refreshed.categories.first?.name, "改名后父级")
        let changedSave = try XCTUnwrap(capture.lastNotification())
        let revision = try LedgerSaveRevision.shared.readContentStamp()
        for _ in 0..<3 { NotificationCenter.default.post(changedSave) }
        center.recordMutation()
        await store.reload(filter: filter, actor: reader, beforePublication: { computationCount += 1 })
        await Task.yield()
        XCTAssertEqual(center.revision, 1, "Explicit acknowledgment and duplicate delivery coalesce")
        XCTAssertEqual(computationCount, 2)
        XCTAssertEqual(try LedgerSaveRevision.shared.readContentStamp(), revision)
        try FinanceDataManagementService.rename(category: category, to: "再次真实改名", in: context)
        try await waitForRevision(center, atLeast: 2)
        XCTAssertEqual(center.revision, 2, "A new willSave for the same IDs is a real edit")
    }

    func testBackgroundMetadataNotificationWaitsForFinalBoundaryWithoutBlockingMainActor() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        let category = Category(kind: .expense, name: "原名称", symbolName: "folder", colorToken: "blue")
        context.insert(category)
        try context.save()
        let center = LedgerChangeCenter()
        center.observeSaves(in: context.container)
        let gate = ContentNotificationGate()
        let container = context.container
        let id = category.id
        let writing = Task.detached {
            try LedgerSaveRevision.shared.withImportBoundary {
                let writer = ModelContext(container)
                let category = try XCTUnwrap(writer.fetch(FetchDescriptor<PersonalFinanceOS.Category>(predicate: #Predicate { $0.id == id })).first)
                category.name = "后台修改"
                try writer.save()
                try gate.pauseAfterSave()
            }
        }
        let reached = await Task.detached { gate.waitUntilSaved() }.value
        XCTAssertTrue(reached)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(center.revision, 0, "Consumers must not wake while the writer still owns the final boundary")
        gate.release.signal()
        try await writing.value
        try await waitForRevision(center, atLeast: 1)
        XCTAssertEqual(center.revision, 1)
        let snapshot = try await LedgerAnalysisActor(modelContainer: container).snapshot(filter: LedgerFilter(dateRange: nil))
        XCTAssertEqual(snapshot.metadata.path(id), "后台修改")
    }

    func testChangeCenterDoesNotObserveAnotherContainer() async throws {
        let first = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let second = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let center = LedgerChangeCenter()
        center.observeSaves(in: first)
        let context = ModelContext(second)
        context.insert(Account(name: "另一账本", type: .cash))
        try context.save()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(center.revision, 0)
    }

    private func waitForRevision(_ center: LedgerChangeCenter, atLeast expected: UInt64) async throws {
        for _ in 0..<100 {
            if center.revision >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for completed content notification")
    }

    func testRealSaveNotificationSeparatesBusinessEntitiesFromProjectionReceipt() throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        let capture = SaveNotificationCapture()
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) {
            capture.receive($0)
        }
        let beforeObserver = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: nil, queue: nil) {
            capture.receive($0)
        }
        defer { NotificationCenter.default.removeObserver(observer); NotificationCenter.default.removeObserver(beforeObserver) }
        let account = Account(name: "合成账户", type: .cash)
        context.insert(account)
        try context.save()
        let receipt = SyncProjectionReceipt(projectionID: UUID())
        context.insert(receipt)
        try context.save()
        account.name = "合成账户改名"
        try context.save()
        let observed = capture.snapshot()
        // Types/keys only: no model IDs or ledger field values enter test logs.
        print("SAVE_NOTIFICATION_KEYS", observed.map { ($0.keys, $0.isContext, $0.isWillSave) })
        XCTAssertEqual(observed.map(\.isWillSave), [true, false, true, false, true, false])
        XCTAssertTrue(observed.allSatisfy(\.isContext))
        let snapshots = observed.filter { !$0.isWillSave }
        guard snapshots.count == 3 else { return XCTFail("Expected three successful saves") }
        XCTAssertEqual(snapshots[0].entities, ["Account"])
        XCTAssertEqual(snapshots[1].entities, ["SyncProjectionReceipt"])
        XCTAssertEqual(snapshots[2].entities, ["Account"])
    }
}

private final class ContentNotificationGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let saved = DispatchSemaphore(value: 0)
    func pauseAfterSave() throws {
        XCTAssertFalse(Thread.isMainThread)
        saved.signal()
        guard release.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
    }
    func waitUntilSaved() -> Bool { saved.wait(timeout: .now() + 10) == .success }
}
