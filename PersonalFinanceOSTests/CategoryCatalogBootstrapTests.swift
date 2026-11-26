import SwiftData
import XCTest
import UIKit
@testable import PersonalFinanceOS

@MainActor
final class CategoryCatalogBootstrapTests: XCTestCase {
    func testCatalogSymbolsResolveOnCurrentSystemWithRuntimeFallback() throws {
        for definition in try CategoryCatalog.load().definitions {
            let symbol = CategoryCatalogAppearance.style(for: definition).symbol
            XCTAssertNotNil(UIImage(systemName: CategoryIconLibrary.availableSymbol(symbol)), definition.storageDefaultKey)
        }
        XCTAssertEqual(CategoryIconLibrary.availableSymbol("synthetic-unavailable-symbol"), CategoryIconLibrary.fallback)
        XCTAssertNotNil(UIImage(systemName: CategoryIconLibrary.fallback))
    }

    func testDiskReopenPreservesAllNewCatalogIdentitiesWithoutAnotherSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-bootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration("CatalogBootstrap", schema: AppSchema.schema,
            url: directory.appendingPathComponent("ledger.store"), cloudKitDatabase: .none)
        let original = try autoreleasepool {
            let context = ModelContext(try ModelContainerFactory.make(configuration: configuration))
            try DefaultFinanceDataService.ensureDefaults(in: context)
            return try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context))
        }
        try autoreleasepool {
            let context = ModelContext(try ModelContainerFactory.make(configuration: configuration))
            let revision = LedgerSaveRevision.shared.revision
            try DefaultFinanceDataService.ensureDefaults(in: context)
            XCTAssertEqual(LedgerSaveRevision.shared.revision, revision)
            XCTAssertEqual(original, try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context)))
            XCTAssertTrue(try pristine(context))
        }
    }

    func testNewInstallationSeedsExact233StorageKeysAndMeaningfulIconsOnce() throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let catalog = try CategoryCatalog.load()
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertEqual(categories.count, 233)
        XCTAssertEqual(categories.filter { $0.kind == .expense && $0.parentID == nil }.count, 20)
        XCTAssertEqual(categories.filter { $0.kind == .income && $0.parentID == nil }.count, 6)
        XCTAssertEqual(Set(categories.map(\.defaultDefinitionKey)), Set(catalog.definitions.map(\.storageDefaultKey)))
        XCTAssertTrue(categories.allSatisfy { CategoryIconLibrary.isValidStoredIcon($0.symbolName) && $0.symbolName != CategoryIconLibrary.fallback })
        XCTAssertNoThrow(try CategoryHierarchy(categories: categories).validateAll())
        XCTAssertTrue(try pristine(context))
        let records = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context))
        let revision = LedgerSaveRevision.shared.revision
        try DefaultFinanceDataService.ensureDefaults(in: ModelContext(context.container))
        XCTAssertEqual(LedgerSaveRevision.shared.revision, revision)
        XCTAssertEqual(records, try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: ModelContext(context.container))))
    }

    func testFrozen77LedgerRemainsPristineAndDoesNotSilentlyInstallNewCatalog() throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: context)
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context))
        let revision = LedgerSaveRevision.shared.revision
        try DefaultFinanceDataService.ensureDefaults(in: context)
        XCTAssertEqual(revision, LedgerSaveRevision.shared.revision)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersonalFinanceOS.Category>()), 77)
        XCTAssertTrue(try pristine(context))
        XCTAssertEqual(before, try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context)))
    }

    func testNewCatalogCanBePristineRestoreDestinationButCustomizationCannot() async throws {
        let source = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: source)
        let data = try await NativeBackupActor(modelContainer: source.container).exportData()
        let destination = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: destination)
        let result = try await NativeBackupActor(modelContainer: destination.container).restore(
            data: data, admission: offlineRestoreTicket(for: destination.container))
        XCTAssertEqual(result.insertedCategoryCount, 77)
        try DefaultFinanceDataService.ensureDefaults(in: destination)
        XCTAssertEqual(try ModelContext(destination.container).fetchCount(FetchDescriptor<PersonalFinanceOS.Category>()), 77)
        let fresh = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: fresh)
        let root = try XCTUnwrap(fresh.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.parentID == nil })
        try FinanceDataManagementService.rename(category: root, to: "我的自定义用途", in: fresh)
        XCTAssertFalse(try pristine(ModelContext(fresh.container)))
        do {
            _ = try await NativeBackupActor(modelContainer: fresh.container).restore(data: data, admission: offlineRestoreTicket(for: fresh.container))
            XCTFail("Customized catalog is not a pristine restore destination")
        } catch { XCTAssertEqual(error as? NativeBackupError, .destinationContainsUserLedger) }
    }

    func testNewCatalogDeletionAndFutureVersionNeverRepopulateOnBootstrap() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let target = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining.tea-drink" })
        _ = try await MetadataMutationActor(modelContainer: context.container).deleteCategory(id: target.id, targetID: nil)
        let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<AppMetadata>()).first)
        metadata.defaultCategorySeedVersion = 99
        try context.save()
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let current = ModelContext(context.container)
        XCTAssertEqual(try current.fetchCount(FetchDescriptor<PersonalFinanceOS.Category>()), 232)
        XCTAssertEqual(try current.fetch(FetchDescriptor<AppMetadata>()).first?.defaultCategorySeedVersion, 99)
        XCTAssertFalse(try pristine(current))
    }

    private func pristine(_ context: ModelContext) throws -> Bool {
        try DefaultFinanceDataService.isPristineBootstrap(accounts: context.fetch(FetchDescriptor<Account>()),
            categories: context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), appMetadata: context.fetch(FetchDescriptor<AppMetadata>()))
    }
}
