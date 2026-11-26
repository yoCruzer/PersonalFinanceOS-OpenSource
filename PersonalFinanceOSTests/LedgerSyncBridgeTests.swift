import CloudKit
import SwiftData
import XCTest
@testable import PersonalFinanceOS

private final class ProjectionWriteGate: @unchecked Sendable {
    let start = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    func waitForStart() -> Bool { start.wait(timeout: .now() + 10) == .success }
    func commit() throws {
        start.signal()
        guard finished.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
    }
}

@MainActor
final class LedgerSyncBridgeTests: XCTestCase {
    func testBackgroundBusinessSaveAfterNoChangeProjectionCheckCannotBeConfirmed() async throws {
        try await assertBackgroundSaveCannotConfirm(appliesRemote: false, afterStamp: false)
    }

    func testBackgroundBusinessSaveAfterActualProjectionCheckCannotBeConfirmed() async throws {
        try await assertBackgroundSaveCannotConfirm(appliesRemote: true, afterStamp: false)
    }

    func testBackgroundBusinessSaveAfterBoundProjectionStampCannotBeConfirmed() async throws {
        try await assertBackgroundSaveCannotConfirm(appliesRemote: false, afterStamp: true)
    }

    private func assertBackgroundSaveCannotConfirm(appliesRemote: Bool, afterStamp: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = try makeContext()
        let tag = Tag(name: "Background deletion")
        local.insert(tag)
        try local.save()
        let (session, controller, engine, mapping) = try await confirmedBridge(local: local, directory: directory)
        let previous = await session.syncEvidence().lastConfirmedAt
        XCTAssertNotNil(previous)
        let beforeReceipt = try LedgerSnapshotCodec.committedProjectionID(in: local)
        if appliesRemote {
            let remote = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
            try LedgerSnapshotCodec.apply(LedgerSnapshotCodec.capture(in: local), in: remote)
            let account = try XCTUnwrap(remote.fetch(FetchDescriptor<Account>()).first)
            account.name = "Remote applied"
            try remote.save()
            var identity = mapping
            var cloud = await session.snapshot()
            cloud.beginWritingSession()
            try cloud.captureLocal(identity.capture(LedgerSnapshotCodec.capture(in: remote)))
            try await session.receiveRemoteRecords(bridgeRecords(cloud), syncEngine: engine)
            try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        }
        let gate = ProjectionWriteGate()
        let writer = MetadataMutationActor(modelContainer: local.container)
        let id = tag.id
        let writing = Task.detached {
            guard gate.waitForStart() else { throw CocoaError(.userCancelled) }
            defer { gate.finished.signal() }
            return try await writer.deleteTag(id: id, resolution: nil)
        }
        var injected = false
        var completions = 0
        let captured = expectation(description: "Later reconcile captured the background deletion")
        if !afterStamp {
            // Outside both production locks. Never block a writer while holding its boundary.
            controller.afterCheckedProjection = {
                guard !injected else { return }
                injected = true
                try gate.commit()
            }
        }
        controller.reconcileCheckpoint = { stage in
            if stage == .beforeAcknowledgment, afterStamp, !injected {
                injected = true
                try gate.commit()
            }
            if stage == .completed {
                completions += 1
                let evidence = await session.syncEvidence()
                XCTAssertEqual(evidence.lastConfirmedAt, previous, "Uncaptured business save must not advance confirmation")
                await controller.refreshStatus()
                XCTAssertNotEqual(controller.displaySnapshot.stage, .confirmed)
                if completions == 1 {
                    let replica = await session.snapshot()
                    XCTAssertTrue(replica.localBaseline.keys.contains { $0.hasPrefix("tags:") },
                        "The new business deletion has not been captured by this projection")
                } else {
                    let replica = await session.snapshot()
                    XCTAssertFalse(replica.localBaseline.keys.contains { $0.hasPrefix("tags:") })
                    XCTAssertGreaterThan(evidence.pendingUploads, 0)
                    captured.fulfill()
                }
            }
        }
        await controller.reconcile(in: local, changes: LedgerChangeCenter())
        _ = try await writing.value
        XCTAssertTrue(injected)
        let fresh = ModelContext(local.container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Tag>()), 0)
        if appliesRemote {
            XCTAssertEqual(try fresh.fetch(FetchDescriptor<Account>()).first?.name, "Remote applied")
            XCTAssertNotEqual(try LedgerSnapshotCodec.committedProjectionID(in: fresh), beforeReceipt)
        } else {
            XCTAssertEqual(try LedgerSnapshotCodec.committedProjectionID(in: fresh), beforeReceipt, "Exercise the no-change projection path")
        }
        await fulfillment(of: [captured], timeout: 10)
        controller.afterCheckedProjection = nil
        controller.reconcileCheckpoint = nil
        try await acknowledgeBridgeUploads(session, engine: engine)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        await controller.reconcile(in: fresh, changes: LedgerChangeCenter())
        await controller.refreshStatus()
        XCTAssertEqual(controller.displaySnapshot.stage, .confirmed)
        let final = await session.syncEvidence()
        XCTAssertNotNil(final.lastConfirmedAt)
        XCTAssertNotEqual(final.lastConfirmedAt, previous)
        await session.stop()
    }

    func testWinningUploadConflictAfterAcknowledgmentCannotConfirmBeforeProjection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = try makeContext()
        let (session, controller, engine, mapping) = try await confirmedBridge(local: local, directory: directory)
        let previous = await session.syncEvidence().lastConfirmedAt
        let account = try XCTUnwrap(local.fetch(FetchDescriptor<Account>()).first)
        try FinanceDataManagementService.rename(account: account, to: "Local A", in: local)
        // Prepare the synthetic remote before capturing the controller's business stamp.
        // A real server callback does not save another SwiftData store on this process.
        let localA = try LedgerSnapshotCodec.capture(in: local)
        let remote = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try LedgerSnapshotCodec.apply(localA, in: remote)
        let other = try XCTUnwrap(remote.fetch(FetchDescriptor<Account>()).first)
        other.name = "Winning B"
        try remote.save()
        var identity = mapping
        var winner = await session.snapshot()
        winner.beginWritingSession()
        // First advance above A's local capture, then advance B above that revision.
        try winner.captureLocal(identity.capture(localA))
        try winner.captureLocal(identity.capture(LedgerSnapshotCodec.capture(in: remote)))
        let serverRecords = try bridgeRecords(winner)
        var injected = false
        var completions = 0
        let applied = expectation(description: "Conflict winner was applied and confirmed")
        controller.reconcileCheckpoint = { stage in
            if stage == .afterAcknowledgment, !injected {
                injected = true
                let ready = await session.syncEvidence()
                XCTAssertTrue(ready.appliedCurrentFetch)
                await session.recordSendActivity(uploading: true, syncEngine: engine)
                let batch = await session.recordZoneChangeBatch(scope: .all, syncEngine: engine)
                let outgoing = try XCTUnwrap(batch?.recordsToSave.first)
                let contentRevision = LedgerSaveRevision.shared.contentRevision
                let server = try XCTUnwrap(serverRecords.first { $0.recordID == outgoing.recordID })
                let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
                try await session.recordSentRecords([], failedSaves: [(outgoing, error)], syncEngine: engine)
                // The SDK owns removal of completed outbox entries; simulate that completion.
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(outgoing.recordID)])
                await session.recordSendActivity(uploading: false, syncEngine: engine)
                let arrived = await session.syncEvidence()
                XCTAssertEqual(arrived.pendingUploads, 0)
                XCTAssertEqual(arrived.queuedChanges, 0)
                XCTAssertFalse(arrived.uploading)
                XCTAssertEqual(LedgerSaveRevision.shared.contentRevision, contentRevision,
                    "The server conflict must not create an unrelated SwiftData business revision")
                XCTAssertFalse(arrived.appliedCurrentFetch, "Conflict winner must invalidate A application evidence")
                XCTAssertFalse(arrived.canConfirm)
                XCTAssertEqual(try ModelContext(local.container).fetch(FetchDescriptor<Account>()).first?.name, "Local A")
            }
            if stage == .completed {
                completions += 1
                let evidence = await session.syncEvidence()
                if completions == 1 {
                    XCTAssertEqual(evidence.lastConfirmedAt, previous)
                    await controller.refreshStatus()
                    XCTAssertNotEqual(controller.displaySnapshot.stage, .confirmed)
                } else {
                    XCTAssertEqual(try ModelContext(local.container).fetch(FetchDescriptor<Account>()).first?.name, "Winning B")
                    XCTAssertTrue(evidence.canConfirm)
                    await controller.refreshStatus()
                    XCTAssertEqual(controller.displaySnapshot.stage, .confirmed)
                    XCTAssertNotEqual(evidence.lastConfirmedAt, previous)
                    applied.fulfill()
                }
            }
        }
        await controller.reconcile(in: local, changes: LedgerChangeCenter())
        await fulfillment(of: [applied], timeout: 10)
        controller.reconcileCheckpoint = nil
        await session.stop()
    }

    private func bridgeRecords(_ replica: ProtectedLedgerReplica) throws -> [CKRecord] {
        try replica.records.map { key, value in
            let record = CKRecord(recordType: PrivateCloudReplicaSession.recordType,
                recordID: .init(recordName: PrivateCloudReplicaSession.recordName(for: key), zoneID: PrivateCloudReplicaSession.zoneID))
            record["envelope"] = try JSONEncoder().encode(PrivateCloudReplicaSession.Envelope(
                format: 1, accountIdentifier: "A", key: key, record: value)) as CKRecordValue
            return record
        }
    }

    private func acknowledgeBridgeUploads(_ session: PrivateCloudReplicaSession, engine: CKSyncEngine) async throws {
        while let batch = await session.recordZoneChangeBatch(scope: .all, syncEngine: engine), !batch.recordsToSave.isEmpty {
            let records = batch.recordsToSave
            try await session.recordSentRecords(records, failedSaves: [], syncEngine: engine)
            engine.state.remove(pendingRecordZoneChanges: records.map { .saveRecord($0.recordID) })
        }
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
    }

    private func confirmedBridge(local: ModelContext, directory: URL) async throws
        -> (PrivateCloudReplicaSession, ICloudSyncController, CKSyncEngine, LedgerSyncIdentity) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var mapping = LedgerSyncIdentity()
        var replica = ProtectedLedgerReplica(accountIdentifier: "A")
        try replica.captureLocal(mapping.capture(LedgerSnapshotCodec.capture(in: local)))
        let url = directory.appendingPathComponent("state.json")
        try JSONEncoder().encode(PrivateCloudReplicaSession.State(replica: replica,
            initialProjectionCompleted: true, initialFetchCompleted: true)).write(to: url)
        let session = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "A", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "A")
        let current = await session.engine
        let engine = try XCTUnwrap(current)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        let controller = ICloudSyncController(confirmedSession: session, identity: mapping,
            identityURL: directory.appendingPathComponent("identity.json"))
        await controller.reconcile(in: local, changes: LedgerChangeCenter())
        try await acknowledgeBridgeUploads(session, engine: engine)
        await controller.reconcile(in: local, changes: LedgerChangeCenter())
        await controller.refreshStatus()
        XCTAssertEqual(controller.displaySnapshot.stage, .confirmed)
        return (session, controller, engine, mapping)
    }

    func testLateProjectionReceiptCannotConfirmNewerFetchedGraph() async throws {
        try await assertFetchedGraphCannotConfirm(arrival: .beforeAcknowledgment)
    }

    func testFetchedGraphAfterAcknowledgmentCannotConfirmBeforeProjection() async throws {
        try await assertFetchedGraphCannotConfirm(arrival: .afterAcknowledgment)
    }

    private func assertFetchedGraphCannotConfirm(arrival: ICloudSyncController.ReconcileStage) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = try makeContext()
        let remote = try makeContext()
        let account = try XCTUnwrap(remote.fetch(FetchDescriptor<Account>()).first)
        var mapping = LedgerSyncIdentity()
        var cloud = ProtectedLedgerReplica(accountIdentifier: "A")
        func records(_ replica: ProtectedLedgerReplica) throws -> [CKRecord] {
            try replica.records.map { key, value in
                let record = CKRecord(recordType: PrivateCloudReplicaSession.recordType,
                    recordID: .init(recordName: PrivateCloudReplicaSession.recordName(for: key), zoneID: PrivateCloudReplicaSession.zoneID))
                record["envelope"] = try JSONEncoder().encode(PrivateCloudReplicaSession.Envelope(
                    format: 1, accountIdentifier: "A", key: key, record: value)) as CKRecordValue
                return record
            }
        }
        account.name = "Projection A"
        try remote.save()
        try cloud.captureLocal(mapping.capture(LedgerSnapshotCodec.capture(in: remote)))
        let first = try records(cloud)
        account.name = "Projection B"
        try remote.save()
        try cloud.captureLocal(mapping.capture(LedgerSnapshotCodec.capture(in: remote)))
        let second = try records(cloud)
        let session = try PrivateCloudReplicaSession(stateURL: directory.appendingPathComponent("state.json"),
            accountIdentifier: "A", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "A")
        let current = await session.engine
        let engine = try XCTUnwrap(current)
        try await session.receiveRemoteRecords(first, syncEngine: engine)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        let controller = ICloudSyncController(confirmedSession: session, identity: LedgerSyncIdentity(),
            identityURL: directory.appendingPathComponent("identity.json"))
        var injected = false
        var completions = 0
        let appliedB = expectation(description: "New graph applied by next reconciliation")
        controller.reconcileCheckpoint = { stage in
            if stage == arrival, !injected {
                injected = true
                XCTAssertEqual(try local.fetch(FetchDescriptor<Account>()).first?.name, "Projection A")
                try await session.receiveRemoteRecords(second, syncEngine: engine)
                try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
                let evidence = await session.syncEvidence()
                XCTAssertFalse(evidence.canConfirm)
                XCTAssertFalse(evidence.appliedCurrentFetch)
            }
            if stage == .completed {
                completions += 1
                let evidence = await session.syncEvidence()
                if completions == 1 {
                    XCTAssertEqual(try local.fetch(FetchDescriptor<Account>()).first?.name, "Projection A")
                    XCTAssertFalse(evidence.appliedCurrentFetch, "A receipt must not endorse fetched B")
                    XCTAssertFalse(evidence.canConfirm)
                    XCTAssertNil(evidence.lastConfirmedAt)
                } else {
                    XCTAssertEqual(try local.fetch(FetchDescriptor<Account>()).first?.name, "Projection B")
                    XCTAssertTrue(evidence.canConfirm)
                    XCTAssertNotNil(evidence.lastConfirmedAt)
                    appliedB.fulfill()
                }
            }
        }
        await controller.reconcile(in: local, changes: LedgerChangeCenter())
        await fulfillment(of: [appliedB], timeout: 10)
        controller.reconcileCheckpoint = nil
        await session.stop()
    }

    func testInitialReconcileRejectsRemoteArrivalsAtEveryPreparationBoundary() async throws {
        for checkpoint in [ICloudSyncController.ReconcileStage.snapshot, .prepared, .projectionPrepared, .beforeApply] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let local = try makeContext()
            let original = try LedgerSnapshotCodec.capture(in: local)
            let remote = try makeContext()
            let account = try XCTUnwrap(remote.fetch(FetchDescriptor<Account>()).first)
            account.name = "Remote latest"
            remote.insert(FinanceTransaction(type: .expense, amountMinorUnits: 321,
                occurredAt: Date(timeIntervalSince1970: 0), localDayKey: "1970-01-01",
                timeZoneIdentifier: "UTC", accountID: account.id))
            try remote.save()
            var remoteIdentity = LedgerSyncIdentity()
            var cloud = ProtectedLedgerReplica(accountIdentifier: "A")
            try cloud.captureLocal(remoteIdentity.capture(LedgerSnapshotCodec.capture(in: remote)))
            let records = try cloud.records.map { key, value in
                let record = CKRecord(recordType: PrivateCloudReplicaSession.recordType,
                    recordID: .init(recordName: PrivateCloudReplicaSession.recordName(for: key),
                                    zoneID: PrivateCloudReplicaSession.zoneID))
                record["envelope"] = try JSONEncoder().encode(PrivateCloudReplicaSession.Envelope(
                    format: ProtectedLedgerReplica.currentFormat, accountIdentifier: "A", key: key, record: value)) as CKRecordValue
                return record
            }
            let session = try PrivateCloudReplicaSession(stateURL: directory.appendingPathComponent("state.json"), accountIdentifier: "A", automaticallySync: false)
            try await session.start(verifiedAccountIdentifier: "A")
            let engineValue = await session.engine
            let engine = try XCTUnwrap(engineValue)
            if checkpoint != .snapshot {
                try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
            }
            // For apply races, start with an older cloud graph, so no bootstrap is captured.
            if checkpoint == .projectionPrepared || checkpoint == .beforeApply {
                account.name = "Remote older"
                try remote.save()
                var oldCloud = ProtectedLedgerReplica(accountIdentifier: "A")
                try oldCloud.captureLocal(remoteIdentity.capture(LedgerSnapshotCodec.capture(in: remote)))
                // Advance the delivered latest version above this earlier graph deterministically.
                cloud = oldCloud
                account.name = "Remote latest"
                try remote.save()
                try cloud.captureLocal(remoteIdentity.capture(LedgerSnapshotCodec.capture(in: remote)))
                let older = try oldCloud.records.map { key, value -> CKRecord in
                    let record = CKRecord(recordType: PrivateCloudReplicaSession.recordType,
                        recordID: .init(recordName: PrivateCloudReplicaSession.recordName(for: key), zoneID: PrivateCloudReplicaSession.zoneID))
                    record["envelope"] = try JSONEncoder().encode(PrivateCloudReplicaSession.Envelope(format: 1, accountIdentifier: "A", key: key, record: value)) as CKRecordValue
                    return record
                }
                try await session.receiveRemoteRecords(older, syncEngine: engine)
            }
            let latest = try cloud.records.map { key, value -> CKRecord in
                let record = CKRecord(recordType: PrivateCloudReplicaSession.recordType,
                    recordID: .init(recordName: PrivateCloudReplicaSession.recordName(for: key), zoneID: PrivateCloudReplicaSession.zoneID))
                record["envelope"] = try JSONEncoder().encode(PrivateCloudReplicaSession.Envelope(format: 1, accountIdentifier: "A", key: key, record: value)) as CKRecordValue
                return record
            }
            let controller = ICloudSyncController(confirmedSession: session, identity: LedgerSyncIdentity(), identityURL: directory.appendingPathComponent("identity.json"))
            var injected = false
            let completed = expectation(description: "Reconcile retried and committed latest graph")
            var rejectedStale = false
            controller.reconcileCheckpoint = { stage in
                if stage == .retrying {
                    rejectedStale = true
                    XCTAssertEqual(try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: local)),
                                   try LedgerSnapshotCodec.records(original), "Stale plan must not apply before retry")
                    return
                }
                if stage == .completed { completed.fulfill(); return }
                guard stage == checkpoint, !injected else { return }
                injected = true
                try await session.receiveRemoteRecords(checkpoint == .snapshot || checkpoint == .prepared ? records : latest, syncEngine: engine)
                try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
            }
            let changes = LedgerChangeCenter()
            await controller.reconcile(in: local, changes: changes)
            XCTAssertTrue(injected)
            XCTAssertTrue(rejectedStale, "A changed graph must reject the first plan before awaiting a fresh pass")
            await fulfillment(of: [completed], timeout: 10)
            controller.reconcileCheckpoint = nil
            let result = try LedgerSnapshotCodec.capture(in: local)
            XCTAssertEqual(result.accounts.count, 1)
            XCTAssertEqual(result.accounts.first?.id, original.accounts.first?.id)
            XCTAssertEqual(result.accounts.first?.name, "Remote latest")
            XCTAssertEqual(result.categories.count, original.categories.count)
            XCTAssertEqual(result.transactions.count, 1)
            let replica = await session.snapshot()
            XCTAssertEqual(replica.clock, cloud.clock)
            XCTAssertFalse(replica.records.values.contains { $0.revision.author == replica.author })
            XCTAssertTrue(engine.state.pendingRecordZoneChanges.isEmpty)
            await session.stop()
        }
    }

    func testAccountSwitchWithSharedIdentityWaitsBeforeCapturingPristineLedger() async throws {
        try await verifyNewTransportBarrier(from: .development, to: .development, nextAccount: "B")
    }

    func testEnvironmentSwitchesWithSharedIdentityWaitBeforeCapturingPristineLedger() async throws {
        try await verifyNewTransportBarrier(from: .development, to: .production, nextAccount: "A")
        try await verifyNewTransportBarrier(from: .production, to: .development, nextAccount: "A")
    }

    func testNewEmptyAccountCannotQueueBootstrapUntilFetchCompletes() async throws {
        try await verifyNewTransportBarrier(from: .development, to: .development, nextAccount: "B", cloudHasLedger: false)
    }

    private func verifyNewTransportBarrier(
        from: CloudReplicaLocation.Environment, to: CloudReplicaLocation.Environment, nextAccount: String,
        cloudHasLedger: Bool = true
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = try makeContext()
        let localID = try XCTUnwrap(local.fetch(FetchDescriptor<Account>()).first?.id)
        let changes = LedgerChangeCenter()
        let firstLocation = CloudReplicaLocation(root: directory, environment: from, account: "A")
        let first = try PrivateCloudReplicaSession(
            stateURL: firstLocation.stateURL, accountIdentifier: "A", automaticallySync: false
        )
        try await first.start(verifiedAccountIdentifier: "A")
        let firstEngine = await first.engine
        try await first.recordFetchCompletion(succeeded: true, syncEngine: try XCTUnwrap(firstEngine))
        let firstController = ICloudSyncController(
            confirmedSession: first, identity: LedgerSyncIdentity(), identityURL: firstLocation.identityURL
        )
        await firstController.reconcile(in: local, changes: changes)
        let firstCompletion = await first.initialProjection(pristine: true)
        XCTAssertEqual(firstCompletion, .established)
        await first.stop()
        let shared = try JSONDecoder().decode(LedgerSyncIdentity.self, from: Data(contentsOf: firstLocation.identityURL))
        // Pre-fix identity files containing this key must remain readable but cannot authorize B.
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(shared)) as? [String: Any])
        legacyJSON["initialProjectionCompleted"] = true
        let retained = try JSONDecoder().decode(LedgerSyncIdentity.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertEqual(retained, shared)

        let nextLocation = CloudReplicaLocation(root: directory, environment: to, account: nextAccount)
        XCTAssertEqual(firstLocation.identityURL, nextLocation.identityURL)
        // Simulate already durable remote arrivals with no local baseline for this transport.
        let remote = try makeContext()
        let remoteAccount = try XCTUnwrap(remote.fetch(FetchDescriptor<Account>()).first)
        remoteAccount.name = "Remote existing account"
        try remote.save()
        var remoteIdentity = LedgerSyncIdentity()
        var cloud = ProtectedLedgerReplica(accountIdentifier: nextAccount)
        try cloud.captureLocal(remoteIdentity.capture(LedgerSnapshotCodec.capture(in: remote)))
        var fresh = ProtectedLedgerReplica(accountIdentifier: nextAccount)
        if cloudHasLedger { try fresh.merge(cloud) }
        try FileManager.default.createDirectory(at: nextLocation.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(PrivateCloudReplicaSession.State(replica: fresh))
            .write(to: nextLocation.stateURL, options: .atomic)
        let next = try PrivateCloudReplicaSession(
            stateURL: nextLocation.stateURL, accountIdentifier: nextAccount, automaticallySync: false
        )
        try await next.start(verifiedAccountIdentifier: nextAccount)
        let engine = await next.engine
        let current = try XCTUnwrap(engine)
        let controller = ICloudSyncController(
            confirmedSession: next, identity: retained, identityURL: nextLocation.identityURL
        )
        let before = await next.snapshot()
        await controller.reconcile(in: local, changes: changes)
        let waiting = await next.initialProjection(pristine: true)
        let after = await next.snapshot()
        XCTAssertEqual(waiting, .waitingForFetch)
        XCTAssertEqual(after, before, "No bootstrap capture or local revision before successful fetch")
        XCTAssertTrue(after.localBaseline.isEmpty)
        if !cloudHasLedger { XCTAssertTrue(current.state.pendingRecordZoneChanges.isEmpty) }
        // Existing remote values may already be pending; no local bootstrap may be added.
        XCTAssertFalse(after.records.keys.contains("accounts:\(LedgerSyncIdentity.bootstrapAccountID.uuidString)"))
        XCTAssertEqual(try local.fetch(FetchDescriptor<Account>()).map(\.id), [localID])

        try await next.recordFetchCompletion(succeeded: false, syncEngine: current)
        await controller.reconcile(in: local, changes: changes)
        let afterFailedFetch = await next.snapshot()
        XCTAssertEqual(afterFailedFetch, before)
        try await next.recordFetchCompletion(succeeded: true, syncEngine: current)
        await controller.reconcile(in: local, changes: changes)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(try local.fetch(FetchDescriptor<Account>()).map(\.id), [localID])
        if cloudHasLedger {
            XCTAssertEqual(try local.fetch(FetchDescriptor<Account>()).first?.name, "Remote existing account")
        }
        let projected = await next.snapshot()
        XCTAssertFalse(projected.localBaseline.isEmpty)
        if cloudHasLedger {
            XCTAssertEqual(projected.clock, before.clock, "Adoption must not promote the pristine local bootstrap")
        } else {
            XCTAssertNotNil(projected.livePayloads["accounts:\(LedgerSyncIdentity.bootstrapAccountID.uuidString)"])
            XCTAssertFalse(current.state.pendingRecordZoneChanges.isEmpty)
        }
        await next.stop()
        let restarted = try PrivateCloudReplicaSession(stateURL: nextLocation.stateURL, accountIdentifier: nextAccount)
        let restartedMode = await restarted.initialProjection(pristine: true)
        XCTAssertEqual(restartedMode, .established)
    }

    func testConfirmedNewAccountMustFetchBeforeCapturingNonPristineLedger() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = try makeContext()
        let account = try XCTUnwrap(local.fetch(FetchDescriptor<Account>()).first)
        account.name = "Existing user ledger"
        try local.save()
        let session = try PrivateCloudReplicaSession(
            stateURL: directory.appendingPathComponent("B/replica.json"), accountIdentifier: "B", automaticallySync: false
        )
        try await session.start(verifiedAccountIdentifier: "B")
        let controller = ICloudSyncController(
            confirmedSession: session, identity: LedgerSyncIdentity(), identityURL: directory.appendingPathComponent("identities.json")
        )
        await controller.reconcile(in: local, changes: LedgerChangeCenter())
        let replica = await session.snapshot()
        let fetched = await session.hasCompletedFetch
        XCTAssertFalse(fetched)
        XCTAssertTrue(replica.localBaseline.isEmpty)
        XCTAssertEqual(replica.clock, 0)
        let engine = await session.engine
        try await session.recordFetchCompletion(succeeded: true, syncEngine: try XCTUnwrap(engine))
        await controller.reconcile(in: local, changes: LedgerChangeCenter())
        let ready = await session.snapshot()
        XCTAssertNotNil(ready.livePayloads["accounts:\(account.id.uuidString)"])
        XCTAssertEqual(ready.clock, 1)
        XCTAssertEqual(controller.status, .enabled)
        await session.stop()
    }

    func testFreshNonPristineTransportCapturesAboveRemoteClockWithoutDeletingRemoteOnlyRows() async throws {
        for (environment, accountName) in [(CloudReplicaLocation.Environment.development, "A"), (.production, "A"), (.development, "B")] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let context = try makeContext()
            let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first)
            account.name = "Local authority"
            try context.save()
            var identity = LedgerSyncIdentity()
            let local = try identity.capture(LedgerSnapshotCodec.capture(in: context))
            let key = "accounts:\(account.id.uuidString)"
            var remoteAccount = try JSONDecoder().decode(NativeBackupPackage.AccountPayload.self, from: XCTUnwrap(local[key]))
            remoteAccount.name = "Remote old value"
            var remoteOnly = remoteAccount
            remoteOnly.id = UUID()
            remoteOnly.name = "Remote only"
            remoteOnly.isDefault = false
            let remoteOnlyKey = "accounts:\(remoteOnly.id.uuidString)"
            var remote = ProtectedLedgerReplica(accountIdentifier: accountName)
            let revision = ProtectedLedgerReplica.Revision(counter: 50, author: UUID())
            // This positive clock-ordering case requires a complete initial graph.
            // Partial delivery is covered separately and must not authorize capture.
            for (recordKey, payload) in local where !recordKey.hasPrefix("accounts:") {
                try remote.mergeRecord(.init(revision: revision, payload: payload), key: recordKey, accountIdentifier: accountName)
            }
            for (recordKey, payload) in [(key, remoteAccount), (remoteOnlyKey, remoteOnly)] {
                try remote.mergeRecord(.init(revision: revision, payload: JSONEncoder().encode(payload)), key: recordKey, accountIdentifier: accountName)
            }
            let location = CloudReplicaLocation(root: directory, environment: environment, account: accountName)
            try FileManager.default.createDirectory(at: location.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(PrivateCloudReplicaSession.State(replica: remote)).write(to: location.stateURL)
            let session = try PrivateCloudReplicaSession(stateURL: location.stateURL, accountIdentifier: accountName, automaticallySync: false)
            try await session.start(verifiedAccountIdentifier: accountName)
            let engine = await session.engine
            let current = try XCTUnwrap(engine)
            let controller = ICloudSyncController(confirmedSession: session, identity: identity, identityURL: location.identityURL)
            await controller.reconcile(in: context, changes: LedgerChangeCenter())
            let waiting = await session.snapshot()
            XCTAssertEqual(waiting.clock, 50)
            XCTAssertTrue(waiting.localBaseline.isEmpty)
            try await session.recordFetchCompletion(succeeded: true, syncEngine: current)
            await controller.reconcile(in: context, changes: LedgerChangeCenter())
            let captured = await session.snapshot()
            XCTAssertEqual(captured.records[key]?.revision.counter, 51)
            XCTAssertNotNil(captured.livePayloads[remoteOnlyKey])
            XCTAssertEqual(account.name, "Local authority")
            XCTAssertTrue(try context.fetch(FetchDescriptor<Account>()).contains { $0.id == remoteOnly.id })
            await session.stop()
        }
    }

    func testPristineDevicesShareBootstrapIdentityAndKeepItAcrossTransportChanges() throws {
        let first = try makeContext()
        let second = try makeContext()
        let firstPackage = try LedgerSnapshotCodec.capture(in: first)
        let secondPackage = try LedgerSnapshotCodec.capture(in: second)
        let firstID = try XCTUnwrap(firstPackage.accounts.first?.id)
        let secondID = try XCTUnwrap(secondPackage.accounts.first?.id)
        XCTAssertNotEqual(firstID, secondID)
        var firstIdentity = LedgerSyncIdentity()
        var secondIdentity = LedgerSyncIdentity()
        firstIdentity.adoptBootstrapAccount(localID: firstID, wireID: LedgerSyncIdentity.bootstrapAccountID)
        secondIdentity.adoptBootstrapAccount(localID: secondID, wireID: LedgerSyncIdentity.bootstrapAccountID)
        let firstWire = try firstIdentity.capture(firstPackage)
        let secondWire = try secondIdentity.capture(secondPackage)
        XCTAssertEqual(Set(firstWire.keys.filter { $0.hasPrefix("accounts:") }),
                       Set(secondWire.keys.filter { $0.hasPrefix("accounts:") }))
        let restored = try JSONDecoder().decode(LedgerSyncIdentity.self, from: JSONEncoder().encode(firstIdentity))
        XCTAssertEqual(restored, firstIdentity)
        var transportIdentity = restored
        var newEnvironmentReplica = ProtectedLedgerReplica(accountIdentifier: "other-account")
        try newEnvironmentReplica.captureLocal(transportIdentity.capture(firstPackage))
        let projected = try transportIdentity.localPackage(from: newEnvironmentReplica)
        XCTAssertEqual(projected.accounts.map(\.id), [firstID])
        XCTAssertEqual(try transportIdentity.capture(projected), firstWire)
        XCTAssertEqual(try first.fetch(FetchDescriptor<Account>()).map(\.id), [firstID])
    }

    func testNewDeviceAdoptsLedgerWithoutReplacingLocalUUIDsOrDuplicatingDefaults() throws {
        let first = try makeContext()
        let account = try XCTUnwrap(first.fetch(FetchDescriptor<Account>()).first)
        let category = try XCTUnwrap(first.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining.lunch" })
        let tag = Tag(name: "同步标签", colorToken: "teal")
        first.insert(tag)
        let transaction = FinanceTransaction(
            type: .expense, amountMinorUnits: 123_456_789, occurredAt: Date(timeIntervalSince1970: 0),
            localDayKey: "1970-01-01", timeZoneIdentifier: "UTC", accountID: account.id,
            categoryID: category.id, note: "精确金额与原有身份", tags: [tag]
        )
        first.insert(transaction)
        try first.save()
        let originalID = transaction.id
        var firstIdentity = LedgerSyncIdentity()
        var firstReplica = ProtectedLedgerReplica(accountIdentifier: "private-account")
        try firstReplica.captureLocal(firstIdentity.capture(LedgerSnapshotCodec.capture(in: first)))

        let second = try makeContext()
        let secondAccount = try XCTUnwrap(second.fetch(FetchDescriptor<Account>()).first)
        let secondOriginalID = secondAccount.id
        var secondIdentity = LedgerSyncIdentity()
        _ = try secondIdentity.capture(LedgerSnapshotCodec.capture(in: second))
        secondIdentity.adoptBootstrapAccount(localID: secondOriginalID, wireID: account.id)
        var secondReplica = ProtectedLedgerReplica(accountIdentifier: "private-account")
        try secondReplica.merge(firstReplica)
        let candidate = try secondIdentity.localPackage(from: secondReplica)
        try LedgerSnapshotCodec.apply(candidate, in: second)
        secondReplica.acknowledgeLocalProjection(try secondIdentity.capture(candidate))

        for _ in 0..<4 {
            try secondReplica.captureLocal(secondIdentity.capture(LedgerSnapshotCodec.capture(in: second)))
            try firstReplica.merge(secondReplica)
            let firstCandidate = try firstIdentity.localPackage(from: firstReplica)
            try LedgerSnapshotCodec.apply(firstCandidate, in: first)
            firstReplica.acknowledgeLocalProjection(try firstIdentity.capture(firstCandidate))
            try secondReplica.merge(firstReplica)
            try LedgerSnapshotCodec.apply(secondIdentity.localPackage(from: secondReplica), in: second)
        }
        XCTAssertEqual(try first.fetch(FetchDescriptor<FinanceTransaction>()).map(\.id), [originalID])
        let received = try XCTUnwrap(second.fetch(FetchDescriptor<FinanceTransaction>()).first)
        XCTAssertEqual(received.amountMinorUnits, 123_456_789)
        XCTAssertEqual(received.accountID, secondOriginalID)
        XCTAssertEqual(received.tags.map(\.id), [tag.id])
        XCTAssertEqual(try second.fetch(FetchDescriptor<Account>()).map(\.id), [secondOriginalID])
        XCTAssertEqual(try second.fetchCount(FetchDescriptor<AppMetadata>()), 1)
        let categories = try second.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertEqual(categories.count, Set(categories.map(\.defaultDefinitionKey)).count)
    }

    func testConcurrentImportUsesOneWireIdentityAndPreservesEachLocalTransactionID() throws {
        let first = try makeContext()
        let baseline = try LedgerSnapshotCodec.capture(in: first)
        let secondContainer = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let second = ModelContext(secondContainer)
        try LedgerSnapshotCodec.apply(baseline, in: second)
        let accountID = try XCTUnwrap(baseline.accounts.first?.id)
        let firstTransaction = FinanceTransaction(
            type: .expense, amountMinorUnits: 1021, occurredAt: Date(timeIntervalSince1970: 0),
            localDayKey: "1970-01-01", timeZoneIdentifier: "UTC", accountID: accountID,
            externalSource: .wacai, externalTransactionID: "same-statement-row",
            importFingerprint: "same-fingerprint"
        )
        let secondTransaction = FinanceTransaction(
            type: .expense, amountMinorUnits: 1021, occurredAt: Date(timeIntervalSince1970: 0),
            localDayKey: "1970-01-01", timeZoneIdentifier: "UTC", accountID: accountID,
            externalSource: .wacai, externalTransactionID: "same-statement-row",
            importFingerprint: "same-fingerprint"
        )
        first.insert(firstTransaction)
        second.insert(secondTransaction)
        try first.save()
        try second.save()
        var firstIdentity = LedgerSyncIdentity()
        var secondIdentity = LedgerSyncIdentity()
        var firstReplica = ProtectedLedgerReplica(accountIdentifier: "account")
        var secondReplica = ProtectedLedgerReplica(accountIdentifier: "account")
        try firstReplica.captureLocal(firstIdentity.capture(LedgerSnapshotCodec.capture(in: first)))
        try secondReplica.captureLocal(secondIdentity.capture(LedgerSnapshotCodec.capture(in: second)))
        let savedFirst = firstReplica
        try firstReplica.merge(secondReplica)
        try secondReplica.merge(savedFirst)
        try LedgerSnapshotCodec.apply(firstIdentity.localPackage(from: firstReplica), in: first)
        try LedgerSnapshotCodec.apply(secondIdentity.localPackage(from: secondReplica), in: second)
        XCTAssertEqual(try first.fetch(FetchDescriptor<FinanceTransaction>()).map(\.id), [firstTransaction.id])
        XCTAssertEqual(try second.fetch(FetchDescriptor<FinanceTransaction>()).map(\.id), [secondTransaction.id])
        XCTAssertEqual(firstReplica.records, secondReplica.records)
        XCTAssertEqual(firstReplica.records.keys.filter { $0.hasPrefix("transactions:") }.count, 1)
    }

    func testRealConcurrentImportConvergesMetadataBatchAndRollback() async throws {
        let first = try makeContext()
        let second = try makeContext()
        let csv = "transaction_id,type,amount,date_time,category,account,tags\ndeep-audit-1,expense,18.00,2026-01-01 10:00,餐饮 / 深审早餐,深审账户,深审标签\ndeep-audit-2,expense,22.00,2026-01-01 11:00,餐饮 / 深审早餐,深审账户,深审标签"
        let document = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: "synthetic.csv")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let parsed = try FinanceCSVService.parsePlan(document: document, mapping: FinanceCSVService.autoMapping(headers: document.headers), fileName: "synthetic.csv", calendar: calendar)
        for context in [first, second] {
            let duplicates = try await ImportPlanningActor(modelContainer: context.container).duplicateRecords(for: parsed)
            let plan = FinanceCSVService.assessDuplicates(parsed, existingRecords: duplicates)
            let models = FinanceCSVService.makeImportModelSnapshot(
                accounts: try context.fetch(FetchDescriptor<Account>()),
                categories: try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()),
                tags: try context.fetch(FetchDescriptor<Tag>()))
            let request = try FinanceCSVService.makeBackgroundCommitRequest(plan: plan, modelSnapshot: models,
                createMissingCategories: true, createMissingAccounts: true, createMissingTags: true,
                rememberedCategoryMappings: [:])
            XCTAssertEqual(request.accountsToCreate.count, 1)
            XCTAssertEqual(request.categoriesToCreate.count, 1)
            XCTAssertEqual(request.tagsToCreate.count, 1)
            _ = try await ImportCommitActor(modelContainer: context.container).commit(request)
        }
        let batchA = try XCTUnwrap(first.fetch(FetchDescriptor<ImportBatch>()).first?.id)
        let batchB = try XCTUnwrap(second.fetch(FetchDescriptor<ImportBatch>()).first?.id)
        XCTAssertNotEqual(batchA, batchB)
        var identityA = LedgerSyncIdentity()
        var identityB = LedgerSyncIdentity()
        var replicaA = ProtectedLedgerReplica(accountIdentifier: "A")
        var replicaB = ProtectedLedgerReplica(accountIdentifier: "A")
        try replicaA.captureLocal(identityA.capture(LedgerSnapshotCodec.capture(in: first)))
        try replicaB.captureLocal(identityB.capture(LedgerSnapshotCodec.capture(in: second)))
        try replicaA.merge(replicaB)
        try replicaB.merge(replicaA)
        for (context, identity, replica, batchID) in [(first, identityA, replicaA, batchA), (second, identityB, replicaB, batchB)] {
            let package = try identity.localPackage(from: replica)
            XCTAssertEqual(package.transactions.count, 2)
            XCTAssertEqual(package.accounts.filter { $0.name == "深审账户" }.count, 1)
            XCTAssertEqual(package.categories.filter { $0.name == "深审早餐" }.count, 1)
            XCTAssertEqual(package.tags.filter { $0.name == "深审标签" }.count, 1)
            XCTAssertEqual(package.importBatches.count, 1)
            XCTAssertEqual(package.transactions.first?.importBatchID, batchID)
            let decoded = try JSONDecoder().decode(NativeBackupPackage.self, from: JSONEncoder().encode(package))
            let restored = try makeContext()
            try LedgerSnapshotCodec.apply(ValidatedLedgerSnapshot(decoded), in: restored)
            let backupRoundTrip = try LedgerSnapshotCodec.capture(in: restored)
            XCTAssertEqual(try LedgerSnapshotCodec.records(backupRoundTrip), try LedgerSnapshotCodec.records(package))
            try LedgerSnapshotCodec.apply(ValidatedLedgerSnapshot(package), in: context)
        }
        // A rollback on either original local batch ID covers the entire converged import.
        let result = try await ImportRollbackActor(modelContainer: first.container).rollback(batchID: batchA, preserveEdited: false, includeUncertain: true, reviewedRevision: LedgerSaveRevision.shared.contentRevision)
        XCTAssertEqual(result.deletedCount, 2)
        // Use A's projected baseline, not B's local IDs, before capturing its rollback.
        replicaA.acknowledgeLocalProjection(try identityA.capture(identityA.localPackage(from: replicaB)))
        try replicaA.captureLocal(identityA.capture(LedgerSnapshotCodec.capture(in: first)))
        try replicaB.merge(replicaA)
        let rolledBack = try identityB.localPackage(from: replicaB)
        try LedgerSnapshotCodec.apply(ValidatedLedgerSnapshot(rolledBack), in: second)
        XCTAssertTrue(rolledBack.transactions.allSatisfy { $0.deletedAt != nil })
        XCTAssertEqual(rolledBack.importBatches.first?.status, .rolledBack)
        let summary = try await ImportRollbackActor(modelContainer: second.container).summary(batchID: batchB)
        XCTAssertEqual(summary.currentActiveCount, 0)
        XCTAssertEqual(try second.fetch(FetchDescriptor<ImportBatch>()).count, 1)
    }

    func testSameNamedUserMetadataKeepsDistinctWireIdentities() throws {
        var firstIdentity = LedgerSyncIdentity()
        var secondIdentity = LedgerSyncIdentity()
        var first = ProtectedLedgerReplica(accountIdentifier: "A")
        var second = ProtectedLedgerReplica(accountIdentifier: "A")
        for index in 0..<2 {
            let context = try makeContext()
            context.insert(Account(name: "User same name", type: .other))
            context.insert(Tag(name: "User same name"))
            context.insert(PersonalFinanceOS.Category(kind: .expense, name: "User same name", symbolName: "circle", colorToken: "teal"))
            try context.save()
            let package = try LedgerSnapshotCodec.capture(in: context)
            if index == 0 { try first.captureLocal(firstIdentity.capture(package)) }
            else { try second.captureLocal(secondIdentity.capture(package)) }
        }
        try first.merge(second)
        let package = try firstIdentity.localPackage(from: first)
        XCTAssertEqual(package.accounts.filter { $0.name == "User same name" }.count, 2)
        XCTAssertEqual(package.categories.filter { $0.name == "User same name" }.count, 2)
        XCTAssertEqual(package.tags.filter { $0.name == "User same name" }.count, 2)
    }

    func testHardDeleteThenWinningRemoteEditResurrectsOriginalLocalIdentities() throws {
        let context = try makeContext()
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first)
        let category = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining.lunch" })
        let tag = Tag(name: "Historical alias")
        context.insert(tag)
        context.insert(ImportEntityOrigin(entityKey: "tags:\(tag.id.uuidString)", semanticKey: "import-v1:resurrection-tag"))
        let imported = FinanceTransaction(type: .expense, amountMinorUnits: 500,
            occurredAt: Date(timeIntervalSince1970: 1_767_225_600), localDayKey: "2026-01-01", timeZoneIdentifier: "UTC",
            accountID: account.id, categoryID: category.id, externalSource: .genericCSV,
            externalTransactionID: "resurrect-import", tags: [tag])
        context.insert(imported)
        let importedID = imported.id
        try context.save()
        let accountID = account.id
        let categoryID = category.id
        let tagID = tag.id
        var identity = LedgerSyncIdentity()
        identity.adoptBootstrapAccount(localID: accountID, wireID: LedgerSyncIdentity.bootstrapAccountID)
        let original = try identity.capture(LedgerSnapshotCodec.capture(in: context))
        var replica = ProtectedLedgerReplica(accountIdentifier: "A")
        try replica.captureLocal(original)
        let aliases = identity.localToWire
        context.delete(imported)
        context.delete(account)
        context.delete(category)
        context.delete(tag)
        try context.save()
        try replica.captureLocal(identity.capture(LedgerSnapshotCodec.capture(in: context)))
        XCTAssertEqual(identity.localToWire, aliases)
        for kindAndID in [("accounts", accountID), ("categories", categoryID), ("tags", tagID), ("transactions", importedID)] {
            let wireID = try XCTUnwrap(aliases["\(kindAndID.0):\(kindAndID.1.uuidString)"])
            let key = "\(kindAndID.0):\(wireID.uuidString)"
            XCTAssertNil(replica.records[key]?.payload)
            try replica.mergeRecord(.init(revision: .init(counter: 50, author: UUID()), payload: original[key]), key: key, accountIdentifier: "A")
        }
        let restored = try identity.localPackage(from: replica)
        XCTAssertTrue(restored.accounts.contains { $0.id == accountID })
        XCTAssertTrue(restored.categories.contains { $0.id == categoryID })
        XCTAssertTrue(restored.tags.contains { $0.id == tagID })
        XCTAssertEqual(restored.transactions.first?.id, importedID)
        try LedgerSnapshotCodec.apply(ValidatedLedgerSnapshot(restored), in: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Account>()).contains { $0.id == accountID })
        XCTAssertTrue(try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).contains { $0.id == categoryID })
        XCTAssertEqual(try context.fetch(FetchDescriptor<FinanceTransaction>()).first?.id, importedID)
    }

    func testIncompleteRemoteRelationshipIsStagedWithoutMutatingLocalLedger() throws {
        let context = try makeContext()
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first)
        let tag = Tag(name: "稍后移除", colorToken: "teal")
        context.insert(tag)
        let transaction = FinanceTransaction(
            type: .expense, amountMinorUnits: 321, occurredAt: Date(timeIntervalSince1970: 0),
            localDayKey: "1970-01-01", timeZoneIdentifier: "UTC", accountID: account.id, tags: [tag]
        )
        context.insert(transaction)
        try context.save()
        var identity = LedgerSyncIdentity()
        var replica = ProtectedLedgerReplica(accountIdentifier: "account")
        try replica.captureLocal(identity.capture(LedgerSnapshotCodec.capture(in: context)))
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context))
        let revision = ProtectedLedgerReplica.Revision(counter: replica.clock + 1, author: UUID())
        try replica.mergeRecord(.init(revision: revision, payload: nil), key: "tags:\(tag.id.uuidString)", accountIdentifier: "account")
        XCTAssertThrowsError(try LedgerSnapshotCodec.apply(identity.localPackage(from: replica), in: context))
        XCTAssertEqual(try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context)), before)
        XCTAssertEqual(transaction.tags.map(\.id), [tag.id])

        var payload = try XCTUnwrap(LedgerSnapshotCodec.capture(in: context).transactions.first)
        payload.tagIDs = []
        try replica.mergeRecord(
            .init(revision: revision, payload: JSONEncoder().encode(payload)),
            key: "transactions:\(transaction.id.uuidString)", accountIdentifier: "account"
        )
        try LedgerSnapshotCodec.apply(identity.localPackage(from: replica), in: context)
        XCTAssertTrue(transaction.tags.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Tag>()), 0)
        XCTAssertEqual(transaction.amountMinorUnits, 321)
    }

    func testProjectionRefusesToOverwriteUnsavedLocalEdits() throws {
        let context = try makeContext()
        let baseline = try LedgerSnapshotCodec.capture(in: context)
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first)
        account.name = "尚未保存的用户编辑"
        XCTAssertThrowsError(try LedgerSnapshotCodec.apply(baseline, in: context))
        XCTAssertEqual(account.name, "尚未保存的用户编辑")
        XCTAssertTrue(context.hasChanges)
    }

    func testProjectionReceiptIsLocalAndCommitsWithTheGraph() throws {
        let context = try makeContext()
        let package = try LedgerSnapshotCodec.capture(in: context)
        let before = try LedgerSnapshotCodec.records(package)
        let id = UUID()
        try LedgerSnapshotCodec.apply(package, in: context, projectionID: id)
        XCTAssertEqual(try LedgerSnapshotCodec.committedProjectionID(in: context), id)
        XCTAssertEqual(try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context)), before)
        let invalid = NativeBackupPackage(
            manifest: package.manifest, accounts: [], categories: package.categories,
            tags: [], merchants: [], importBatches: [], transactions: [], dailyReviews: [],
            appMetadata: package.appMetadata
        )
        XCTAssertThrowsError(try LedgerSnapshotCodec.apply(invalid, in: context, projectionID: UUID()))
        XCTAssertEqual(try LedgerSnapshotCodec.committedProjectionID(in: context), id)
    }

    func testIncrementalProjectionKeepsUnchangedTagsAndOtherRowsInLargeLedger() async throws {
        let context = try makeContext()
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first)
        let tag = Tag(name: "保留关联", colorToken: "teal")
        context.insert(tag)
        for index in 0..<5_000 {
            context.insert(FinanceTransaction(
                type: .expense, amountMinorUnits: 1, occurredAt: Date(timeIntervalSince1970: 0),
                localDayKey: "1970-01-01", timeZoneIdentifier: "UTC", accountID: account.id,
                note: "row-\(index)", tags: index == 0 ? [tag] : []
            ))
        }
        try context.save()
        let package = try await LedgerSnapshotReader(modelContainer: context.container).capture()
        var records = try LedgerSnapshotCodec.records(package)
        var payload = try XCTUnwrap(package.transactions.first(where: { $0.note == "row-0" }))
        payload.amountMinorUnits = 7
        let key = "transactions:\(payload.id.uuidString)"
        records[key] = try JSONEncoder().encode(payload)
        let candidate = try ValidatedLedgerSnapshot(LedgerSnapshotCodec.package(from: records))
        let revision = LedgerSaveRevision.shared.revision
        let started = Date()
        try LedgerSnapshotCodec.apply(candidate, in: context, changedKeys: [key], projectionID: UUID())
        let duration = Date().timeIntervalSince(started)
        print("SYNC_BENCHMARK rows=5000 changed=1 apply_seconds=\(duration)")
        XCTAssertGreaterThan(LedgerSaveRevision.shared.revision, revision)
        let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(transactions.count, 5_000)
        XCTAssertEqual(transactions.reduce(Int64(0)) { $0 + $1.amountMinorUnits }, 5_006)
        let changed = try XCTUnwrap(transactions.first { $0.id == payload.id })
        XCTAssertEqual(changed.tags.map(\.id), [tag.id])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Tag>()), 1)
    }

    func testConcurrentDefaultCategoryDeletionMarkersAreUnioned() throws {
        let first = try makeContext()
        let second = try makeContext()
        let firstMetadata = try XCTUnwrap(first.fetch(FetchDescriptor<AppMetadata>()).first)
        let secondMetadata = try XCTUnwrap(second.fetch(FetchDescriptor<AppMetadata>()).first)
        firstMetadata.deletedDefaultCategoryKeys = ["deleted-a"]
        secondMetadata.deletedDefaultCategoryKeys = ["deleted-b"]
        try first.save()
        try second.save()
        var firstIdentity = LedgerSyncIdentity()
        var secondIdentity = LedgerSyncIdentity()
        var firstReplica = ProtectedLedgerReplica(accountIdentifier: "account")
        var secondReplica = ProtectedLedgerReplica(accountIdentifier: "account")
        try firstReplica.captureLocal(firstIdentity.capture(LedgerSnapshotCodec.capture(in: first)))
        try secondReplica.captureLocal(secondIdentity.capture(LedgerSnapshotCodec.capture(in: second)))
        try firstReplica.merge(secondReplica)
        let result = try firstIdentity.localPackage(from: firstReplica)
        XCTAssertEqual(result.appMetadata.first?.deletedDefaultCategoryKeys, ["deleted-a", "deleted-b"])
    }

    func testMergedCurrencyMismatchAndCategoryCycleAreRejectedBeforeProjection() throws {
        let context = try makeContext()
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first)
        context.insert(FinanceTransaction(
            type: .expense, amountMinorUnits: 100, occurredAt: Date(timeIntervalSince1970: 0),
            localDayKey: "1970-01-01", timeZoneIdentifier: "UTC", accountID: account.id
        ))
        try context.save()
        let package = try LedgerSnapshotCodec.capture(in: context)
        let original = try LedgerSnapshotCodec.records(package)
        _ = try ValidatedLedgerSnapshot(package)
        var currencyRecords = original
        var changedAccount = try XCTUnwrap(package.accounts.first)
        changedAccount.currencyCode = "USD"
        currencyRecords["accounts:\(changedAccount.id.uuidString)"] = try JSONEncoder().encode(changedAccount)
        XCTAssertThrowsError(try ValidatedLedgerSnapshot(LedgerSnapshotCodec.package(from: currencyRecords)))
        var cycleRecords = original
        let roots = package.categories.filter { $0.kind == .expense && $0.parentID == nil }
        XCTAssertGreaterThanOrEqual(roots.count, 2)
        var first = roots[0]
        var second = roots[1]
        first.parentID = second.id
        second.parentID = first.id
        cycleRecords["categories:\(first.id.uuidString)"] = try JSONEncoder().encode(first)
        cycleRecords["categories:\(second.id.uuidString)"] = try JSONEncoder().encode(second)
        XCTAssertThrowsError(try ValidatedLedgerSnapshot(LedgerSnapshotCodec.package(from: cycleRecords)))
        XCTAssertEqual(try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context)), original)
    }

    func testSyncPreparationBenchmarksAt1k5k12k50k() async throws {
        for count in [1_000, 5_000, 12_000, 50_000] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let context = try makeContext()
            let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first)
            let category = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.kind == .expense })
            let date = Date(timeIntervalSince1970: 1_767_225_600)
            for index in 0..<count {
                context.insert(FinanceTransaction(type: .expense, amountMinorUnits: Int64(index + 1), occurredAt: date,
                    localDayKey: "2026-01-01", timeZoneIdentifier: "Asia/Shanghai", accountID: account.id,
                    categoryID: category.id, note: "Synthetic sync benchmark \(index)"))
            }
            try context.save()
            let url = directory.appendingPathComponent("replica.json")
            let session = try PrivateCloudReplicaSession(stateURL: url, accountIdentifier: "benchmark", automaticallySync: false)
            try await session.start(verifiedAccountIdentifier: "benchmark")
            let engine = await session.engine
            try await session.recordFetchCompletion(succeeded: true, syncEngine: XCTUnwrap(engine))
            // No networking or engine state updates in the measured local preparation.
            await session.stop()
            var identity = LedgerSyncIdentity()
            for phase in ["initial", "single-add"] {
                if phase == "single-add" {
                    context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 123, occurredAt: date,
                        localDayKey: "2026-01-01", timeZoneIdentifier: "Asia/Shanghai", accountID: account.id,
                        categoryID: category.id, note: "Synthetic single addition"))
                    try context.save()
                }
                let start = Date()
                let package = try await LedgerSnapshotReader(modelContainer: context.container).capture()
                let captured = Date()
                let records = try LedgerSnapshotCodec.records(package)
                let wire = try identity.capture(package)
                try JSONEncoder().encode(identity).write(to: directory.appendingPathComponent("identities.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                let encoded = Date()
                try await session.captureLocal(wire)
                let completed = Date()
                let persist = await session.lastPersistenceDuration
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let replica = await session.snapshot()
                XCTAssertEqual(package.transactions.count, count + (phase == "single-add" ? 1 : 0))
                XCTAssertEqual(replica.livePayloads.count, records.count)
                XCTAssertEqual(replica.clock, phase == "initial" ? 1 : 2)
                print("SYNC_BENCH count=\(count) phase=\(phase) capture_s=\(captured.timeIntervalSince(start)) encode_identity_s=\(encoded.timeIntervalSince(captured)) replica_capture_s=\(completed.timeIntervalSince(encoded)) persist_s=\(persist) total_s=\(completed.timeIntervalSince(start)) state_bytes=\(size)")
            }
        }
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        try DefaultFinanceDataService.ensureDefaults(in: context)
        return context
    }
}
