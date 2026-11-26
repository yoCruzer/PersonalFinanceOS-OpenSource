import Foundation
import SwiftData

enum DefaultFinanceDataService {
    static let currentCategorySeedVersion = 4
    static let frozenCategorySeedVersion = 3

    struct FrozenDefinition: Sendable {
        let key: String
        let parentKey: String?
        let kind: CategoryKind
        let name: String
        let symbol: String
        let color: String
        let sortOrder: Int
        let pinned: Bool

        func matches(_ value: MetadataEditSnapshot.CategoryValue, parentKey currentParentKey: String?) -> Bool {
            value.defaultDefinitionKey == key && currentParentKey == parentKey &&
            value.kindRawValue == kind.rawValue && value.name == name &&
            value.symbolName == symbol && value.colorToken == color &&
            value.sortOrder == sortOrder && value.isPinnedForQuickAdd == pinned &&
            value.isSystemCategory && !value.isHidden && value.archivedAt == nil
        }
    }

    /// Frozen V3 attributes and ordinal order; never derive these from the new resource.
    static var frozenDefinitions: [FrozenDefinition] {
        definitions.enumerated().flatMap { rootOrder, root in
            [FrozenDefinition(
                key: root.key, parentKey: nil, kind: root.kind, name: root.name,
                symbol: root.symbol, color: root.color, sortOrder: rootOrder, pinned: false
            )] + root.children.enumerated().map { childOrder, child in
                FrozenDefinition(
                    key: "\(root.key).\(child.key)", parentKey: root.key, kind: root.kind,
                    name: child.name, symbol: child.symbol, color: root.color,
                    sortOrder: childOrder, pinned: child.pinned
                )
            }
        }
    }

    static func isPristineBootstrap(
        accounts: [Account],
        categories: [Category],
        appMetadata: [AppMetadata]
    ) -> Bool {
        guard accounts.count == 1,
              let account = accounts.first,
              account.name == "日常账户",
              account.type == .other,
              account.openingBalanceMinorUnits == 0,
              account.currencyCode == Money.cnyCode,
              account.isDefault,
              account.sortOrder == 0,
              account.archivedAt == nil,
              appMetadata.count == 1,
              let metadata = appMetadata.first,
              [frozenCategorySeedVersion, currentCategorySeedVersion].contains(metadata.defaultCategorySeedVersion),
              metadata.deletedDefaultCategoryKeys.isEmpty else {
            return false
        }

        if metadata.defaultCategorySeedVersion == currentCategorySeedVersion {
            let definitions = PublishedV4Bootstrap.definitions
            guard categories.count == definitions.count else { return false }
            let grouped = Dictionary(grouping: categories, by: \.defaultDefinitionKey)
            guard grouped.count == categories.count, grouped.values.allSatisfy({ $0.count == 1 }) else { return false }
            let byKey = grouped.mapValues { $0[0] }
            for definition in definitions {
                guard let category = byKey[definition.key],
                      category.kind == definition.kind, category.name == definition.name,
                      category.parentID == definition.parentKey.flatMap({ byKey[$0]?.id }),
                      (category.symbolName == definition.symbol ||
                       (definition.key == "expense.dining.fruit" && category.symbolName == "basket")),
                      category.colorToken == definition.color, category.sortOrder == definition.sortOrder,
                      category.isPinnedForQuickAdd == definition.pinned,
                      category.isSystemCategory, !category.isHidden, category.archivedAt == nil else { return false }
            }
            return true
        }

        let expectedCategoryCount = definitions.reduce(0) { $0 + 1 + $1.children.count }
        guard categories.count == expectedCategoryCount else { return false }
        let keyedCategories = Dictionary(
            grouping: categories,
            by: \Category.defaultDefinitionKey
        )
        guard keyedCategories.count == expectedCategoryCount,
              keyedCategories[""] == nil,
              keyedCategories.values.allSatisfy({ $0.count == 1 }) else {
            return false
        }

        for (rootOrder, definition) in definitions.enumerated() {
            guard let root = keyedCategories[definition.key]?.first,
                  root.kind == definition.kind,
                  root.name == definition.name,
                  root.parentID == nil,
                  root.symbolName == definition.symbol,
                  root.colorToken == definition.color,
                  root.sortOrder == rootOrder,
                  !root.isPinnedForQuickAdd,
                  root.isSystemCategory,
                  !root.isHidden,
                  root.archivedAt == nil else {
                return false
            }
            for (childOrder, child) in definition.children.enumerated() {
                let key = "\(definition.key).\(child.key)"
                guard let category = keyedCategories[key]?.first,
                      category.kind == definition.kind,
                      category.name == child.name,
                      category.parentID == root.id,
                      category.symbolName == child.symbol,
                      category.colorToken == definition.color,
                      category.sortOrder == childOrder,
                      category.isPinnedForQuickAdd == child.pinned,
                      category.isSystemCategory,
                      !category.isHidden,
                      category.archivedAt == nil else {
                    return false
                }
            }
        }
        return true
    }

