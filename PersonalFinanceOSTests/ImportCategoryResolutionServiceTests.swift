import XCTest
@testable import PersonalFinanceOS

final class ImportCategoryResolutionServiceTests: XCTestCase {
    @MainActor
    func testImportSnapshotPreservesStorageIdentityIndependentlyOfDisplayPath() {
        let fixture = makeCategories()
        fixture.dining.defaultDefinitionKey = "expense.dining"
        fixture.fruit.defaultDefinitionKey = "expense.dining.fruit"
        fixture.dining.name = "餐饮饮品"
        let snapshot = FinanceCSVService.makeImportModelSnapshot(accounts: [], categories: fixture.all, tags: [])
        XCTAssertEqual(snapshot.categories.first { $0.id == fixture.dining.id }?.defaultDefinitionKey, "expense.dining")
        XCTAssertEqual(snapshot.categories.first { $0.id == fixture.fruit.id }?.defaultDefinitionKey, "expense.dining.fruit")
        XCTAssertEqual(snapshot.categories.first { $0.id == fixture.fruit.id }?.parentID, fixture.dining.id)
        let result = ImportCategoryResolutionService.resolve(
            source: .wacai, rawCategory: "餐饮饮品 / 水果", note: "水果", merchant: "",
            type: .expense, kind: .expense, categories: snapshot.categories
        )
        XCTAssertEqual(result.resolvedCategoryID, fixture.fruit.id)
        XCTAssertNil(result.proposedRootID)
    }

    func testHiddenOrMissingParentRejectsExactPathRememberedMappingAndInference() {
        let fixture = makeCategories()
        fixture.dining.isHidden = true
        for raw in ["餐饮 / 水果", "水果", "买水果"] {
            let result = ImportCategoryResolutionService.resolve(
                source: .wacai, rawCategory: raw, note: "买水果", merchant: "",
                type: .expense, kind: .expense, categories: fixture.all, rememberedCategoryID: fixture.fruit.id
            )
            XCTAssertNil(result.resolvedCategoryID)
            XCTAssertNil(result.proposedRootID)
            XCTAssertTrue(result.requiresReview)
        }
        let missingParent = fixture.all.filter { $0.id != fixture.dining.id }
        XCTAssertNil(resolve("水果", categories: missingParent).resolvedCategoryID)
    }

    func testExactPathAndUniqueChildNameResolveDeterministically() {
        let fixture = makeCategories()
        let path = resolve("购物 / 其他", categories: fixture.all)
        XCTAssertEqual(path.resolvedCategoryID, fixture.shoppingOther.id)
        XCTAssertEqual(path.reason, .exactPath)

        let unique = resolve("水果", categories: fixture.all)
        XCTAssertEqual(unique.resolvedCategoryID, fixture.fruit.id)
        XCTAssertEqual(unique.reason, .uniqueChildName)

        let ambiguous = resolve("其他", categories: fixture.all)
        XCTAssertNil(ambiguous.resolvedCategoryID)
        XCTAssertTrue(ambiguous.requiresReview)
    }

    func testAliasesReuseExistingRootsAndChildren() {
        let fixture = makeCategories()
        fixture.dining.defaultDefinitionKey = "expense.dining"
        fixture.shopping.defaultDefinitionKey = "expense.shopping"
        fixture.baby.defaultDefinitionKey = "expense.shopping.baby-care"
        fixture.housing.defaultDefinitionKey = "expense.home"
        fixture.utilities.defaultDefinitionKey = "expense.home.utilities"
        XCTAssertEqual(
            resolve("母婴用品", categories: fixture.all).resolvedCategoryID,
            fixture.baby.id
        )
        XCTAssertEqual(
            resolve("餐饮美食", categories: fixture.all).resolvedCategoryID,
            fixture.dining.id
        )
        XCTAssertEqual(
            resolve("生活缴费", categories: fixture.all).resolvedCategoryID,
            fixture.utilities.id
        )
    }

