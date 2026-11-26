import Foundation
import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class CategoryConsumerEligibilityTests: XCTestCase {
    func testRemoteHiddenParentDisablesNewTargetsAcrossConsumersButPreservesHistoricalEdit() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: context)
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let root = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.dining" })
        let lunch = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.dining.lunch" })
        var draft = TransactionDraft()
        draft.amountText = "12.34"
        draft.accountID = accounts.first?.id
        draft.categoryID = lunch.id
        draft.note = "午餐"
        let saved = try TransactionLifecycleService.save(draft: draft, accounts: accounts, categories: categories, in: context)
        var records = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: ModelContext(context.container)))
        var payload = try XCTUnwrap(LedgerSnapshotCodec.capture(in: ModelContext(context.container)).categories.first { $0.id == root.id })
        payload.isHidden = true
        records["categories:\(root.id.uuidString)"] = try JSONEncoder().encode(payload)
        try LedgerSnapshotCodec.apply(LedgerSnapshotCodec.package(from: records), in: ModelContext(context.container))
        let fresh = ModelContext(context.container)
        let currentCategories = try fresh.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let hierarchy = CategoryHierarchy(categories: currentCategories)
        XCTAssertFalse(hierarchy.activeCategories(kind: .expense).contains { $0.id == lunch.id })
        XCTAssertFalse(hierarchy.selectableCategories(kind: .expense).contains { $0.id == lunch.id })
        XCTAssertFalse(hierarchy.orderedCategories(kind: .expense, activeOnly: true).contains { $0.id == lunch.id })
        XCTAssertFalse(CategoryQuickAccessService.visibleCategories(categories: currentCategories, transactions: [], kind: .expense,
            selectedID: lunch.id, suggestedID: lunch.id, limit: 10).contains { $0.id == lunch.id })
        let typed = currentCategories.map {
            SuggestionCategory(id: $0.id, name: $0.name, kind: $0.kind, isActive: $0.isActiveForSelection,
                               parentID: $0.parentID, defaultDefinitionKey: $0.defaultDefinitionKey)
        }
        XCTAssertNil(SmartTransactionSuggestionService.suggest(note: "午餐", type: .expense, categories: typed, tags: [], history: []).categoryID)
        XCTAssertNil(QuickAddTimePriorService.categoryID(occurredAt: Date(timeIntervalSince1970: 12 * 3600),
            timeZone: TimeZone(secondsFromGMT: 0)!, categories: typed))
        let imported = ImportCategoryResolutionService.resolve(source: .genericCSV, rawCategory: "餐饮 / 午餐", note: "午餐",
            merchant: "", type: .expense, kind: .expense, categories: currentCategories, rememberedCategoryID: lunch.id)
        XCTAssertNotEqual(imported.resolvedCategoryID, lunch.id)
        do {
            _ = try await LedgerBatchOperationActor(modelContainer: context.container).correctCategory(selectedIDs: [saved.id], targetID: lunch.id)
            XCTFail("Batch must reject an inactive parent even for an already selected child")
        } catch { XCTAssertEqual(error as? TransactionBatchOperationError, .invalidCategory) }
        XCTAssertThrowsError(try TransactionLifecycleService.save(draft: draft, accounts: accounts, categories: currentCategories, in: fresh)) {
            XCTAssertEqual($0 as? TransactionDraftError, .unavailableReference)
        }
        let current = try XCTUnwrap(fresh.fetch(FetchDescriptor<FinanceTransaction>()).first)
        var edit = TransactionDraft(transaction: current)
        edit.note = "保留历史分类，仅改备注"
        let updated = try TransactionLifecycleService.save(draft: edit, editing: current, accounts: accounts, categories: currentCategories, in: fresh)
        XCTAssertEqual(updated.categoryID, lunch.id)
        XCTAssertEqual(hierarchy.displayPath(for: try XCTUnwrap(hierarchy.category(id: lunch.id))), "餐饮 / 午餐")
        XCTAssertNoThrow(try NativeBackupService.validate(LedgerSnapshotCodec.capture(in: ModelContext(context.container))))
    }

    func testDomainAndTypedEligibilityAgreeForEveryInvalidParentShape() {
        let root = PersonalFinanceOS.Category(kind: .expense, name: "餐饮", symbolName: "fork.knife", colorToken: "orange")
        let child = PersonalFinanceOS.Category(kind: .expense, name: "午餐", parentID: root.id, symbolName: "fork.knife", colorToken: "orange")
        func assertUnavailable(_ categories: [PersonalFinanceOS.Category]) {
            XCTAssertFalse(CategoryHierarchy(categories: categories).isEligibleForSelection(child))
            let typed = categories.map { SuggestionCategory(id: $0.id, name: $0.name, kind: $0.kind, isActive: $0.isActiveForSelection, parentID: $0.parentID) }
            XCTAssertFalse(SuggestionCategoryEligibility.active(typed).contains { $0.id == child.id })
        }
        assertUnavailable([child])
        root.archivedAt = Date()
        assertUnavailable([root, child])
        root.archivedAt = nil
        root.isHidden = true
        assertUnavailable([root, child])
        root.isHidden = false
        root.kind = .income
        assertUnavailable([root, child])
        root.kind = .expense
        root.parentID = UUID()
        assertUnavailable([root, child])
    }
}
