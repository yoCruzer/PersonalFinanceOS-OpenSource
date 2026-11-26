import Foundation
import SwiftData

struct MetadataDeletionPlan: Equatable, Sendable {
    let analysis: MetadataDeletionAnalysis
    let validTargetIDs: Set<UUID>
}

struct MetadataMutationResult: Equatable, Sendable {
    let changedTransactionCount: Int
}

actor MetadataMutationActor {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) { self.modelContainer = modelContainer }

    func analyzeAccount(id: UUID) throws -> MetadataDeletionPlan {
        try MetadataMutationWriter(modelContext: ModelContext(modelContainer)).analyzeAccount(id: id)
    }

    func analyzeCategory(id: UUID) throws -> MetadataDeletionPlan {
        try MetadataMutationWriter(modelContext: ModelContext(modelContainer)).analyzeCategory(id: id)
    }

    func analyzeTag(id: UUID) throws -> MetadataDeletionPlan {
        try MetadataMutationWriter(modelContext: ModelContext(modelContainer)).analyzeTag(id: id)
    }

    func deleteAccount(id: UUID, targetID: UUID?, now: Date = Date()) throws -> MetadataMutationResult {
        try mutate { try $0.deleteAccount(id: id, targetID: targetID, now: now) }
    }

    func deleteCategory(id: UUID, targetID: UUID?, now: Date = Date(),
                        onBoundaryContention: (@Sendable () -> Void)? = nil) throws -> MetadataMutationResult {
        try mutate(onContention: onBoundaryContention) { try $0.deleteCategory(id: id, targetID: targetID, now: now) }
    }

    func deleteTag(id: UUID, resolution: TagDeletionResolution?, now: Date = Date()) throws -> MetadataMutationResult {
        try mutate { try $0.deleteTag(id: id, resolution: resolution, now: now) }
    }

    private func mutate(onContention: (@Sendable () -> Void)? = nil,
                        _ body: (MetadataMutationWriter) throws -> MetadataMutationResult) rethrows -> MetadataMutationResult {
        try LedgerSaveRevision.shared.withImportBoundary(onContention: onContention) {
            // A preview actor may hold registered values from before an import/projection.
            // Resolve relationships and migration policy again after acquiring the boundary.
            let context = ModelContext(modelContainer)
            do { return try body(MetadataMutationWriter(modelContext: context)) }
            catch { context.rollbackNotifyingSync(); throw error }
        }
    }
}

private struct MetadataMutationWriter {
    let modelContext: ModelContext

    func analyzeAccount(id: UUID) throws -> MetadataDeletionPlan {
        let source = try account(id: id)
        let accounts = try modelContext.fetch(FetchDescriptor<Account>())
        let transactions = try accountTransactions(id: id)
        let activeTargets = accounts.filter { $0.id != id && $0.archivedAt == nil }
        let direct = transactions.filter { $0.accountID == id }
        let indirect = transactions.filter { $0.destinationAccountID == id }
        let affectedTransfers = transactions.filter {
            $0.type == .transfer && ($0.accountID == id || $0.destinationAccountID == id)
        }
        let validTargetIDs = Set(activeTargets.compactMap { target -> UUID? in
            guard transactions.allSatisfy({ $0.currencyCode == target.currencyCode }) else {
                return nil
            }
            guard transactions.allSatisfy({ transaction in
                guard transaction.type == .transfer else { return true }
                let newSource = transaction.accountID == id ? target.id : transaction.accountID
                let newDestination = transaction.destinationAccountID == id
                    ? target.id : transaction.destinationAccountID
                return newSource != newDestination
            }) else { return nil }
            return target.id
        })
        return MetadataDeletionPlan(
            analysis: MetadataDeletionAnalysis(
                directTransactionCount: direct.count,
                indirectTransactionCount: indirect.count,
                childObjectCount: 0,
                affectedTransferCount: affectedTransfers.count,
                isDefaultOrPreferred: source.isDefault,
                isLastAvailable: activeTargets.isEmpty,
                hasUnmigratableRelationships: !transactions.isEmpty && validTargetIDs.isEmpty
            ),
            validTargetIDs: validTargetIDs
        )
    }

    func analyzeCategory(id: UUID) throws -> MetadataDeletionPlan {
        let source = try category(id: id)
        let categories = try modelContext.fetch(FetchDescriptor<Category>())
        let transactions = try categoryTransactions(id: id)
        let hierarchy = CategoryHierarchy(categories: categories)
        let children = hierarchy.children(of: source)
        let remaining = CategoryHierarchy(categories: categories.filter { $0.id != id })
        let targets = remaining.selectableCategories(kind: source.kind)
        return MetadataDeletionPlan(
            analysis: MetadataDeletionAnalysis(
                directTransactionCount: transactions.count,
                indirectTransactionCount: 0,
                childObjectCount: children.count,
                affectedTransferCount: 0,
                isDefaultOrPreferred: source.isPinnedForQuickAdd || source.isSystemCategory,
                isLastAvailable: targets.isEmpty,
                hasUnmigratableRelationships: !children.isEmpty
            ),
            validTargetIDs: Set(targets.map(\.id))
        )
    }

