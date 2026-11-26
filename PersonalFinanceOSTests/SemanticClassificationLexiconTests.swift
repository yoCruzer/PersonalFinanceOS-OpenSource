import XCTest
@testable import PersonalFinanceOS

final class SemanticClassificationLexiconTests: XCTestCase {
    private func catalog() throws -> ([SuggestionCategory], [String: UUID]) {
        let definitions = try CategoryCatalog.load().definitions
        let ids = Dictionary(uniqueKeysWithValues: definitions.map { ($0.semanticKey, UUID()) })
        return (definitions.map {
            SuggestionCategory(id: ids[$0.semanticKey]!, name: $0.name, kind: $0.kind,
                isActive: true, parentID: $0.parentSemanticKey.flatMap { ids[$0] },
                defaultDefinitionKey: $0.storageDefaultKey)
        }, ids)
    }

    func testBundledRulesCoverAllNonOtherLeaves() throws {
        let rules = try XCTUnwrap(SemanticClassificationLexicon.bundled)
        XCTAssertEqual(rules.rules.count, 181)
        XCTAssertFalse(rules.rules.contains { $0.semanticKey.hasSuffix(".other") })
    }

    func testUndoRestoresPreviousCategoryAndLocksLaterAutomaticUpdates() {
        let previous = UUID(), automatic = UUID()
        var session = SmartSuggestionSession(editingExisting: false, hasInitialCategory: false, initialTagIDs: [])
        XCTAssertEqual(session.applyAutomaticCategory(automatic, currentCategoryID: previous), automatic)
        XCTAssertEqual(session.undoAutomaticSuggestion(currentCategoryID: automatic), previous)
        XCTAssertEqual(session.rejectedAutomaticCategoryID, automatic)
        XCTAssertFalse(session.allowsAutomaticRun)
        XCTAssertNil(session.applyAutomaticCategory(UUID(), currentCategoryID: previous))
        session.requestRefresh(currentCategoryID: previous)
        XCTAssertFalse(session.allowsAutomaticRun)
    }

    func testExplicitDevelopmentExamplesChoosePurpose() throws {
        let (categories, ids) = try catalog()
        for (note, key) in [
            ("午餐吃火锅", "expense.dining.lunch"),
            ("笔记本电脑", "expense.devices.computer"),
            ("手机话费", "expense.digital-services.phone-plan"),
            ("孩子鞋", "expense.clothing.shoes"),
            ("孩子纸尿裤", "expense.childcare.diapers"),
            ("摄影培训", "expense.education.courses"),
            ("火车出差", "expense.transportation.rail"),
            ("外卖午饭", "expense.dining.lunch")
        ] {
            let result = SmartTransactionSuggestionService.suggest(note: note, type: .expense,
                categories: categories, tags: [], history: [])
            XCTAssertNotNil(ids[key], key)
            XCTAssertEqual(result.categoryID, ids[key], note)
            XCTAssertEqual(result.categoryConfidence, .high, note)
        }
    }

    func testAmbiguityRefundAndTransferDoNotAutoChoose() throws {
        let (categories, _) = try catalog()
        for note in ["京东付款", "苹果和手机壳", "收到退款", "不是咖啡，是滤芯", "咖啡和午餐"] {
            let result = SmartTransactionSuggestionService.suggest(note: note, type: .expense,
                categories: categories, tags: [], history: [])
            XCTAssertNotEqual(result.categoryConfidence, .high, note)
        }
        XCTAssertNil(SmartTransactionSuggestionService.suggest(note: "午餐", type: .transfer,
            categories: categories, tags: [], history: []).categoryID)
        let mixedRental = SmartTransactionSuggestionService.suggest(note: "本月房屋租金和车位出租收入合计", type: .income,
            categories: categories, tags: [], history: [])
        XCTAssertEqual(mixedRental.categoryConfidence, .medium)
        XCTAssertTrue(mixedRental.requiresUserChoice)
    }

    func testRecallRanksEntireCatalogBeforeLimitAndIsOrderIndependent() throws {
        let (categories, ids) = try catalog()
        let leaves = categories.filter { $0.parentID != nil }
        let target = try XCTUnwrap(ids["expense.transportation.rail"])
        func recall(_ input: [SuggestionCategory]) -> [UUID] {
            FoundationCandidateRecall.select(note: "火车出差", merchant: "", type: .expense,
                categories: input, fullCategories: categories, deterministic: .none, limit: 48).map(\.id)
        }
        XCTAssertEqual(recall(leaves), recall(leaves.reversed()))
        XCTAssertEqual(recall(leaves).first, target)
        XCTAssertEqual(recall(leaves).count, 48)
    }

    func testOldCatalogReturnsCompatibleCoffeeCandidateWithoutInstallingNewNode() throws {
        let definitions = DefaultFinanceDataService.frozenDefinitions
        let ids = Dictionary(uniqueKeysWithValues: definitions.map { ($0.key, UUID()) })
        let categories = definitions.map {
            SuggestionCategory(id: ids[$0.key]!, name: $0.name, kind: $0.kind, isActive: true,
                parentID: $0.parentKey.flatMap { ids[$0] }, defaultDefinitionKey: $0.key)
        }
        let result = SmartTransactionSuggestionService.suggest(note: "咖啡", type: .expense,
            categories: categories, tags: [], history: [])
        XCTAssertEqual(result.categoryID, ids["expense.dining.coffee-tea"])
        XCTAssertEqual(result.categoryConfidence, .medium)
        XCTAssertEqual(categories.count, 77)
    }

    func testRepurposedStableKeyAndHiddenParentAreNotRuleTargets() throws {
        let (original, ids) = try catalog()
        let coffee = try XCTUnwrap(ids["expense.dining.coffee"])
        let root = try XCTUnwrap(ids["expense.dining"])
        for mode in ["rename", "hideParent"] {
            let categories = original.map { value in
                SuggestionCategory(id: value.id, name: mode == "rename" && value.id == coffee ? "养老储备" : value.name,
                    kind: value.kind, isActive: !(mode == "hideParent" && value.id == root),
                    parentID: value.parentID, defaultDefinitionKey: value.defaultDefinitionKey)
            }
            let result = SmartTransactionSuggestionService.suggest(note: "咖啡", type: .expense,
                categories: categories, tags: [], history: [])
            XCTAssertNotEqual(result.categoryID, coffee, mode)
            if mode == "hideParent" {
                let recalled = FoundationCandidateRecall.select(note: "咖啡", merchant: "", type: .expense,
                    categories: categories, fullCategories: categories, deterministic: .none, limit: 48)
                XCTAssertFalse(recalled.contains { $0.id == coffee })
            }
        }
    }
}
