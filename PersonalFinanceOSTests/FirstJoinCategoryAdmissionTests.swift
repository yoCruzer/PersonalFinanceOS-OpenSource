import CloudKit
import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class FirstJoinCategoryAdmissionTests: XCTestCase {
    func testRetainedManualRequestResumesAfterCategoryResolutionWithoutAnotherClick() async throws {
        let transport = SyntheticSyncTransport()
        let fixture = try await makeFixture(operations: .init(fetchChanges: { try await transport.fetch($0) },
            cancelOperations: { _ in }, sendChanges: { try await transport.send($0, options: $1) }))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await transport.attach(fixture.session)
        fixture.controller.setForeground(true)
        let changes = LedgerChangeCenter()
        await fixture.controller.syncNow(in: fixture.local, changes: changes)
        XCTAssertEqual(fixture.controller.requestPause, .categoryReview)
        XCTAssertTrue(fixture.controller.isSyncRequested)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .categoryReview)
        let before = await transport.counters()
        XCTAssertEqual(before.sends, 0)
        let review = try XCTUnwrap(fixture.controller.categoryReview)
        try await fixture.controller.resolveCategoryReview(id: review.id,
            choices: Dictionary(uniqueKeysWithValues: review.conflicts.map { ($0.id, .local) }),
            in: fixture.local, changes: changes)
        await fixture.controller.waitForRequestWork()
        XCTAssertFalse(fixture.controller.isSyncRequested)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        XCTAssertEqual(try fixture.local.fetch(FetchDescriptor<FinanceTransaction>()).map(\.id), [fixture.transactionID])
        await fixture.controller.disable()
    }

    func testManualRequestIsCoalescedAndStopsAtDisabledActivationBoundary() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let changes = LedgerChangeCenter()
        var activations = 0
        fixture.controller.manualSyncActivated = {
            activations += 1
            await fixture.controller.syncNow(in: fixture.local, changes: changes)
            await fixture.controller.disable()
        }
        await fixture.controller.syncNow(in: fixture.local, changes: changes)
        XCTAssertEqual(activations, 1)
        XCTAssertFalse(fixture.controller.isSyncRequested)
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .off)
        XCTAssertNil(fixture.controller.displaySnapshot.lastConfirmedAt)
    }

    func testCurrentLocalSaveAndOldUploadCallbackCannotKeepConfirmedPresentation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let changes = LedgerChangeCenter()
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        let review = try XCTUnwrap(fixture.controller.categoryReview)
        try await fixture.controller.resolveCategoryReview(id: review.id,
            choices: Dictionary(uniqueKeysWithValues: review.conflicts.map { ($0.id, .local) }),
            in: fixture.local, changes: changes)
        let current = await fixture.session.engine
        let engine = try XCTUnwrap(current)
        var lastRecords: [CKRecord] = []
        for _ in 0..<20 {
            let pending = await fixture.session.syncEvidence()
            if pending.pendingUploads == 0 { break }
            let batch = await fixture.session.recordZoneChangeBatch(scope: .all, syncEngine: engine)
            let records = try XCTUnwrap(batch).recordsToSave
            XCTAssertFalse(records.isEmpty)
            try await fixture.session.recordSavedRecords(records, syncEngine: engine)
            engine.state.remove(pendingRecordZoneChanges: records.map { .saveRecord($0.recordID) })
            lastRecords = records
        }
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        await fixture.controller.refreshStatus()
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        let edit = ModelContext(fixture.local.container)
        let transaction = try XCTUnwrap(edit.fetch(FetchDescriptor<FinanceTransaction>()).first)
        transaction.note = "新合成变化"
        try edit.save()
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .preparing)
        try await fixture.session.recordSavedRecords(lastRecords, syncEngine: engine)
        await fixture.controller.refreshStatus()
        XCTAssertNotEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        await fixture.controller.refreshStatus()
        XCTAssertNotEqual(fixture.controller.displaySnapshot.stage, .confirmed)
        XCTAssertGreaterThan(fixture.controller.displaySnapshot.pendingChanges, 0)
        await fixture.controller.disable()
        try await fixture.session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        await fixture.controller.refreshStatus()
        XCTAssertEqual(fixture.controller.displaySnapshot.stage, .off)
        XCTAssertNil(fixture.controller.displaySnapshot.lastConfirmedAt)
    }

    func testFirstCaptureRetainsRemoteFutureCatalogMarkerWithoutInstallingOrApprovingNodes() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let remoteMetadata = try XCTUnwrap(fixture.remote.fetch(FetchDescriptor<AppMetadata>()).first)
        remoteMetadata.defaultCategorySeedVersion = 99
        try fixture.remote.save()
        var cloud = fixture.cloud
        var remoteIdentity = fixture.remoteIdentity
        try cloud.captureLocal(remoteIdentity.capture(LedgerSnapshotCodec.capture(in: fixture.remote)))
        try await deliver(cloud, to: fixture.session)
        let changes = LedgerChangeCenter()
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        XCTAssertEqual(fixture.controller.status, .needsCategoryReview)
        let local = try LedgerSnapshotCodec.capture(in: ModelContext(fixture.local.container))
        XCTAssertEqual(local.appMetadata.first?.defaultCategorySeedVersion, 99)
        XCTAssertEqual(local.categories.count, 77)
        let awaiting = await fixture.session.snapshot()
        XCTAssertTrue(awaiting.localBaseline.isEmpty)
        XCTAssertEqual(awaiting.clock, cloud.clock)
        let review = try XCTUnwrap(fixture.controller.categoryReview)
        try await fixture.controller.resolveCategoryReview(
            id: review.id, choices: Dictionary(uniqueKeysWithValues: review.conflicts.map { ($0.id, .local) }),
            in: fixture.local, changes: changes
        )
        XCTAssertEqual(fixture.controller.status, .enabled)
        let settled = await fixture.session.snapshot()
        let wirePackage = try LedgerSyncIdentity.wirePackage(from: settled.localBaseline)
        XCTAssertEqual(wirePackage.appMetadata.first?.defaultCategorySeedVersion, 99)
        try DefaultFinanceDataService.ensureDefaults(in: fixture.local)
        let preview = try await CategoryCatalogService.preview(in: fixture.local, sync: fixture.controller)
        XCTAssertFalse(preview.plan.canCommit)
        XCTAssertTrue(preview.plan.entries.allSatisfy { $0.reason == .futureCatalogVersion })
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        let unchanged = await fixture.session.snapshot()
        XCTAssertEqual(unchanged.clock, settled.clock)
        XCTAssertEqual(try ModelContext(fixture.local.container).fetch(FetchDescriptor<PersonalFinanceOS.Category>()).count, 77)
        await fixture.session.stop()
    }

    func testHigherRevisionFromOlderCatalogCannotDowngradeConfirmedFutureMarker() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let changes = LedgerChangeCenter()
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        let review = try XCTUnwrap(fixture.controller.categoryReview)
        try await fixture.controller.resolveCategoryReview(
            id: review.id, choices: Dictionary(uniqueKeysWithValues: review.conflicts.map { ($0.id, .local) }),
            in: fixture.local, changes: changes
        )
        let current = ModelContext(fixture.local.container)
        let metadata = try XCTUnwrap(current.fetch(FetchDescriptor<AppMetadata>()).first)
        metadata.defaultCategorySeedVersion = 99
        try current.save()
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        let known = await fixture.session.snapshot()
        var olderWire = known.localBaseline
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for key in olderWire.keys.filter({ $0.hasPrefix("appMetadata:") }) {
            var payload = try JSONDecoder().decode(NativeBackupPackage.AppMetadataPayload.self, from: XCTUnwrap(olderWire[key]))
            payload.defaultCategorySeedVersion = 3
            payload.updatedAt = Date().addingTimeInterval(3600)
            olderWire[key] = try encoder.encode(payload)
        }
        var cloud = ProtectedLedgerReplica(accountIdentifier: "A")
        try cloud.merge(known)
        try cloud.captureLocal(olderWire)
        XCTAssertGreaterThan(cloud.clock, known.clock)
        try await deliver(cloud, to: fixture.session)
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        XCTAssertEqual(fixture.controller.status, .enabled)
        let after = try LedgerSnapshotCodec.capture(in: ModelContext(fixture.local.container))
        XCTAssertEqual(after.appMetadata.first?.defaultCategorySeedVersion, 99)
        XCTAssertEqual(after.categories.count, 77)
        XCTAssertEqual(after.transactions.map(\.id), [fixture.transactionID])
        let reasserted = await fixture.session.snapshot()
        XCTAssertGreaterThan(reasserted.clock, cloud.clock)
        XCTAssertEqual(try LedgerSyncIdentity.wirePackage(from: reasserted.localBaseline).appMetadata.first?.defaultCategorySeedVersion, 99)
        XCTAssertEqual(try LedgerSyncIdentity.wirePackage(from: reasserted.livePayloads).appMetadata.first?.defaultCategorySeedVersion, 99)
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        let stable = await fixture.session.snapshot()
        XCTAssertEqual(stable.clock, reasserted.clock)
        await fixture.session.stop()
    }

    func testCatalogAdmissionWaitsForRealJoinAndRejectsLaterRemoteArrival() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let changes = LedgerChangeCenter()
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        let pending = try await CategoryCatalogService.preview(in: fixture.local, sync: fixture.controller)
        XCTAssertEqual(pending.plan.readiness, .pendingRemoteGraph)
        XCTAssertFalse(pending.plan.canCommit)
        let review = try XCTUnwrap(fixture.controller.categoryReview)
        try await fixture.controller.resolveCategoryReview(
            id: review.id, choices: Dictionary(uniqueKeysWithValues: review.conflicts.map { ($0.id, .local) }),
            in: fixture.local, changes: changes
        )
        let preview = try await CategoryCatalogService.preview(in: fixture.local, sync: fixture.controller)
        XCTAssertEqual(preview.plan.readiness, .confirmedGraph)
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: ModelContext(fixture.local.container)))
        let revision = changes.revision
        let category = try XCTUnwrap(fixture.remote.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first {
            $0.defaultDefinitionKey == "expense.dining.lunch"
        })
        category.name = "预览期间远端更改"
        try fixture.remote.save()
        var cloud = await fixture.session.snapshot()
        var mapping = fixture.remoteIdentity
        try cloud.captureLocal(mapping.capture(LedgerSnapshotCodec.capture(in: fixture.remote)))
        try await deliver(cloud, to: fixture.session)
        XCTAssertThrowsError(try CategoryCatalogService.commit(
            preview, selected: ["expense.dining.coffee"], in: fixture.local,
            sync: fixture.controller, changes: changes
        ))
        XCTAssertEqual(try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: ModelContext(fixture.local.container))), before)
        XCTAssertEqual(changes.revision, revision)
        await fixture.session.stop()
    }

    func testPartialCatalogUpgradeKeepsWireAliasesAndConfirmedReopenDoesNotFillSkippedNodes() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let changes = LedgerChangeCenter()
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        let review = try XCTUnwrap(fixture.controller.categoryReview)
        try await fixture.controller.resolveCategoryReview(
            id: review.id, choices: Dictionary(uniqueKeysWithValues: review.conflicts.map { ($0.id, .local) }),
            in: fixture.local, changes: changes
        )
        let identityURL = fixture.directory.appendingPathComponent("identity.json")
        let oldIdentity = try JSONDecoder().decode(LedgerSyncIdentity.self, from: Data(contentsOf: identityURL))
        let preview = try await CategoryCatalogService.preview(in: fixture.local, sync: fixture.controller)
        XCTAssertEqual(preview.plan.readiness, .confirmedGraph)
        XCTAssertEqual(try CategoryCatalogService.commit(
            preview, selected: ["expense.dining.coffee"], in: fixture.local,
            sync: fixture.controller, changes: changes
        ), 1)
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        XCTAssertEqual(fixture.controller.status, .enabled)
        let identity = try JSONDecoder().decode(LedgerSyncIdentity.self, from: Data(contentsOf: identityURL))
        for (key, wireID) in oldIdentity.localToWire {
            XCTAssertEqual(identity.localToWire[key], wireID)
        }
        let beforeReopen = await fixture.session.snapshot()
        await fixture.session.stop()
        let reopened = try PrivateCloudReplicaSession(
            stateURL: fixture.directory.appendingPathComponent("replica.json"), accountIdentifier: "A", automaticallySync: false
        )
        try await reopened.start(verifiedAccountIdentifier: "A")
        let controller = ICloudSyncController(confirmedSession: reopened, identity: identity, identityURL: identityURL)
        let context = ModelContext(fixture.local.container)
        try DefaultFinanceDataService.ensureDefaults(in: context)
        await controller.reconcile(in: context, changes: changes)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertNil(controller.categoryReview)
        let after = try LedgerSnapshotCodec.capture(in: ModelContext(context.container))
        XCTAssertEqual(after.categories.count, 78)
        XCTAssertEqual(after.transactions.map(\.id), [fixture.transactionID])
        XCTAssertEqual(after.transactions.first?.amountMinorUnits, 1234)
        XCTAssertFalse(after.categories.contains { $0.defaultDefinitionKey == "expense.dining.tea-drink" })
        XCTAssertEqual(after.appMetadata.first?.defaultCategorySeedVersion, 4)
        let state = await reopened.snapshot()
        XCTAssertEqual(state.localBaseline, beforeReopen.localBaseline)
        XCTAssertEqual(state.clock, beforeReopen.clock)
        XCTAssertNoThrow(try NativeBackupService.validate(after))
        await reopened.stop()
    }

    func testNonPristineControllerProtectsCloudPersonalizationBeforeCaptureAndAcceptsExplicitCloudChoice() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: fixture.local))
        let changes = LedgerChangeCenter()
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        XCTAssertEqual(fixture.controller.status, .needsCategoryReview)
        let review = try XCTUnwrap(fixture.controller.categoryReview)
        XCTAssertEqual(review.conflicts.count, 1)
        let paused = await fixture.session.snapshot()
        XCTAssertEqual(paused.clock, fixture.cloud.clock)
        XCTAssertTrue(paused.localBaseline.isEmpty)
        XCTAssertEqual(try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: fixture.local)), before)
        let engine = await fixture.session.engine
        XCTAssertTrue(try XCTUnwrap(engine).state.pendingRecordZoneChanges.isEmpty)

        try await fixture.controller.resolveCategoryReview(
            id: review.id, choices: Dictionary(uniqueKeysWithValues: review.conflicts.map { ($0.id, .remote) }),
            in: fixture.local, changes: changes
        )
        XCTAssertEqual(fixture.controller.status, .enabled)
        XCTAssertNil(fixture.controller.categoryReview)
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(fixture.local.container))
        let category = try XCTUnwrap(package.categories.first { $0.id == fixture.categoryID })
        XCTAssertEqual(category.name, "我的午餐")
        XCTAssertTrue(category.isHidden)
        XCTAssertEqual(category.defaultDefinitionKey, "expense.dining.lunch")
        XCTAssertEqual(package.transactions.map(\.id), [fixture.transactionID])
        XCTAssertEqual(package.transactions.first?.categoryID, fixture.categoryID)
        XCTAssertEqual(package.transactions.first?.amountMinorUnits, 1234)
        let joined = await fixture.session.snapshot()
        XCTAssertFalse(joined.localBaseline.isEmpty)
        XCTAssertNoThrow(try NativeBackupService.validate(package))
        await fixture.session.stop()
        let persistedIdentity = try JSONDecoder().decode(LedgerSyncIdentity.self, from: Data(contentsOf: fixture.directory.appendingPathComponent("identity.json")))
        let reopened = try PrivateCloudReplicaSession(
            stateURL: fixture.directory.appendingPathComponent("replica.json"), accountIdentifier: "A", automaticallySync: false
        )
        try await reopened.start(verifiedAccountIdentifier: "A")
        let reopenedController = ICloudSyncController(
            confirmedSession: reopened, identity: persistedIdentity, identityURL: fixture.directory.appendingPathComponent("identity.json")
        )
        await reopenedController.reconcile(in: ModelContext(fixture.local.container), changes: changes)
        XCTAssertEqual(reopenedController.status, .enabled)
        XCTAssertNil(reopenedController.categoryReview)
        let afterReopen = await reopened.snapshot()
        XCTAssertEqual(afterReopen.clock, joined.clock)
        XCTAssertEqual(afterReopen.localBaseline, joined.localBaseline)
        await reopened.stop()
    }

    func testExplicitLocalChoicePreservesLocalCategoryAndCompleteSnapshot() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let changes = LedgerChangeCenter()
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        let review = try XCTUnwrap(fixture.controller.categoryReview)
        try await fixture.controller.resolveCategoryReview(
            id: review.id, choices: Dictionary(uniqueKeysWithValues: review.conflicts.map { ($0.id, .local) }),
            in: fixture.local, changes: changes
        )
        XCTAssertEqual(fixture.controller.status, .enabled)
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(fixture.local.container))
        XCTAssertEqual(package.categories.first { $0.id == fixture.categoryID }?.name, "午餐")
        XCTAssertEqual(package.categories.count, 77)
        XCTAssertEqual(package.transactions.map(\.id), [fixture.transactionID])
        let replica = await fixture.session.snapshot()
        XCTAssertFalse(replica.records.values.contains { $0.payload == nil })
        XCTAssertNoThrow(try NativeBackupService.validate(package))
        await fixture.session.stop()
    }

    func testRemoteArrivalInvalidatesChoiceAndReopenStillRequiresReview() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let changes = LedgerChangeCenter()
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        let review = try XCTUnwrap(fixture.controller.categoryReview)
        let remoteCategory = try XCTUnwrap(fixture.remote.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first {
            $0.defaultDefinitionKey == "expense.dining.lunch"
        })
        remoteCategory.name = "云端再次修改"
        try fixture.remote.save()
        var cloud = fixture.cloud
        var identity = fixture.remoteIdentity
        try cloud.captureLocal(identity.capture(LedgerSnapshotCodec.capture(in: fixture.remote)))
        try await deliver(cloud, to: fixture.session)
        do {
            try await fixture.controller.resolveCategoryReview(
                id: review.id, choices: Dictionary(uniqueKeysWithValues: review.conflicts.map { ($0.id, .remote) }),
                in: fixture.local, changes: changes
            )
            XCTFail("A choice cannot apply to a later cloud graph")
        } catch FirstJoinCategoryAdmission.Failure.staleChoices {}
        XCTAssertEqual(try fixture.local.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first {
            $0.id == fixture.categoryID
        }?.name, "午餐")
        let pending = await fixture.session.snapshot()
        XCTAssertTrue(pending.localBaseline.isEmpty)
        await fixture.session.stop()
        let reopened = try PrivateCloudReplicaSession(
            stateURL: fixture.directory.appendingPathComponent("replica.json"), accountIdentifier: "A", automaticallySync: false
        )
        try await reopened.start(verifiedAccountIdentifier: "A")
        let controller = ICloudSyncController(
            confirmedSession: reopened, identity: LedgerSyncIdentity(), identityURL: fixture.directory.appendingPathComponent("identity.json")
        )
        await controller.reconcile(in: fixture.local, changes: changes)
        XCTAssertEqual(controller.status, .needsCategoryReview)
        XCTAssertEqual(controller.categoryReview?.conflicts.first?.remote?.name, "云端再次修改")
        let afterReopen = await reopened.snapshot()
        XCTAssertTrue(afterReopen.localBaseline.isEmpty)
        await reopened.stop()
    }

    func testLocalSaveInvalidatesReviewWithoutLosingTheNewNote() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let changes = LedgerChangeCenter()
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        let review = try XCTUnwrap(fixture.controller.categoryReview)
        let transaction = try XCTUnwrap(fixture.local.fetch(FetchDescriptor<FinanceTransaction>()).first)
        var draft = TransactionDraft(transaction: transaction)
        draft.note = "审阅期间保存的新备注"
        _ = try TransactionLifecycleService.save(
            draft: draft, editing: transaction,
            accounts: fixture.local.fetch(FetchDescriptor<Account>()),
            categories: fixture.local.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), in: fixture.local
        )
        do {
            try await fixture.controller.resolveCategoryReview(
                id: review.id, choices: Dictionary(uniqueKeysWithValues: review.conflicts.map { ($0.id, .remote) }),
                in: fixture.local, changes: changes
            )
            XCTFail("A review of older ledger contents cannot replace a later local save")
        } catch FirstJoinCategoryAdmission.Failure.staleChoices {}
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(fixture.local.container))
        XCTAssertEqual(package.transactions.first?.note, draft.note)
        XCTAssertEqual(package.transactions.first?.amountMinorUnits, 1234)
        XCTAssertEqual(package.categories.first { $0.id == fixture.categoryID }?.name, "午餐")
        let replica = await fixture.session.snapshot()
        XCTAssertTrue(replica.localBaseline.isEmpty)
        await fixture.session.stop()
    }

    func testPartialGraphDoesNotCaptureOrInstallMissingCategories() async throws {
        let fixture = try await makeFixture(deliverCompleteGraph: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: fixture.local))
        await fixture.controller.reconcile(in: fixture.local, changes: LedgerChangeCenter())
        XCTAssertEqual(fixture.controller.status, .pendingRelationships)
        XCTAssertNil(fixture.controller.categoryReview)
        let replica = await fixture.session.snapshot()
        XCTAssertTrue(replica.localBaseline.isEmpty)
        XCTAssertEqual(replica.records.count, 1)
        XCTAssertEqual(try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: fixture.local)), before)
        await fixture.session.stop()
    }

    func testCloudDeletionNeedsReviewAndCannotEraseLocallyReferencedCategory() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let remoteCategoryID = try XCTUnwrap(fixture.remote.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first {
            $0.defaultDefinitionKey == "expense.dining.lunch"
        }?.id)
        _ = try await MetadataMutationActor(modelContainer: fixture.remote.container).deleteCategory(id: remoteCategoryID, targetID: nil)
        var cloud = fixture.cloud
        var identity = fixture.remoteIdentity
        try cloud.captureLocal(identity.capture(LedgerSnapshotCodec.capture(in: ModelContext(fixture.remote.container))))
        try await deliver(cloud, to: fixture.session)
        let changes = LedgerChangeCenter()
        await fixture.controller.reconcile(in: fixture.local, changes: changes)
        let review = try XCTUnwrap(fixture.controller.categoryReview)
        XCTAssertEqual(review.conflicts.count, 1)
        XCTAssertTrue(try XCTUnwrap(review.conflicts.first).remoteDeleted)
        do {
            try await fixture.controller.resolveCategoryReview(
                id: review.id, choices: Dictionary(uniqueKeysWithValues: review.conflicts.map { ($0.id, .remote) }),
                in: fixture.local, changes: changes
            )
            XCTFail("Cloud deletion may not remove a category still referenced by the local transaction")
        } catch let error as NativeBackupError {
            guard case .invalidReference = error else { throw error }
        }
        let beforeChoice = await fixture.session.snapshot()
        XCTAssertTrue(beforeChoice.localBaseline.isEmpty)
        XCTAssertEqual(beforeChoice.clock, cloud.clock)
        XCTAssertEqual(try fixture.local.fetchCount(FetchDescriptor<FinanceTransaction>()), 1)
        try await fixture.controller.resolveCategoryReview(
            id: review.id, choices: Dictionary(uniqueKeysWithValues: review.conflicts.map { ($0.id, .local) }),
            in: fixture.local, changes: changes
        )
        XCTAssertEqual(fixture.controller.status, .enabled)
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(fixture.local.container))
        XCTAssertEqual(package.transactions.map(\.id), [fixture.transactionID])
        XCTAssertEqual(package.transactions.first?.categoryID, fixture.categoryID)
        XCTAssertEqual(package.categories.first { $0.id == fixture.categoryID }?.name, "午餐")
        XCTAssertTrue(package.appMetadata.first?.deletedDefaultCategoryKeys.contains("expense.dining.lunch") == true)
        XCTAssertNoThrow(try NativeBackupService.validate(package))
        await fixture.session.stop()
    }

    private struct Fixture {
        let directory: URL
        let local: ModelContext
        let remote: ModelContext
        let session: PrivateCloudReplicaSession
        let controller: ICloudSyncController
        let cloud: ProtectedLedgerReplica
        let remoteIdentity: LedgerSyncIdentity
        let categoryID: UUID
        let transactionID: UUID
    }

    private func makeFixture(deliverCompleteGraph: Bool = true, operations: PrivateCloudReplicaSession.EngineOperations? = nil) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: local)
        try DefaultFinanceDataService.ensureDefaults(in: local)
        let account = try XCTUnwrap(local.fetch(FetchDescriptor<Account>()).first)
        let category = try XCTUnwrap(local.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first {
            $0.defaultDefinitionKey == "expense.dining.lunch"
        })
        let transaction = FinanceTransaction(
            type: .expense, amountMinorUnits: 1234, occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            localDayKey: "2023-11-14", timeZoneIdentifier: "UTC", accountID: account.id, categoryID: category.id
        )
        local.insert(transaction)
        try local.save()
        let remote = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: remote)
        try DefaultFinanceDataService.ensureDefaults(in: remote)
        let remoteCategory = try XCTUnwrap(remote.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first {
            $0.defaultDefinitionKey == "expense.dining.lunch"
        })
        remoteCategory.name = "我的午餐"
        remoteCategory.isHidden = true
        try remote.save()
        var remoteIdentity = LedgerSyncIdentity()
        var cloud = ProtectedLedgerReplica(accountIdentifier: "A")
        let wire = try remoteIdentity.capture(LedgerSnapshotCodec.capture(in: remote))
        try cloud.captureLocal(deliverCompleteGraph ? wire : wire.filter { $0.key.hasPrefix("appMetadata:") })
        let session = try PrivateCloudReplicaSession(
            stateURL: directory.appendingPathComponent("replica.json"), accountIdentifier: "A", automaticallySync: false, operations: operations
        )
        try await session.start(verifiedAccountIdentifier: "A")
        try await deliver(cloud, to: session)
        let engine = await session.engine
        try await session.recordFetchCompletion(succeeded: true, syncEngine: XCTUnwrap(engine))
        let controller = ICloudSyncController(
            confirmedSession: session, identity: LedgerSyncIdentity(), identityURL: directory.appendingPathComponent("identity.json")
        )
        return Fixture(directory: directory, local: local, remote: remote, session: session, controller: controller,
                       cloud: cloud, remoteIdentity: remoteIdentity, categoryID: category.id, transactionID: transaction.id)
    }

    private func deliver(_ replica: ProtectedLedgerReplica, to session: PrivateCloudReplicaSession) async throws {
        let records = try replica.records.map { key, value -> CKRecord in
            let record = CKRecord(recordType: PrivateCloudReplicaSession.recordType,
                recordID: .init(recordName: PrivateCloudReplicaSession.recordName(for: key), zoneID: PrivateCloudReplicaSession.zoneID))
            record["envelope"] = try JSONEncoder().encode(PrivateCloudReplicaSession.Envelope(
                format: 1, accountIdentifier: "A", key: key, record: value
            )) as CKRecordValue
            return record
        }
        let engine = await session.engine
        try await session.receiveRemoteRecords(records, syncEngine: XCTUnwrap(engine))
    }
}
