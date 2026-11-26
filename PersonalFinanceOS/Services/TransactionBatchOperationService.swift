import Foundation
import SwiftData

struct TransactionBatchSelection: Equatable {
    private(set) var ids: Set<UUID> = []

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    mutating func toggle(_ id: UUID) {
        if !ids.insert(id).inserted { ids.remove(id) }
    }

    mutating func selectAll(currentResultIDs: [UUID]) {
        ids = Set(currentResultIDs)
    }

    mutating func clear() {
        ids.removeAll()
    }

    mutating func reconcile(currentResultIDs: [UUID]) {
        ids.formIntersection(currentResultIDs)
    }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }
}

struct TransactionBatchSummary: Equatable, Sendable {
    let count: Int
    let incomeMinorUnits: Int64
    let expenseMinorUnits: Int64

    static func make(transactions: [FinanceTransaction], selectedIDs: Set<UUID>) -> Self {
        let selected = transactions.filter { selectedIDs.contains($0.id) && $0.deletedAt == nil }
        var income: Int64 = 0
        var expense: Int64 = 0
        for transaction in selected {
            switch transaction.type {
            case .income:
                income = safeAdd(income, transaction.amountMinorUnits)
            case .expense:
                expense = safeAdd(expense, transaction.amountMinorUnits)
            case .refund:
                expense = safeSubtract(expense, transaction.amountMinorUnits)
            case .transfer:
                break
            }
        }
        return Self(
            count: selected.count,
            incomeMinorUnits: income,
            expenseMinorUnits: expense
        )
    }

    private static func safeAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (result, overflow) = left.addingReportingOverflow(right)
        return overflow ? .max : result
    }

    private static func safeSubtract(_ left: Int64, _ right: Int64) -> Int64 {
        let (result, overflow) = left.subtractingReportingOverflow(right)
        return overflow ? .min : result
    }
}

enum TransactionBatchTagOperation: Equatable, Sendable {
    case add(UUID)
    case remove(UUID)
    case replace(sourceID: UUID, targetID: UUID)
}

enum TransactionBatchOperationError: LocalizedError, Equatable, Sendable {
    case noSelection
    case invalidAccount
    case incompatibleCurrency
    case transferConflict
    case invalidCategory
    case categoryKindMismatch
    case invalidTag
    case sameTagReplacement

    var errorDescription: String? {
        switch self {
        case .noSelection: "没有可操作的交易。"
        case .invalidAccount: "目标账户不可用。"
        case .incompatibleCurrency: "目标账户币种与所选交易不一致。"
        case .transferConflict: "迁移会让转账的转出和转入账户相同。"
        case .invalidCategory: "目标分类不可用。"
        case .categoryKindMismatch: "目标分类与所选交易的收支类型不一致。"
        case .invalidTag: "目标标签不可用。"
        case .sameTagReplacement: "来源标签和目标标签不能相同。"
        }
    }
}

enum TransactionBatchOperationService {
    @MainActor
    static func exportData(
        selectedIDs: Set<UUID>,
        transactions: [FinanceTransaction],
        categories: [Category],
        accounts: [Account]
    ) throws -> Data {
        let selected = activeSelection(selectedIDs, transactions: transactions)
        guard !selected.isEmpty else { throw TransactionBatchOperationError.noSelection }
        return FinanceCSVService.exportData(
            transactions: selected,
            categories: categories,
            accounts: accounts
        )
    }

    @MainActor
    static func softDelete(
        selectedIDs: Set<UUID>,
        transactions: [FinanceTransaction],
        in context: ModelContext,
        now: Date = Date(),
        save: (() throws -> Void)? = nil
    ) throws -> TransactionBatchSummary {
        let selected = try refetchedActiveSelection(selectedIDs, in: context)
        let summary = TransactionBatchSummary.make(
            transactions: selected,
            selectedIDs: Set(selected.map(\.id))
        )
        try atomically(selected, in: context, save: save) {
            $0.deletedAt = now
            $0.updatedAt = now
        }
        return summary
    }

    @MainActor
    static func planAccountMigration(
        selectedIDs: Set<UUID>,
        to target: Account,
        in context: ModelContext
    ) throws -> TransactionBatchSummary {
        summary(try accountMigrationChanges(selectedIDs: selectedIDs, to: target, in: context).0)
    }

    @MainActor
    static func migrateAccount(
        selectedIDs: Set<UUID>,
        to target: Account,
        transactions: [FinanceTransaction],
        in context: ModelContext,
        now: Date = Date(),
        save: (() throws -> Void)? = nil
    ) throws -> TransactionBatchSummary {
        let (changed, currentTarget) = try accountMigrationChanges(
            selectedIDs: selectedIDs,
            to: target,
            in: context
        )
        try atomically(changed, in: context, save: save) {
            $0.accountID = currentTarget.id
            $0.updatedAt = now
        }
        return summary(changed)
    }

