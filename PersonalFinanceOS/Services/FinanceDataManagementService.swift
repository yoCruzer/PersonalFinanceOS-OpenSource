import Foundation
import SwiftData

enum FinanceDataManagementError: Error, Equatable {
    case emptyName
    case busy
    case pendingChanges
    case staleMetadata
    case lastActiveAccount
    case lastActiveCategory
    case archivedAccountCannotBeDefault
    case duplicateName
    case migrationRequired
    case invalidMigrationTarget
    case categoryHasChildren
    case transferMigrationConflict
    case invalidCategoryOrder
    case invalidCategoryIcon
}

extension FinanceDataManagementError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .busy:
            "账本正在更新，请稍后重试。输入内容已保留。"
        case .staleMetadata:
            "账户、分类或标签已发生变化，请刷新后重新确认。输入内容已保留。"
        case .pendingChanges:
            "当前还有未保存的修改，请先处理后重试。"
        case .emptyName:
            "名称不能为空。"
        case .lastActiveAccount:
            "至少需要保留一个可用账户。"
        case .lastActiveCategory:
            "每种收支类型至少需要保留一个可用分类。"
        case .archivedAccountCannotBeDefault:
            "请先启用账户，再将它设为默认账户。"
        case .duplicateName:
            "名称已存在，请换一个名称。"
        case .migrationRequired:
            "该对象仍被历史交易使用，请先选择安全处理方式。"
        case .invalidMigrationTarget:
            "迁移目标不存在、已停用或与原对象不兼容。"
        case .categoryHasChildren:
            "该大类仍有小类，请先逐个迁移、停用或删除小类。"
        case .transferMigrationConflict:
            "迁移会让转账的来源和目标变成同一账户，请选择其他账户。"
        case .invalidCategoryOrder:
            "只能调整同一收支类型、同一层级内的分类顺序。"
        case .invalidCategoryIcon:
            "文字图标不能为空且最多两个字符。"
        }
    }
}

struct MetadataDeletionAnalysis: Equatable, Sendable {
    let directTransactionCount: Int
    let indirectTransactionCount: Int
    let childObjectCount: Int
    let affectedTransferCount: Int
    let isDefaultOrPreferred: Bool
    let isLastAvailable: Bool
    let hasUnmigratableRelationships: Bool

    var affectedTransactionCount: Int {
        directTransactionCount + indirectTransactionCount
    }
}

enum TagDeletionResolution: Equatable, Sendable {
    case remove
    case replace(with: UUID)
}

enum FinanceDataManagementService {
    @MainActor
    static func analyzeDeletion(
        of account: Account,
        in context: ModelContext
    ) throws -> MetadataDeletionAnalysis {
        let transactions = try LedgerQueryService.fetchForAccount(account.id, in: context)
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let direct = transactions.filter { $0.accountID == account.id }
        let indirect = transactions.filter { $0.destinationAccountID == account.id }
        let affectedTransfers = transactions.filter {
            $0.type == .transfer &&
            ($0.accountID == account.id || $0.destinationAccountID == account.id)
        }
        let activeTargets = accounts.filter {
            $0.id != account.id && $0.archivedAt == nil
        }
        let hasConflictForEveryTarget = !affectedTransfers.isEmpty && activeTargets.allSatisfy { target in
            affectedTransfers.contains { transaction in
                let newSource = transaction.accountID == account.id ? target.id : transaction.accountID
                let newDestination = transaction.destinationAccountID == account.id
                    ? target.id
                    : transaction.destinationAccountID
                return newSource == newDestination
            }
        }
        return MetadataDeletionAnalysis(
            directTransactionCount: direct.count,
            indirectTransactionCount: indirect.count,
            childObjectCount: 0,
            affectedTransferCount: affectedTransfers.count,
            isDefaultOrPreferred: account.isDefault,
            isLastAvailable: activeTargets.isEmpty,
            hasUnmigratableRelationships: hasConflictForEveryTarget
        )
    }