    func analyzeTag(id: UUID) throws -> MetadataDeletionPlan {
        _ = try tag(id: id)
        let count = try tagTransactions(id: id).count
        let targets = try modelContext.fetch(FetchDescriptor<Tag>()).filter {
            $0.id != id && $0.archivedAt == nil
        }
        return MetadataDeletionPlan(
            analysis: MetadataDeletionAnalysis(
                directTransactionCount: count,
                indirectTransactionCount: 0,
                childObjectCount: 0,
                affectedTransferCount: 0,
                isDefaultOrPreferred: false,
                isLastAvailable: false,
                hasUnmigratableRelationships: false
            ),
            validTargetIDs: Set(targets.map(\.id))
        )
    }

    func deleteAccount(
        id: UUID,
        targetID: UUID?,
        now: Date = Date()
    ) throws -> MetadataMutationResult {
        let source = try account(id: id)
        let accounts = try modelContext.fetch(FetchDescriptor<Account>())
        let affected = try accountTransactions(id: id)
        let remainingActive = accounts.filter { $0.id != id && $0.archivedAt == nil }
        guard !remainingActive.isEmpty else { throw FinanceDataManagementError.lastActiveAccount }
        let target = try resolveAccountTarget(
            targetID,
            sourceID: id,
            affected: affected,
            accounts: accounts
        )
        if source.isDefault {
            let replacement = target ?? remainingActive.sorted(by: Self.accountOrder).first
            guard let replacement else { throw FinanceDataManagementError.lastActiveAccount }
            for account in accounts where account.id != id {
                let shouldBeDefault = account.id == replacement.id
                if account.isDefault != shouldBeDefault {
                    account.isDefault = shouldBeDefault
                    account.updatedAt = now
                }
            }
        }
        if let target {
            for transaction in affected {
                if transaction.accountID == id { transaction.accountID = target.id }
                if transaction.destinationAccountID == id {
                    transaction.destinationAccountID = target.id
                }
                transaction.updatedAt = now
            }
        }
        modelContext.delete(source)
        try saveOrRollback()
        return MetadataMutationResult(changedTransactionCount: affected.count)
    }

    func deleteCategory(
        id: UUID,
        targetID: UUID?,
        now: Date = Date()
    ) throws -> MetadataMutationResult {
        let source = try category(id: id)
        let categories = try modelContext.fetch(FetchDescriptor<Category>())
        let hierarchy = CategoryHierarchy(categories: categories)
        guard hierarchy.children(of: source).isEmpty else {
            throw FinanceDataManagementError.categoryHasChildren
        }
        let affected = try categoryTransactions(id: id)
        let remaining = CategoryHierarchy(categories: categories.filter { $0.id != id })
        if source.isActiveForSelection,
           remaining.selectableCategories(kind: source.kind).isEmpty {
            throw FinanceDataManagementError.lastActiveCategory
        }
        let target = try resolveCategoryTarget(
            targetID,
            source: source,
            affected: affected,
            categories: categories
        )
        if let target {
            if source.isPinnedForQuickAdd {
                target.isPinnedForQuickAdd = true
                target.updatedAt = now
            }
            for transaction in affected {
                transaction.categoryID = target.id
                transaction.categoryDecisionSource = .unchanged
                transaction.updatedAt = now
            }
        }
        var deletedKeys: Set<String> = []
        if !source.defaultDefinitionKey.isEmpty {
            deletedKeys.insert(source.defaultDefinitionKey)
        } else {
            // Use the same narrow purpose proof as automatic reuse; do not stamp a custom row.
            let metadataRows = try modelContext.fetch(FetchDescriptor<AppMetadata>())
            let snapshot = CategoryCatalogPlanner.Snapshot(categories: categories.map(MetadataEditSnapshot.CategoryValue.init),
                metadata: metadataRows.map { .init(id: $0.id, seedVersion: $0.defaultCategorySeedVersion,
                    deletedKeys: $0.deletedDefaultCategoryKeys) })
            let plan = CategoryCatalogPlanner.additions(catalog: try CategoryCatalog.load(), snapshot: snapshot, readiness: .offline)
            if plan.canCommit {
                for entry in plan.entries where plan.reusableIDs[entry.id] == id {
                    deletedKeys.insert(entry.definition.storageDefaultKey)
                }
            }
        }
        if !deletedKeys.isEmpty {
            let metadata = try modelContext.fetch(FetchDescriptor<AppMetadata>()).first ?? {
                let value = AppMetadata()
                modelContext.insert(value)
                return value
            }()
            var tombstones = metadata.deletedDefaultCategoryKeys
            tombstones.formUnion(deletedKeys)
            metadata.deletedDefaultCategoryKeys = tombstones
            metadata.updatedAt = now
        }
        modelContext.delete(source)
        try saveOrRollback()
        return MetadataMutationResult(changedTransactionCount: affected.count)
    }