    @MainActor
    static func planCategoryMigration(
        selectedIDs: Set<UUID>,
        to target: Category,
        in context: ModelContext
    ) throws -> TransactionBatchSummary {
        summary(try categoryMigrationChanges(selectedIDs: selectedIDs, to: target, in: context).0)
    }

    @MainActor
    static func migrateCategory(
        selectedIDs: Set<UUID>,
        to target: Category,
        transactions: [FinanceTransaction],
        in context: ModelContext,
        now: Date = Date(),
        save: (() throws -> Void)? = nil
    ) throws -> TransactionBatchSummary {
        let (changed, currentTarget) = try categoryMigrationChanges(
            selectedIDs: selectedIDs,
            to: target,
            in: context
        )
        try atomically(changed, in: context, save: save) {
            $0.categoryID = currentTarget.id
            $0.categoryDecisionSource = .unchanged
            var reasons = $0.reviewReasons
            reasons.remove(.uncategorized)
            reasons.remove(.importUncertain)
            $0.reviewReasons = reasons
            if reasons.isEmpty { $0.reviewStatus = .complete }
            $0.updatedAt = now
        }
        return summary(changed)
    }

    @MainActor
    static func planTagUpdate(
        selectedIDs: Set<UUID>,
        operation: TransactionBatchTagOperation,
        in context: ModelContext
    ) throws -> TransactionBatchSummary {
        summary(try tagUpdateChanges(selectedIDs: selectedIDs, operation: operation, in: context).transactions)
    }

    @MainActor
    static func updateTags(
        selectedIDs: Set<UUID>,
        operation: TransactionBatchTagOperation,
        transactions: [FinanceTransaction],
        tags: [Tag],
        in context: ModelContext,
        now: Date = Date(),
        save: (() throws -> Void)? = nil
    ) throws -> TransactionBatchSummary {
        let changes = try tagUpdateChanges(
            selectedIDs: selectedIDs,
            operation: operation,
            in: context
        )
        switch operation {
        case .add:
            guard let tag = changes.targetTag else {
                throw TransactionBatchOperationError.invalidTag
            }
            try atomically(changes.transactions, in: context, save: save) { transaction in
                transaction.tags.append(tag)
                transaction.updatedAt = now
            }
        case let .remove(id):
            try atomically(changes.transactions, in: context, save: save) { transaction in
                transaction.tags.removeAll { $0.id == id }
                transaction.updatedAt = now
            }
        case let .replace(sourceID, targetID):
            guard let target = changes.targetTag else {
                throw TransactionBatchOperationError.invalidTag
            }
            try atomically(changes.transactions, in: context, save: save) { transaction in
                transaction.tags.removeAll { $0.id == sourceID || $0.id == targetID }
                transaction.tags.append(target)
                transaction.updatedAt = now
            }
        }
        return summary(changes.transactions)
    }

    @MainActor
    private static func accountMigrationChanges(
        selectedIDs: Set<UUID>,
        to target: Account,
        in context: ModelContext
    ) throws -> ([FinanceTransaction], Account) {
        let selected = try refetchedActiveSelection(selectedIDs, in: context)
        let targetID = target.id
        guard let currentTarget = try context.fetch(FetchDescriptor<Account>(
            predicate: #Predicate { $0.id == targetID && $0.archivedAt == nil }
        )).first else {
            throw TransactionBatchOperationError.invalidAccount
        }
        guard selected.allSatisfy({ $0.currencyCode == currentTarget.currencyCode }) else {
            throw TransactionBatchOperationError.incompatibleCurrency
        }
        guard !selected.contains(where: {
            $0.type == .transfer && $0.destinationAccountID == currentTarget.id &&
                $0.accountID != currentTarget.id
        }) else { throw TransactionBatchOperationError.transferConflict }
        return (selected.filter { $0.accountID != currentTarget.id }, currentTarget)
    }

    @MainActor
    private static func categoryMigrationChanges(
        selectedIDs: Set<UUID>,
        to target: Category,
        in context: ModelContext
    ) throws -> ([FinanceTransaction], Category) {
        let selected = try refetchedActiveSelection(selectedIDs, in: context)
        let targetID = target.id
        guard let currentTarget = try context.fetch(FetchDescriptor<Category>(
            predicate: #Predicate { $0.id == targetID && $0.archivedAt == nil && !$0.isHidden }
        )).first else {
            throw TransactionBatchOperationError.invalidCategory
        }
        guard selected.allSatisfy({ transaction in
            guard transaction.type != .transfer else { return false }
            let expected: CategoryKind = transaction.type == .income ? .income : .expense
            return currentTarget.kind == expected
        }) else { throw TransactionBatchOperationError.categoryKindMismatch }
        return (selected.filter { $0.categoryID != currentTarget.id }, currentTarget)
    }

