import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class DefaultCategoryHierarchyTests: XCTestCase {
    func testNoOpBootstrapDoesNotPublishAnotherSave() throws {
        let context = try makeContext()
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let revision = LedgerSaveRevision.shared.revision
        try DefaultFinanceDataService.ensureDefaults(in: context)
        XCTAssertEqual(LedgerSaveRevision.shared.revision, revision)
        XCTAssertFalse(context.hasChanges)
    }

    func testBootstrapPreservesPendingEditorChangesWithoutSavingThem() throws {
        let context = try makeContext()
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first)
        account.name = "未保存输入"
        XCTAssertThrowsError(try DefaultFinanceDataService.ensureDefaults(in: context)) {
            XCTAssertEqual($0 as? FinanceDataManagementError, .pendingChanges)
        }
        XCTAssertEqual(account.name, "未保存输入")
        XCTAssertTrue(context.hasChanges)
        let fresh = ModelContext(context.container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Account>()).first?.name, "日常账户")
    }

    func testEnsuringDefaultsTwicePreservesDefinitionIconsAndPristineBootstrap() throws {
        let context = try makeContext()

        try DefaultFinanceDataService.ensureDefaults(in: context)
        try DefaultFinanceDataService.ensureDefaults(in: context)

        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let metadata = try context.fetch(FetchDescriptor<AppMetadata>())
        let home = try XCTUnwrap(categories.first {
            $0.defaultDefinitionKey == "expense.household.furniture"
        })
        XCTAssertEqual(home.symbolName, "sofa")
        XCTAssertTrue(DefaultFinanceDataService.isPristineBootstrap(
            accounts: accounts,
            categories: categories,
            appMetadata: metadata
        ))
    }

    func testBlankStoreSeedsCompleteTwoLevelDefaultsOnce() throws {
        let context = try makeContext()

        try DefaultFinanceDataService.ensureDefaults(in: context)
        try DefaultFinanceDataService.ensureDefaults(in: context)

        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let hierarchy = CategoryHierarchy(categories: categories)
        XCTAssertNoThrow(try hierarchy.validateAll())
        XCTAssertEqual(categories.filter { $0.kind == .expense }.count, 198)
        XCTAssertEqual(categories.filter { $0.kind == .income }.count, 35)
        XCTAssertEqual(
            categories.filter { $0.kind == .expense && $0.parentID == nil }.map(\.name).sorted(),
            try CategoryCatalog.load().catalog.filter { $0.kind == .expense }.map(\.displayName).sorted()
        )

        let dining = try XCTUnwrap(categories.first {
            $0.kind == .expense && $0.defaultDefinitionKey == "expense.dining" && $0.parentID == nil
        })
        XCTAssertEqual(
            hierarchy.children(of: dining).map(\.name),
            ["早餐", "午餐", "晚餐", "夜宵", "正餐（未分餐次）", "咖啡", "奶茶", "饮料饮水", "零食烘焙", "水果", "酒水", "其他餐饮"]
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AppMetadata>()).first?.defaultCategorySeedVersion,
            DefaultFinanceDataService.currentCategorySeedVersion
        )
        let systemKeys = categories.filter(\.isSystemCategory).map(\.defaultDefinitionKey)
        XCTAssertTrue(systemKeys.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(systemKeys).count, systemKeys.count)
        XCTAssertTrue(systemKeys.contains("expense.dining.fruit"))
        XCTAssertFalse(systemKeys.contains { $0.contains(".child.") })
    }

    func testFrozenV3LexiconStillCoversEveryLegacyNonOtherChildPath() throws {
        let context = try makeContext()
        try seedFrozenV3Ledger(in: context)
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let categoriesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let expectedPaths = Set(categories.compactMap { category -> String? in
            guard category.parentID != nil,
                  !category.name.hasPrefix("其他"),
                  let root = categoriesByID[category.parentID!] else {
                return nil
            }
            return "\(category.kind.rawValue)|\(root.name)|\(category.name)"
        })

        XCTAssertEqual(SmartClassificationLexicon.coveredPaths, expectedPaths)
        XCTAssertEqual(expectedPaths.count, 55)
    }

    func testDeletedDefaultDoesNotReappear() throws {
        let context = try makeContext()
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let fruit = try XCTUnwrap(categories.first { $0.name == "水果" })
        let deletedID = fruit.id

        let definitionKey = fruit.defaultDefinitionKey
        try FinanceDataManagementService.permanentlyDelete(category: fruit, in: context)
        let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<AppMetadata>()).first)
        XCTAssertTrue(metadata.deletedDefaultCategoryKeys.contains(definitionKey))
        metadata.defaultCategorySeedVersion = 0
        try context.save()
        try DefaultFinanceDataService.ensureDefaults(in: context)

        let reloaded = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertFalse(reloaded.contains { $0.id == deletedID || $0.name == "水果" })
    }

    func testDeletedDefaultTombstoneDoesNotConflictWithUserRecreatedName() throws {
        let context = try makeContext()
        try DefaultFinanceDataService.ensureDefaults(in: context)
        var categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let fruit = try XCTUnwrap(categories.first { $0.name == "水果" })
        let diningID = try XCTUnwrap(fruit.parentID)
        try FinanceDataManagementService.permanentlyDelete(category: fruit, in: context)

        categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        _ = try FinanceDataManagementService.addCategory(
            name: "水果",
            kind: .expense,
            parentID: diningID,
            categories: categories,
            in: context
        )
        let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<AppMetadata>()).first)
        metadata.defaultCategorySeedVersion = 0
        try context.save()
        try DefaultFinanceDataService.ensureDefaults(in: context)

        let reloaded = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
            .filter { $0.name == "水果" && $0.parentID == diningID }
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertFalse(reloaded[0].isSystemCategory)
        XCTAssertTrue(reloaded[0].defaultDefinitionKey.isEmpty)
    }

    func testOrdinalKeysAndTombstonesMigrateToStableSemanticKeys() throws {
        let context = try makeContext()
        let dining = PersonalFinanceOS.Category(
            kind: .expense,
            name: "餐饮",
            defaultDefinitionKey: "expense.dining",
            symbolName: "fork.knife",
            colorToken: "orange",
            isSystemCategory: true
        )
        let fruit = PersonalFinanceOS.Category(
            kind: .expense,
            name: "水果",
            parentID: dining.id,
            defaultDefinitionKey: "expense.dining.child.4",
            symbolName: "apple.logo",
            colorToken: "orange",
            isSystemCategory: true
        )
        let metadata = AppMetadata(
            defaultCategorySeedVersion: 2,
            deletedDefaultCategoryKeys: ["expense.dining.child.1"]
        )
        context.insert(dining)
        context.insert(fruit)
        context.insert(metadata)
        try context.save()

        try DefaultFinanceDataService.ensureDefaults(in: context)

        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertEqual(categories.first { $0.id == fruit.id }?.defaultDefinitionKey, "expense.dining.fruit")
        XCTAssertFalse(categories.contains { $0.parentID == dining.id && $0.name == "午餐" })
        let storedMetadata = try XCTUnwrap(ModelContext(context.container).fetch(FetchDescriptor<AppMetadata>()).first)
        XCTAssertTrue(storedMetadata.deletedDefaultCategoryKeys.contains("expense.dining.lunch"))
        XCTAssertFalse(storedMetadata.deletedDefaultCategoryKeys.contains("expense.dining.child.1"))
    }

    func testExistingUserRootWithDefaultNameIsReusedWithoutDuplicate() throws {
        let context = try makeContext()
        let customDining = PersonalFinanceOS.Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        context.insert(customDining)
        try context.save()

        try DefaultFinanceDataService.ensureDefaults(in: context)

        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertEqual(categories.filter { $0.kind == .expense && $0.name == "餐饮" }.count, 1)
        XCTAssertFalse(customDining.isSystemCategory)
        XCTAssertEqual(categories.filter { $0.parentID == customDining.id }.count, 8)
    }

    func testLegacyDefaultUpgradePreservesTransactionAndCategoryIdentity() throws {
        let context = try makeContext()
        let account = Account(name: "现金", type: .cash, isDefault: true)
        let legacyHousing = PersonalFinanceOS.Category(
            kind: .expense,
            name: "居住",
            symbolName: "house",
            colorToken: "teal",
            isSystemCategory: true
        )
        let transaction = FinanceTransaction(
            type: .expense,
            amountMinorUnits: 12_345,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            localDayKey: "2023-11-15",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: account.id,
            categoryID: legacyHousing.id,
            note: "旧账"
        )
        context.insert(account)
        context.insert(legacyHousing)
        context.insert(transaction)
        try context.save()

        try DefaultFinanceDataService.ensureDefaults(in: context)

        let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions[0].amountMinorUnits, 12_345)
        XCTAssertEqual(transactions[0].note, "旧账")
        XCTAssertEqual(transactions[0].categoryID, legacyHousing.id)
        XCTAssertEqual(categories.first { $0.id == legacyHousing.id }?.name, "居家")
        XCTAssertNil(categories.first { $0.id == legacyHousing.id }?.parentID)
    }

    func testCategoryCreationValidatesDepthTypeAndSiblingNameScope() throws {
        let context = try makeContext()
        try DefaultFinanceDataService.ensureDefaults(in: context)
        var categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let dining = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.dining" && $0.parentID == nil })
        let travel = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.travel" && $0.parentID == nil })
        let income = try XCTUnwrap(categories.first { $0.kind == .income && $0.parentID == nil })

        let diningChild = try FinanceDataManagementService.addCategory(
            name: "自定义",
            kind: .expense,
            parentID: dining.id,
            categories: categories,
            in: context
        )
        categories.append(diningChild)

        XCTAssertThrowsError(try FinanceDataManagementService.addCategory(
            name: "自定义",
            kind: .expense,
            parentID: dining.id,
            categories: categories,
            in: context
        )) {
            XCTAssertEqual($0 as? FinanceDataManagementError, .duplicateName)
        }
        XCTAssertNoThrow(try FinanceDataManagementService.addCategory(
            name: "自定义",
            kind: .expense,
            parentID: travel.id,
            categories: categories,
            in: context
        ))
        XCTAssertThrowsError(try FinanceDataManagementService.addCategory(
            name: "第三层",
            kind: .expense,
            parentID: diningChild.id,
            categories: categories,
            in: context
        )) {
            XCTAssertEqual($0 as? CategoryHierarchyError, .parentIsChild)
        }
        XCTAssertThrowsError(try FinanceDataManagementService.addCategory(
            name: "类型不符",
            kind: .expense,
            parentID: income.id,
            categories: categories,
            in: context
        )) {
            XCTAssertEqual($0 as? CategoryHierarchyError, .kindMismatch)
        }
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(
            "DefaultHierarchy-\(UUID().uuidString)",
            schema: AppSchema.schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AppSchema.schema,
            configurations: [configuration]
        )
        return ModelContext(container)
    }
}
