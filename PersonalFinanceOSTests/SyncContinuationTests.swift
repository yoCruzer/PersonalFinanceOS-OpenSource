import CloudKit
import SwiftData
import XCTest
@testable import PersonalFinanceOS

private enum SyncCallbackContext {
    @TaskLocal static var isDelegate = false
}

private actor ContinuationGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class SendEditProbe {
    let controller: ICloudSyncController
    let context: ModelContext
    let session: PrivateCloudReplicaSession
    var oldRecord: CKRecord?
    var key: String?
    var editedID: UUID?
    init(controller: ICloudSyncController, context: ModelContext, session: PrivateCloudReplicaSession) {
        self.controller = controller; self.context = context; self.session = session
    }
    func beforeReceipt(_ records: [CKRecord]) async throws {
        guard oldRecord == nil else { return }
        for record in records {
            guard let data = record["envelope"] as? Data else { continue }
            let envelope = try JSONDecoder().decode(PrivateCloudReplicaSession.Envelope.self, from: data)
            guard envelope.key.hasPrefix("transactions:"), let payload = envelope.record.payload else { continue }
            let sent = try JSONDecoder().decode(NativeBackupPackage.TransactionPayload.self, from: payload)
            let local = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == sent.id })
            oldRecord = record; key = envelope.key; editedID = local.id
            local.note = "New edit while the old revision is in flight"
            try context.save()
            await controller.reconcile(in: context, changes: LedgerChangeCenter())
            let current = await session.snapshot()
            XCTAssertNotEqual(current.records[envelope.key]?.revision, envelope.record.revision)
            return
        }
    }
}

@MainActor
private final class SnapshotCounter {
    var count = 0
    var atFirstSend: Int?
    func markFirstSend() { atFirstSend = count }
}

@MainActor
private final class SyncEventRelay {
    let controller: ICloudSyncController
    let context: ModelContext
    let changes = LedgerChangeCenter()
    private var observers: [NSObjectProtocol] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var active = true
    init(controller: ICloudSyncController, context: ModelContext) {
        self.controller = controller; self.context = context
        for name in [PrivateCloudReplicaSession.didChange, LedgerSaveRevision.editingDidEnd] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.forward() }
            })
        }
    }
    private func forward() {
        guard active else { return }
        let id = UUID()
        tasks[id] = Task {
            await controller.synchronize(in: context, changes: changes)
            tasks[id] = nil
        }
    }
    func drain() async {
        await Task.yield()
        while let task = tasks.values.first { await task.value }
    }
    func stop() {
        active = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
}

actor SyntheticSyncTransport {
    var session: PrivateCloudReplicaSession?
    var fetches = 0
    var sends = 0
    var batches = 0
    var saved = 0
    var batchLimit = Int.max
    var interruptAfterBatch: Int?
    var interrupted = false
    var maxPersistenceSeconds: TimeInterval = 0
    var nextSendError: CKError?
    var limitNextBatch = false
    var limitApplied = false
    func limitFirstBatch() { limitNextBatch = true }
    var onSend: (@Sendable () -> Void)?
    var beforeReceipt: (@Sendable ([CKRecord]) async throws -> Void)?
    var everyReceipt: (@Sendable ([CKRecord]) async throws -> Void)?
    func beforeEveryReceipt(_ callback: @escaping @Sendable ([CKRecord]) async throws -> Void) { everyReceipt = callback }
    func failNextSend(_ error: CKError) { nextSendError = error }
    func observeSend(_ callback: @escaping @Sendable () -> Void) { onSend = callback }
    func beforeNextReceipt(_ callback: @escaping @Sendable ([CKRecord]) async throws -> Void) { beforeReceipt = callback }

    func attach(_ session: PrivateCloudReplicaSession, batchLimit: Int = Int.max, interruptAfterBatch: Int? = nil) {
        self.session = session
        self.batchLimit = batchLimit
        self.interruptAfterBatch = interruptAfterBatch
    }
    func fetch(_ engine: CKSyncEngine) async throws {
        XCTAssertFalse(SyncCallbackContext.isDelegate, "Network follow-ups must escape the delegate task context")
        guard let session else { throw CocoaError(.coderInvalidValue) }
        fetches += 1
        await session.recordFetchStarted(syncEngine: engine)
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        await session.recordZoneFetchResult(error: nil, syncEngine: engine)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
    }
    func send(_ engine: CKSyncEngine, options: CKSyncEngine.SendChangesOptions) async throws {
        XCTAssertFalse(SyncCallbackContext.isDelegate, "Network follow-ups must escape the delegate task context")
        guard let session else { throw CocoaError(.coderInvalidValue) }
        sends += 1
        if let error = nextSendError { nextSendError = nil; throw error }
        onSend?()
        await session.recordSendActivity(uploading: true, syncEngine: engine)
        for _ in 0..<batchLimit {
            guard let batch = await session.recordZoneChangeBatch(scope: options.scope, syncEngine: engine),
                  !batch.recordsToSave.isEmpty else { break }
            let records = batch.recordsToSave
            if limitNextBatch {
                limitNextBatch = false
                limitApplied = true
                try await session.recordSentRecords([], failedSaves: records.map { ($0, CKError(.limitExceeded)) }, syncEngine: engine)
                await session.recordSendActivity(uploading: false, syncEngine: engine)
                return
            }
            if limitApplied { XCTAssertLessThanOrEqual(records.count, 50) }
            if let before = beforeReceipt { beforeReceipt = nil; try await before(records) }
            try await everyReceipt?(records)
            XCTAssertLessThanOrEqual(records.count, 100)
            // Simulate only SDK transport/state removal. Payload selection, revision
            // acknowledgments, persistence and convergence all use production code.
            engine.state.remove(pendingRecordZoneChanges: records.map { .saveRecord($0.recordID) })
            try await session.recordSentRecords(records, failedSaves: [], syncEngine: engine)
            batches += 1
            saved += records.count
            maxPersistenceSeconds = max(maxPersistenceSeconds, await session.lastPersistenceDuration)
            if interruptAfterBatch == batches, !interrupted {
                interrupted = true
                await session.recordFetchStarted(syncEngine: engine)
                let blocked = await session.recordZoneChangeBatch(scope: .all, syncEngine: engine)
                XCTAssertNil(blocked, "Fetch invalidates readiness; the safety gate stays closed")
                break
            }
        }
        await session.recordSendActivity(uploading: false, syncEngine: engine)
    }
    func counters() -> (fetches: Int, sends: Int, batches: Int, saved: Int, persistence: TimeInterval) {
        (fetches, sends, batches, saved, maxPersistenceSeconds)
    }
}

