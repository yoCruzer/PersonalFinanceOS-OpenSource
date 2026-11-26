import SwiftData
import XCTest
@testable import PersonalFinanceOS

/// An explicit existing V3 ledger for migration tests; never a production bootstrap switch.
@MainActor
func seedFrozenV3Ledger(in context: ModelContext) throws {
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Account>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersonalFinanceOS.Category>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppMetadata>()), 0)
    context.insert(Account(name: "日常账户", type: .other, isDefault: true))
    var ids: [String: UUID] = [:]
    for definition in DefaultFinanceDataService.frozenDefinitions {
        let category = PersonalFinanceOS.Category(kind: definition.kind, name: definition.name,
            parentID: definition.parentKey.flatMap { ids[$0] }, defaultDefinitionKey: definition.key,
            symbolName: definition.symbol, colorToken: definition.color, sortOrder: definition.sortOrder,
            isPinnedForQuickAdd: definition.pinned, isSystemCategory: true)
        context.insert(category)
        ids[definition.key] = category.id
    }
    context.insert(AppMetadata(defaultCategorySeedVersion: 3))
    try context.save()
}