    private struct ChildDefinition {
        let key: String
        let name: String
        let symbol: String
        let pinned: Bool
    }

    private struct RootDefinition {
        let key: String
        let kind: CategoryKind
        let name: String
        let legacyNames: [String]
        let symbol: String
        let color: String
        let children: [ChildDefinition]
    }

    @MainActor
    static func ensureDefaults(in context: ModelContext) throws {
        do {
            try LedgerSaveRevision.shared.withProjectionBoundary {
                guard !context.hasChanges else { throw FinanceDataManagementError.pendingChanges }
                let fresh = ModelContext(context.container)
                do {
                    try ensureDefaultsLocked(in: fresh)
                } catch {
                    fresh.rollbackNotifyingSync()
                    throw error
                }
            }
        } catch ReconcileRevision.Failure.stalePlan {
            throw FinanceDataManagementError.busy
        }
    }

    @MainActor
    private static func ensureDefaultsLocked(in context: ModelContext) throws {
        if try isCompletelyEmpty(in: context) {
            try seedNewCatalog(in: context)
            try context.save()
            return
        }
        var accounts = try context.fetch(FetchDescriptor<Account>())
        if accounts.allSatisfy({ $0.archivedAt != nil }) {
            let account = Account(name: "日常账户", type: .other, isDefault: true)
            context.insert(account)
            accounts.append(account)
        } else if !accounts.contains(where: { $0.archivedAt == nil && $0.isDefault }) {
            accounts.first(where: { $0.archivedAt == nil })?.isDefault = true
        }

        var categories = try context.fetch(FetchDescriptor<Category>())
        for category in categories where
            !CategoryIconLibrary.isValidStoredIcon(category.symbolName) {
            category.symbolName = CategoryIconLibrary.suggestedSymbol(
                for: category.name,
                kind: category.kind
            )
        }

        var metadata = try context.fetch(FetchDescriptor<AppMetadata>()).first
        if metadata == nil {
            let created = AppMetadata()
            context.insert(created)
            metadata = created
        }

        if let metadata,
           metadata.defaultCategorySeedVersion < frozenCategorySeedVersion {
            let tombstones = migratedTombstones(metadata.deletedDefaultCategoryKeys)
            metadata.deletedDefaultCategoryKeys = tombstones
            seedHierarchy(
                existing: &categories,
                tombstones: tombstones,
                in: context
            )
            metadata.defaultCategorySeedVersion = frozenCategorySeedVersion
            metadata.updatedAt = Date()
        }

        if context.hasChanges { try context.save() }
    }

    private struct CatalogSeed {
        let definition: CategoryCatalog.Definition
        let parentStorageKey: String?
        let sortOrder: Int
    }

    private static func catalogSeeds(_ catalog: CategoryCatalog) -> [CatalogSeed] {
        let bySemantic = Dictionary(uniqueKeysWithValues: catalog.definitions.map { ($0.semanticKey, $0) })
        return catalog.catalog.enumerated().flatMap { rootOrder, root in
            [CatalogSeed(definition: bySemantic[root.semanticKey]!, parentStorageKey: nil, sortOrder: rootOrder)]
                + root.children.enumerated().map { order, leaf in
                    CatalogSeed(definition: bySemantic[leaf.semanticKey]!, parentStorageKey: root.storageDefaultKey, sortOrder: order)
                }
        }
    }

    private static func isCompletelyEmpty(in context: ModelContext) throws -> Bool {
        try context.fetchCount(FetchDescriptor<AppMetadata>()) == 0 &&
            context.fetchCount(FetchDescriptor<Account>()) == 0 &&
            context.fetchCount(FetchDescriptor<Category>()) == 0 &&
            context.fetchCount(FetchDescriptor<FinanceTransaction>()) == 0 &&
            context.fetchCount(FetchDescriptor<Tag>()) == 0 &&
            context.fetchCount(FetchDescriptor<Merchant>()) == 0 &&
            context.fetchCount(FetchDescriptor<ImportBatch>()) == 0 &&
            context.fetchCount(FetchDescriptor<DailyReview>()) == 0 &&
            context.fetchCount(FetchDescriptor<ImportEntityOrigin>()) == 0 &&
            context.fetchCount(FetchDescriptor<SyncProjectionReceipt>()) == 0
    }

