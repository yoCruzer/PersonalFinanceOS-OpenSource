import CloudKit
import XCTest
@testable import PersonalFinanceOS

final class PrivateCloudReplicaSessionTests: XCTestCase {
    func testFreshConfirmationRequiresEveryTransportAndApplicationCondition() {
        typealias Evidence = PrivateCloudReplicaSession.SyncEvidence
        func value(blocked: Int?) -> Evidence {
            Evidence(revision: 0, connected: blocked != 0, uploading: blocked == 1, receiving: blocked == 2,
                currentFetchSucceeded: blocked != 3, appliedCurrentFetch: blocked != 4,
                authorityReady: blocked != 5, pendingUploads: blocked == 6 ? 1 : 0,
                pendingApply: blocked == 7, queuedChanges: blocked == 8 ? 1 : 0,
                quarantined: blocked == 9 ? 1 : 0, errorCodes: blocked == 10 ? [4] : [],
                lastUploadAt: nil, lastAppliedAt: nil, lastConfirmedAt: Date(timeIntervalSince1970: 1), zoneReady: blocked != 11)
        }
        XCTAssertTrue(value(blocked: nil).canConfirm)
        for blocker in 0...11 { XCTAssertFalse(value(blocked: blocker).canConfirm, "blocker \(blocker)") }
    }