@MainActor
final class SyncContinuationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let context: ModelContext
        let session: PrivateCloudReplicaSession
        let controller: ICloudSyncController
        let engine: CKSyncEngine
        let transport: SyntheticSyncTransport
    }

    private func fixture(transactions: Int = 3, batchLimit: Int = Int.max, interruptAfterBatch: Int? = nil, disk: Bool = false, officialLocation: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container: ModelContainer
        if disk {
            container = try ModelContainerFactory.make(configuration: ModelConfiguration(schema: AppSchema.schema,
                url: root.appendingPathComponent("local.store"), cloudKitDatabase: .none))
        } else { container = try ModelContainerFactory.make(isStoredInMemoryOnly: true) }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first)
        let category = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.kind == .expense })
        for index in 0..<transactions {
            context.insert(FinanceTransaction(type: .expense, amountMinorUnits: Int64(index + 1),
                occurredAt: Date(timeIntervalSince1970: 1_767_225_600), localDayKey: "2026-01-01",
                timeZoneIdentifier: "Asia/Shanghai", accountID: account.id, categoryID: category.id))
        }
        try context.save()
        let transport = SyntheticSyncTransport()
        let location = CloudReplicaLocation(root: root, environment: .development, account: "synthetic")
        let stateURL = officialLocation ? location.stateURL : root.appendingPathComponent("state.json")
        let identityURL = officialLocation ? location.identityURL : root.appendingPathComponent("identity.json")
        let session = try PrivateCloudReplicaSession(stateURL: stateURL,
            accountIdentifier: "synthetic", automaticallySync: false, operations: .init(
                fetchChanges: { try await transport.fetch($0) }, cancelOperations: { _ in },
                sendChanges: { try await transport.send($0, options: $1) }))
        await transport.attach(session, batchLimit: batchLimit, interruptAfterBatch: interruptAfterBatch)
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let value = await session.engine
        let engine = try XCTUnwrap(value)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        let controller = ICloudSyncController(confirmedSession: session, identity: LedgerSyncIdentity(), identityURL: identityURL)
        controller.setForeground(true)
        return Fixture(root: root, context: context, session: session, controller: controller, engine: engine, transport: transport)
    }

    func testOneRequestConverges12500TransactionsThroughRealBatchesAndDurableReceipts() async throws {
        let fixture = try await fixture(transactions: 12_500, batchLimit: 8)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let relay = SyncEventRelay(controller: fixture.controller, context: fixture.context)
        defer { relay.stop() }
        let snapshots = SnapshotCounter()
        fixture.controller.reconcileCheckpoint = { if $0 == .snapshot { snapshots.count += 1 } }
        await fixture.transport.beforeNextReceipt { _ in await snapshots.markFirstSend() }
        let start = Date()
        await fixture.controller.syncNow(in: fixture.context, changes: LedgerChangeCenter())
        await relay.drain()
        await fixture.controller.waitForRequestWork()
        await relay.drain()
        let elapsed = Date().timeIntervalSince(start)
        let evidence = await fixture.session.syncEvidence()
        let replica = await fixture.session.snapshot()
        let counters = await fixture.transport.counters()
        XCTAssertFalse(fixture.controller.isSyncRequested)
        XCTAssertNotNil(fixture.controller.completedRequestAt)
        XCTAssertTrue(evidence.canConfirm)
        XCTAssertEqual(evidence.pendingUploads, 0)
        XCTAssertEqual(counters.saved, replica.records.count)
        XCTAssertGreaterThan(counters.saved, 12_500)
        XCTAssertGreaterThan(counters.batches, 125)
        XCTAssertGreaterThan(counters.sends, 1)
        XCTAssertEqual(counters.fetches, 1, "No fetch per send or per batch")
        XCTAssertEqual(snapshots.count, snapshots.atFirstSend, "Upload-only events must not re-snapshot the ledger")
        XCTAssertLessThanOrEqual(snapshots.count, 2, "At most one initial stale projection can be invalidated by the manual Fetch")
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<FinanceTransaction>()), 12_500)
        print("SYNC_CONTINUATION entities=\(counters.saved) batches=\(counters.batches) sends=\(counters.sends) fetches=\(counters.fetches) snapshots=\(snapshots.count) initial_snapshots=\(snapshots.atFirstSend ?? -1) total_s=\(elapsed) max_persist_s=\(counters.persistence)")
        let disk = try JSONDecoder().decode(PrivateCloudReplicaSession.State.self,
            from: Data(contentsOf: fixture.root.appendingPathComponent("state.json")))
        XCTAssertEqual(disk.uploadedRevisions.count, replica.records.count)
        XCTAssertEqual(disk.replica.records, replica.records)
        await fixture.controller.disable()
    }

    func testFetchInterruptionRetainsIntentAndResumesAfterApplicationEvent() async throws {
        let fixture = try await fixture(transactions: 350, interruptAfterBatch: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let changes = LedgerChangeCenter()
        await fixture.controller.syncNow(in: fixture.context, changes: changes)
        XCTAssertTrue(fixture.controller.isSyncRequested)
        XCTAssertNil(fixture.controller.completedRequestAt)
        let paused = await fixture.session.syncEvidence()
        XCTAssertGreaterThan(paused.pendingUploads, 0)
        XCTAssertFalse(paused.appliedCurrentFetch)
        try await fixture.session.recordFetchCompletion(succeeded: true, syncEngine: fixture.engine)
        await fixture.controller.synchronize(in: fixture.context, changes: changes)
        await fixture.controller.waitForRequestWork()
        XCTAssertFalse(fixture.controller.isSyncRequested)
        let resumed = await fixture.session.syncEvidence()
        XCTAssertTrue(resumed.canConfirm)
        XCTAssertNotNil(fixture.controller.completedRequestAt)
        await fixture.controller.disable()
    }

    func testUnsavedEditsParkRequestAndSaveEventResumesWithoutClick() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let account = try XCTUnwrap(fixture.context.fetch(FetchDescriptor<Account>()).first)
        account.name = "Synthetic unsaved edit"
        let changes = LedgerChangeCenter()
        await fixture.controller.syncNow(in: fixture.context, changes: changes)
        XCTAssertTrue(fixture.controller.isSyncRequested)
        XCTAssertEqual(fixture.controller.requestPause, .edits)
        let counters = await fixture.transport.counters()
        XCTAssertEqual(counters.sends, 0)
        try fixture.context.save()
        await fixture.controller.synchronize(in: fixture.context, changes: changes)
        await fixture.controller.waitForRequestWork()
        XCTAssertFalse(fixture.controller.isSyncRequested)
        XCTAssertNotNil(fixture.controller.completedRequestAt)
        XCTAssertEqual(account.name, "Synthetic unsaved edit")
        await fixture.controller.disable()
    }

    func testManualRequestJoinsRunningReconcileAndDuplicateClicks() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let entered = expectation(description: "running reconciliation")
        let manualActivated = expectation(description: "manual activated")
        let gate = ContinuationGate()
        var first = true
        fixture.controller.reconcileCheckpoint = { stage in
            if stage == .snapshot, first { first = false; entered.fulfill(); await gate.wait() }
        }
        fixture.controller.manualSyncActivated = { manualActivated.fulfill() }
        let changes = LedgerChangeCenter()
        let reconciliation = Task { await fixture.controller.reconcile(in: fixture.context, changes: changes) }
        await fulfillment(of: [entered], timeout: 5)
        let manual = Task { await fixture.controller.syncNow(in: fixture.context, changes: changes) }
        await fulfillment(of: [manualActivated], timeout: 5)
        await fixture.controller.syncNow(in: fixture.context, changes: changes)
        let before = await fixture.transport.counters()
        XCTAssertEqual(before.sends, 0)
        XCTAssertTrue(fixture.controller.isSyncRequested)
        await gate.release()
        _ = await reconciliation.value
        await manual.value
        await fixture.controller.waitForRequestWork()
        XCTAssertFalse(fixture.controller.isSyncRequested)
        let after = await fixture.transport.counters()
        XCTAssertEqual(after.fetches, 1)
        XCTAssertNil(fixture.controller.lastFailure)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        await fixture.controller.disable()
    }

    func testRollbackNotificationResumesRequestWithoutSaveOrClick() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let relay = SyncEventRelay(controller: fixture.controller, context: fixture.context)
        defer { relay.stop() }
        let account = try XCTUnwrap(fixture.context.fetch(FetchDescriptor<Account>()).first)
        let original = account.name
        account.name = "Discarded synthetic edit"
        await fixture.controller.syncNow(in: fixture.context, changes: LedgerChangeCenter())
        XCTAssertEqual(fixture.controller.requestPause, .edits)
        fixture.context.rollbackNotifyingSync()
        await relay.drain()
        await fixture.controller.waitForRequestWork()
        await relay.drain()
        XCTAssertFalse(fixture.controller.isSyncRequested)
        XCTAssertEqual(account.name, original)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        await fixture.controller.disable()
    }

    func testBackgroundPausesAndForegroundResumesRetainedRequest() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.controller.setForeground(false)
        await fixture.controller.syncNow(in: fixture.context, changes: LedgerChangeCenter())
        XCTAssertTrue(fixture.controller.isSyncRequested)
        XCTAssertEqual(fixture.controller.requestPause, .background)
        let paused = await fixture.transport.counters()
        XCTAssertEqual(paused.sends, 0)
        fixture.controller.setForeground(true)
        await fixture.controller.waitForRequestWork()
        XCTAssertFalse(fixture.controller.isSyncRequested)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        await fixture.controller.disable()
    }

    func testStableApplicationReasonsAndLongestGroupedRetryAfter() {
        let failure = SyncFailure.capture(ProtectedLedgerReplica.Failure.initialFetchRequired, phase: "manualSync")
        XCTAssertEqual(failure.reasonCode, "projection_not_ready")
        XCTAssertNotEqual(failure.code, 0)
        let short = CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 2.0])
        let long = CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 60.0])
        let grouped = SyncFailure.grouped([short, long], phase: "upload")
        XCTAssertEqual(grouped.first?.retryAfter, 60)
        XCTAssertEqual(grouped.first?.count, 2)
    }

    func testOfflineFailureRetainsIntentAndRecoverySeparatesHistoricalFailure() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.transport.failNextSend(CKError(.networkUnavailable))
        let changes = LedgerChangeCenter()
        await fixture.controller.syncNow(in: fixture.context, changes: changes)
        XCTAssertTrue(fixture.controller.isSyncRequested)
        XCTAssertEqual(fixture.controller.requestPause, .serviceRetry)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .retrying)
        XCTAssertNil(fixture.controller.completedRequestAt)
        let failed = await fixture.transport.counters()
        await fixture.controller.syncNow(in: fixture.context, changes: changes)
        await fixture.controller.waitForRequestWork()
        let duplicate = await fixture.transport.counters()
        XCTAssertEqual(duplicate.sends, failed.sends, "A repeated tap cannot bypass SDK retry state")
        let edit = try XCTUnwrap(fixture.context.fetch(FetchDescriptor<Account>()).first)
        edit.name = "Pending after network recovery"
        await fixture.session.recordOperationResult(errors: [], syncEngine: fixture.engine)
        await fixture.controller.synchronize(in: fixture.context, changes: changes)
        await fixture.controller.waitForRequestWork()
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .editing)
        XCTAssertTrue(fixture.controller.displaySnapshot.failures.isEmpty)
        try fixture.context.save()
        await fixture.controller.synchronize(in: fixture.context, changes: changes)
        await fixture.controller.waitForRequestWork()
        XCTAssertFalse(fixture.controller.isSyncRequested)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        XCTAssertTrue(fixture.controller.displaySnapshot.failures.isEmpty)
        XCTAssertTrue(fixture.controller.displaySnapshot.historicalFailures.contains { $0.code == CKError.Code.networkUnavailable.rawValue })
        await fixture.controller.disable()
    }

    func testServiceDeadlineWakesOnceWithoutAnotherEventOrClick() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let delay = 1.0
        await fixture.session.recordOperationResult(errors: [CKError(.requestRateLimited,
            userInfo: [CKErrorRetryAfterKey: delay])], syncEngine: fixture.engine)
        // A success delivered before the deadline must not make a manual send bypass it.
        await fixture.session.recordOperationResult(errors: [], syncEngine: fixture.engine)
        let resumed = expectation(description: "deadline resumes retained request")
        await fixture.transport.observeSend { resumed.fulfill() }
        let started = Date()
        await fixture.controller.syncNow(in: fixture.context, changes: LedgerChangeCenter())
        XCTAssertEqual(fixture.controller.requestPause, .serviceRetry)
        let paused = await fixture.transport.counters()
        XCTAssertEqual(paused.sends, 0)
        await fulfillment(of: [resumed], timeout: 5)
        await fixture.controller.waitForRequestWork()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9)
        XCTAssertFalse(fixture.controller.isSyncRequested)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        await fixture.controller.disable()
    }

    func testAccountChangeDuringFetchCannotHideBehindApplyingGate() async throws {
        for switched in [false, true] {
            let fixture = try await fixture(transactions: 350, interruptAfterBatch: 1)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let changes = LedgerChangeCenter()
            await fixture.controller.syncNow(in: fixture.context, changes: changes)
            let before = await fixture.session.snapshot()
            let change: CKSyncEngine.Event.AccountChange.ChangeType = switched
                ? .switchAccounts(previousUser: .init(recordName: "synthetic"), currentUser: .init(recordName: "other"))
                : .signOut(previousUser: .init(recordName: "synthetic"))
            await fixture.session.recordAccountChange(change, syncEngine: fixture.engine)
            await fixture.controller.synchronize(in: fixture.context, changes: changes)
            await fixture.controller.waitForRequestWork()
            XCTAssertFalse(fixture.controller.isSyncRequested)
            XCTAssertEqual(fixture.controller.status, switched ? .accountChanged : .unavailable)
            XCTAssertNil(fixture.controller.completedRequestAt)
            let after = await fixture.session.snapshot()
            XCTAssertEqual(after, before)
            await fixture.controller.disable()
        }
    }

    func testOffDuringRunningReconcileRejectsOldCompletionAndKeepsLedger() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = ContinuationGate()
        let entered = expectation(description: "old projection")
        fixture.controller.reconcileCheckpoint = { stage in
            if stage == .snapshot { entered.fulfill(); await gate.wait() }
        }
        let request = Task { await fixture.controller.syncNow(in: fixture.context, changes: LedgerChangeCenter()) }
        await fulfillment(of: [entered], timeout: 5)
        await fixture.controller.disable()
        XCTAssertFalse(fixture.controller.isSyncRequested)
        await gate.release()
        await request.value
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .off)
        XCTAssertNil(fixture.controller.completedRequestAt)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<FinanceTransaction>()), 3)
        let sent = await fixture.transport.counters()
        XCTAssertEqual(sent.sends, 0)
    }

    func testOldReceiptCannotConfirmInFlightEditAndNextRequestSendsIt() async throws {
        let fixture = try await fixture(transactions: 300)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = SendEditProbe(controller: fixture.controller, context: fixture.context, session: fixture.session)
        await fixture.transport.beforeEveryReceipt { try await probe.beforeReceipt($0) }
        let changes = LedgerChangeCenter()
        await fixture.controller.syncNow(in: fixture.context, changes: changes)
        let old = try XCTUnwrap(probe.oldRecord)
        let key = try XCTUnwrap(probe.key)
        XCTAssertFalse(fixture.controller.isSyncRequested, "The frozen round can finish while a newer edit awaits its own receipt")
        XCTAssertNotNil(fixture.controller.completedRequestAt)
        let pending = await fixture.session.syncEvidence()
        XCTAssertGreaterThan(pending.pendingUploads, 0)
        XCTAssertFalse(pending.canConfirm)
        XCTAssertNotEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        try await fixture.session.recordSavedRecords([old, old], syncEngine: fixture.engine)
        let newer = await fixture.session.snapshot()
        let next = await fixture.session.recordZoneChangeBatch(scope: .all, syncEngine: fixture.engine)
        let resent = try XCTUnwrap(next?.recordsToSave.first { $0.recordID == old.recordID })
        let resentEnvelope = try JSONDecoder().decode(PrivateCloudReplicaSession.Envelope.self,
            from: XCTUnwrap(resent["envelope"] as? Data))
        XCTAssertEqual(resentEnvelope.record.revision, newer.records[key]?.revision)
        await fixture.session.recordSendActivity(uploading: false, syncEngine: fixture.engine)
        await fixture.controller.synchronize(in: fixture.context, changes: changes)
        await fixture.controller.waitForRequestWork()
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<FinanceTransaction>()), 300)
        let edited = try XCTUnwrap(fixture.context.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == probe.editedID })
        XCTAssertEqual(edited.note, "New edit while the old revision is in flight")
        await fixture.controller.disable()
    }

    func testFailedReceiptPersistenceCannotReduceTargetOrPending() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.controller.reconcile(in: fixture.context, changes: LedgerChangeCenter())
        let target = await fixture.session.makeUploadTarget()
        let batchValue = await fixture.session.recordZoneChangeBatch(scope: .all, syncEngine: fixture.engine)
        let batch = try XCTUnwrap(batchValue)
        let before = await fixture.session.requestProgress(target: target)
        let url = fixture.root.appendingPathComponent("state.json")
        let backup = fixture.root.appendingPathComponent("saved-state.json")
        let original = try Data(contentsOf: url)
        try FileManager.default.moveItem(at: url, to: backup)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do {
            try await fixture.session.recordSavedRecords(batch.recordsToSave, syncEngine: fixture.engine)
            XCTFail("The synthetic directory must reject receipt persistence")
        } catch { }
        let failed = await fixture.session.requestProgress(target: target)
        XCTAssertEqual(failed.targetRemaining, before.targetRemaining)
        XCTAssertEqual(failed.pending, before.pending)
        XCTAssertFalse(failed.targetComplete)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: backup, to: url)
        await fixture.session.recordSendActivity(uploading: false, syncEngine: fixture.engine)
        await fixture.controller.syncNow(in: fixture.context, changes: LedgerChangeCenter())
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        await fixture.controller.disable()
    }

    func testRemoteCorrectionRemovesOnlyStaleQuarantineAndDuplicateDeliveryKeepsIdentity() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transactions = try fixture.context.fetch(FetchDescriptor<FinanceTransaction>())
        let large = try XCTUnwrap(transactions.first)
        large.note = String(repeating: "x", count: 950_000)
        try fixture.context.save()
        await fixture.controller.syncNow(in: fixture.context, changes: LedgerChangeCenter())
        let blocked = await fixture.session.syncEvidence()
        XCTAssertEqual(blocked.quarantined, 1)
        XCTAssertEqual(blocked.pendingUploads, 1)
        XCTAssertTrue(fixture.controller.isSyncRequested)
        XCTAssertNil(fixture.controller.completedRequestAt)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .oversized)
        let before = await fixture.session.snapshot()
        let key = "transactions:" + large.id.uuidString
        var corrected = try JSONDecoder().decode(NativeBackupPackage.TransactionPayload.self,
            from: XCTUnwrap(before.livePayloads[key]))
        corrected.note = "Remote corrected synthetic note"
        var wire = before.livePayloads
        wire[key] = try JSONEncoder().encode(corrected)
        var remote = before
        remote.beginWritingSession()
        try remote.captureLocal(wire)
        let record = CKRecord(recordType: PrivateCloudReplicaSession.recordType,
            recordID: .init(recordName: PrivateCloudReplicaSession.recordName(for: key), zoneID: PrivateCloudReplicaSession.zoneID))
        record["envelope"] = try JSONEncoder().encode(PrivateCloudReplicaSession.Envelope(format: 1,
            accountIdentifier: "synthetic", key: key, record: XCTUnwrap(remote.records[key]))) as CKRecordValue
        try await fixture.session.receiveRemoteRecords([record, record], syncEngine: fixture.engine)
        await fixture.controller.synchronize(in: fixture.context, changes: LedgerChangeCenter())
        await fixture.controller.waitForRequestWork()
        let after = await fixture.session.syncEvidence()
        XCTAssertEqual(after.quarantined, 0)
        XCTAssertEqual(after.pendingUploads, 0)
        XCTAssertEqual(after.queuedChanges, 0)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<FinanceTransaction>()), 3)
        let ids = try fixture.context.fetch(FetchDescriptor<FinanceTransaction>()).map(\.id)
        XCTAssertEqual(Set(ids), Set(transactions.map(\.id)))
        await fixture.controller.disable()
    }

    func testColdStartRebuildsIntentFromDurableUnconfirmedChanges() async throws {
        let fixture = try await fixture(transactions: 350, interruptAfterBatch: 1, disk: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalIDs = Set(try fixture.context.fetch(FetchDescriptor<FinanceTransaction>()).map(\.id))
        await fixture.controller.syncNow(in: fixture.context, changes: LedgerChangeCenter())
        let pending = await fixture.session.syncEvidence()
        XCTAssertGreaterThan(pending.pendingUploads, 0)
        await fixture.controller.disable()
        let readContainer = try ModelContainerFactory.make(configuration: ModelConfiguration(schema: AppSchema.schema,
            url: fixture.root.appendingPathComponent("local.store"), cloudKitDatabase: .none))
        let readContext = ModelContext(readContainer)
        let transport = SyntheticSyncTransport()
        let reopened = try PrivateCloudReplicaSession(stateURL: fixture.root.appendingPathComponent("state.json"),
            accountIdentifier: "synthetic", automaticallySync: false, operations: .init(
                fetchChanges: { try await transport.fetch($0) }, cancelOperations: { _ in },
                sendChanges: { try await transport.send($0, options: $1) }))
        await transport.attach(reopened)
        try await reopened.start(verifiedAccountIdentifier: "synthetic")
        let identity = try JSONDecoder().decode(LedgerSyncIdentity.self,
            from: Data(contentsOf: fixture.root.appendingPathComponent("identity.json")))
        let controller = ICloudSyncController(confirmedSession: reopened, identity: identity,
            identityURL: fixture.root.appendingPathComponent("identity.json"))
        controller.setForeground(true)
        await controller.synchronize(in: readContext, changes: LedgerChangeCenter())
        await controller.waitForRequestWork()
        XCTAssertFalse(controller.isSyncRequested)
        XCTAssertEqual(controller.displaySnapshot.stage, .confirmed)
        let resumed = await transport.counters()
        XCTAssertEqual(resumed.saved, pending.pendingUploads)
        let records = try readContext.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(Set(records.map(\.id)), originalIDs)
        XCTAssertEqual(records.reduce(Int64(0)) { $0 + $1.amountMinorUnits }, 61_425)
        await controller.disable()
    }

    func testReadinessWakeBetweenPauseDecisionAndWorkerExitIsNotLost() async throws {
        let fixture = try await fixture(transactions: 350, interruptAfterBatch: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let parked = expectation(description: "decided to park")
        let gate = ContinuationGate()
        var first = true
        fixture.controller.beforeRequestPark = {
            if first { first = false; parked.fulfill(); await gate.wait() }
        }
        let changes = LedgerChangeCenter()
        let request = Task { await fixture.controller.syncNow(in: fixture.context, changes: changes) }
        await fulfillment(of: [parked], timeout: 5)
        try await fixture.session.recordFetchCompletion(succeeded: true, syncEngine: fixture.engine)
        await fixture.controller.synchronize(in: fixture.context, changes: changes)
        await gate.release()
        await request.value
        await fixture.controller.waitForRequestWork()
        XCTAssertFalse(fixture.controller.isSyncRequested)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        await fixture.controller.disable()
    }

    func testTerminalSessionReplacementRebindsRetainedRequestAndRejectsOldCallbacks() async throws {
        let fixture = try await fixture(transactions: 350, interruptAfterBatch: 1, officialLocation: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let accountKey = "icloudSyncConfirmedAccount.Development"
        let savedAccount = UserDefaults.standard.string(forKey: accountKey)
        defer { UserDefaults.standard.set(savedAccount, forKey: accountKey) }
        UserDefaults.standard.set("synthetic", forKey: accountKey)
        let changes = LedgerChangeCenter()
        await fixture.controller.syncNow(in: fixture.context, changes: changes)
        XCTAssertTrue(fixture.controller.isSyncRequested)
        let replacementTransport = SyntheticSyncTransport()
        fixture.controller.activationVerification = {
            .init(environment: .development, account: "synthetic", root: fixture.root, automaticallySync: false,
                operations: .init(fetchChanges: { try await replacementTransport.fetch($0) },
                    cancelOperations: { _ in }, sendChanges: { try await replacementTransport.send($0, options: $1) }))
        }
        fixture.controller.activationSessionStarted = { await replacementTransport.attach($0) }
        await fixture.session.recordOperationResult(errors: [CKError(.permissionFailure)], syncEngine: fixture.engine, phase: .download)
        await fixture.controller.synchronize(in: fixture.context, changes: changes)
        await fixture.controller.waitForRequestWork()
        XCTAssertEqual(fixture.controller.status, .error)
        await fixture.controller.syncNow(in: fixture.context, changes: changes)
        await fixture.controller.waitForRequestWork()
        XCTAssertFalse(fixture.controller.isSyncRequested)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        try await fixture.session.recordFetchCompletion(succeeded: true, syncEngine: fixture.engine)
        await fixture.session.recordOperationResult(errors: [], syncEngine: fixture.engine)
        await fixture.controller.refreshStatus()
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<FinanceTransaction>()), 350)
        await fixture.controller.disable()
    }

    func testReducedBatchPolicyResumesSameRequestAfterSDKSendReturns() async throws {
        let fixture = try await fixture(transactions: 350)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.transport.limitFirstBatch()
        await fixture.controller.syncNow(in: fixture.context, changes: LedgerChangeCenter())
        XCTAssertFalse(fixture.controller.isSyncRequested)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        let counters = await fixture.transport.counters()
        XCTAssertEqual(counters.sends, 2)
        XCTAssertGreaterThan(counters.batches, 10)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<FinanceTransaction>()), 350)
        await fixture.controller.disable()
    }

    func testOffOnWhileOldWorkerIsParkedCannotClearNewRequest() async throws {
        let fixture = try await fixture(transactions: 350, interruptAfterBatch: 1, officialLocation: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let accountKey = "icloudSyncConfirmedAccount.Development"
        let savedAccount = UserDefaults.standard.string(forKey: accountKey)
        defer { UserDefaults.standard.set(savedAccount, forKey: accountKey) }
        UserDefaults.standard.set("synthetic", forKey: accountKey)
        let gate = ContinuationGate()
        let parked = expectation(description: "old worker parked")
        var first = true
        fixture.controller.beforeRequestPark = {
            if first { first = false; parked.fulfill(); await gate.wait() }
        }
        let old = Task { await fixture.controller.syncNow(in: fixture.context, changes: LedgerChangeCenter()) }
        await fulfillment(of: [parked], timeout: 5)
        await fixture.controller.disable()
        let replacement = SyntheticSyncTransport()
        fixture.controller.activationVerification = {
            .init(environment: .development, account: "synthetic", root: fixture.root, automaticallySync: false,
                operations: .init(fetchChanges: { try await replacement.fetch($0) }, cancelOperations: { _ in },
                    sendChanges: { try await replacement.send($0, options: $1) }))
        }
        fixture.controller.activationSessionStarted = { await replacement.attach($0) }
        await fixture.controller.enable()
        await fixture.controller.synchronize(in: fixture.context, changes: LedgerChangeCenter())
        await fixture.controller.waitForRequestWork()
        let completed = fixture.controller.completedRequestAt
        XCTAssertNotNil(completed)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        await gate.release()
        await old.value
        XCTAssertEqual(fixture.controller.completedRequestAt, completed)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        XCTAssertFalse(fixture.controller.isSyncRequested)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<FinanceTransaction>()), 350)
        await fixture.controller.disable()
    }

    func testForegroundWorkerDoesNotInheritDelegateTaskContext() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await SyncCallbackContext.$isDelegate.withValue(true) {
            await fixture.controller.syncNow(in: fixture.context, changes: LedgerChangeCenter())
        }
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        await fixture.controller.disable()
    }

    func testBounded12500SnapshotAndJSONPersistenceMeasurement() async throws {
        let fixture = try await fixture(transactions: 12_500)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let start = Date()
        let package = try await LedgerSnapshotReader(modelContainer: fixture.context.container).capture()
        let captured = Date()
        var identity = LedgerSyncIdentity()
        let wire = try identity.capture(package)
        let encoded = Date()
        try await fixture.session.captureLocal(wire)
        let finished = Date()
        let persistence = await fixture.session.lastPersistenceDuration
        let stateBytes = try fixture.root.appendingPathComponent("state.json").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertEqual(package.transactions.count, 12_500)
        XCTAssertGreaterThan(wire.count, 12_500)
        let disk = try JSONDecoder().decode(PrivateCloudReplicaSession.State.self,
            from: Data(contentsOf: fixture.root.appendingPathComponent("state.json")))
        XCTAssertEqual(disk.replica.records.count, wire.count)
        print("SYNC_PREPARATION entities=\(wire.count) snapshot_s=\(captured.timeIntervalSince(start)) identity_s=\(encoded.timeIntervalSince(captured)) capture_persist_s=\(finished.timeIntervalSince(encoded)) json_persist_s=\(persistence) state_bytes=\(stateBytes)")
        await fixture.controller.disable()
    }

    func testOverlappingReconcileWaitsForTheRunningProjection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let session = try PrivateCloudReplicaSession(stateURL: root.appendingPathComponent("state.json"),
            accountIdentifier: "synthetic", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let value = await session.engine
        let engine = try XCTUnwrap(value)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        let controller = ICloudSyncController(confirmedSession: session, identity: LedgerSyncIdentity(),
            identityURL: root.appendingPathComponent("identity.json"))
        let entered = expectation(description: "first projection captured")
        let joined = expectation(description: "second caller started")
        let gate = ContinuationGate()
        var first = true
        controller.reconcileCheckpoint = { stage in
            if stage == .snapshot, first {
                first = false
                entered.fulfill()
                await gate.wait()
            }
        }
        let changes = LedgerChangeCenter()
        let running = Task { await controller.reconcile(in: context, changes: changes) }
        await fulfillment(of: [entered], timeout: 5)
        var returned = false
        let overlapping = Task {
            joined.fulfill()
            await controller.reconcile(in: context, changes: changes)
            returned = true
        }
        await fulfillment(of: [joined], timeout: 5)
        XCTAssertFalse(returned, "An overlapping await must not return before the running projection has finished")
        await gate.release()
        await running.value
        await overlapping.value
        let evidence = await session.syncEvidence()
        XCTAssertTrue(evidence.authorityReady)
        XCTAssertTrue(evidence.appliedCurrentFetch)
        await session.stop()
    }
}