    @MainActor
    static func analyzeDeletion(
        of category: Category,
        in context: ModelContext
    ) throws -> MetadataDeletionAnalysis {
        let transactions = try LedgerQueryService.fetchForCategory(category.id, in: context)
        let categories = try context.fetch(FetchDescriptor<Category>())
        let direct = transactions.filter { $0.categoryID == category.id }
        let hierarchy = CategoryHierarchy(categories: categories)
        let children = hierarchy.children(of: category)
        let remainingHierarchy = CategoryHierarchy(categories: categories.filter { $0.id != category.id })
        let activePeers = remainingHierarchy.selectableCategories(kind: category.kind)
        return MetadataDeletionAnalysis(
            directTransactionCount: direct.count,
            indirectTransactionCount: 0,
            childObjectCount: children.count,
            affectedTransferCount: 0,
            isDefaultOrPreferred: category.isPinnedForQuickAdd || category.isSystemCategory,
            isLastAvailable: activePeers.isEmpty,
            hasUnmigratableRelationships: !children.isEmpty
        )
    }

    @MainActor
    static func analyzeDeletion(
        of tag: Tag,
        in context: ModelContext
    ) throws -> MetadataDeletionAnalysis {
        // Soft-deleted transactions still retain the relationship and therefore must be
        // counted before a tag can be safely removed or replaced.
        let directCount = try LedgerQueryService.fetchForTag(tag.id, in: context).count
        return MetadataDeletionAnalysis(
            directTransactionCount: directCount,
            indirectTransactionCount: 0,
            childObjectCount: 0,
            affectedTransferCount: 0,
            isDefaultOrPreferred: false,
            isLastAvailable: false,
            hasUnmigratableRelationships: false
        )
    }

    @MainActor
    static func permanentlyDelete(
        account: Account,
        migratingTo target: Account? = nil,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let transactions = try LedgerQueryService.fetchForAccount(account.id, in: context)
        let accountSnapshots = accounts.map {
            ($0, $0.isDefault, $0.updatedAt)
        }
        guard accounts.contains(where: { $0.id == account.id }) else {
            throw FinanceDataManagementError.invalidMigrationTarget
        }
        let affected = transactions.filter {
            $0.accountID == account.id || $0.destinationAccountID == account.id
        }
        let remainingActive = accounts.filter {
            $0.id != account.id && $0.archivedAt == nil
        }
        guard !remainingActive.isEmpty else {
            throw FinanceDataManagementError.lastActiveAccount
        }

        let resolvedTarget: Account?
        if affected.isEmpty {
            if let target {
                resolvedTarget = try validAccountTarget(
                    target,
                    sourceID: account.id,
                    accounts: accounts
                )
            } else {
                resolvedTarget = nil
            }
        } else {
            guard let target else {
                throw FinanceDataManagementError.migrationRequired
            }
            resolvedTarget = try validAccountTarget(
                target,
                sourceID: account.id,
                accounts: accounts
            )
        }

        let transactionSnapshots = affected.map {
            ($0, $0.accountID, $0.destinationAccountID, $0.updatedAt)
        }
        if let resolvedTarget {
            for transaction in affected {
                guard transaction.currencyCode == resolvedTarget.currencyCode else {
                    throw FinanceDataManagementError.invalidMigrationTarget
                }
                let newSource = transaction.accountID == account.id
                    ? resolvedTarget.id
                    : transaction.accountID
                let newDestination = transaction.destinationAccountID == account.id
                    ? resolvedTarget.id
                    : transaction.destinationAccountID
                if transaction.type == .transfer && newSource == newDestination {
                    throw FinanceDataManagementError.transferMigrationConflict
                }
            }
        }

        let replacementDefault = resolvedTarget
            ?? remainingActive.sorted(by: accountOrder).first
        if account.isDefault {
            guard let replacementDefault else {
                throw FinanceDataManagementError.lastActiveAccount
            }
            for candidate in accounts where candidate.id != account.id {
                candidate.isDefault = candidate.id == replacementDefault.id
                if candidate.isDefault { candidate.updatedAt = now }
            }
        }
        if let resolvedTarget {
            for transaction in affected {
                if transaction.accountID == account.id {
                    transaction.accountID = resolvedTarget.id
                }
                if transaction.destinationAccountID == account.id {
                    transaction.destinationAccountID = resolvedTarget.id
                }
                transaction.updatedAt = now
            }
        }
        context.delete(account)
        do {
            try context.save()
        } catch {
            context.rollbackNotifyingSync()
            if !(try context.fetch(FetchDescriptor<Account>())).contains(where: {
                $0.id == account.id
            }) {
                context.insert(account)
            }
            for (candidate, isDefault, updatedAt) in accountSnapshots {
                candidate.isDefault = isDefault
                candidate.updatedAt = updatedAt
            }
            for (transaction, sourceID, destinationID, updatedAt) in transactionSnapshots {
                transaction.accountID = sourceID
                transaction.destinationAccountID = destinationID
                transaction.updatedAt = updatedAt
            }
            throw error
        }
    }