    func deleteTag(
        id: UUID,
        resolution: TagDeletionResolution?,
        now: Date = Date()
    ) throws -> MetadataMutationResult {
        let source = try tag(id: id)
        let affected = try tagTransactions(id: id)
        guard affected.isEmpty || resolution != nil else {
            throw FinanceDataManagementError.migrationRequired
        }
        let replacement: Tag?
        switch resolution {
        case let .replace(targetID):
            let value = try tag(id: targetID)
            guard value.id != id, value.archivedAt == nil else {
                throw FinanceDataManagementError.invalidMigrationTarget
            }
            replacement = value
        case .remove, .none:
            replacement = nil
        }
        for transaction in affected {
            transaction.tags.removeAll { $0.id == id || $0.id == replacement?.id }
            if let replacement { transaction.tags.append(replacement) }
            transaction.updatedAt = now
        }
        modelContext.delete(source)
        try saveOrRollback()
        return MetadataMutationResult(changedTransactionCount: affected.count)
    }

    private func account(id: UUID) throws -> Account {
        var descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let value = try modelContext.fetch(descriptor).first else {
            throw FinanceDataManagementError.invalidMigrationTarget
        }
        return value
    }

    private func category(id: UUID) throws -> Category {
        var descriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let value = try modelContext.fetch(descriptor).first else {
            throw FinanceDataManagementError.invalidMigrationTarget
        }
        return value
    }

    private func tag(id: UUID) throws -> Tag {
        var descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let value = try modelContext.fetch(descriptor).first else {
            throw FinanceDataManagementError.invalidMigrationTarget
        }
        return value
    }

    private func accountTransactions(id: UUID) throws -> [FinanceTransaction] {
        try modelContext.fetch(FetchDescriptor<FinanceTransaction>(predicate: #Predicate {
            $0.accountID == id || $0.destinationAccountID == id
        }))
    }

    private func categoryTransactions(id: UUID) throws -> [FinanceTransaction] {
        try modelContext.fetch(FetchDescriptor<FinanceTransaction>(predicate: #Predicate {
            $0.categoryID == id
        }))
    }

    private func tagTransactions(id: UUID) throws -> [FinanceTransaction] {
        try modelContext.fetch(FetchDescriptor<FinanceTransaction>(predicate: #Predicate { transaction in
            transaction.storedTags?.contains { $0.id == id } == true
        }))
    }

    private func resolveAccountTarget(
        _ targetID: UUID?,
        sourceID: UUID,
        affected: [FinanceTransaction],
        accounts: [Account]
    ) throws -> Account? {
        guard !affected.isEmpty else {
            guard let targetID else { return nil }
            return try validAccountTarget(targetID, sourceID: sourceID, accounts: accounts)
        }
        guard let targetID else { throw FinanceDataManagementError.migrationRequired }
        let target = try validAccountTarget(targetID, sourceID: sourceID, accounts: accounts)
        for transaction in affected {
            guard transaction.currencyCode == target.currencyCode else {
                throw FinanceDataManagementError.invalidMigrationTarget
            }
            let newSource = transaction.accountID == sourceID ? target.id : transaction.accountID
            let newDestination = transaction.destinationAccountID == sourceID
                ? target.id : transaction.destinationAccountID
            if transaction.type == .transfer, newSource == newDestination {
                throw FinanceDataManagementError.transferMigrationConflict
            }
        }
        return target
    }

    private func validAccountTarget(
        _ targetID: UUID,
        sourceID: UUID,
        accounts: [Account]
    ) throws -> Account {
        guard targetID != sourceID,
              let target = accounts.first(where: { $0.id == targetID }),
              target.archivedAt == nil else {
            throw FinanceDataManagementError.invalidMigrationTarget
        }
        return target
    }

    private func resolveCategoryTarget(
        _ targetID: UUID?,
        source: Category,
        affected: [FinanceTransaction],
        categories: [Category]
    ) throws -> Category? {
        guard !affected.isEmpty else {
            guard let targetID else { return nil }
            return try validCategoryTarget(targetID, source: source, categories: categories)
        }
        guard let targetID else { throw FinanceDataManagementError.migrationRequired }
        return try validCategoryTarget(targetID, source: source, categories: categories)
    }

    private func validCategoryTarget(
        _ targetID: UUID,
        source: Category,
        categories: [Category]
    ) throws -> Category {
        guard targetID != source.id,
              let target = categories.first(where: { $0.id == targetID }),
              target.kind == source.kind,
              target.archivedAt == nil,
              !target.isHidden,
              CategoryHierarchy(categories: categories)
                .selectableCategories(kind: source.kind)
                .contains(where: { $0.id == targetID }) else {
            throw FinanceDataManagementError.invalidMigrationTarget
        }
        return target
    }

    private func saveOrRollback() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollbackNotifyingSync()
            throw error
        }
    }

    private static func accountOrder(_ left: Account, _ right: Account) -> Bool {
        if left.sortOrder != right.sortOrder { return left.sortOrder < right.sortOrder }
        return left.id.uuidString < right.id.uuidString
    }
}