    private static func seedNewCatalog(in context: ModelContext) throws {
        let catalog = try CategoryCatalog.load()
        context.insert(Account(name: "日常账户", type: .other, isDefault: true))
        var ids: [String: UUID] = [:]
        for seed in catalogSeeds(catalog) {
            let definition = seed.definition
            let style = CategoryCatalogAppearance.style(for: definition)
            let category = Category(kind: definition.kind, name: definition.name,
                parentID: seed.parentStorageKey.flatMap { ids[$0] }, defaultDefinitionKey: definition.storageDefaultKey,
                symbolName: style.symbol, colorToken: style.color, sortOrder: seed.sortOrder,
                isPinnedForQuickAdd: style.pinned, isSystemCategory: true)
            context.insert(category)
            ids[definition.storageDefaultKey] = category.id
        }
        context.insert(AppMetadata(defaultCategorySeedVersion: currentCategorySeedVersion))
    }

    @MainActor
    private static func seedHierarchy(
        existing categories: inout [Category],
        tombstones: Set<String>,
        in context: ModelContext
    ) {
        for (rootOrder, definition) in definitions.enumerated() {
            guard !tombstones.contains(definition.key) else { continue }
            let root = matchingRoot(for: definition, in: categories) ?? {
                let created = Category(
                    kind: definition.kind,
                    name: definition.name,
                    defaultDefinitionKey: definition.key,
                    symbolName: definition.symbol,
                    colorToken: definition.color,
                    sortOrder: rootOrder,
                    isSystemCategory: true
                )
                context.insert(created)
                categories.append(created)
                return created
            }()

            if root.isSystemCategory && root.defaultDefinitionKey.isEmpty {
                root.defaultDefinitionKey = definition.key
            }

            if root.isSystemCategory,
               definition.legacyNames.contains(root.name) {
                root.name = definition.name
                root.updatedAt = Date()
            }

            for (childOrder, child) in definition.children.enumerated() {
                let childKey = "\(definition.key).\(child.key)"
                let legacyKey = "\(definition.key).child.\(childOrder)"
                guard !tombstones.contains(childKey) else { continue }
                if let existingChild = categories.first(where: {
                    $0.kind == definition.kind &&
                    $0.parentID == root.id &&
                    sameName($0.name, child.name)
                }) {
                    if existingChild.isSystemCategory && (
                        existingChild.defaultDefinitionKey.isEmpty ||
                        existingChild.defaultDefinitionKey == legacyKey
                    ) {
                        existingChild.defaultDefinitionKey = childKey
                    }
                    continue
                }
                let created = Category(
                    kind: definition.kind,
                    name: child.name,
                    parentID: root.id,
                    defaultDefinitionKey: childKey,
                    symbolName: child.symbol,
                    colorToken: definition.color,
                    sortOrder: childOrder,
                    isPinnedForQuickAdd: child.pinned,
                    isSystemCategory: true
                )
                context.insert(created)
                categories.append(created)
            }
        }
    }

    static func migratedTombstones(_ tombstones: Set<String>) -> Set<String> {
        var migrated = tombstones
        for definition in definitions {
            for (index, child) in definition.children.enumerated() {
                let legacyKey = "\(definition.key).child.\(index)"
                guard migrated.remove(legacyKey) != nil else { continue }
                migrated.insert("\(definition.key).\(child.key)")
            }
        }
        return migrated
    }

    private static func matchingRoot(
        for definition: RootDefinition,
        in categories: [Category]
    ) -> Category? {
        categories.first {
            $0.kind == definition.kind &&
            $0.parentID == nil &&
            sameName($0.name, definition.name)
        } ?? categories.first {
            $0.kind == definition.kind &&
            $0.parentID == nil &&
            $0.isSystemCategory &&
            definition.legacyNames.contains($0.name)
        }
    }

