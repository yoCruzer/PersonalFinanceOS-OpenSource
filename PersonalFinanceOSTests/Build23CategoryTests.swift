import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class Build23CategoryTests: XCTestCase {
    func testWaitingAdmissionKeepsExistingInstallationFacts() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: context)
        let sync = ICloudSyncController()
        await sync.disable()
        try sync.prepareEnable()
        let result = try await CategoryCatalogService.completeMissing(in: context, sync: sync, changes: LedgerChangeCenter())
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.installed, 43)
        XCTAssertEqual(result.waiting, 190)
        await sync.disable()
    }

    func testTransportChargingPurposeReusesActualIdentityWithoutMovingIt() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: context)
        let root = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.transportation" })
        let charging = PersonalFinanceOS.Category(kind: .expense, name: "充电", parentID: root.id,
            symbolName: "bolt", colorToken: "purple")
        context.insert(charging)
        try context.save()
        let sync = ICloudSyncController()
        await sync.disable()
        let preview = try await CategoryCatalogService.preview(in: context, sync: sync, additionsOnly: true)
        XCTAssertEqual(preview.plan.reusableIDs["expense.vehicle.charging"], charging.id)
        XCTAssertEqual(preview.plan.entries.first { $0.id == "expense.vehicle.charging" }?.change, CategoryCatalogPlanner.Change.none)
        let old = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context))
        let result = try await CategoryCatalogService.completeMissing(in: context, sync: sync, changes: LedgerChangeCenter())
        XCTAssertEqual(result.added, 189)
        let current = ModelContext(context.container)
        let actual = try current.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertFalse(actual.contains { $0.defaultDefinitionKey == "expense.vehicle.charging" })
        let after = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: current))
        for (key, value) in old where key.hasPrefix("categories:") || key.hasPrefix("transactions:") { XCTAssertEqual(after[key], value) }
        let categories = actual.map { SuggestionCategory(id: $0.id, name: $0.name, kind: $0.kind,
            isActive: $0.isActiveForSelection, parentID: $0.parentID, defaultDefinitionKey: $0.defaultDefinitionKey) }
        let matches = try XCTUnwrap(SemanticClassificationLexicon.bundled).matches(note: "汽车充电", kind: .expense, categories: categories)
        XCTAssertEqual(matches.first { $0.semanticKey == "expense.vehicle.charging" }?.categoryID, charging.id)
        let imported = ImportCategoryResolutionService.resolve(source: .genericCSV, rawCategory: "车辆养护/充电",
            note: "", merchant: "", type: .expense, kind: .expense, categories: actual)
        XCTAssertEqual(imported.resolvedCategoryID, charging.id)
        XCTAssertNil(imported.proposedChildName)
        // The shared planner also protects deletion intent for this reused custom identity.
        _ = try await MetadataMutationActor(modelContainer: current.container).deleteCategory(id: charging.id, targetID: nil)
        _ = try await CategoryCatalogService.completeMissing(in: ModelContext(context.container), sync: sync, changes: LedgerChangeCenter())
        XCTAssertFalse(try ModelContext(context.container).fetch(FetchDescriptor<PersonalFinanceOS.Category>()).contains {
            $0.name == "充电"
        })
        await sync.disable()
    }
    func testAmbiguousChargingPurposesStayPreservedWithoutAnotherInsertion() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: context)
        let root = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.transportation" })
        for _ in 0..<2 { context.insert(PersonalFinanceOS.Category(kind: .expense, name: "充电", parentID: root.id, symbolName: "bolt", colorToken: "blue")) }
        try context.save()
        let sync = ICloudSyncController()
        await sync.disable()
        let preview = try await CategoryCatalogService.preview(in: context, sync: sync, additionsOnly: true)
        let entry = try XCTUnwrap(preview.plan.entries.first { $0.id == "expense.vehicle.charging" })
        XCTAssertEqual(entry.reason, .nameConflict)
        XCTAssertFalse(entry.selectedByDefault)
        _ = try await CategoryCatalogService.completeMissing(in: context, sync: sync, changes: LedgerChangeCenter())
        XCTAssertEqual(try ModelContext(context.container).fetch(FetchDescriptor<PersonalFinanceOS.Category>()).filter { $0.name == "充电" }.count, 2)
    }

    func testCloudGraphReadinessResumesCompletionThenSaveAnalysisExportAndReplicaUseNewCategory() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: context)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try PrivateCloudReplicaSession(stateURL: root.appendingPathComponent("state.json"), accountIdentifier: "synthetic", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "synthetic")
        let engineValue = await session.engine
        let engine = try XCTUnwrap(engineValue)
        let sync = ICloudSyncController(confirmedSession: session, identity: LedgerSyncIdentity(), identityURL: root.appendingPathComponent("identity.json"))
        let changes = LedgerChangeCenter()
        let completion = CategoryCompletionState()
        await completion.refresh(in: context, sync: sync, changes: changes)
        XCTAssertEqual(completion.completion?.waiting, 190)
        XCTAssertEqual(completion.completion?.installed, 43)
        let old = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context))
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        await sync.reconcile(in: context, changes: changes)
        await completion.refresh(in: context, sync: sync, changes: changes)
        XCTAssertEqual(completion.completion?.added, 190)
        let current = ModelContext(context.container)
        let actual = try current.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let after = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: current))
        for (key, value) in old where key.hasPrefix("categories:") || key.hasPrefix("transactions:") { XCTAssertEqual(after[key], value) }
        let leaf = try XCTUnwrap(actual.first { $0.defaultDefinitionKey == "expense.health.medicine" })
        XCTAssertTrue(CategoryHierarchy(categories: actual).selectableCategories(kind: .expense).contains { $0.id == leaf.id })
        let accounts = try current.fetch(FetchDescriptor<Account>())
        var draft = TransactionDraft()
        draft.amountText = "12.34"
        draft.categoryID = leaf.id
        draft.accountID = accounts.first?.id
        draft.note = "synthetic new category"
        _ = try TransactionLifecycleService.save(draft: draft, accounts: accounts, categories: actual, in: current)
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let analysis = try await actor.snapshot(filter: LedgerFilter(category: .direct(leaf.id)))
        XCTAssertEqual(analysis.totals.netExpenseMinorUnits, 1234)
        XCTAssertEqual(analysis.transactionIDs.count, 1)
        let csv = String(decoding: try await actor.exportData(snapshot: analysis), as: UTF8.self)
        XCTAssertTrue(csv.contains("药品"))
        await sync.reconcile(in: current, changes: changes)
        let replica = await session.snapshot()
        XCTAssertTrue(replica.livePayloads.keys.contains { $0.hasPrefix("transactions:") })
        let next = try await CategoryCatalogService.preview(in: ModelContext(context.container), sync: sync, additionsOnly: true)
        let inventory: [[String: String]] = next.plan.entries.map { entry in
            let id = next.plan.reusableIDs[entry.id]
            let category = id.flatMap { id in actual.first { $0.id == id } }
            return ["semantic": entry.id, "actualID": id?.uuidString ?? "none",
                "actualPath": category.map { $0.displayPath(in: actual) } ?? "none",
                "installation": entry.installation.rawValue,
                "reason": entry.reason.map { String(describing: $0) } ?? "none",
                "selectable": category.map { String(CategoryHierarchy(categories: actual).isEligibleForSelection($0)) } ?? "false",
                "icon": category?.symbolName ?? "none"]
        }
        XCTAssertEqual(inventory.count, 233)
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: inventory, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Build23-Synthetic-Catalog-Inventory"
        attachment.lifetime = .keepAlways
        add(attachment)
        await sync.disable()
    }

    func testRepeatedUnchangedCompletionDoesNotFillDiagnosticRingWithPreviews() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let sync = ICloudSyncController()
        await sync.disable()
        let state = CategoryCompletionState()
        let before = LocalDiagnostics.shared.report().entries.filter { $0.stage == .catalogPreview }.count
        for _ in 0..<10 { await state.refresh(in: context, sync: sync, changes: LedgerChangeCenter()) }
        let after = LocalDiagnostics.shared.report().entries.filter { $0.stage == .catalogPreview }.count
        XCTAssertLessThanOrEqual(after - before, 1)
    }

}
