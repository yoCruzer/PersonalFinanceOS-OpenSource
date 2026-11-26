import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class CategoryCatalogServiceTests: XCTestCase {
    func testApprovedUpgradePreserves77IdentitiesAndExactTransactionPayloads() async throws {
        let (context, sync) = try await fixture()
        let before = try LedgerSnapshotCodec.capture(in: context)
        let changes = LedgerChangeCenter()
        let preview = try await CategoryCatalogService.preview(in: context, sync: sync)
        let selected = Set(preview.plan.entries.filter(\.selectedByDefault).map(\.id))
        let count = try CategoryCatalogService.commit(preview, selected: selected, in: context, sync: sync, changes: changes)
        XCTAssertEqual(count, selected.count)
        let after = try LedgerSnapshotCodec.capture(in: ModelContext(context.container))
        XCTAssertEqual(after.categories.count, 267)
        XCTAssertEqual(Set(before.categories.map(\.id)).intersection(after.categories.map(\.id)).count, 77)
        for old in before.categories {
            XCTAssertEqual(after.categories.first { $0.id == old.id }?.defaultDefinitionKey, old.defaultDefinitionKey)
        }
        let oldRecords = try LedgerSnapshotCodec.records(before).filter { $0.key.hasPrefix("transactions:") }
        let newRecords = try LedgerSnapshotCodec.records(after).filter { $0.key.hasPrefix("transactions:") }
        XCTAssertEqual(oldRecords, newRecords)
        XCTAssertEqual(changes.revision, 1)
        XCTAssertNoThrow(try NativeBackupService.validate(after))
    }

    func testPartialApprovalIsNotImplicitPermissionOnReopen() async throws {
        let (context, sync) = try await fixture()
        let changes = LedgerChangeCenter()
        let preview = try await CategoryCatalogService.preview(in: context, sync: sync)
        XCTAssertEqual(try CategoryCatalogService.commit(preview, selected: ["expense.dining.coffee"], in: context, sync: sync, changes: changes), 1)
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let reopened = ModelContext(context.container)
        let categories = try reopened.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertEqual(categories.count, 78)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<AppMetadata>()).first?.defaultCategorySeedVersion, 4)
        let next = try await CategoryCatalogService.preview(in: reopened, sync: sync)
        XCTAssertEqual(next.plan.entries.first { $0.id == "expense.dining.coffee" }?.change, CategoryCatalogPlanner.Change.none)
        XCTAssertEqual(next.plan.entries.first { $0.id == "expense.dining.tea-drink" }?.installation, .availableNotInstalled)
        XCTAssertEqual(changes.revision, 1)
    }

    func testMetadataChangesRejectOldPlanButUnrelatedCaptureDoesNot() async throws {
        let (context, sync) = try await fixture()
        let changes = LedgerChangeCenter()
        let preview = try await CategoryCatalogService.preview(in: context, sync: sync)
        try saveTransaction(in: context, note: "预览期间记账")
        XCTAssertEqual(try CategoryCatalogService.commit(preview, selected: ["expense.dining.coffee"], in: context, sync: sync, changes: changes), 1)
        let stale = try await CategoryCatalogService.preview(in: context, sync: sync)
        let other = ModelContext(context.container)
        let root = try XCTUnwrap(other.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining" })
        try FinanceDataManagementService.rename(category: root, to: "我的餐饮", in: other, now: root.updatedAt)
        XCTAssertThrowsError(try CategoryCatalogService.commit(stale, selected: ["expense.dining.tea-drink"], in: context, sync: sync, changes: changes))
        let rejection = try XCTUnwrap(LocalDiagnostics.shared.report().entries.last)
        XCTAssertEqual(rejection.stage, .catalogCommit)
        XCTAssertEqual(rejection.flags["commitSucceeded"], false)
        XCTAssertEqual(rejection.codes, ["busyOrStale"])
        XCTAssertFalse(try LocalDiagnostics.shared.json().contains("我的餐饮"))
        let fresh = ModelContext(context.container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).count, 78)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<FinanceTransaction>()).count, 2)
        XCTAssertEqual(changes.revision, 1)
    }

    func testMissingApprovedParentRollsBackEarlierInsertionsAndDoesNotNotify() async throws {
        let (context, sync) = try await fixture()
        let changes = LedgerChangeCenter()
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: ModelContext(context.container)))
        let preview = try await CategoryCatalogService.preview(in: context, sync: sync)
        let root = try XCTUnwrap(preview.plan.entries.first { $0.definition.parentSemanticKey == nil && $0.change == .insert })
        let child = try XCTUnwrap(preview.plan.entries.first { $0.definition.parentSemanticKey == root.id && $0.change == .insert })
        XCTAssertThrowsError(try CategoryCatalogService.commit(preview, selected: ["expense.dining.coffee", child.id], in: context, sync: sync, changes: changes))
        let after = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: ModelContext(context.container)))
        XCTAssertEqual(before, after)
        XCTAssertEqual(changes.revision, 0)
    }

    func testEnablingSyncInvalidatesOfflineApprovalAndUnconfirmedSessionCannotCommit() async throws {
        let (context, sync) = try await fixture()
        let changes = LedgerChangeCenter()
        let preview = try await CategoryCatalogService.preview(in: context, sync: sync)
        try sync.prepareEnable()
        XCTAssertThrowsError(try CategoryCatalogService.commit(preview, selected: ["expense.dining.coffee"], in: context, sync: sync, changes: changes))
        let pending = try await CategoryCatalogService.preview(in: context, sync: sync)
        XCTAssertEqual(pending.plan.readiness, .pendingRemoteGraph)
        XCTAssertFalse(pending.plan.canCommit)
        XCTAssertThrowsError(try CategoryCatalogService.commit(pending, selected: ["expense.dining.coffee"], in: context, sync: sync, changes: changes))
        XCTAssertEqual(try ModelContext(context.container).fetch(FetchDescriptor<PersonalFinanceOS.Category>()).count, 77)
        XCTAssertEqual(changes.revision, 0)
        await sync.disable()
    }

    func testAutomaticCompletionOnlyAddsMissingAndPreservesEveryProtectedField() async throws {
        let (context, sync) = try await fixture()
        let old = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining" })
        old.name = "我的餐饮"
        old.colorToken = "purple"
        old.symbolName = "star"
        old.sortOrder = 999
        try context.save()
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context))
        let changes = LedgerChangeCenter()
        let result = try await CategoryCatalogService.completeMissing(in: context, sync: sync, changes: changes)
        XCTAssertEqual(result.added, 190)
        let after = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: ModelContext(context.container)))
        for (key, value) in before where key.hasPrefix("transactions:") || key.hasPrefix("categories:") {
            XCTAssertEqual(after[key], value, key)
        }
        let second = try await CategoryCatalogService.completeMissing(in: ModelContext(context.container), sync: sync, changes: changes)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(changes.revision, 1)
        XCTAssertEqual(after, try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: ModelContext(context.container))))
    }

    func testInterruptedInsertOnlyPlanRollsBackAndDiskReopenCompletesOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration("CatalogRecovery", schema: AppSchema.schema,
            url: directory.appendingPathComponent("ledger.store"), cloudKitDatabase: .none)
        let context = ModelContext(try ModelContainerFactory.make(configuration: configuration))
        try seedFrozenV3Ledger(in: context)
        let sync = ICloudSyncController()
        await sync.disable()
        let changes = LedgerChangeCenter()
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context))
        let preview = try await CategoryCatalogService.preview(in: context, sync: sync, additionsOnly: true)
        let root = try XCTUnwrap(preview.plan.entries.first { $0.definition.parentSemanticKey == nil && $0.change == .insert })
        let child = try XCTUnwrap(preview.plan.entries.first { $0.definition.parentSemanticKey == root.id && $0.change == .insert })
        XCTAssertThrowsError(try CategoryCatalogService.commit(preview,
            selected: ["expense.dining.coffee", child.id], in: context, sync: sync, changes: changes))
        XCTAssertEqual(before, try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: ModelContext(context.container))))
        XCTAssertEqual(changes.revision, 0)
        let reopened = ModelContext(try ModelContainerFactory.make(configuration: configuration))
        let completed = try await CategoryCatalogService.completeMissing(in: reopened, sync: sync, changes: changes)
        XCTAssertEqual(completed.added, 190)
        let after = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: reopened))
        for (key, value) in before where key.hasPrefix("categories:") || key.hasPrefix("transactions:") {
            XCTAssertEqual(after[key], value, key)
        }
        let secondReopen = ModelContext(try ModelContainerFactory.make(configuration: configuration))
        let retry = try await CategoryCatalogService.completeMissing(in: secondReopen, sync: sync, changes: changes)
        XCTAssertEqual(retry.added, 0)
        XCTAssertEqual(after, try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: secondReopen)))
        XCTAssertNoThrow(try CategoryHierarchy(categories: secondReopen.fetch(FetchDescriptor<PersonalFinanceOS.Category>())).validateAll())
    }

    func testAutomaticCompletionRespectsRelatedDeletionInactiveParentAndCustomPurpose() async throws {
        let (context, sync) = try await fixture()
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let dining = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.dining" })
        dining.isHidden = true
        let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<AppMetadata>()).first)
        metadata.deletedDefaultCategoryKeys.insert("expense.pets.medical")
        metadata.deletedDefaultCategoryKeys.insert("expense.dining.child.5")
        let custom = PersonalFinanceOS.Category(kind: .expense, name: "宠物养护", symbolName: "pawprint", colorToken: "purple")
        context.insert(custom)
        try context.save()
        let before = MetadataEditSnapshot.CategoryValue(custom)
        let preview = try await CategoryCatalogService.preview(in: context, sync: sync, additionsOnly: true)
        XCTAssertEqual(preview.plan.entries.first { $0.id == "expense.dining.coffee" }?.reason, .inactiveParent)
        XCTAssertEqual(preview.plan.entries.first { $0.id == "expense.pets.medical" }?.reason, .deleted)
        XCTAssertTrue(preview.plan.entries.first { $0.id == "expense.health.medicine" }?.selectedByDefault == true)
        let result = try await CategoryCatalogService.completeMissing(in: context, sync: sync, changes: LedgerChangeCenter())
        XCTAssertGreaterThan(result.added, 0)
        let fresh = try ModelContext(context.container).fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertEqual(fresh.filter { $0.name == "宠物养护" && $0.parentID == nil }.count, 1)
        XCTAssertEqual(fresh.first { $0.defaultDefinitionKey == "expense.pets.food" }?.parentID, custom.id)
        XCTAssertFalse(fresh.contains { $0.defaultDefinitionKey == "expense.pets.medical" })
        XCTAssertFalse(fresh.contains { $0.defaultDefinitionKey == "expense.dining.coffee" })
        XCTAssertEqual(fresh.first { $0.id == custom.id }.map(MetadataEditSnapshot.CategoryValue.init), before)
    }

    func testConcurrentCompletionUsesStableWireIdentitiesWithoutDuplicateCategories() async throws {
        let (first, syncA) = try await fixture()
        let (second, syncB) = try await fixture()
        _ = try await CategoryCatalogService.completeMissing(in: first, sync: syncA, changes: LedgerChangeCenter())
        _ = try await CategoryCatalogService.completeMissing(in: second, sync: syncB, changes: LedgerChangeCenter())
        var identityA = LedgerSyncIdentity(), identityB = LedgerSyncIdentity()
        var replicaA = ProtectedLedgerReplica(accountIdentifier: "synthetic"), replicaB = ProtectedLedgerReplica(accountIdentifier: "synthetic")
        try replicaA.captureLocal(identityA.capture(LedgerSnapshotCodec.capture(in: ModelContext(first.container))))
        try replicaB.captureLocal(identityB.capture(LedgerSnapshotCodec.capture(in: ModelContext(second.container))))
        try replicaA.merge(replicaB)
        try replicaB.merge(replicaA)
        XCTAssertEqual(replicaA.records, replicaB.records)
        let merged = try identityA.localPackage(from: replicaA)
        XCTAssertEqual(merged.categories.count, 267)
        XCTAssertEqual(Set(merged.categories.map(\.defaultDefinitionKey)).count, 267)
        XCTAssertNoThrow(try NativeBackupService.validate(merged))
    }

    func testReusedCustomChildDeletionSurvivesDiskReopenAndDoesNotBlockOtherAdditions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration("ReusedDeletion", schema: AppSchema.schema,
            url: directory.appendingPathComponent("ledger.store"), cloudKitDatabase: .none)
        var context: ModelContext? = ModelContext(try ModelContainerFactory.make(configuration: configuration))
        try seedFrozenV3Ledger(in: XCTUnwrap(context))
        let sync = ICloudSyncController()
        await sync.disable()
        let changes = LedgerChangeCenter()
        let root = try XCTUnwrap(context!.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining" })
        let custom = PersonalFinanceOS.Category(kind: .expense, name: "咖啡", parentID: root.id,
            symbolName: "star", colorToken: "purple", sortOrder: 999)
        context!.insert(custom)
        try context!.save()
        let id = custom.id
        let before = MetadataEditSnapshot.CategoryValue(custom)
        let preview = try await CategoryCatalogService.preview(in: context!, sync: sync, additionsOnly: true)
        XCTAssertEqual(preview.plan.reusableIDs["expense.dining.coffee"], id)
        // Apply a partial automatic additions plan; unrelated missing uses remain available.
        XCTAssertEqual(try CategoryCatalogService.commit(preview, selected: ["expense.dining.tea-drink"],
            in: context!, sync: sync, changes: changes), 1)
        XCTAssertEqual(try ModelContext(context!.container).fetch(FetchDescriptor<PersonalFinanceOS.Category>())
            .first { $0.id == id }.map(MetadataEditSnapshot.CategoryValue.init), before)
        _ = try await MetadataMutationActor(modelContainer: context!.container).deleteCategory(id: id, targetID: nil)
        context = nil
        let reopened = ModelContext(try ModelContainerFactory.make(configuration: configuration))
        let next = try await CategoryCatalogService.preview(in: reopened, sync: sync, additionsOnly: true)
        XCTAssertEqual(next.plan.entries.first { $0.id == "expense.dining.coffee" }?.reason, .deleted)
        XCTAssertTrue(next.plan.entries.first { $0.id == "expense.health.medicine" }?.selectedByDefault == true)
        let result = try await CategoryCatalogService.completeMissing(in: reopened, sync: sync, changes: changes)
        XCTAssertGreaterThan(result.added, 0)
        let fresh = ModelContext(reopened.container)
        let rows = try fresh.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertFalse(rows.contains { $0.id == id || $0.defaultDefinitionKey == "expense.dining.coffee" })
        XCTAssertTrue(rows.contains { $0.defaultDefinitionKey == "expense.health.medicine" })
        XCTAssertTrue(try XCTUnwrap(fresh.fetch(FetchDescriptor<AppMetadata>()).first).deletedDefaultCategoryKeys.contains("expense.dining.coffee"))
    }

    func testReusedCustomDeletionIntentConvergesAcrossReplicas() async throws {
        let (first, sync) = try await fixture()
        let root = try XCTUnwrap(first.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining" })
        let custom = PersonalFinanceOS.Category(kind: .expense, name: "咖啡", parentID: root.id, symbolName: "star", colorToken: "purple")
        first.insert(custom)
        try first.save()
        _ = try await CategoryCatalogService.completeMissing(in: first, sync: sync, changes: LedgerChangeCenter())
        var mappingA = LedgerSyncIdentity(), mappingB = LedgerSyncIdentity()
        var replicaA = ProtectedLedgerReplica(accountIdentifier: "synthetic")
        try replicaA.captureLocal(mappingA.capture(LedgerSnapshotCodec.capture(in: ModelContext(first.container))))
        var replicaB = replicaA
        replicaB.beginWritingSession()
        let second = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try LedgerSnapshotCodec.apply(ValidatedLedgerSnapshot(mappingB.localPackage(from: replicaB)), in: second)
        replicaB.acknowledgeLocalProjection(try mappingB.capture(LedgerSnapshotCodec.capture(in: second)))
        _ = try await MetadataMutationActor(modelContainer: first.container).deleteCategory(id: custom.id, targetID: nil)
        try replicaA.captureLocal(mappingA.capture(LedgerSnapshotCodec.capture(in: ModelContext(first.container))))
        try replicaB.merge(replicaA)
        let merged = try mappingB.localPackage(from: replicaB)
        try LedgerSnapshotCodec.apply(ValidatedLedgerSnapshot(merged), in: second)
        _ = try await CategoryCatalogService.completeMissing(in: ModelContext(second.container), sync: sync, changes: LedgerChangeCenter())
        let result = try LedgerSnapshotCodec.capture(in: ModelContext(second.container))
        XCTAssertFalse(result.categories.contains { $0.name == "咖啡" && $0.kind == .expense })
        XCTAssertEqual(try LedgerSnapshotCodec.records(result).filter { $0.key.hasPrefix("transactions:") },
            try LedgerSnapshotCodec.records(merged).filter { $0.key.hasPrefix("transactions:") })
        XCTAssertTrue(try XCTUnwrap(ModelContext(second.container).fetch(FetchDescriptor<AppMetadata>()).first)
            .deletedDefaultCategoryKeys.contains("expense.dining.coffee"))
    }

    func testDeletingReusedInactiveCustomRootSuppressesOnlyItsFamily() async throws {
        for archived in [false, true] {
            let (context, sync) = try await fixture()
            let custom = PersonalFinanceOS.Category(kind: .expense, name: "宠物养护", symbolName: "pawprint", colorToken: "purple")
            custom.isHidden = !archived
            custom.archivedAt = archived ? Date() : nil
            context.insert(custom)
            try context.save()
            let preview = try await CategoryCatalogService.preview(in: context, sync: sync, additionsOnly: true)
            XCTAssertEqual(preview.plan.reusableIDs["expense.pets"], custom.id)
            _ = try await MetadataMutationActor(modelContainer: context.container).deleteCategory(id: custom.id, targetID: nil)
            let next = try await CategoryCatalogService.preview(in: ModelContext(context.container), sync: sync, additionsOnly: true)
            XCTAssertEqual(next.plan.entries.first { $0.id == "expense.pets" }?.reason, .deleted)
            XCTAssertEqual(next.plan.entries.first { $0.id == "expense.pets.food" }?.reason, .deleted)
            XCTAssertTrue(next.plan.entries.first { $0.id == "expense.health.medicine" }?.selectedByDefault == true)
        }
    }

    private func fixture() async throws -> (ModelContext, ICloudSyncController) {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: context)
        try DefaultFinanceDataService.ensureDefaults(in: context)
        try saveTransaction(in: context, note: "历史交易")
        let sync = ICloudSyncController()
        await sync.disable()
        return (context, sync)
    }

    private func saveTransaction(in context: ModelContext, note: String) throws {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        var draft = TransactionDraft()
        draft.amountText = "12.34"
        draft.accountID = accounts.first?.id
        draft.categoryID = categories.first { $0.defaultDefinitionKey == "expense.dining.breakfast" }?.id
        draft.note = note
        _ = try TransactionLifecycleService.save(draft: draft, accounts: accounts, categories: categories, in: context)
    }
}
