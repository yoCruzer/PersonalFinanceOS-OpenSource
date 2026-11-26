import CloudKit
import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class Build23SyncRecoveryTests: XCTestCase {
    func testRestrictedAccountKeepsPermanentErrorEvidence() {
        XCTAssertThrowsError(try ICloudSyncController.requireAvailableAccount(.restricted)) { error in
            XCTAssertEqual((error as? CKError)?.code, .permissionFailure)
            XCTAssertFalse(SyncFailure.capture(error, phase: "activation").retryable)
        }
    }

    func testTemporaryAccountUnavailabilityKeepsServiceStatus() {
        XCTAssertNoThrow(try ICloudSyncController.requireAvailableAccount(.available))
        for status in [CKAccountStatus.temporarilyUnavailable, .couldNotDetermine] {
            XCTAssertThrowsError(try ICloudSyncController.requireAvailableAccount(status)) { error in
                XCTAssertEqual((error as? CKError)?.code, .accountTemporarilyUnavailable)
                XCTAssertTrue(SyncFailure.capture(error, phase: "activation").retryable)
            }
        }
    }

    func testMissingAccountNeedsUserActionRatherThanAutomaticActivationRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try PrivateCloudReplicaSession(stateURL: root.appendingPathComponent("state.json"), accountIdentifier: "synthetic", automaticallySync: false)
        let controller = ICloudSyncController(confirmedSession: session, identity: LedgerSyncIdentity(), identityURL: root.appendingPathComponent("identity.json"))
        controller.activationVerification = { try ICloudSyncController.requireAvailableAccount(.noAccount); throw CKError(.internalError) }
        await controller.activate()
        XCTAssertEqual(controller.status, .error)
        XCTAssertEqual(controller.displaySnapshot.stage, .error)
        XCTAssertEqual(controller.lastFailure?.code, CKError.Code.notAuthenticated.rawValue)
        XCTAssertEqual(controller.lastFailure?.retryable, false)
        await controller.disable()
    }

    func testTerminalSessionIsReplacedThroughVerifiedActivation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try PrivateCloudReplicaSession(stateURL: root.appendingPathComponent("old.json"),
            accountIdentifier: "synthetic", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let old = await session.engine
        let engine = try XCTUnwrap(old)
        await session.recordOperationResult(errors: [CKError(.permissionFailure)], syncEngine: engine)
        let controller = ICloudSyncController(confirmedSession: session, identity: LedgerSyncIdentity(),
            identityURL: root.appendingPathComponent("identity.json"))
        var verified = false
        controller.activationVerification = {
            verified = true
            throw CKError(.networkUnavailable)
        }
        await controller.activate()
        XCTAssertTrue(verified, "A retained terminal session must enter real account verification on retry")
        XCTAssertEqual(controller.status, .retrying)
        await controller.disable()
    }

    func testMissingZoneIsRecoverableAndDoesNotEndorseAnEmptyGraph() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try PrivateCloudReplicaSession(stateURL: root.appendingPathComponent("state.json"),
            accountIdentifier: "synthetic", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let value = await session.engine
        let engine = try XCTUnwrap(value)
        await session.recordOperationResult(errors: [CKError(.zoneNotFound)], syncEngine: engine, phase: .download)
        let current = await session.engine
        XCTAssertTrue(current === engine, "Missing cloud zone must retain a recoverable engine")
        let evidence = await session.syncEvidence()
        XCTAssertFalse(evidence.currentFetchSucceeded)
        XCTAssertFalse(evidence.canConfirm)
        XCTAssertFalse(engine.state.pendingDatabaseChanges.isEmpty)
        await session.stop()
    }
    func testVerifiedRetryActuallyCreatesUsableSessionAndIgnoresOldCallbacks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "icloudSyncConfirmedAccount.Development"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("synthetic", forKey: key)
        let old = try PrivateCloudReplicaSession(stateURL: root.appendingPathComponent("old.json"),
            accountIdentifier: "synthetic", automaticallySync: false)
        try await old.start(verifiedAccountIdentifier: "synthetic")
        let value = await old.engine
        let engine = try XCTUnwrap(value)
        await old.recordOperationResult(errors: [CKError(.permissionFailure)], syncEngine: engine)
        let controller = ICloudSyncController(confirmedSession: old, identity: LedgerSyncIdentity(),
            identityURL: root.appendingPathComponent("identities.json"))
        controller.activationVerification = {
            .init(environment: .development, account: "synthetic", root: root, automaticallySync: false)
        }
        await controller.activate()
        await controller.refreshStatus()
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.displaySnapshot.engineAvailable)
        XCTAssertFalse(controller.displaySnapshot.firstFetchCompleted)
        XCTAssertEqual(controller.displaySnapshot.pendingDatabaseChanges, 1)
        XCTAssertEqual(controller.displaySnapshot.pendingChanges, 0)
        await old.recordOperationResult(errors: [], syncEngine: engine)
        try await old.recordFetchCompletion(succeeded: true, syncEngine: engine)
        let ignored = await old.syncEvidence()
        XCTAssertFalse(ignored.currentFetchSucceeded)
        XCTAssertFalse(ignored.connected)
        await controller.disable()
        XCTAssertEqual(controller.status, .off)
    }

    func testStartPersistenceFailureCanRetryWithoutRetainingBrokenSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "icloudSyncConfirmedAccount.Development"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("synthetic", forKey: key)
        try Data([0]).write(to: root)
        let old = try PrivateCloudReplicaSession(stateURL: root.appendingPathComponent("old.json"),
            accountIdentifier: "synthetic", automaticallySync: false)
        let controller = ICloudSyncController(confirmedSession: old, identity: LedgerSyncIdentity(),
            identityURL: root.appendingPathComponent("identities.json"))
        controller.activationVerification = {
            .init(environment: .development, account: "synthetic", root: root, automaticallySync: false)
        }
        await controller.activate()
        XCTAssertEqual(controller.status, .error)
        XCTAssertEqual(controller.lastFailure?.phase, "activation")
        try FileManager.default.removeItem(at: root)
        await controller.activate()
        await controller.refreshStatus()
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.displaySnapshot.engineAvailable)
        XCTAssertNil(controller.lastFailure)
        await controller.disable()
    }

    func testAccountChangeRequiresExplicitConfirmationAndCloseDuringVerificationStaysOff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try PrivateCloudReplicaSession(stateURL: root.appendingPathComponent("old.json"),
            accountIdentifier: "synthetic", automaticallySync: false)
        try await old.start(verifiedAccountIdentifier: "synthetic")
        let value = await old.engine
        let engine = try XCTUnwrap(value)
        await old.recordAccountChange(.switchAccounts(previousUser: .init(recordName: "synthetic"),
            currentUser: .init(recordName: "other")), syncEngine: engine)
        let controller = ICloudSyncController(confirmedSession: old, identity: LedgerSyncIdentity(),
            identityURL: root.appendingPathComponent("identities.json"))
        var verified = false
        controller.activationVerification = {
            verified = true
            await controller.disable()
            return .init(environment: .development, account: "other", root: root, automaticallySync: false)
        }
        await controller.activate()
        XCTAssertEqual(controller.status, .accountChanged)
        XCTAssertFalse(verified)
        await controller.activate(allowAccountChange: true)
        XCTAssertTrue(verified)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.status, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudReplicaLocation(root: root,
            environment: .development, account: "other").stateURL.path))
    }

    func testMissingZoneRecoveryRequiresFreshFetchAndProjectionBeforeBusinessSend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try PrivateCloudReplicaSession(stateURL: root.appendingPathComponent("state.json"),
            accountIdentifier: "synthetic", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let value = await session.engine
        let engine = try XCTUnwrap(value)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        let contents = ["transactions:fixture": Data([1])]
        try await session.captureLocal(contents)
        try await session.acknowledgeRecoveryProjection(contents)
        let before = await session.snapshot()
        await session.recordZoneFetchResult(error: CKError(.zoneNotFound), syncEngine: engine)
        let blocked = await session.recordZoneChangeBatch(scope: .all, syncEngine: engine)
        XCTAssertNil(blocked)
        let after = await session.snapshot()
        XCTAssertEqual(before, after, "Cloud zone disappearance must not remove ledger values or tombstones")
        await session.recordDatabaseSendResult(savedZoneIDs: [PrivateCloudReplicaSession.zoneID], errors: [], syncEngine: engine)
        let builtZone = await session.syncEvidence()
        XCTAssertTrue(builtZone.zoneReady)
        XCTAssertFalse(builtZone.currentFetchSucceeded)
        let notApplied = await session.recordZoneChangeBatch(scope: .all, syncEngine: engine)
        XCTAssertNil(notApplied, "Zone creation alone must not publish business records")
        await session.recordZoneFetchResult(error: nil, syncEngine: engine)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        try await session.acknowledgeRecoveryProjection(contents)
        let resumed = await session.recordZoneChangeBatch(scope: .all, syncEngine: engine)
        XCTAssertEqual(resumed?.recordsToSave.count, 1)
        await session.stop()
    }

    func testEmptyAndNoChangeFetchNeedZoneProofButNoModificationEvent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try PrivateCloudReplicaSession(stateURL: root.appendingPathComponent("state.json"),
            accountIdentifier: "synthetic", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let value = await session.engine
        let engine = try XCTUnwrap(value)
        await session.recordFetchStarted(syncEngine: engine)
        try await session.finishFetchRound(syncEngine: engine)
        let uninitialized = await session.syncEvidence()
        XCTAssertFalse(uninitialized.currentFetchSucceeded, "Unconfirmed initialization is not an empty cloud ledger")
        await session.recordDatabaseSendResult(savedZoneIDs: [PrivateCloudReplicaSession.zoneID], errors: [], syncEngine: engine)
        for _ in 0..<2 {
            await session.recordFetchStarted(syncEngine: engine)
            // No database/record modifications: the successful whole fetch is still evidence.
            try await session.finishFetchRound(syncEngine: engine)
            let fetched = await session.syncEvidence()
            XCTAssertTrue(fetched.currentFetchSucceeded)
            XCTAssertFalse(fetched.appliedCurrentFetch)
            try await session.acknowledgeRecoveryProjection([:])
            let applied = await session.syncEvidence()
            XCTAssertTrue(applied.appliedCurrentFetch)
        }
        await session.stop()
    }

    func testFailureWhitelistPreservesPhaseCountsAndRetryWithoutPrivateContents() {
        let error = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 3.5,
            NSLocalizedDescriptionKey: "private ledger text", "secret": "hidden record name"])
        let failures = SyncFailure.grouped([error, error, CKError(.permissionFailure)], phase: "databaseUpload")
        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(failures.first(where: { $0.code == error.code.rawValue })?.count, 2)
        XCTAssertEqual(failures.first(where: { $0.code == error.code.rawValue })?.retryAfter, 3.5)
        let data = try! JSONEncoder().encode(failures)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("private ledger"))
        XCTAssertFalse(text.contains("hidden record"))
    }

}

private extension PrivateCloudReplicaSession {
    @discardableResult
    func acknowledgeRecoveryProjection(_ snapshot: [String: Data]) throws -> ProjectionEvidence {
        let graph = reconcileState(pristine: false)
        return try XCTUnwrap(acknowledgeLocalProjection(snapshot, ifCurrent: graph.token,
            fetchGeneration: graph.fetchGeneration, projectionID: nil))
    }
}