    func testKnownRootCanProposeChildButUnknownRootNeverGetsCreated() {
        let fixture = makeCategories()
        let proposed = resolve("餐饮 / 早午餐", categories: fixture.all)
        XCTAssertNil(proposed.resolvedCategoryID)
        XCTAssertEqual(proposed.proposedRootID, fixture.dining.id)
        XCTAssertEqual(proposed.proposedChildName, "早午餐")
        XCTAssertEqual(proposed.confidence, .high)

        let unknown = resolve("全新大类 / 子类", categories: fixture.all)
        XCTAssertNil(unknown.resolvedCategoryID)
        XCTAssertNil(unknown.proposedRootID)
        XCTAssertEqual(unknown.reason, .unresolved)
    }

    @MainActor
    func testRememberedMappingUsesSourceAndNormalizedRawCategory() {
        let defaults = UserDefaults(suiteName: "ImportMapping.\(UUID().uuidString)")!
        let fixture = makeCategories()
        let snapshot = FinanceCSVService.makeImportModelSnapshot(accounts: [], categories: fixture.all, tags: [])
        ImportCategoryMappingStore.remember(
            source: .wacai,
            rawCategory: " 餐饮美食 ",
            kind: .expense,
            targetID: fixture.fruit.id,
            categories: snapshot.categories,
            defaults: defaults
        )
        let mappings = ImportCategoryMappingStore.mappings(categories: snapshot.categories, defaults: defaults)
        let key = ImportCategoryMappingStore.stableKey(
            source: .wacai,
            rawCategory: "餐饮美食",
            kind: .expense
        )
        XCTAssertEqual(mappings[key], fixture.fruit.id)
        XCTAssertNil(mappings[ImportCategoryMappingStore.stableKey(
            source: .wacai,
            rawCategory: "餐饮美食",
            kind: .income
        )])
    }

    func testLegacyRootAliasPreservesCustomChildAfterCatalogRename() {
        let fixture = makeCategories()
        fixture.dining.name = "餐饮饮品"
        fixture.dining.defaultDefinitionKey = "expense.dining"
        let result = resolve("餐饮 / 深审早餐", categories: fixture.all)
        XCTAssertNil(result.resolvedCategoryID)
        XCTAssertEqual(result.proposedRootID, fixture.dining.id)
        XCTAssertEqual(result.proposedChildName, "深审早餐")
        XCTAssertTrue(result.requiresReview)
        let child = category("深审早餐", parentID: fixture.dining.id)
        XCTAssertEqual(resolve("餐饮 / 深审早餐", categories: fixture.all + [child]).resolvedCategoryID, child.id)
        let duplicate = category("深审早餐", parentID: fixture.dining.id)
        let ambiguous = resolve("餐饮 / 深审早餐", categories: fixture.all + [child, duplicate])
        XCTAssertNil(ambiguous.resolvedCategoryID)
        XCTAssertNil(ambiguous.proposedRootID)

        fixture.dining.name = "个人收藏"
        XCTAssertNil(resolve("餐饮 / 自定义项目", categories: fixture.all).proposedRootID)
        fixture.dining.name = "餐饮饮品"
        let conflictingRoot = category("餐饮")
        XCTAssertNil(resolve("餐饮 / 自定义项目", categories: fixture.all + [conflictingRoot]).proposedRootID)
        let breakfast = category("早餐", parentID: fixture.dining.id)
        breakfast.defaultDefinitionKey = "expense.dining.breakfast"
        XCTAssertEqual(resolve("深审早餐", categories: fixture.all + [breakfast]).resolvedCategoryID, breakfast.id)
        let conflictingPath = resolve("餐饮 / 深审早餐", categories: fixture.all + [conflictingRoot, breakfast])
        XCTAssertNil(conflictingPath.resolvedCategoryID, "Explicit root ambiguity cannot fall through to breakfast inference")
        XCTAssertNil(conflictingPath.proposedRootID)
        XCTAssertTrue(conflictingPath.requiresReview)
        fixture.dining.isHidden = true
        XCTAssertNil(resolve("餐饮 / 自定义项目", categories: fixture.all).proposedRootID)
    }