    @MainActor
    static func permanentlyDelete(
        category: Category,
        migratingTo target: Category? = nil,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        let categories = try context.fetch(FetchDescriptor<Category>())
        let transactions = try LedgerQueryService.fetchForCategory(category.id, in: context)
        guard categories.contains(where: { $0.id == category.id }) else {
            throw FinanceDataManagementError.invalidMigrationTarget
        }
        let hierarchy = CategoryHierarchy(categories: categories)
        guard hierarchy.children(of: category).isEmpty else {
            throw FinanceDataManagementError.categoryHasChildren
        }
        let affected = transactions.filter { $0.categoryID == category.id }
        let remainingHierarchy = CategoryHierarchy(categories: categories.filter { $0.id != category.id })
        if category.isActiveForSelection &&
            remainingHierarchy.selectableCategories(kind: category.kind).isEmpty {
            throw FinanceDataManagementError.lastActiveCategory
        }

        let resolvedTarget: Category?
        if affected.isEmpty {
            if let target {
                resolvedTarget = try validCategoryTarget(
                    target,
                    source: category,
                    categories: categories
                )
            } else {
                resolvedTarget = nil
            }
        } else {
            guard let target else {
                throw FinanceDataManagementError.migrationRequired
            }
            resolvedTarget = try validCategoryTarget(
                target,
                source: category,
                categories: categories
            )
        }

        let transactionSnapshots = affected.map {
            ($0, $0.categoryID, $0.categoryDecisionSource, $0.updatedAt)
        }
        let targetSnapshot = resolvedTarget.map {
            ($0, $0.isPinnedForQuickAdd, $0.updatedAt)
        }
        if let resolvedTarget {
            if category.isPinnedForQuickAdd {
                resolvedTarget.isPinnedForQuickAdd = true
                resolvedTarget.updatedAt = now
            }
            for transaction in affected {
                transaction.categoryID = resolvedTarget.id
                transaction.categoryDecisionSource = .unchanged
                transaction.updatedAt = now
            }
        }
        if !category.defaultDefinitionKey.isEmpty {
            let metadata = try context.fetch(FetchDescriptor<AppMetadata>()).first ?? {
                let created = AppMetadata()
                context.insert(created)
                return created
            }()
            var tombstones = metadata.deletedDefaultCategoryKeys
            tombstones.insert(category.defaultDefinitionKey)
            metadata.deletedDefaultCategoryKeys = tombstones
            metadata.updatedAt = now
        }
        context.delete(category)
        do {
            try context.save()
        } catch {
            context.rollbackNotifyingSync()
            if !(try context.fetch(FetchDescriptor<Category>())).contains(where: {
                $0.id == category.id
            }) {
                context.insert(category)
            }
            if let (target, wasPinned, updatedAt) = targetSnapshot {
                target.isPinnedForQuickAdd = wasPinned
                target.updatedAt = updatedAt
            }
            for (transaction, categoryID, categoryDecisionSource, updatedAt) in transactionSnapshots {
                transaction.categoryID = categoryID
                transaction.categoryDecisionSource = categoryDecisionSource
                transaction.updatedAt = updatedAt
            }
            throw error
        }
    }

