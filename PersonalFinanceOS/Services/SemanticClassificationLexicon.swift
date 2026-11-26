import Foundation

/// Local deterministic vocabulary, separate from the ledger and optional model provider.
struct SemanticClassificationLexicon: Decodable, Sendable {
    struct Rule: Decodable, Sendable {
        let id: String
        let semanticKey: String
        let keywords: [String]
        let exclusions: [String]
    }

    struct Match: Sendable {
        let categoryID: UUID
        let semanticKey: String
        let ruleID: String
        let score: Int
        let phrase: String
        let explanation: String
    }

    static let bundled: SemanticClassificationLexicon? = {
        guard let url = Bundle.main.url(forResource: "classification_v4_rules", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }()

    private static let frozenByKey = Dictionary(uniqueKeysWithValues: DefaultFinanceDataService.frozenDefinitions.map { ($0.key, $0) })

    let version: Int
    let rules: [Rule]

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        let catalog = try CategoryCatalog.load()
        let expected = Set(catalog.definitions.filter { $0.parentSemanticKey != nil && !$0.semanticKey.hasSuffix(".other") }.map(\.semanticKey))
        guard value.version == 1, Set(value.rules.map(\.id)).count == value.rules.count,
              Set(value.rules.map(\.semanticKey)) == expected,
              value.rules.allSatisfy({ !$0.keywords.isEmpty && $0.keywords.allSatisfy { !$0.isEmpty } }) else {
            throw CategoryCatalog.Failure.invalidResource
        }
        return Self(version: value.version, rules: value.rules.map {
            Rule(id: $0.id, semanticKey: $0.semanticKey, keywords: $0.keywords.map(Self.normalize), exclusions: $0.exclusions.map(Self.normalize))
        })
    }

    func matches(note: String, kind: CategoryKind, categories: [SuggestionCategory]) -> [Match] {
        guard let index = CategoryCatalogIndex.bundled else { return [] }
        let text = SmartTransactionSuggestionService.normalize(note)
        let active = SuggestionCategoryEligibility.active(categories).filter { $0.kind == kind }
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        return rules.compactMap { rule in
            guard let definition = index.bySemanticKey[rule.semanticKey], definition.kind == kind,
                  !rule.exclusions.contains(where: { text.contains($0) }),
                  let phrase = rule.keywords.filter({ text.contains($0) }).max(by: { $0.count < $1.count }) else { return nil }
            if let target = target(definition: definition, rule: rule, categories: active, byID: byID, index: index) {
                return Match(categoryID: target.id, semanticKey: rule.semanticKey, ruleID: rule.id,
                    score: 94 + min(max(0, phrase.count - 2), 4) * 2, phrase: phrase,
                    explanation: "匹配本地用途：\(target.parentID.flatMap { byID[$0]?.name } ?? "") / \(target.name)")
            }
            guard let fallbackKey = Self.compatibilityKey(for: rule.semanticKey),
                  let frozen = Self.frozenByKey[fallbackKey],
                  let fallback = uniqueCategory(storageKey: fallbackKey, names: [frozen.name],
                    parentStorageKeys: [frozen.parentKey].compactMap { $0 }, parentNames: [frozen.parentKey.flatMap { key in
                        Self.frozenByKey[key]?.name
                    }].compactMap { $0 }, categories: active, byID: byID) else { return nil }
            return Match(categoryID: fallback.id, semanticKey: rule.semanticKey, ruleID: rule.id,
                score: 72, phrase: phrase, explanation: "所需细分类尚未启用，可选择旧分类：\(frozen.name)")
        }
    }

    private func target(definition: CategoryCatalog.Definition, rule: Rule, categories: [SuggestionCategory],
                        byID: [UUID: SuggestionCategory], index: CategoryCatalogIndex) -> SuggestionCategory? {
        guard let root = definition.parentSemanticKey.flatMap({ index.bySemanticKey[$0] }) else { return nil }
        if definition.semanticKey == CategoryPurposeCompatibility.chargingKey {
            let purposes = categories.filter { value in
                let parent = value.parentID.flatMap { byID[$0] }
                return CategoryPurposeCompatibility.matches(semanticKey: definition.semanticKey, kind: value.kind,
                    name: value.name, storageKey: value.defaultDefinitionKey, parentKind: parent?.kind,
                    parentName: parent?.name, parentKey: parent?.defaultDefinitionKey,
                    parentIsRoot: parent != nil && parent?.parentID == nil)
            }
            return purposes.count == 1 ? purposes[0] : nil
        }
        let old = Self.frozenByKey[definition.storageDefaultKey]
        let oldRoot = old?.parentKey.flatMap { key in Self.frozenByKey[key] }
        return uniqueCategory(storageKey: definition.storageDefaultKey,
            names: [definition.name] + rule.keywords + [old?.name].compactMap { $0 },
            parentStorageKeys: [root.storageDefaultKey] + [old?.parentKey].compactMap { $0 },
            parentNames: [root.name] + [oldRoot?.name].compactMap { $0 }, categories: categories, byID: byID)
    }