    private static func sameName(_ left: String, _ right: String) -> Bool {
        left.compare(
            right,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }

    private static let definitions: [RootDefinition] = [
        root("expense.dining", .expense, "餐饮", symbol: "fork.knife", color: "orange", children: [
            child("breakfast", "早餐", "sunrise", true), child("lunch", "午餐", "fork.knife", true),
            child("dinner", "晚餐", "takeoutbag.and.cup.and.straw", true), child("takeout-snacks", "外卖零食", "takeoutbag.and.cup.and.straw", true),
            child("fruit", "水果", "apple.logo", true), child("coffee-tea", "咖啡奶茶", "cup.and.saucer", true),
            child("groceries", "买菜食材", "basket", true), child("other", "其他餐饮", "ellipsis.circle", false)
        ]),
        root("expense.transportation", .expense, "交通", symbol: "car", color: "blue", children: [
            child("bus", "公交", "bus", true), child("metro", "地铁", "tram", true), child("taxi", "打车", "car", true),
            child("fuel", "加油", "fuelpump", false), child("parking", "停车", "parkingsign.circle", false),
            child("toll", "高速过路", "road.lanes", false), child("maintenance", "维修保养", "wrench.and.screwdriver", false),
            child("other", "其他交通", "ellipsis.circle", false)
        ]),
        root("expense.shopping", .expense, "购物", symbol: "bag", color: "purple", children: [
            child("daily-goods", "日用品", "basket", true), child("clothing", "服饰鞋包", "tshirt", false), child("digital", "数码", "desktopcomputer", false),
            child("home", "家居", "sofa", false), child("baby-care", "婴幼儿养护", "figure.2.and.child.holdinghands", true),
            child("beauty", "美妆护肤", "comb", false), child("gifts", "礼物", "gift", false), child("other", "其他购物", "ellipsis.circle", false)
        ]),
        root("expense.home", .expense, "居家", legacy: ["居住"], symbol: "house", color: "teal", children: [
            child("rent-mortgage", "房租房贷", "house", false), child("utilities", "水电燃气", "bolt.house", false), child("property", "物业", "building.2", false),
            child("telecom", "通讯网络", "wifi", false), child("maintenance", "家政维修", "wrench.and.screwdriver", false), child("other", "其他居家", "ellipsis.circle", false)
        ]),
        root("expense.health-education", .expense, "医疗教育", legacy: ["医疗"], symbol: "cross.case", color: "blue", children: [
            child("medical", "医疗药品", "pills", false), child("checkup", "体检", "heart.text.clipboard", false), child("wellness", "保健", "heart", false),
            child("courses", "学习课程", "graduationcap", false), child("books", "书籍文具", "book", false), child("other", "其他医教", "ellipsis.circle", false)
        ]),
        root("expense.entertainment", .expense, "娱乐", symbol: "gamecontroller", color: "green", children: [
            child("movies-shows", "电影演出", "film", false), child("games", "游戏", "gamecontroller", false), child("sports", "运动", "figure.run", false),
            child("gatherings", "聚会", "person.3", false), child("hobbies", "兴趣爱好", "paintpalette", false), child("subscriptions", "会员订阅", "rectangle.stack.badge.play", false),
            child("other", "其他娱乐", "ellipsis.circle", false)
        ]),
        root("expense.gifts", .expense, "人情", symbol: "person.2", color: "orange", children: [
            child("red-envelope", "红包", "envelope", false), child("cash-gift", "礼金", "gift", false), child("parents", "孝敬长辈", "person.2", false),
            child("other", "其他人情", "ellipsis.circle", false)
        ]),
        root("expense.travel", .expense, "旅行", symbol: "suitcase.rolling", color: "blue", children: [
            child("lodging", "住宿", "bed.double", false), child("tickets", "门票", "ticket", false), child("transport", "旅行交通", "airplane", false),
            child("dining", "旅行餐饮", "fork.knife", false), child("shopping", "旅行购物", "bag", false), child("other", "其他旅行", "ellipsis.circle", false)
        ]),
        root("expense.other", .expense, "其他支出", legacy: ["其他"], symbol: "ellipsis.circle", color: "teal", children: [
            child("other", "其他", "ellipsis.circle", false)
        ]),
        root("income.work", .income, "工作收入", legacy: ["薪资"], symbol: "briefcase", color: "green", children: [
            child("salary", "工资", "banknote", true), child("bonus", "奖金", "gift", false), child("reimbursement", "报销", "doc.text", false), child("part-time", "兼职", "clock.arrow.circlepath", false)
        ]),
        root("income.investment", .income, "理财收入", legacy: ["理财"], symbol: "chart.line.uptrend.xyaxis", color: "blue", children: [
            child("interest", "利息", "percent", false), child("dividend", "分红", "chart.pie", false), child("investment-return", "投资收益", "chart.line.uptrend.xyaxis", false)
        ]),
        root("income.other", .income, "其他收入", symbol: "plus.circle", color: "teal", children: [
            child("refund", "退款", "arrow.uturn.backward.circle", false), child("red-envelope", "红包", "envelope", false),
            child("cash-gift", "礼金", "gift", false), child("other", "其他", "ellipsis.circle", false)
        ])
    ]

    private static func root(
        _ key: String,
        _ kind: CategoryKind,
        _ name: String,
        legacy: [String] = [],
        symbol: String,
        color: String,
        children: [ChildDefinition]
    ) -> RootDefinition {
        RootDefinition(
            key: key,
            kind: kind,
            name: name,
            legacyNames: legacy,
            symbol: symbol,
            color: color,
            children: children
        )
    }

    private static func child(
        _ key: String,
        _ name: String,
        _ symbol: String,
        _ pinned: Bool
    ) -> ChildDefinition {
        ChildDefinition(key: key, name: name, symbol: symbol, pinned: pinned)
    }
}
