import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class ImportCategoryMappingValidityTests: XCTestCase {
    private var retainedContext: ModelContext?
    private let key = ImportCategoryMappingStore.stableKey(source: .genericCSV, rawCategory: "工作餐", kind: .expense)

    func testCacheReopenAndKnownSynonymousRenameRetainExplicitMapping() throws {
        let (categories, lunch, root) = try fixture()
        let suite = "MappingValidity.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(remember(lunch, categories: categories, defaults: defaults))
        XCTAssertEqual(mappings(categories, defaults: UserDefaults(suiteName: suite)!)[key], lunch.id)
        root.name = "餐饮"
        XCTAssertEqual(mappings(categories, defaults: defaults)[key], lunch.id)
        lunch.colorToken = "green"
        lunch.sortOrder += 10
        XCTAssertEqual(mappings(categories, defaults: defaults)[key], lunch.id)
    }

    func testRepurposeHiddenParentMissingTargetAndRecreatedIdentityCannotReuseCache() throws {
        let (categories, lunch, root) = try fixture()
        let suite = "MappingValidity.\(UUID())"
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        XCTAssertTrue(remember(lunch, categories: categories, defaults: isolated))
        let bytes = isolated.data(forKey: "importCategoryMappings.v2")
        lunch.name = "设备投资"
        XCTAssertNil(mappings(categories, defaults: isolated)[key])
        lunch.name = "午餐"
        root.isHidden = true
        XCTAssertNil(mappings(categories, defaults: isolated)[key])
        root.isHidden = false
        XCTAssertNil(mappings(categories.filter { $0.id != lunch.id }, defaults: isolated)[key])
        lunch.createdAt = lunch.createdAt.addingTimeInterval(1)
        XCTAssertNil(mappings(categories, defaults: isolated)[key])
        XCTAssertEqual(bytes, isolated.data(forKey: "importCategoryMappings.v2"))
    }

    func testRestoreGenerationRejectsDelayedRememberAndRetainsOldBytesForReview() throws {
        let (categories, lunch, _) = try fixture()
        let suite = "MappingValidity.\(UUID())"
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let generation = ImportCategoryMappingStore.generation(defaults: isolated)
        XCTAssertTrue(remember(lunch, categories: categories, defaults: isolated))
        let bytes = isolated.data(forKey: "importCategoryMappings.v2")
        ImportCategoryMappingStore.invalidateForRestore(defaults: isolated)
        XCTAssertTrue(mappings(categories, defaults: isolated).isEmpty)
        XCTAssertFalse(ImportCategoryMappingStore.remember(source: .genericCSV, rawCategory: "工作餐", kind: .expense,
            targetID: lunch.id, categories: snapshot(categories), expectedGeneration: generation, defaults: isolated))
        XCTAssertEqual(bytes, isolated.data(forKey: "importCategoryMappings.v2"))
        XCTAssertTrue(remember(lunch, categories: categories, defaults: isolated))
        XCTAssertEqual(mappings(categories, defaults: isolated)[key], lunch.id)
    }

    func testLegacyUUIDOnlyAndUnreadableFutureCacheArePreservedButNeverApplied() throws {
        let (categories, lunch, _) = try fixture()
        let suite = "MappingValidity.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = [key: lunch.id.uuidString]
        defaults.set(legacy, forKey: "importCategoryMappings.v1")
        XCTAssertTrue(mappings(categories, defaults: defaults).isEmpty)
        XCTAssertEqual(defaults.dictionary(forKey: "importCategoryMappings.v1") as? [String: String], legacy)
        for bytes in [Data("broken".utf8), Data("{\"version\":99,\"entries\":{}}".utf8)] {
            defaults.set(bytes, forKey: "importCategoryMappings.v2")
            XCTAssertTrue(mappings(categories, defaults: defaults).isEmpty)
            XCTAssertFalse(remember(lunch, categories: categories, defaults: defaults))
            XCTAssertEqual(defaults.data(forKey: "importCategoryMappings.v2"), bytes)
        }
    }

    private func fixture() throws -> ([PersonalFinanceOS.Category], PersonalFinanceOS.Category, PersonalFinanceOS.Category) {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        retainedContext = context
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let lunch = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.dining.lunch" })
        return (categories, lunch, try XCTUnwrap(categories.first { $0.id == lunch.parentID }))
    }

    private func snapshot(_ categories: [PersonalFinanceOS.Category]) -> [ImportCategorySnapshot] {
        FinanceCSVService.makeImportModelSnapshot(accounts: [], categories: categories, tags: []).categories
    }

    private func mappings(_ categories: [PersonalFinanceOS.Category], defaults: UserDefaults) -> [String: UUID] {
        ImportCategoryMappingStore.mappings(categories: snapshot(categories), defaults: defaults)
    }

    private func remember(_ category: PersonalFinanceOS.Category, categories: [PersonalFinanceOS.Category], defaults: UserDefaults) -> Bool {
        ImportCategoryMappingStore.remember(source: .genericCSV, rawCategory: "工作餐", kind: .expense,
            targetID: category.id, categories: snapshot(categories), defaults: defaults)
    }
}