    @MainActor
    static func permanentlyDelete(
        tag: Tag,
        resolution: TagDeletionResolution? = nil,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        let tags = try context.fetch(FetchDescriptor<Tag>())
        let transactions = try LedgerQueryService.fetchForTag(tag.id, in: context)
        guard tags.contains(where: { $0.id == tag.id }) else {
            throw FinanceDataManagementError.invalidMigrationTarget
        }
        let affected = transactions.filter { transaction in
            transaction.tags.contains { $0.id == tag.id }
        }
        if !affected.isEmpty && resolution == nil {
            throw FinanceDataManagementError.migrationRequired
        }

        let replacement: Tag?
        switch resolution {
        case .replace(let targetID):
            guard let target = tags.first(where: {
                $0.id == targetID &&
                $0.id != tag.id &&
                $0.archivedAt == nil
            }) else {
                throw FinanceDataManagementError.invalidMigrationTarget
            }
            replacement = target
        case .remove, .none:
            replacement = nil
        }

        let transactionSnapshots = affected.map {
            ($0, $0.tags, $0.updatedAt)
        }
        for transaction in affected {
            var retained = transaction.tags.filter { $0.id != tag.id }
            if let replacement, !retained.contains(where: { $0.id == replacement.id }) {
                retained.append(replacement)
            }
            transaction.tags = retained
            transaction.updatedAt = now
        }
        context.delete(tag)
        do {
            try context.save()
        } catch {
            context.rollbackNotifyingSync()
            if !(try context.fetch(FetchDescriptor<Tag>())).contains(where: {
                $0.id == tag.id
            }) {
                context.insert(tag)
            }
            for (transaction, tags, updatedAt) in transactionSnapshots {
                transaction.tags = tags
                transaction.updatedAt = updatedAt
            }
            throw error
        }
    }
    @MainActor
    static func addAccount(
        name: String,
        type: AccountType,
        accounts: [Account],
        in context: ModelContext,
        now: Date = Date()
    ) throws -> Account {
        try withMetadataBoundary(in: context) { currentContext in
            let accounts = try currentContext.fetch(FetchDescriptor<Account>())
            let cleanName = try validatedName(name)
            let account = Account(
                name: cleanName,
                type: type,
                isDefault: !accounts.contains { $0.archivedAt == nil && $0.isDefault },
                sortOrder: (accounts.map(\.sortOrder).max() ?? -1) + 1,
                createdAt: now,
                updatedAt: now
            )
            context.insert(account)
            do {
                try context.save()
                return account
            } catch {
                context.rollbackNotifyingSync()
                throw error
            }
        }
    }

    @MainActor
    static func rename(
        account: Account,
        to name: String,
        baseline: MetadataEditSnapshot.AccountValue? = nil,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        try withAccountEditBoundary(target: account, baseline: baseline, in: context) { _ in
            account.name = try validatedName(name)
            account.updatedAt = now
            try saveOrRollback(context)
        }
    }

    @MainActor
    static func setDefault(
        _ account: Account,
        accounts: [Account],
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        try withAccountEditBoundary(target: account, in: context) { accounts in
            guard account.archivedAt == nil else {
                throw FinanceDataManagementError.archivedAccountCannotBeDefault
            }
            for candidate in accounts {
                candidate.isDefault = candidate.id == account.id
                if candidate.id == account.id {
                    candidate.updatedAt = now
                }
            }
            try saveOrRollback(context)
        }
    }

    @MainActor
    static func setAccountActive(
        _ account: Account,
        isActive: Bool,
        accounts: [Account],
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        try withAccountEditBoundary(target: account, in: context) { accounts in
            if isActive {
                account.archivedAt = nil
                if !accounts.contains(where: {
                    $0.id != account.id && $0.archivedAt == nil && $0.isDefault
                }) {
                    account.isDefault = true
                }
            } else {
                let replacements = accounts.filter {
                    $0.id != account.id && $0.archivedAt == nil
                }
                guard !replacements.isEmpty else {
                    throw FinanceDataManagementError.lastActiveAccount
                }
                account.archivedAt = now
                if account.isDefault {
                    account.isDefault = false
                    replacements.sorted(by: accountOrder).first?.isDefault = true
                }
            }
            account.updatedAt = now
            try saveOrRollback(context)
        }
    }

