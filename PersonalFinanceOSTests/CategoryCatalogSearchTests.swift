import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class CategoryCatalogSearchTests: XCTestCase {
    func testNewCatalogSearchFindsMovedIdentityByCurrentAndFrozenPaths() throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let hierarchy = CategoryHierarchy(categories: categories)
        let fuel = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.transportation.fuel" })
        XCTAssertEqual(hierarchy.displayPath(for: fuel), "车辆养护 / 加油")
        for query in ["交通/加油", "交通 ／ 加油", "车辆养护 / 加油", "加油"] {
            XCTAssertTrue(hierarchy.matches(fuel, query: query), query)
        }
        let custom = PersonalFinanceOS.Category(kind: .expense, name: "自定义用途", symbolName: "star", colorToken: "teal")
        XCTAssertFalse(CategoryHierarchy(categories: [custom]).matches(custom, query: "交通/加油"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersonalFinanceOS.Category>()), 233)
    }

    func testLegacyGroupingDoesNotHidePinnedSelectedOrSuggestedCompatibilityCategories() throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: context)
        var categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let legacy = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.dining.coffee-tea" })
        let root = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.dining" })
        let new = PersonalFinanceOS.Category(kind: .expense, name: "咖啡", parentID: root.id,
            defaultDefinitionKey: "expense.dining.coffee", symbolName: "cup.and.saucer", colorToken: "orange", isSystemCategory: true)
        context.insert(new)
        categories.append(new)
        legacy.isPinnedForQuickAdd = false
        try context.save()
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context))
        func visible(selected: UUID? = nil, suggested: UUID? = nil) -> [UUID] {
            CategoryQuickAccessService.visibleCategories(categories: categories, transactions: [], kind: .expense,
                selectedID: selected, suggestedID: suggested, limit: 300).map(\.id)
        }
        XCTAssertFalse(visible().contains(legacy.id))
        XCTAssertTrue(visible(selected: legacy.id).contains(legacy.id))
        XCTAssertTrue(visible(suggested: legacy.id).contains(legacy.id))
        XCTAssertTrue(CategoryHierarchy(categories: categories).selectableCategories(kind: .expense).contains { $0.id == legacy.id })
        XCTAssertTrue(CategoryHierarchy(categories: categories).matches(legacy, query: "咖啡奶茶"))
        XCTAssertEqual(before, try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context)))
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(context.container))
        var records = try LedgerSnapshotCodec.records(package)
        var pinned = try XCTUnwrap(package.categories.first { $0.id == legacy.id })
        pinned.isPinnedForQuickAdd = true
        records["categories:\(legacy.id.uuidString)"] = try JSONEncoder().encode(pinned)
        try LedgerSnapshotCodec.apply(LedgerSnapshotCodec.package(from: records), in: ModelContext(context.container))
        let current = try ModelContext(context.container).fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertTrue(CategoryQuickAccessService.visibleCategories(categories: current, transactions: [], kind: .expense,
            selectedID: nil, suggestedID: nil, limit: 300).contains { $0.id == legacy.id })
    }
}