    func testProductionAcknowledgmentAndFreshAppliedFetchBoundConfirmationToCurrentSession() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("state.json")
        let session = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "synthetic", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let maybeEngine = await session.engine
        let engine = try XCTUnwrap(maybeEngine)
        let initial = await session.syncEvidence()
        XCTAssertFalse(initial.canConfirm)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        let contents = ["transactions:synthetic": Data([1])]
        try await session.captureLocal(contents)
        let application = try await session.acknowledgeCommittedTestProjection(contents)
        let beforeSend = await session.syncEvidence()
        XCTAssertGreaterThan(beforeSend.pendingUploads, 0)
        XCTAssertFalse(beforeSend.canConfirm)
        let batch = await session.recordZoneChangeBatch(scope: .all, syncEngine: engine)
        let records = try XCTUnwrap(batch).recordsToSave
        // Simulated server result, through the same durable production handler.
        try await session.recordSavedRecords(records, syncEngine: engine)
        engine.state.remove(pendingRecordZoneChanges: records.map { .saveRecord($0.recordID) })
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        let ready = await session.syncEvidence()
        XCTAssertTrue(ready.canConfirm)
        let revision = LedgerSaveRevision.shared.contentRevision
        let date = try await session.confirmLocalState(contentRevision: revision, projection: application)
        XCTAssertNotNil(date)
        await session.recordOperationResult(errors: [CKError(.networkUnavailable)], syncEngine: engine)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        try await session.acknowledgeCommittedTestProjection(contents)
        let uploadFailed = await session.syncEvidence()
        XCTAssertFalse(uploadFailed.canConfirm)
        XCTAssertEqual(uploadFailed.errorCodes, [CKError.Code.networkUnavailable.rawValue])
        await session.recordOperationResult(errors: [], syncEngine: engine)
        try await session.captureLocal(["transactions:synthetic": Data([2])])
        let newer = await session.syncEvidence()
        XCTAssertFalse(newer.canConfirm)
        await session.stop()
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        let stopped = await session.syncEvidence()
        XCTAssertFalse(stopped.canConfirm)
        let reopened = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "synthetic", automaticallySync: false)
        try await reopened.start(verifiedAccountIdentifier: "synthetic")
        let historical = await reopened.syncEvidence()
        XCTAssertEqual(historical.lastConfirmedAt, date)
        XCTAssertFalse(historical.currentFetchSucceeded)
        XCTAssertFalse(historical.canConfirm)
        await reopened.stop()
    }

    func testLateReceiptDoesNotClearNewerPendingProjectionOrEndorseANewerFetchRound() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let session = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "A", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "A")
        let current = await session.engine
        let engine = try XCTUnwrap(current)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        let contents = ["transactions:1": Data([1])]
        try await session.captureLocal(contents)
        let graph = await session.reconcileState(pristine: false)
        let first = try await session.prepareProjection(contents, ifCurrent: graph.token)
        // Even a later successful no-change fetch needs its own application evidence.
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        let firstResult = try await session.acknowledgeLocalProjection(contents, ifCurrent: first.token,
            fetchGeneration: graph.fetchGeneration, projectionID: first.id)
        XCTAssertNil(firstResult)
        let fetched = await session.syncEvidence()
        XCTAssertFalse(fetched.appliedCurrentFetch)
        let next = await session.reconcileState(pristine: false)
        let second = try await session.prepareProjection(["transactions:1": Data([2])], ifCurrent: next.token)
        let lateResult = try await session.acknowledgeLocalProjection(contents, ifCurrent: first.token,
            fetchGeneration: graph.fetchGeneration, projectionID: first.id)
        XCTAssertNil(lateResult)
        let evidence = await session.syncEvidence()
        XCTAssertTrue(evidence.pendingApply)
        XCTAssertFalse(evidence.canConfirm)
        await session.stop()
        let reopened = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "A", automaticallySync: false)
        // The newer durable receipt survives the old acknowledgment and disk reopening.
        try await reopened.recoverProjection(committedID: second.id)
        let recovered = await reopened.snapshot()
        XCTAssertEqual(recovered.localBaseline, ["transactions:1": Data([2])])
    }

    func testConflictLoserAndUnchangedServerRecordsKeepCurrentProjectionEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try PrivateCloudReplicaSession(stateURL: directory.appendingPathComponent("state.json"),
            accountIdentifier: "A", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "A")
        let current = await session.engine
        let engine = try XCTUnwrap(current)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        try await session.captureLocal(["transactions:1": Data([1])])
        try await session.acknowledgeCommittedTestProjection(["transactions:1": Data([1])])
        let oldBatch = await session.recordZoneChangeBatch(scope: .all, syncEngine: engine)
        let oldRecord = try XCTUnwrap(oldBatch?.recordsToSave.first)
        try await session.recordSentRecords([oldRecord], failedSaves: [], syncEngine: engine)
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(oldRecord.recordID)])
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        try await session.captureLocal(["transactions:1": Data([2])])
        let evidence = try await session.acknowledgeCommittedTestProjection(["transactions:1": Data([2])])
        let newBatch = await session.recordZoneChangeBatch(scope: .all, syncEngine: engine)
        let newRecord = try XCTUnwrap(newBatch?.recordsToSave.first)
        try await session.recordSentRecords([newRecord], failedSaves: [], syncEngine: engine)
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(newRecord.recordID)])
        for server in [newRecord, oldRecord] {
            await session.recordSendActivity(uploading: true, syncEngine: engine)
            let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
            try await session.recordSentRecords([], failedSaves: [(newRecord, error)], syncEngine: engine)
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(newRecord.recordID)])
            await session.recordSendActivity(uploading: false, syncEngine: engine)
            let stillCurrent = await session.isCurrentProjection(evidence)
            XCTAssertTrue(stillCurrent, "Same or losing server versions do not change the applied graph")
            let before = await session.syncEvidence()
            XCTAssertTrue(before.appliedCurrentFetch)
            if server === oldRecord {
                XCTAssertEqual(before.pendingUploads, 1)
                XCTAssertFalse(before.canConfirm)
                let retry = await session.recordZoneChangeBatch(scope: .all, syncEngine: engine)
                let winner = try XCTUnwrap(retry?.recordsToSave.first)
                try await session.recordSentRecords([winner], failedSaves: [], syncEngine: engine)
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(winner.recordID)])
            }
            let confirmed = try await session.confirmLocalState(contentRevision: LedgerSaveRevision.shared.contentRevision, projection: evidence)
            XCTAssertNotNil(confirmed)
            let replica = await session.snapshot()
            XCTAssertEqual(replica.livePayloads, ["transactions:1": Data([2])])
        }
        await session.stop()
        try await session.start(verifiedAccountIdentifier: "A")
        let staleActivation = await session.isCurrentProjection(evidence)
        XCTAssertFalse(staleActivation)
        let restarted = await session.engine
        let nextEngine = try XCTUnwrap(restarted)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: nextEngine)
        let newEvidence = try await session.acknowledgeCommittedTestProjection(["transactions:1": Data([2])])
        nextEngine.state.remove(pendingDatabaseChanges: nextEngine.state.pendingDatabaseChanges)
        let rejected = try await session.confirmLocalState(contentRevision: LedgerSaveRevision.shared.contentRevision, projection: evidence)
        XCTAssertNil(rejected, "A proof from an old activation cannot confirm a new session")
        let confirmed = try await session.confirmLocalState(contentRevision: LedgerSaveRevision.shared.contentRevision, projection: newEvidence)
        XCTAssertNotNil(confirmed)
        await session.stop()
    }

    func testAuthenticationRetryDoesNotBypassRealAccountChanges() async throws {
        let previous = CKRecord.ID(recordName: "A")
        let other = CKRecord.ID(recordName: "B")
        let changes: [(CKSyncEngine.Event.AccountChange.ChangeType, PrivateCloudReplicaSession.Status)] = [
            (.signOut(previousUser: previous), .accountUnavailable),
            (.switchAccounts(previousUser: previous, currentUser: other), .accountChanged),
            (.signIn(currentUser: other), .accountChanged)
        ]
        for (change, expected) in changes {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = try PrivateCloudReplicaSession(stateURL: directory.appendingPathComponent("state.json"), accountIdentifier: "A", automaticallySync: false)
            try await session.start(verifiedAccountIdentifier: "A")
            let engine = await session.engine
            let current = try XCTUnwrap(engine)
            try await session.recordFetchCompletion(succeeded: true, syncEngine: current)
            try await session.captureLocal(["transactions:1": Data([1])])
            let before = await session.snapshot()
            let pending = current.state.pendingRecordZoneChanges
            await session.recordOperationResult(errors: [CKError(.notAuthenticated)], syncEngine: current)
            await session.recordAccountChange(change, syncEngine: current)
            await session.recordOperationResult(errors: [], syncEngine: current)
            try await session.recordFetchCompletion(succeeded: true, syncEngine: current)
            await session.recordAccountChange(.signIn(currentUser: previous), syncEngine: current)
            let status = await session.status
            let after = await session.snapshot()
            let stoppedEngine = await session.engine
            XCTAssertEqual(status, expected)
            XCTAssertNil(stoppedEngine)
            XCTAssertEqual(before, after)
            XCTAssertEqual(current.state.pendingRecordZoneChanges, pending)
            await session.stop()
        }
    }

    func testRestoredOutboxWaitsForCurrentLocalAuthorityAndDoesNotStarve() async throws {
        for editedWhileOff in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("replica.json")
            let first = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "A", automaticallySync: false)
            try await first.start(verifiedAccountIdentifier: "A")
            let firstEngine = await first.engine
            let oldEngine = try XCTUnwrap(firstEngine)
            try await first.recordFetchCompletion(succeeded: true, syncEngine: oldEngine)
            let original = ["transactions:fixture": Data("100".utf8)]
            try await first.captureLocal(original)
            try await first.acknowledgeCommittedTestProjection(original)
            // Preserve real SDK serialization with its old pending record for crash/relaunch.
            var persisted = try JSONDecoder().decode(PrivateCloudReplicaSession.State.self, from: Data(contentsOf: url))
            for _ in 0..<100 where persisted.engineState == nil {
                try await Task.sleep(for: .milliseconds(10))
                persisted = try JSONDecoder().decode(PrivateCloudReplicaSession.State.self, from: Data(contentsOf: url))
            }
            XCTAssertNotNil(persisted.engineState)
            var restoredConfiguration = PrivateCloudReplicaSession.configuration(
                stateSerialization: try XCTUnwrap(persisted.engineState), delegate: first
            )
            restoredConfiguration.automaticallySync = false
            let restoredOutbox = CKSyncEngine(restoredConfiguration)
            XCTAssertFalse(restoredOutbox.state.pendingRecordZoneChanges.isEmpty,
                           "Serialized SDK state itself must carry the old outbox, before session enqueue")
            await first.stop()
            try JSONEncoder().encode(persisted).write(to: url, options: .atomic)
            let reopened = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "A", automaticallySync: false)
            try await reopened.start(verifiedAccountIdentifier: "A")
            let nextEngine = await reopened.engine
            let current = try XCTUnwrap(nextEngine)
            XCTAssertFalse(current.state.pendingRecordZoneChanges.isEmpty)
            let blocked = await reopened.recordZoneChangeBatch(scope: .all, syncEngine: current)
            XCTAssertNil(blocked)
            let latest = editedWhileOff ? ["transactions:fixture": Data("150".utf8)] : original
            try await reopened.captureLocal(latest)
            let beforeAcknowledgment = await reopened.recordZoneChangeBatch(scope: .all, syncEngine: current)
            XCTAssertNil(beforeAcknowledgment)
            let beforeFreshFetch = await reopened.recordZoneChangeBatch(scope: .all, syncEngine: current)
            XCTAssertNil(beforeFreshFetch, "Historical fetch receipts cannot publish before a fresh remote graph")
            try await reopened.recordFetchCompletion(succeeded: true, syncEngine: current)
            try await reopened.acknowledgeCommittedTestProjection(latest)
            let ready = await reopened.recordZoneChangeBatch(scope: .all, syncEngine: current)
            let record = try XCTUnwrap(ready?.recordsToSave.first)
            let envelope = try JSONDecoder().decode(PrivateCloudReplicaSession.Envelope.self,
                                                   from: XCTUnwrap(record["envelope"] as? Data))
            XCTAssertEqual(envelope.record.payload, latest["transactions:fixture"])
            XCTAssertEqual(envelope.record.revision.counter, editedWhileOff ? 2 : 1)
            await reopened.stop()
            let stopped = await reopened.recordZoneChangeBatch(scope: .all, syncEngine: current)
            XCTAssertNil(stopped)
        }
    }

    func testTransientSendAndFetchOutcomesRecoverWithoutLosingPendingOrRevivingOldEngine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try PrivateCloudReplicaSession(stateURL: directory.appendingPathComponent("state.json"), accountIdentifier: "A", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "A")
        let engine = await session.engine
        let current = try XCTUnwrap(engine)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: current)
        try await session.captureLocal(["transactions:1": Data([1])])
        let pending = current.state.pendingRecordZoneChanges
        for code in [CKError.Code.notAuthenticated, .networkUnavailable, .networkFailure, .requestRateLimited, .serviceUnavailable, .zoneBusy, .accountTemporarilyUnavailable, .operationCancelled] {
            await session.recordOperationResult(errors: [CKError(code)], syncEngine: current)
            let retrying = await session.status
            XCTAssertEqual(retrying, .retrying)
            await session.recordOperationResult(errors: [], syncEngine: current)
            let sent = await session.status
            XCTAssertEqual(sent, .active)
            await session.recordOperationResult(errors: [CKError(code)], syncEngine: current)
            try await session.recordFetchCompletion(succeeded: true, syncEngine: current)
            let fetched = await session.status
            XCTAssertEqual(fetched, .retrying, "Download success must not clear a pending upload failure")
            XCTAssertEqual(current.state.pendingRecordZoneChanges, pending)
        }
        await session.recordOperationResult(errors: [CKError(.permissionFailure)], syncEngine: current)
        await session.recordOperationResult(errors: [], syncEngine: current)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: current)
        let permanent = await session.status
        XCTAssertEqual(permanent, .needsAttention)
        await session.stop()
        await session.recordOperationResult(errors: [], syncEngine: current)
        let stopped = await session.status
        XCTAssertEqual(stopped, .stopped)
        try await session.start(verifiedAccountIdentifier: "A")
        let replacement = await session.engine
        let next = try XCTUnwrap(replacement)
        await session.recordOperationResult(errors: [CKError(.networkUnavailable)], syncEngine: next)
        await session.recordOperationResult(errors: [], syncEngine: current)
        let stillRetrying = await session.status
        XCTAssertEqual(stillRetrying, .retrying)
        await session.stop()
    }

    func testSizeAwareBatchesQuarantineOversizedAndRetainPendingAfterLimitExceeded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try PrivateCloudReplicaSession(stateURL: directory.appendingPathComponent("state.json"), accountIdentifier: "A", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "A")
        let engine = await session.engine
        let current = try XCTUnwrap(engine)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: current)
        var snapshot = Dictionary(uniqueKeysWithValues: (0..<8).map { ("transactions:\($0)", Data(repeating: 65, count: 200_000)) })
        snapshot["transactions:oversized"] = Data(repeating: 66, count: 800_000)
        try await session.captureLocal(snapshot)
        try await session.acknowledgeCommittedTestProjection(snapshot)
        let pending = current.state.pendingRecordZoneChanges
        let first = await session.recordZoneChangeBatch(scope: .all, syncEngine: current)
        let batch = try XCTUnwrap(first)
        XCTAssertGreaterThan(batch.recordsToSave.count, 1)
        XCTAssertLessThan(batch.recordsToSave.count, 8)
        XCTAssertLessThan(batch.recordsToSave.reduce(0) { $0 + (($1["envelope"] as? Data)?.count ?? 0) }, PrivateCloudReplicaSession.maximumBatchBytes)
        for record in batch.recordsToSave { try await session.handleLimitExceeded(record: record, syncEngine: current) }
        XCTAssertEqual(current.state.pendingRecordZoneChanges, pending)
        let split = await session.recordZoneChangeBatch(scope: .all, syncEngine: current)
        XCTAssertLessThanOrEqual(try XCTUnwrap(split).recordsToSave.count, batch.recordsToSave.count / 2)
        var delivered: Set<String> = []
        while let next = await session.recordZoneChangeBatch(scope: .all, syncEngine: current) {
            for record in next.recordsToSave { delivered.insert(record.recordID.recordName) }
            current.state.remove(pendingRecordZoneChanges: next.recordsToSave.map { .saveRecord($0.recordID) })
        }
        XCTAssertEqual(delivered.count, 8)
        let diagnostics = await session.oversizedRecords()
        XCTAssertGreaterThan(try XCTUnwrap(diagnostics["transactions:oversized"]).encodedBytes, PrivateCloudReplicaSession.maximumEnvelopeBytes)
        XCTAssertEqual(current.state.pendingRecordZoneChanges.count, 1)
        let intact = await session.snapshot()
        XCTAssertEqual(intact.livePayloads, snapshot)
        snapshot["transactions:oversized"] = Data([1])
        try await session.captureLocal(snapshot)
        try await session.acknowledgeCommittedTestProjection(snapshot)
        let repaired = await session.recordZoneChangeBatch(scope: .all, syncEngine: current)
        XCTAssertNotNil(repaired)
        await session.stop()
    }

    func testSmallRecordsKeepNormalBatchCapacityAndSingleServerLimitIsIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let session = try await fetchedSession(url: url, account: "A")
        try await session.start(verifiedAccountIdentifier: "A")
        let engine = await session.engine
        let current = try XCTUnwrap(engine)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: current)
        let snapshot = Dictionary(uniqueKeysWithValues: (0..<120).map { ("transactions:\($0)", Data([1])) })
        try await session.captureLocal(snapshot)
        try await session.acknowledgeCommittedTestProjection(snapshot)
        let originalPending = current.state.pendingRecordZoneChanges
        var next = await session.recordZoneChangeBatch(scope: .all, syncEngine: current)
        XCTAssertEqual(next?.recordsToSave.count, 100)
        while let batch = next, batch.recordsToSave.count > 1 {
            try await session.handleLimitExceeded(record: XCTUnwrap(batch.recordsToSave.first), syncEngine: current)
            next = await session.recordZoneChangeBatch(scope: .all, syncEngine: current)
        }
        let isolated = try XCTUnwrap(next?.recordsToSave.first)
        try await session.handleLimitExceeded(record: isolated, syncEngine: current)
        let continuing = await session.recordZoneChangeBatch(scope: .all, syncEngine: current)
        XCTAssertNotEqual(continuing?.recordsToSave.first?.recordID, isolated.recordID)
        XCTAssertEqual(current.state.pendingRecordZoneChanges, originalPending)
        let diagnostics = await session.oversizedRecords()
        XCTAssertEqual(diagnostics.count, 1)
        await session.stop()
        let reopened = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "A", automaticallySync: false)
        let retained = await reopened.oversizedRecords()
        XCTAssertEqual(retained, diagnostics)
        let replica = await reopened.snapshot()
        XCTAssertEqual(replica.livePayloads, snapshot)
    }

    private func fetchedSession(url: URL, account: String) async throws -> PrivateCloudReplicaSession {
        let session = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: account, automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: account)
        let engine = await session.engine
        try await session.recordFetchCompletion(succeeded: true, syncEngine: XCTUnwrap(engine))
        await session.stop()
        return session
    }

    func testFreshSessionRefusesRevisionBeforeFetchEvenForDirectCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try PrivateCloudReplicaSession(stateURL: directory.appendingPathComponent("state.json"), accountIdentifier: "A", automaticallySync: false)
        do {
            try await session.captureLocal(["transactions:1": Data([1])])
            XCTFail("Fresh transport must fetch before creating any local revision")
        } catch { XCTAssertEqual(error as? ProtectedLedgerReplica.Failure, .initialFetchRequired) }
        let unchanged = await session.snapshot()
        XCTAssertEqual(unchanged.clock, 0)
    }

    func testStoppedAndReplacedEngineCannotCompleteFetchOrFetchRecordZones() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try PrivateCloudReplicaSession(
            stateURL: directory.appendingPathComponent("replica.json"),
            accountIdentifier: "account", automaticallySync: false
        )
        try await session.start(verifiedAccountIdentifier: "account")
        let firstEngine = await session.engine
        let old = try XCTUnwrap(firstEngine)
        let original = CKSyncEngine.FetchChangesOptions(scope: .all)
        let activeOptions = await session.fetchOptions(original, syncEngine: old)
        XCTAssertEqual(activeOptions.scope, .zoneIDs([PrivateCloudReplicaSession.zoneID]))
        await session.stop()
        let before = await session.snapshot()
        try await session.recordFetchCompletion(succeeded: true, syncEngine: old)
        let stoppedOptions = await session.fetchOptions(original, syncEngine: old)
        let stoppedStatus = await session.status
        let stoppedFetch = await session.hasCompletedFetch
        XCTAssertEqual(stoppedOptions.scope, .zoneIDs([]))
        XCTAssertTrue(stoppedOptions.prioritizedZoneIDs.isEmpty)
        XCTAssertEqual(stoppedStatus, .stopped)
        XCTAssertFalse(stoppedFetch)

        let otherAccount = try PrivateCloudReplicaSession(
            stateURL: directory.appendingPathComponent("B/replica.json"),
            accountIdentifier: "B", automaticallySync: false
        )
        try await otherAccount.start(verifiedAccountIdentifier: "B")
        try await otherAccount.recordFetchCompletion(succeeded: true, syncEngine: old)
        let otherOptions = await otherAccount.fetchOptions(original, syncEngine: old)
        let otherMode = await otherAccount.initialProjection(pristine: true)
        XCTAssertEqual(otherOptions.scope, .zoneIDs([]))
        XCTAssertEqual(otherMode, .waitingForFetch)
        await otherAccount.stop()

        try await session.start(verifiedAccountIdentifier: "account")
        let nextEngine = await session.engine
        let current = try XCTUnwrap(nextEngine)
        XCTAssertFalse(current === old)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: old)
        let lateOptions = await session.fetchOptions(original, syncEngine: old)
        let stillWaiting = await session.initialProjection(pristine: true)
        let after = await session.snapshot()
        XCTAssertEqual(lateOptions.scope, .zoneIDs([]))
        XCTAssertEqual(stillWaiting, .waitingForFetch)
        XCTAssertEqual(after, before)
        try await session.recordFetchCompletion(succeeded: false, syncEngine: current)
        let failedFetch = await session.initialProjection(pristine: true)
        XCTAssertEqual(failedFetch, .waitingForFetch)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: current)
        let ready = await session.initialProjection(pristine: true)
        XCTAssertEqual(ready, .adoptBootstrap)
        await session.stop()
    }

    func testSuccessfulInitialFetchSurvivesCrashBeforeProjectionButNotOtherReplica() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("A/replica.json")
        let session = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "A", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "A")
        let engine = await session.engine
        try await session.recordFetchCompletion(succeeded: true, syncEngine: try XCTUnwrap(engine))
        await session.stop()
        let reopened = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "A")
        let mode = await reopened.initialProjection(pristine: true)
        XCTAssertEqual(mode, .adoptBootstrap)
        let other = try PrivateCloudReplicaSession(stateURL: directory.appendingPathComponent("B/replica.json"), accountIdentifier: "B")
        let otherMode = await other.initialProjection(pristine: true)
        XCTAssertEqual(otherMode, .waitingForFetch)
    }

    func testInitialProjectionCompletionSurvivesSameAccountRestartAndLegacyState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replica.json")
        let first = try await fetchedSession(url: url, account: "A")
        // Completion is distinct from a nonempty baseline, even for an empty projection.
        try await first.acknowledgeCommittedTestProjection([:])
        let reopened = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "A")
        let completed = await reopened.initialProjection(pristine: true)
        XCTAssertEqual(completed, .established)

        // Old candidate files have no new key. Only their own baseline is used as evidence.
        var legacyReplica = ProtectedLedgerReplica(accountIdentifier: "A")
        try legacyReplica.captureLocal(["accounts:fixture": Data([1])])
        let legacy = PrivateCloudReplicaSession.State(replica: legacyReplica)
        try JSONEncoder().encode(legacy).write(to: url, options: .atomic)
        let oldReopened = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "A")
        let oldCompleted = await oldReopened.initialProjection(pristine: true)
        XCTAssertEqual(oldCompleted, .established)
    }

    func testCloudEnvironmentsAndAccountsSeparateTransportButShareLedgerIdentity() {
        let root = URL(fileURLWithPath: "/tmp/ledger-environment-test")
        let development = CloudReplicaLocation(root: root, environment: .development, account: "A")
        let production = CloudReplicaLocation(root: root, environment: .production, account: "A")
        let otherAccount = CloudReplicaLocation(root: root, environment: .development, account: "B")
        XCTAssertNotEqual(development.stateURL, production.stateURL)
        XCTAssertNotEqual(development.stateURL, otherAccount.stateURL)
        XCTAssertEqual(development.identityURL, production.identityURL)
        XCTAssertEqual(development.identityURL, otherAccount.identityURL)
        XCTAssertNil(CloudReplicaLocation.Environment(rawValue: "unknown"))
    }

    func testOfflineReplicaReopensWithPendingLocalChangesAndRejectsDifferentAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replica.json")
        let first = try await fetchedSession(url: url, account: "account-A")
        let initialStatus = await first.status
        XCTAssertEqual(initialStatus, .stopped)
        try await first.captureLocal(["transactions:1": Data([1, 2, 3])])
        await first.stop()
        let reopened = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "account-A")
        let snapshot = await reopened.snapshot()
        XCTAssertEqual(snapshot.livePayloads["transactions:1"], Data([1, 2, 3]))
        let original = await first.snapshot()
        XCTAssertNotEqual(snapshot.author, original.author)
        XCTAssertEqual(snapshot.records, original.records)
        XCTAssertThrowsError(try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "account-B"))
        let intact = await reopened.snapshot()
        XCTAssertEqual(intact.records, original.records)
        try Data("incomplete".utf8).write(to: url)
        XCTAssertThrowsError(try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "account-A"))
    }

    func testCloudRecordNamesAreStableAndDoNotExposeLedgerKeys() {
        let key = "transactions:12345678-1234-1234-1234-123456789012"
        let name = PrivateCloudReplicaSession.recordName(for: key)
        XCTAssertEqual(name.count, 64)
        XCTAssertEqual(name, PrivateCloudReplicaSession.recordName(for: key))
        XCTAssertNotEqual(name, PrivateCloudReplicaSession.recordName(for: key + "2"))
        XCTAssertFalse(name.contains("transactions"))
    }

    func testEnabledTransportConfigurationUsesPrivateDatabase() throws {
        let session = try PrivateCloudReplicaSession(
            stateURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            accountIdentifier: "configuration-test"
        )
        let configuration = PrivateCloudReplicaSession.configuration(stateSerialization: nil, delegate: session)
        XCTAssertEqual(configuration.database.databaseScope, .private)
        XCTAssertTrue(configuration.automaticallySync)
        XCTAssertNil(configuration.stateSerialization)
        XCTAssertEqual(ModelContainerFactory.cloudContainerIdentifier, "iCloud.org.example.PersonalFinanceOS")
    }

    func testCrashAfterLedgerCommitDoesNotTurnImportedValuesIntoLocalEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replica.json")
        let first = try await fetchedSession(url: url, account: "account")
        try await first.captureLocal(["transaction:1": Data([1])])
        let target = ["transaction:1": Data([2])]
        let receipt = try await first.prepareProjection(target)
        // Simulate committing the SwiftData receipt, then crashing before acknowledgment.
        let reopened = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "account")
        try await reopened.recoverProjection(committedID: receipt)
        let recovered = await reopened.snapshot()
        try await reopened.captureLocal(target)
        let unchanged = await reopened.snapshot()
        XCTAssertEqual(unchanged.clock, recovered.clock)
        XCTAssertEqual(unchanged.records, recovered.records)
        XCTAssertEqual(unchanged.localBaseline, target)
        // A user edit made after that committed projection remains a new local revision.
        try await reopened.captureLocal(["transaction:1": Data([3])])
        let edited = await reopened.snapshot()
        XCTAssertEqual(edited.clock, recovered.clock + 1)
        XCTAssertEqual(edited.livePayloads["transaction:1"], Data([3]))
    }

    func testCrashBeforeLedgerCommitKeepsPreviousBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replica.json")
        let first = try await fetchedSession(url: url, account: "account")
        let original = ["transaction:1": Data([1])]
        try await first.captureLocal(original)
        _ = try await first.prepareProjection(["transaction:1": Data([2])])
        let reopened = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "account")
        try await reopened.recoverProjection(committedID: nil)
        try await reopened.captureLocal(original)
        let recovered = await reopened.snapshot()
        XCTAssertEqual(recovered.localBaseline, original)
        XCTAssertEqual(recovered.clock, 1)
    }
}

private extension PrivateCloudReplicaSession {
    /// These transport-only fixtures have already committed the supplied local projection.
    @discardableResult
    func acknowledgeCommittedTestProjection(_ snapshot: [String: Data]) throws -> ProjectionEvidence {
        let graph = reconcileState(pristine: false)
        return try XCTUnwrap(acknowledgeLocalProjection(snapshot, ifCurrent: graph.token,
            fetchGeneration: graph.fetchGeneration, projectionID: nil))
    }
}