    @MainActor
    static func addCategory(
        name: String,
        kind: CategoryKind,
        parentID: UUID? = nil,
        symbolName: String? = nil,
        categories: [Category],
        in context: ModelContext,
        now: Date = Date()
    ) throws -> Category {
        try withMetadataBoundary(in: context) { currentContext in
            let categories = try currentContext.fetch(FetchDescriptor<Category>())
            let hierarchy = CategoryHierarchy(categories: categories)
            try hierarchy.validate(kind: kind, parentID: parentID)
            let cleanName = try uniqueCategoryName(
                name,
                kind: kind,
                parentID: parentID,
                excluding: nil,
                categories: categories
            )
            let resolvedSymbolName: String
            if let symbolName {
                guard let normalized = CategoryIconLibrary.normalizedStoredValue(symbolName) else {
                    throw FinanceDataManagementError.invalidCategoryIcon
                }
                resolvedSymbolName = normalized
            } else {
                resolvedSymbolName = CategoryIconLibrary.suggestedSymbol(for: name, kind: kind)
            }
            let category = Category(
                kind: kind,
                name: cleanName,
                parentID: parentID,
                symbolName: resolvedSymbolName,
                colorToken: "teal",
                sortOrder: (
                    categories
                        .filter { $0.kind == kind && $0.parentID == parentID }
                        .map(\.sortOrder)
                        .max() ?? -1
                ) + 1,
                createdAt: now,
                updatedAt: now
            )
            context.insert(category)
            do {
                try context.save()
                return category
            } catch {
                context.rollbackNotifyingSync()
                throw error
            }
        }
    }

    @MainActor
    static func reorderCategories(
        orderedIDs: [UUID],
        kind: CategoryKind,
        parentID: UUID?,
        categories: [Category],
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        try withCategoryEditBoundary(target: nil, in: context) { categories in
            let hierarchy = CategoryHierarchy(categories: categories)
            try hierarchy.validate(kind: kind, parentID: parentID)
            let siblings = hierarchy.siblings(kind: kind, parentID: parentID)
            guard orderedIDs.count == siblings.count,
                  Set(orderedIDs).count == orderedIDs.count,
                  Set(orderedIDs) == Set(siblings.map(\.id)) else {
                throw FinanceDataManagementError.invalidCategoryOrder
            }

            let siblingsByID = Dictionary(uniqueKeysWithValues: siblings.map { ($0.id, $0) })
            let snapshots = siblings.map { ($0, $0.sortOrder, $0.updatedAt) }
            for (index, id) in orderedIDs.enumerated() {
                siblingsByID[id]?.sortOrder = index
                siblingsByID[id]?.updatedAt = now
            }
            do {
                try context.save()
            } catch {
                context.rollbackNotifyingSync()
                for (category, sortOrder, updatedAt) in snapshots {
                    category.sortOrder = sortOrder
                    category.updatedAt = updatedAt
                }
                throw error
            }
        }
    }

    @MainActor
    static func rename(
        category: Category,
        to name: String,
        baseline: MetadataEditSnapshot.CategoryValue? = nil,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        try withCategoryEditBoundary(target: category, baseline: baseline, in: context) { categories in
            category.name = try uniqueCategoryName(
                name,
                kind: category.kind,
                parentID: category.parentID,
                excluding: category.id,
                categories: categories
            )
            category.updatedAt = now
            try saveOrRollback(context)
        }
    }

    @MainActor
    static func update(
        category: Category,
        name: String,
        symbolName: String,
        baseline: MetadataEditSnapshot.CategoryValue? = nil,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        try withCategoryEditBoundary(target: category, baseline: baseline, in: context) { categories in
            guard let normalized = CategoryIconLibrary.normalizedStoredValue(symbolName) else {
                throw FinanceDataManagementError.invalidCategoryIcon
            }
            category.name = try uniqueCategoryName(
                name,
                kind: category.kind,
                parentID: category.parentID,
                excluding: category.id,
                categories: categories
            )
            category.symbolName = normalized
            category.updatedAt = now
            try saveOrRollback(context)
        }
    }

    @MainActor
    static func update(
        category: Category,
        name: String,
        parentID: UUID?,
        symbolName: String,
        categories: [Category],
        baseline: MetadataEditSnapshot.CategoryValue? = nil,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        try withCategoryEditBoundary(target: category, baseline: baseline, in: context) { categories in
            let hierarchy = CategoryHierarchy(categories: categories)
            guard let normalized = CategoryIconLibrary.normalizedStoredValue(symbolName) else {
                throw FinanceDataManagementError.invalidCategoryIcon
            }
            try hierarchy.validate(
                kind: category.kind,
                parentID: parentID,
                categoryID: category.id
            )
            if category.parentID == nil,
               parentID != nil,
               !hierarchy.children(of: category).isEmpty {
                throw CategoryHierarchyError.parentIsChild
            }
            category.name = try uniqueCategoryName(
                name,
                kind: category.kind,
                parentID: parentID,
                excluding: category.id,
                categories: categories
            )
            category.parentID = parentID
            category.symbolName = normalized
            category.updatedAt = now
            try saveOrRollback(context)
        }
    }