    private struct TagUpdateChanges {
        let transactions: [FinanceTransaction]
        let targetTag: Tag?
    }

    @MainActor
    private static func tagUpdateChanges(
        selectedIDs: Set<UUID>,
        operation: TransactionBatchTagOperation,
        in context: ModelContext
    ) throws -> TagUpdateChanges {
        let selected = try refetchedActiveSelection(selectedIDs, in: context)
        switch operation {
        case let .add(id):
            guard let tag = try fetchTag(id, in: context), tag.archivedAt == nil else {
                throw TransactionBatchOperationError.invalidTag
            }
            return TagUpdateChanges(
                transactions: selected.filter { transaction in
                    !transaction.tags.contains(where: { $0.id == id })
                },
                targetTag: tag
            )
        case let .remove(id):
            guard try fetchTag(id, in: context) != nil else {
                throw TransactionBatchOperationError.invalidTag
            }
            return TagUpdateChanges(
                transactions: selected.filter { transaction in
                    transaction.tags.contains(where: { $0.id == id })
                },
                targetTag: nil
            )
        case let .replace(sourceID, targetID):
            guard sourceID != targetID else {
                throw TransactionBatchOperationError.sameTagReplacement
            }
            guard try fetchTag(sourceID, in: context) != nil,
                  let target = try fetchTag(targetID, in: context), target.archivedAt == nil else {
                throw TransactionBatchOperationError.invalidTag
            }
            return TagUpdateChanges(
                transactions: selected.filter { transaction in
                    transaction.tags.contains(where: { $0.id == sourceID })
                },
                targetTag: target
            )
        }
    }

    @MainActor
    private static func refetchedActiveSelection(
        _ ids: Set<UUID>,
        in context: ModelContext
    ) throws -> [FinanceTransaction] {
        let selected = try LedgerQueryService.fetchSelected(ids, in: context)
        guard !selected.isEmpty else { throw TransactionBatchOperationError.noSelection }
        return selected
    }

    @MainActor
    private static func fetchTag(_ id: UUID, in context: ModelContext) throws -> Tag? {
        try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.id == id })).first
    }

    private static func activeSelection(
        _ ids: Set<UUID>,
        transactions: [FinanceTransaction]
    ) -> [FinanceTransaction] {
        transactions.filter { ids.contains($0.id) && $0.deletedAt == nil }
    }

    private static func summary(_ transactions: [FinanceTransaction]) -> TransactionBatchSummary {
        TransactionBatchSummary.make(
            transactions: transactions,
            selectedIDs: Set(transactions.map(\.id))
        )
    }

    @MainActor
    private static func atomically(
        _ transactions: [FinanceTransaction],
        in context: ModelContext,
        save: (() throws -> Void)?,
        mutation: (FinanceTransaction) -> Void
    ) throws {
        guard !transactions.isEmpty else { return }
        let snapshots = transactions.map(TransactionBatchSnapshot.init)
        transactions.forEach(mutation)
        do {
            if let save { try save() } else { try context.save() }
        } catch {
            for snapshot in snapshots {
                snapshot.restore()
            }
            context.rollbackNotifyingSync()
            throw error
        }
    }
}

private struct TransactionBatchSnapshot {
    let transaction: FinanceTransaction
    let accountID: UUID?
    let categoryID: UUID?
    let categoryDecisionSource: CategoryDecisionSource
    let reviewStatus: ReviewStatus
    let reviewReasons: Set<ReviewReason>
    let deletedAt: Date?
    let updatedAt: Date
    let tags: [Tag]

    init(_ transaction: FinanceTransaction) {
        self.transaction = transaction
        accountID = transaction.accountID
        categoryID = transaction.categoryID
        categoryDecisionSource = transaction.categoryDecisionSource
        reviewStatus = transaction.reviewStatus
        reviewReasons = transaction.reviewReasons
        deletedAt = transaction.deletedAt
        updatedAt = transaction.updatedAt
        tags = transaction.tags
    }

    func restore() {
        transaction.accountID = accountID
        transaction.categoryID = categoryID
        transaction.categoryDecisionSource = categoryDecisionSource
        transaction.reviewStatus = reviewStatus
        transaction.reviewReasons = reviewReasons
        transaction.deletedAt = deletedAt
        transaction.updatedAt = updatedAt
        transaction.tags = tags
    }
}