    func testReviewListKeepsEightRowSummaryButSearchesEveryPendingRow() {
        let rows = (1...12).map { row in
            candidate(
                rowNumber: row,
                type: row == 12 ? .income : .expense,
                categoryName: "未知分类 \(row)",
                note: row == 12 ? "最后一条工资" : "普通记录"
            )
        }

        XCTAssertEqual(
            ImportCategoryReviewList.summaryRows(rows).map(\.rowNumber),
            Array(1...8)
        )
        XCTAssertEqual(
            ImportCategoryReviewList.filteredRows(rows, query: "最后一条").map(\.rowNumber),
            [12]
        )
        XCTAssertEqual(
            ImportCategoryReviewList.filteredRows(rows, query: "收入").map(\.rowNumber),
            [12]
        )
        XCTAssertEqual(ImportCategoryReviewList.filteredRows(rows, query: "").count, 12)
    }

    private func resolve(
        _ rawCategory: String,
        categories: [PersonalFinanceOS.Category]
    ) -> ImportCategoryResolution {
        ImportCategoryResolutionService.resolve(
            source: .wacai,
            rawCategory: rawCategory,
            note: "",
            merchant: "",
            type: .expense,
            kind: .expense,
            categories: categories
        )
    }

    private func makeCategories() -> CategoryFixture {
        let dining = category("餐饮")
        let shopping = category("购物")
        let fruit = category("水果", parentID: dining.id)
        let diningOther = category("其他", parentID: dining.id)
        let shoppingOther = category("其他", parentID: shopping.id)
        let baby = category("婴幼儿养护", parentID: shopping.id)
        let housing = category("居家")
        let utilities = category("水电燃气", parentID: housing.id)
        return CategoryFixture(
            dining: dining,
            shopping: shopping,
            fruit: fruit,
            diningOther: diningOther,
            shoppingOther: shoppingOther,
            baby: baby,
            housing: housing,
            utilities: utilities
        )
    }

    private func category(_ name: String, parentID: UUID? = nil) -> PersonalFinanceOS.Category {
        PersonalFinanceOS.Category(
            kind: .expense,
            name: name,
            parentID: parentID,
            symbolName: "square.grid.2x2",
            colorToken: "teal"
        )
    }

    private func candidate(
        rowNumber: Int,
        type: TransactionType,
        categoryName: String,
        note: String
    ) -> ImportCandidate {
        ImportCandidate(
            rowNumber: rowNumber,
            type: type,
            amountMinorUnits: 100,
            occurredAt: Date(),
            timeZoneIdentifier: "Asia/Shanghai",
            categoryName: categoryName,
            accountName: "现金",
            merchantName: "",
            description: "",
            note: note,
            paymentMethod: "",
            statusText: "",
            tagNames: [],
            externalTransactionID: "row-\(rowNumber)",
            stableEventIdentity: "stable-\(rowNumber)",
            fingerprint: "fingerprint-\(rowNumber)",
            isDuplicate: false,
            isSuspectedDuplicate: false
        )
    }
}

private struct CategoryFixture {
    let dining: PersonalFinanceOS.Category
    let shopping: PersonalFinanceOS.Category
    let fruit: PersonalFinanceOS.Category
    let diningOther: PersonalFinanceOS.Category
    let shoppingOther: PersonalFinanceOS.Category
    let baby: PersonalFinanceOS.Category
    let housing: PersonalFinanceOS.Category
    let utilities: PersonalFinanceOS.Category

    var all: [PersonalFinanceOS.Category] {
        [dining, shopping, fruit, diningOther, shoppingOther, baby, housing, utilities]
    }
}