    @MainActor
    static func addTag(
        name: String,
        tags: [Tag],
        in context: ModelContext,
        now: Date = Date()
    ) throws -> Tag {
        try withMetadataBoundary(in: context) { currentContext in
            let tags = try currentContext.fetch(FetchDescriptor<Tag>())
            let value = try uniqueName(name, excluding: nil, existing: tags.map { ($0.id, $0.name) })
            let tag = Tag(
                name: value,
                sortOrder: (tags.map(\.sortOrder).max() ?? -1) + 1,
                createdAt: now,
                updatedAt: now
            )
            context.insert(tag)
            try saveOrRollback(context)
            return tag
        }
    }

    @MainActor
    static func rename(
        tag: Tag,
        to name: String,
        tags: [Tag],
        baseline: MetadataEditSnapshot.TagValue? = nil,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        try withTagEditBoundary(target: tag, baseline: baseline, in: context) { tags in
            tag.name = try uniqueName(
                name,
                excluding: tag.id,
                existing: tags.map { ($0.id, $0.name) }
            )
            tag.updatedAt = now
            try saveOrRollback(context)
        }
    }

    @MainActor
    static func setTagActive(
        _ tag: Tag,
        isActive: Bool,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        try withTagEditBoundary(target: tag, in: context) { _ in
            tag.archivedAt = isActive ? nil : now
            tag.updatedAt = now
            try saveOrRollback(context)
        }
    }

    @MainActor
    static func setCategoryActive(
        _ category: Category,
        isActive: Bool,
        categories: [Category],
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        try withCategoryEditBoundary(target: category, in: context) { categories in
            if isActive {
                category.archivedAt = nil
                category.isHidden = false
            } else {
                let hierarchy = CategoryHierarchy(categories: categories)
                guard hierarchy.children(of: category, activeOnly: true).isEmpty else {
                    throw FinanceDataManagementError.categoryHasChildren
                }
                let remainingHierarchy = CategoryHierarchy(categories: categories.filter { $0.id != category.id })
                guard !remainingHierarchy.selectableCategories(kind: category.kind).isEmpty else {
                    throw FinanceDataManagementError.lastActiveCategory
                }
                category.archivedAt = now
            }
            category.updatedAt = now
            try saveOrRollback(context)
        }
    }

    @MainActor
    private static func withAccountEditBoundary<T>(
        target: Account?,
        baseline: MetadataEditSnapshot.AccountValue? = nil,
        in context: ModelContext,
        _ body: ([Account]) throws -> T
    ) throws -> T {
        let targetValue = baseline ?? target.map(MetadataEditSnapshot.AccountValue.init)
        return try withMetadataBoundary(in: context) { fresh in
            let current = try fresh.fetch(FetchDescriptor<Account>())
            let accounts = try context.fetch(FetchDescriptor<Account>())
            let currentValues = Dictionary(grouping: current.map(MetadataEditSnapshot.AccountValue.init), by: \.id)
            let cachedValues = Dictionary(grouping: accounts.map(MetadataEditSnapshot.AccountValue.init), by: \.id)
            guard currentValues == cachedValues,
                  (targetValue.map { currentValues[$0.id] == [$0] } ?? true),
                  target == nil || (target?.modelContext === context && current.contains { $0.id == target?.id }) else {
                throw FinanceDataManagementError.staleMetadata
            }
            return try body(accounts)
        }
    }

    @MainActor
    private static func withCategoryEditBoundary<T>(
        target: Category?,
        baseline: MetadataEditSnapshot.CategoryValue? = nil,
        in context: ModelContext,
        _ body: ([Category]) throws -> T
    ) throws -> T {
        let targetValue = baseline ?? target.map(MetadataEditSnapshot.CategoryValue.init)
        return try withMetadataBoundary(in: context) { fresh in
            let current = try fresh.fetch(FetchDescriptor<Category>())
            let categories = try context.fetch(FetchDescriptor<Category>())
            let currentValues = Dictionary(grouping: current.map(MetadataEditSnapshot.CategoryValue.init), by: \.id)
            let cachedValues = Dictionary(grouping: categories.map(MetadataEditSnapshot.CategoryValue.init), by: \.id)
            guard currentValues == cachedValues,
                  (targetValue.map { currentValues[$0.id] == [$0] } ?? true),
                  target == nil || (target?.modelContext === context && current.contains { $0.id == target?.id }) else {
                throw FinanceDataManagementError.staleMetadata
            }
            return try body(categories)
        }
    }

