import CloudKit
import SwiftData
import XCTest
@testable import PersonalFinanceOS

private enum DelegateContext {
    @TaskLocal static var isInCallback = false
}

private actor OperationGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private actor OperationSequence {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

final class CloudKitDelegateSchedulingTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
    }

    func testControlUnstructuredTaskInheritsDelegateContext() async {
        let inherited = await DelegateContext.$isInCallback.withValue(true) {
            await Task { DelegateContext.isInCallback }.value
        }
        XCTAssertTrue(inherited, "A plain Task is a positive control for the original bug")
        XCTAssertFalse(DelegateContext.isInCallback)
    }

    func testFirstZoneCreationDetachesAndCoalescesFetchWithoutEndorsingData() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let entered = expectation(description: "follow-up fetch")
        entered.assertForOverFulfill = true
        let gate = OperationGate()
        let session = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "synthetic", operations: .init(
            fetchChanges: { _ in
                XCTAssertFalse(DelegateContext.isInCallback)
                entered.fulfill()
                await gate.wait()
            }, cancelOperations: { _ in XCTAssertFalse(DelegateContext.isInCallback) }))
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let value = await session.engine
        let engine = try XCTUnwrap(value)
        await DelegateContext.$isInCallback.withValue(true) {
            await session.recordDatabaseSendResult(savedZoneIDs: [PrivateCloudReplicaSession.zoneID], errors: [], syncEngine: engine)
            await session.recordDatabaseSendResult(savedZoneIDs: [PrivateCloudReplicaSession.zoneID], errors: [], syncEngine: engine)
        }
        await fulfillment(of: [entered], timeout: 3)
        let task = await session.initializationFetch
        XCTAssertNotNil(task)
        let before = await session.syncEvidence()
        XCTAssertTrue(before.zoneReady)
        XCTAssertFalse(before.currentFetchSucceeded)
        XCTAssertFalse(before.canConfirm)
        let batch = await session.recordZoneChangeBatch(scope: .all, syncEngine: engine)
        XCTAssertNil(batch)
        // Replay ordered SDK outcomes; only a durable completed fetch opens projection.
        await session.recordFetchStarted(syncEngine: engine)
        await session.recordZoneFetchResult(error: nil, syncEngine: engine)
        try await session.finishFetchRound(syncEngine: engine)
        await gate.release()
        await task?.value
        let cleared = await session.initializationFetch
        XCTAssertNil(cleared)
        let data = ["transactions:synthetic": Data([1, 2, 3])]
        try await session.captureLocal(data)
        let snapshot = await session.snapshot()
        await session.stop()
        let reopened = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "synthetic", automaticallySync: false)
        let persisted = await reopened.snapshot()
        XCTAssertEqual(persisted.records, snapshot.records)
        try await reopened.start(verifiedAccountIdentifier: "synthetic")
        let fresh = await reopened.syncEvidence()
        XCTAssertFalse(fresh.currentFetchSucceeded)
        XCTAssertFalse(fresh.canConfirm)
        await reopened.stop()
    }

    func testInitializationCloudErrorsPreserveReplicaAndUseDetachedCancellation() async throws {
        for code in [CKError.Code.networkUnavailable, .operationCancelled, .permissionFailure] {
            let url = location()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let gate = OperationGate()
            let entered = expectation(description: "fetch \(code)")
            let session = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "synthetic", operations: .init(
                fetchChanges: { _ in
                    XCTAssertFalse(DelegateContext.isInCallback)
                    entered.fulfill()
                    await gate.wait()
                    throw CKError(code)
                }, cancelOperations: { _ in XCTAssertFalse(DelegateContext.isInCallback) }))
            try await session.start(verifiedAccountIdentifier: "synthetic")
            let value = await session.engine
            let engine = try XCTUnwrap(value)
            try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
            try await session.captureLocal(["transactions:retained": Data([42])])
            let before = await session.snapshot()
            await session.recordFetchStarted(syncEngine: engine)
            await DelegateContext.$isInCallback.withValue(true) {
                await session.recordDatabaseSendResult(savedZoneIDs: [PrivateCloudReplicaSession.zoneID], errors: [], syncEngine: engine)
            }
            await fulfillment(of: [entered], timeout: 3)
            let task = await session.initializationFetch
            await gate.release()
            await task?.value
            let evidence = await session.syncEvidence()
            XCTAssertEqual(evidence.errorCodes, [code.rawValue])
            XCTAssertFalse(evidence.canConfirm)
            let status = await session.status
            XCTAssertEqual(status, code == .permissionFailure ? .needsAttention : .retrying)
            await session.stop()
            let reopened = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "synthetic", automaticallySync: false)
            let after = await reopened.snapshot()
            XCTAssertEqual(after.records, before.records)
            XCTAssertEqual(after.localBaseline, before.localBaseline)
        }
    }

    func testAccountCallbackCancellationIsDetachedAndRestartWaitsForDrain() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let entered = expectation(description: "cancel")
        let gate = OperationGate()
        let cancellations = OperationSequence()
        let session = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "synthetic", operations: .init(
            fetchChanges: { _ in XCTFail("No fetch expected") },
            cancelOperations: { _ in
                XCTAssertFalse(DelegateContext.isInCallback)
                if await cancellations.next() == 1 { entered.fulfill() }
                await gate.wait()
            }))
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let value = await session.engine
        let old = try XCTUnwrap(value)
        await DelegateContext.$isInCallback.withValue(true) {
            await session.recordAccountChange(.signOut(previousUser: .init(recordName: "synthetic")), syncEngine: old)
        }
        await fulfillment(of: [entered], timeout: 3)
        do {
            try await session.start(verifiedAccountIdentifier: "synthetic")
            XCTFail("Restart must not overtake cancellation")
        } catch { }
        let off = Task { await session.stop() }
        let anotherOff = Task { await session.stop() }
        await gate.release()
        await off.value
        await anotherOff.value
        let drainedCount = await cancellations.count
        XCTAssertEqual(drainedCount, 1)
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let restarted = await session.engine
        XCTAssertFalse(restarted === old)
        // A late terminal event cannot cancel the replacement.
        await session.recordAccountChange(.signOut(previousUser: .init(recordName: "synthetic")), syncEngine: old)
        let current = await session.engine
        XCTAssertTrue(current === restarted)
        await session.stop()
    }

    func testOffOnIgnoresLateFetchFailureAndOldTaskCannotClearNewTask() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let oldGate = OperationGate()
        let newGate = OperationGate()
        let sequence = OperationSequence()
        let oldEntered = expectation(description: "old fetch entered")
        let newEntered = expectation(description: "new fetch entered")
        let session = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "synthetic", operations: .init(
            fetchChanges: { _ in
                XCTAssertFalse(DelegateContext.isInCallback)
                if await sequence.next() == 1 {
                    oldEntered.fulfill()
                    await oldGate.wait()
                } else {
                    newEntered.fulfill()
                    await newGate.wait()
                }
                throw CKError(.permissionFailure)
            }, cancelOperations: { _ in XCTAssertFalse(DelegateContext.isInCallback) }))
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let value = await session.engine
        let old = try XCTUnwrap(value)
        await DelegateContext.$isInCallback.withValue(true) {
            await session.recordDatabaseSendResult(savedZoneIDs: [PrivateCloudReplicaSession.zoneID], errors: [], syncEngine: old)
        }
        await fulfillment(of: [oldEntered], timeout: 3)
        let oldTask = await session.initializationFetch
        await session.stop()
        XCTAssertTrue(oldTask?.isCancelled == true)
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let newValue = await session.engine
        let current = try XCTUnwrap(newValue)
        await session.recordDatabaseSendResult(savedZoneIDs: [PrivateCloudReplicaSession.zoneID], errors: [], syncEngine: old)
        let staleScheduled = await session.initializationFetch
        XCTAssertNil(staleScheduled)
        await session.recordDatabaseSendResult(savedZoneIDs: [PrivateCloudReplicaSession.zoneID], errors: [], syncEngine: current)
        let newTask = await session.initializationFetch
        XCTAssertNotNil(newTask)
        await fulfillment(of: [newEntered], timeout: 3)
        await oldGate.release()
        await oldTask?.value
        let retainedTask = await session.initializationFetch
        let retainedEngine = await session.engine
        let afterOldFailure = await session.syncEvidence()
        XCTAssertNotNil(retainedTask, "Old task cleanup must not clear a new activation's task")
        XCTAssertTrue(retainedEngine === current)
        XCTAssertTrue(afterOldFailure.failures.isEmpty)
        // Stop also cancels the replacement task; its late error cannot revive it.
        await session.stop()
        await newGate.release()
        await newTask?.value
        let final = await session.syncEvidence()
        let status = await session.status
        XCTAssertEqual(status, .stopped)
        XCTAssertTrue(final.failures.isEmpty)
        XCTAssertFalse(final.connected)
    }

    func testCallbackCloudAndPersistenceFailuresDetachCancellationAndRetainDurableState() async throws {
        for persistenceFailure in [false, true] {
            let url = location()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let cancelled = expectation(description: "callback cancellation")
            let session = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "synthetic", operations: .init(
                fetchChanges: { _ in XCTFail("No fetch expected") }, cancelOperations: { _ in
                    XCTAssertFalse(DelegateContext.isInCallback)
                    cancelled.fulfill()
                }))
            try await session.start(verifiedAccountIdentifier: "synthetic")
            let value = await session.engine
            let engine = try XCTUnwrap(value)
            try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
            try await session.captureLocal(["transactions:retained": Data([7])])
            let (before, bytes) = try await DelegateContext.$isInCallback.withValue(true) {
                try await session.injectSyntheticCallbackFailure(at: url, persistenceFailure: persistenceFailure)
            }
            await fulfillment(of: [cancelled], timeout: 3)
            let status = await session.status
            let after = await session.snapshot()
            XCTAssertEqual(status, .needsAttention)
            XCTAssertEqual(after, before)
            await session.stop()
            if persistenceFailure {
                try FileManager.default.removeItem(at: url)
                try bytes.write(to: url, options: .atomic)
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            let reopened = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "synthetic", automaticallySync: false)
            let restored = await reopened.snapshot()
            XCTAssertEqual(restored.records, before.records)
        }
    }

    @MainActor
    func testCloudFailureLeavesLocalLedgerWritableAndDurableAcrossReopen() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "synthetic", operations: .init(
            fetchChanges: { _ in XCTFail("No fetch expected") },
            cancelOperations: { _ in XCTAssertFalse(DelegateContext.isInCallback) }))
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let value = await session.engine
        let engine = try XCTUnwrap(value)
        let store = url.deletingLastPathComponent().appendingPathComponent("local.store")
        let configuration = ModelConfiguration(schema: AppSchema.schema, url: store, cloudKitDatabase: .none)
        var container: ModelContainer? = try ModelContainerFactory.make(configuration: configuration)
        var context: ModelContext? = ModelContext(container!)
        let account = Account(name: "Synthetic cash", type: .cash)
        let category = Category(kind: .expense, name: "Synthetic food", symbolName: "fork.knife", colorToken: "orange")
        context!.insert(account)
        context!.insert(category)
        let accountID = account.id
        let categoryID = category.id
        func transaction(_ amount: Int64) -> FinanceTransaction {
            FinanceTransaction(type: .expense, amountMinorUnits: amount,
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000), localDayKey: "2023-11-14",
                timeZoneIdentifier: "UTC", accountID: accountID, categoryID: categoryID)
        }
        context!.insert(transaction(1234))
        try context!.save()
        await DelegateContext.$isInCallback.withValue(true) {
            await session.recordOperationResult(errors: [CKError(.permissionFailure)], syncEngine: engine, phase: .download)
        }
        context!.insert(transaction(5678))
        try context!.save()
        await session.stop()
        context = nil
        container = nil
        let reopened = try ModelContainerFactory.make(configuration: configuration)
        let read = ModelContext(reopened)
        let transactions = try read.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(transactions.map(\.amountMinorUnits).sorted(), [1234, 5678])
        XCTAssertTrue(transactions.allSatisfy { $0.accountID == accountID && $0.categoryID == categoryID })
    }

    func testExplicitStopFromInheritedContextAlsoDetachesCancellation() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let entered = expectation(description: "stop cancel")
        let gate = OperationGate()
        let session = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "synthetic", operations: .init(
            fetchChanges: { _ in XCTFail("No fetch expected") }, cancelOperations: { _ in
                XCTAssertFalse(DelegateContext.isInCallback)
                entered.fulfill()
                await gate.wait()
            }))
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let stop = Task {
            await DelegateContext.$isInCallback.withValue(true) { await session.stop() }
        }
        await fulfillment(of: [entered], timeout: 3)
        do {
            try await session.start(verifiedAccountIdentifier: "synthetic")
            XCTFail("Explicit stop must establish the same restart barrier")
        } catch { }
        await gate.release()
        await stop.value
    }
}

private extension PrivateCloudReplicaSession {
    /// Keep file fault injection and callback handling in one actor turn: queued SDK
    /// state updates cannot interleave with this UUID-scoped synthetic fixture change.
    func injectSyntheticCallbackFailure(at url: URL, persistenceFailure: Bool) throws -> (ProtectedLedgerReplica, Data) {
        let current = try XCTUnwrap(engine)
        let before = snapshot()
        let bytes = try Data(contentsOf: url)
        if persistenceFailure {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        recordOperationResult(errors: [CKError(persistenceFailure ? .zoneNotFound : .permissionFailure)],
            syncEngine: current, phase: .download)
        return (before, bytes)
    }
}