    private func uniqueCategory(storageKey: String, names: [String], parentStorageKeys: [String], parentNames: [String],
                                categories: [SuggestionCategory], byID: [UUID: SuggestionCategory]) -> SuggestionCategory? {
        let allowedNames = Set(names.map(Self.normalize))
        let allowedParentNames = Set(parentNames.map(Self.normalize))
        let found = categories.filter { value in
            guard allowedNames.contains(Self.normalize(value.name)),
                  value.defaultDefinitionKey.isEmpty || value.defaultDefinitionKey == storageKey,
                  let parent = value.parentID.flatMap({ byID[$0] }), parent.parentID == nil,
                  allowedParentNames.contains(Self.normalize(parent.name)) else { return false }
            return parent.defaultDefinitionKey.isEmpty || parentStorageKeys.contains(parent.defaultDefinitionKey)
        }
        return found.count == 1 ? found[0] : nil
    }

    static func requiresUserChoice(note: String, type: TransactionType, matches: [Match], hasStrongExactMemory: Bool = false) -> Bool {
        let text = normalize(note)
        if !hasStrongExactMemory && ["苹果", "小米", "会员", "充值", "生活费"].contains(text) { return true }
        if !text.isEmpty && matches.isEmpty && !hasStrongExactMemory {
            let platforms = ["京东", "淘宝", "天猫", "拼多多", "美团", "支付宝", "微信", "抖音", "超市", "便利店"]
            let generic = ["", "付款", "支付", "消费", "扣款", "购物", "订单", "买东西"]
            if platforms.contains(where: { platform in generic.contains(text.replacingOccurrences(of: platform, with: "")) }) {
                return true
            }
        }
        if ["不是", "没有买", "没买", "不清楚", "记不清", "或者", "取消了", "最后没有"].contains(where: text.contains) { return true }
        if type != .refund && ["退款", "退回", "退还", "退货", "返还"].contains(where: text.contains) { return true }
        if ["本金", "还款", "提现", "借给"].contains(where: text.contains) { return true }
        if text.contains("转账") && !text.contains("手续费") && type != .income { return true }
        // Distinct, non-overlapping purpose phrases are multiple intents even if
        // one phrase happens to be longer. Do not use a length bonus to hide them.
        let unique = Dictionary(grouping: matches, by: \.categoryID).compactMap { $0.value.max { $0.phrase.count < $1.phrase.count } }
        for (offset, first) in unique.enumerated() {
            for second in unique.dropFirst(offset + 1) {
                if !first.phrase.contains(second.phrase) && !second.phrase.contains(first.phrase) { return true }
            }
        }
        return false
    }

    private static func normalize(_ value: String) -> String { SmartTransactionSuggestionService.normalize(value) }

    private static func compatibilityKey(for semantic: String) -> String? {
        if ["expense.household.paper-cleaning", "expense.household.toiletries"].contains(semantic) { return "expense.shopping.daily-goods" }
        if semantic.hasPrefix("expense.groceries.") { return "expense.dining.groceries" }
        if semantic.hasPrefix("expense.clothing.") { return "expense.shopping.clothing" }
        if semantic.hasPrefix("expense.personal-care.") { return "expense.shopping.beauty" }
        if semantic.hasPrefix("expense.devices.") { return "expense.shopping.digital" }
        if semantic.hasPrefix("expense.childcare.") { return "expense.shopping.baby-care" }
        if semantic.hasPrefix("expense.household.") { return "expense.shopping.home" }
        switch semantic {
        case "expense.dining.coffee", "expense.dining.tea-drink": return "expense.dining.coffee-tea"
        case "expense.dining.snacks": return "expense.dining.takeout-snacks"
        case "expense.home.rent": return "expense.home.rent-mortgage"
        case "expense.home.water", "expense.home.electricity", "expense.home.gas": return "expense.home.utilities"
        case "expense.home.cleaning", "expense.home.repair": return "expense.home.maintenance"
        case "expense.digital-services.phone-plan", "expense.digital-services.mobile-data", "expense.digital-services.broadband": return "expense.home.telecom"
        case "expense.digital-services.media", "expense.digital-services.reading": return "expense.entertainment.subscriptions"
        case "income.work.performance", "income.work.annual-bonus": return "income.work.bonus"
        case "income.investment.deposit-interest", "income.investment.product-interest": return "income.investment.interest"
        case "income.investment.realized": return "income.investment.investment-return"
        default: return nil
        }
    }
}