    @MainActor
    private static func withTagEditBoundary<T>(
        target: Tag?,
        baseline: MetadataEditSnapshot.TagValue? = nil,
        in context: ModelContext,
        _ body: ([Tag]) throws -> T
    ) throws -> T {
        let targetValue = baseline ?? target.map(MetadataEditSnapshot.TagValue.init)
        return try withMetadataBoundary(in: context) { fresh in
            let current = try fresh.fetch(FetchDescriptor<Tag>())
            let tags = try context.fetch(FetchDescriptor<Tag>())
            let currentValues = Dictionary(grouping: current.map(MetadataEditSnapshot.TagValue.init), by: \.id)
            let cachedValues = Dictionary(grouping: tags.map(MetadataEditSnapshot.TagValue.init), by: \.id)
            guard currentValues == cachedValues,
                  (targetValue.map { currentValues[$0.id] == [$0] } ?? true),
                  target == nil || (target?.modelContext === context && current.contains { $0.id == target?.id }) else {
                throw FinanceDataManagementError.staleMetadata
            }
            return try body(tags)
        }
    }

    /// Read and write share the same nonblocking admission as import and migration.
    /// Cached UI arrays never authorize a mutation; scalar editors also compare immutable values.
    @MainActor
    private static func withMetadataBoundary<T>(
        in context: ModelContext,
        _ body: (ModelContext) throws -> T
    ) throws -> T {
        do {
            return try LedgerSaveRevision.shared.withProjectionBoundary {
                guard !context.hasChanges else { throw FinanceDataManagementError.pendingChanges }
                return try body(ModelContext(context.container))
            }
        } catch ReconcileRevision.Failure.stalePlan {
            throw FinanceDataManagementError.busy
        }
    }

    private static func validatedName(_ value: String) throws -> String {
        let cleanName = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw FinanceDataManagementError.emptyName
        }
        return cleanName
    }

    private static func uniqueName(
        _ value: String,
        excluding id: UUID?,
        existing: [(UUID, String)]
    ) throws -> String {
        let name = try validatedName(value)
        guard !existing.contains(where: {
            $0.0 != id && $0.1.compare(
                name,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }) else {
            throw FinanceDataManagementError.duplicateName
        }
        return name
    }

    private static func uniqueCategoryName(
        _ value: String,
        kind: CategoryKind,
        parentID: UUID?,
        excluding id: UUID?,
        categories: [Category]
    ) throws -> String {
        let name = try validatedName(value)
        guard !categories.contains(where: {
            $0.id != id &&
            $0.kind == kind &&
            $0.parentID == parentID &&
            $0.name.compare(
                name,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }) else {
            throw FinanceDataManagementError.duplicateName
        }
        return name
    }

    @MainActor
    private static func saveOrRollback(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollbackNotifyingSync()
            throw error
        }
    }

    private static func accountOrder(_ left: Account, _ right: Account) -> Bool {
        if left.sortOrder != right.sortOrder {
            return left.sortOrder < right.sortOrder
        }
        return left.id.uuidString < right.id.uuidString
    }

    private static func validAccountTarget(
        _ target: Account,
        sourceID: UUID,
        accounts: [Account]
    ) throws -> Account {
        guard target.id != sourceID,
              target.archivedAt == nil,
              let stored = accounts.first(where: { $0.id == target.id }),
              stored.archivedAt == nil else {
            throw FinanceDataManagementError.invalidMigrationTarget
        }
        return stored
    }

    private static func validCategoryTarget(
        _ target: Category,
        source: Category,
        categories: [Category]
    ) throws -> Category {
        guard target.id != source.id,
              target.kind == source.kind,
              target.archivedAt == nil,
              !target.isHidden,
              let stored = categories.first(where: { $0.id == target.id }),
              stored.kind == source.kind,
              stored.archivedAt == nil,
              !stored.isHidden,
              CategoryHierarchy(categories: categories)
                .selectableCategories(kind: source.kind)
                .contains(where: { $0.id == stored.id }) else {
            throw FinanceDataManagementError.invalidMigrationTarget
        }
        return stored
    }
}
