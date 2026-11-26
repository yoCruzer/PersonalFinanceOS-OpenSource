import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class ImportCatalogAliasTests: XCTestCase {
    private func fixture() throws -> (ModelContext, [PersonalFinanceOS.Category]) {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: context)
        return (context, try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()))
    }

    private func resolve(_ raw: String, note: String = "", categories: [PersonalFinanceOS.Category]) -> ImportCategoryResolution {
        ImportCategoryResolutionService.resolve(source: .genericCSV, rawCategory: raw, note: note, merchant: "",
            type: .expense, kind: .expense, categories: categories)
    }

    func testOldMovedFuelPathResolvesReusedStorageIdentityWithoutProposingOldChild() throws {
        let (context, categories) = try fixture()
        let fuel = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.transportation.fuel" })
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context))
        let result = resolve("交通 / 加油", categories: categories)
        XCTAssertEqual(result.resolvedCategoryID, fuel.id)
        XCTAssertEqual(result.reason, .sourceAlias)
        XCTAssertNil(result.proposedRootID)
        XCTAssertFalse(result.requiresReview)
        XCTAssertEqual(before, try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context)))
    }

    func testMissingMixedLegacyTargetNeverProposesAChildAndCanUseExplicitDescription() throws {
        let (_, categories) = try fixture()
        XCTAssertNotNil(ImportCategoryAliasIndex.bundled)
        for source in ["母婴用品", "生活缴费", "购物 / 婴幼儿养护", "居家 / 水电燃气"] {
            let result = resolve(source, categories: categories)
            XCTAssertNil(result.resolvedCategoryID, source)
            XCTAssertNil(result.proposedRootID, source)
            XCTAssertTrue(result.requiresReview, source)
        }
        let diapers = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.childcare.diapers" })
        XCTAssertEqual(resolve("母婴用品", note: "纸尿裤", categories: categories).resolvedCategoryID, diapers.id)
    }

    func testSourceAliasDoesNotClaimSameNamedCustomCategoryOrRepurposedDefault() throws {
        let (_, categories) = try fixture()
        let fuel = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.transportation.fuel" })
        fuel.name = "停车专项"
        let repurposed = resolve("交通 / 加油", categories: categories)
        XCTAssertNil(repurposed.resolvedCategoryID)
        XCTAssertNil(repurposed.proposedRootID)
        let root = PersonalFinanceOS.Category(kind: .expense, name: "购物", symbolName: "bag", colorToken: "blue")
        let custom = PersonalFinanceOS.Category(kind: .expense, name: "婴幼儿养护", parentID: root.id, symbolName: "bag", colorToken: "blue")
        XCTAssertNil(resolve("母婴用品", categories: [root, custom]).resolvedCategoryID)
        XCTAssertTrue(custom.defaultDefinitionKey.isEmpty)
    }

    func testAliasCollisionRequiresReviewAndHiddenParentCannotResolve() throws {
        let (_, categories) = try fixture()
        let fuel = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.transportation.fuel" })
        let oldRoot = PersonalFinanceOS.Category(kind: .expense, name: "交通", symbolName: "car", colorToken: "blue")
        let custom = PersonalFinanceOS.Category(kind: .expense, name: "加油", parentID: oldRoot.id, symbolName: "car", colorToken: "blue")
        XCTAssertTrue(resolve("交通 / 加油", categories: categories + [oldRoot, custom]).requiresReview)
        let parent = try XCTUnwrap(categories.first { $0.id == fuel.parentID })
        parent.isHidden = true
        let hidden = resolve("交通 / 加油", categories: categories)
        XCTAssertNil(hidden.resolvedCategoryID)
        XCTAssertNil(hidden.proposedRootID)
    }
}
