import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class CategoryCatalogPlannerTests: XCTestCase {
    func testBundledCatalogPreservesFrozenStorageIdentityAndCounts() throws {
        let catalog = try CategoryCatalog.load()
        XCTAssertEqual(catalog.catalog.count, 26)
        XCTAssertEqual(catalog.definitions.count, 233)
        XCTAssertEqual(catalog.definitions.filter(\.reusesExistingIdentity).count, 43)
        XCTAssertEqual(Set(catalog.legacyMappings.map(\.oldKey)), Set(DefaultFinanceDataService.frozenDefinitions.map(\.key)))
        let fuel = try XCTUnwrap(catalog.definitions.first { $0.semanticKey == "expense.vehicle.fuel" })
        XCTAssertEqual(fuel.storageDefaultKey, "expense.transportation.fuel")
    }

    func testPristineUpgradePlans190InsertionsAndRetainsAll77IdentitiesWithoutSaving() throws {
        let context = try makeContext()
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let snapshot = try snapshot(in: context)
        let revision = LedgerSaveRevision.shared.revision
        let plan = CategoryCatalogPlanner.make(catalog: try .load(), snapshot: snapshot, readiness: .offline)
        XCTAssertTrue(plan.canCommit)
        XCTAssertEqual(plan.entries.filter { $0.change == .insert }.count, 190)
        XCTAssertEqual(plan.retainedLegacyIDs.count, 34)
        XCTAssertEqual(snapshot.categories.count + plan.entries.filter { $0.change == .insert }.count, 267)
        XCTAssertEqual(LedgerSaveRevision.shared.revision, revision)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try self.snapshot(in: context), snapshot)
    }

    func testFutureVersionAndPartialGraphDoNotAuthorizeInstallation() throws {
        let context = try makeContext()
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let current = try snapshot(in: context)
        let catalog = try CategoryCatalog.load()
        let partial = CategoryCatalogPlanner.make(catalog: catalog, snapshot: current, readiness: .pendingRemoteGraph)
        XCTAssertFalse(partial.canCommit)
        XCTAssertTrue(partial.entries.allSatisfy { !$0.selectedByDefault })
        XCTAssertEqual(partial.entries.filter { $0.installation == .installed }.count, 43)
        XCTAssertEqual(partial.entries.filter { $0.installation == .pendingRemoteGraph }.count, 190)
        XCTAssertEqual(partial.entries.count, 233, "Existing installation facts survive a closed admission gate")
        let future = CategoryCatalogPlanner.Snapshot(categories: current.categories, metadata: [.init(id: current.metadata[0].id, seedVersion: 99, deletedKeys: [])])
        let plan = CategoryCatalogPlanner.make(catalog: catalog, snapshot: future, readiness: .confirmedGraph)
        XCTAssertFalse(plan.canCommit)
        XCTAssertTrue(plan.entries.allSatisfy { $0.reason == .futureCatalogVersion && !$0.selectedByDefault })
    }

    func testCustomizedAndHiddenRootsArePreservedAndSuccessorsNeedExplicitChoice() throws {
        let context = try makeContext()
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let dining = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining" })
        dining.name = "自定义用途"
        dining.isHidden = true
        try context.save()
        let plan = CategoryCatalogPlanner.make(catalog: try .load(), snapshot: try snapshot(in: context), readiness: .offline)
        let root = try XCTUnwrap(plan.entries.first { $0.id == "expense.dining" })
        XCTAssertEqual(root.reason, .customized)
        XCTAssertEqual(root.change, .none)
        let coffee = try XCTUnwrap(plan.entries.first { $0.id == "expense.dining.coffee" })
        XCTAssertEqual(coffee.installation, .suppressedByUserIntent)
        XCTAssertEqual(coffee.reason, .inactiveParent)
        XCTAssertFalse(coffee.selectedByDefault)
        XCTAssertEqual(dining.name, "自定义用途")
    }

    func testLegacyDeletionSuppressesUnprovenSuccessorSplitsWithoutCreatingTombstones() throws {
        let context = try makeContext()
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<AppMetadata>()).first)
        metadata.deletedDefaultCategoryKeys = ["expense.dining.child.5"]
        try context.save()
        let before = try snapshot(in: context)
        let plan = CategoryCatalogPlanner.make(catalog: try .load(), snapshot: before, readiness: .offline)
        let coffee = try XCTUnwrap(plan.entries.first { $0.id == "expense.dining.coffee" })
        XCTAssertEqual(coffee.reason, .legacyDeletionNeedsReview)
        XCTAssertFalse(coffee.selectedByDefault)
        XCTAssertEqual(try snapshot(in: context), before)
        XCTAssertEqual(metadata.deletedDefaultCategoryKeys, ["expense.dining.child.5"])
    }

    func testChangedOriginalParentPreventsAutomaticMoveOfItsPristineChild() throws {
        let context = try makeContext()
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let fuel = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.transportation.fuel" })
        let root = try XCTUnwrap(categories.first { $0.id == fuel.parentID })
        try FinanceDataManagementService.rename(category: root, to: "我的出行用途", in: context)
        let plan = CategoryCatalogPlanner.make(catalog: try .load(), snapshot: try snapshot(in: context), readiness: .offline)
        let entry = try XCTUnwrap(plan.entries.first { $0.id == "expense.vehicle.fuel" })
        XCTAssertEqual(entry.change, .none)
        XCTAssertEqual(entry.reason, .customized)
        XCTAssertFalse(entry.selectedByDefault)
    }

    func testDuplicateStoredIdentityCannotAuthorizeAnyCatalogWrite() throws {
        let context = try makeContext()
        try DefaultFinanceDataService.ensureDefaults(in: context)
        context.insert(PersonalFinanceOS.Category(kind: .expense, name: "重复身份", defaultDefinitionKey: "expense.shopping", symbolName: "star", colorToken: "teal"))
        try context.save()
        let plan = CategoryCatalogPlanner.make(catalog: try .load(), snapshot: try snapshot(in: context), readiness: .offline)
        XCTAssertFalse(plan.canCommit)
        XCTAssertTrue(plan.entries.allSatisfy { $0.reason == .duplicateStorageKey && !$0.selectedByDefault })
    }

    private func snapshot(in context: ModelContext) throws -> CategoryCatalogPlanner.Snapshot {
        .init(
            categories: try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).map(MetadataEditSnapshot.CategoryValue.init).sorted { $0.id.uuidString < $1.id.uuidString },
            metadata: try context.fetch(FetchDescriptor<AppMetadata>()).map { .init(id: $0.id, seedVersion: $0.defaultCategorySeedVersion, deletedKeys: $0.deletedDefaultCategoryKeys) }
        )
    }

    private func makeContext() throws -> ModelContext {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: context)
        return context
    }
}
