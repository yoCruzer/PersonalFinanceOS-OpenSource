import Foundation

enum CategoryHierarchyError: Error, Equatable {
    case missingParent
    case kindMismatch
    case selfParent
    case parentIsChild
    case cycle
}

extension CategoryHierarchyError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingParent:
            "所属大类不存在。"
        case .kindMismatch:
            "大类和小类必须属于相同的收支类型。"
        case .selfParent:
            "分类不能把自己设为所属大类。"
        case .parentIsChild:
            "小类下不能再创建分类，分类最多两级。"
        case .cycle:
            "分类关系不能形成循环。"
        }
    }
}

struct CategoryHierarchy {
    let categories: [Category]
    private let categoriesByID: [UUID: Category]
    private let childrenByParentID: [UUID: [Category]]

    init(categories: [Category]) {
        self.categories = categories
        categoriesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        childrenByParentID = Dictionary(grouping: categories.compactMap { category in
            category.parentID.map { ($0, category) }
        }, by: \.0).mapValues { values in
            values.map(\.1).sorted(by: Self.categoryOrder)
        }
    }

    func category(id: UUID?) -> Category? {
        id.flatMap { categoriesByID[$0] }
    }

    func children(of category: Category, activeOnly: Bool = false) -> [Category] {
        let children = childrenByParentID[category.id] ?? []
        return activeOnly ? children.filter(isEligibleForSelection) : children
    }

    func isEligibleForSelection(_ category: Category) -> Bool {
        guard category.isActiveForSelection else { return false }
        guard let parentID = category.parentID else { return true }
        guard let parent = categoriesByID[parentID] else { return false }
        return parent.parentID == nil && parent.kind == category.kind && parent.isActiveForSelection
    }

    func rootCategory(for category: Category) -> Category {
        guard let parent = self.category(id: category.parentID),
              parent.kind == category.kind else {
            return category
        }
        return parent
    }

    func displayPath(for category: Category) -> String {
        let root = rootCategory(for: category)
        return root.id == category.id ? category.name : "\(root.name) / \(category.name)"
    }

    func aggregateRootID(for categoryID: UUID?) -> UUID? {
        category(id: categoryID).map { rootCategory(for: $0).id } ?? categoryID
    }

    func activeCategories(kind: CategoryKind) -> [Category] {
        categories
            .filter { $0.kind == kind && isEligibleForSelection($0) }
            .sorted(by: Self.categoryOrder)
    }

    func siblings(
        kind: CategoryKind,
        parentID: UUID?,
        activeOnly: Bool = false
    ) -> [Category] {
        categories
            .filter {
                $0.kind == kind &&
                $0.parentID == parentID &&
                (!activeOnly || isEligibleForSelection($0))
            }
            .sorted(by: Self.categoryOrder)
    }

    func orderedCategories(kind: CategoryKind, activeOnly: Bool = false) -> [Category] {
        siblings(kind: kind, parentID: nil, activeOnly: activeOnly).flatMap { root in
            [root] + siblings(kind: kind, parentID: root.id, activeOnly: activeOnly)
        }
    }

    func selectableCategories(kind: CategoryKind) -> [Category] {
        orderedCategories(kind: kind, activeOnly: true).filter { category in
            category.parentID != nil || children(of: category, activeOnly: true).isEmpty
        }
    }

    func descendantIDs(of categoryID: UUID) -> Set<UUID> {
        Set([categoryID] + (childrenByParentID[categoryID] ?? []).map(\.id))
    }

    func matches(_ category: Category, query: String) -> Bool {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        return category.name.localizedCaseInsensitiveContains(value)
            || displayPath(for: category).localizedCaseInsensitiveContains(value)
            || CategoryCatalogIndex.bundled?.matches(storageKey: category.defaultDefinitionKey, query: value) == true
    }

    func validate(
        kind: CategoryKind,
        parentID: UUID?,
        categoryID: UUID? = nil
    ) throws {
        guard let parentID else { return }
        guard parentID != categoryID else {
            throw CategoryHierarchyError.selfParent
        }
        guard let parent = categoriesByID[parentID] else {
            throw CategoryHierarchyError.missingParent
        }
        guard parent.kind == kind else {
            throw CategoryHierarchyError.kindMismatch
        }
        if let categoryID, parent.parentID == categoryID {
            throw CategoryHierarchyError.cycle
        }
        guard parent.parentID == nil else {
            throw CategoryHierarchyError.parentIsChild
        }
    }

    func validateAll() throws {
        for category in categories {
            try validate(
                kind: category.kind,
                parentID: category.parentID,
                categoryID: category.id
            )
        }
    }

    private static func categoryOrder(_ left: Category, _ right: Category) -> Bool {
        if left.sortOrder != right.sortOrder {
            return left.sortOrder < right.sortOrder
        }
        if left.createdAt != right.createdAt {
            return left.createdAt < right.createdAt
        }
        return left.id.uuidString < right.id.uuidString
    }
}

struct CategoryUsageSummary: Equatable {
    let directCount: Int
    let aggregateCount: Int
}

enum CategoryUsageService {
    static func summaries(
        categories: [Category],
        transactions: [FinanceTransaction]
    ) -> [UUID: CategoryUsageSummary] {
        let hierarchy = CategoryHierarchy(categories: categories)
        let directCounts = transactions
            .filter { $0.deletedAt == nil }
            .compactMap(\.categoryID)
            .reduce(into: [UUID: Int]()) { $0[$1, default: 0] += 1 }

        return Dictionary(uniqueKeysWithValues: categories.map { category in
            let direct = directCounts[category.id, default: 0]
            let aggregate: Int
            if category.isRootCategory {
                aggregate = hierarchy.descendantIDs(of: category.id)
                    .reduce(0) { $0 + directCounts[$1, default: 0] }
            } else {
                aggregate = direct
            }
            return (category.id, CategoryUsageSummary(
                directCount: direct,
                aggregateCount: aggregate
            ))
        })
    }
}

extension Category {
    var isRootCategory: Bool { parentID == nil }
    var isChildCategory: Bool { parentID != nil }
    var isUserCreated: Bool { !isSystemCategory }
    var isActiveForSelection: Bool { archivedAt == nil && !isHidden }

    func isLeafCategory(in categories: [Category]) -> Bool {
        CategoryHierarchy(categories: categories).children(of: self, activeOnly: true).isEmpty
    }

    func displayPath(in categories: [Category]) -> String {
        CategoryHierarchy(categories: categories).displayPath(for: self)
    }

    func rootCategory(in categories: [Category]) -> Category {
        CategoryHierarchy(categories: categories).rootCategory(for: self)
    }

    func aggregateRootID(in categories: [Category]) -> UUID {
        CategoryHierarchy(categories: categories).aggregateRootID(for: id) ?? id
    }
}
