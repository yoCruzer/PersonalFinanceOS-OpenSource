import Foundation
import SwiftData

enum TransactionDraftError: Error, Equatable {
    case invalidAmount
    case missingAccount
    case missingCategory
    case busy
    case pendingChanges
    case staleDraft
    case transactionUnavailable
    case unavailableReference
}

extension TransactionDraftError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidAmount:
            "请输入大于 0、最多两位小数的金额。"
        case .missingAccount:
            "请选择账户。"
        case .missingCategory:
            "请选择分类。"
        case .busy:
            "账本正在完成另一项修改，请稍后再次保存。草稿已保留。"
        case .pendingChanges:
            "还有未保存的账本修改，请完成后再次保存。草稿已保留。"
        case .staleDraft:
            "这笔交易已发生变化，请保留当前输入并重新打开最新交易后修改。"
        case .transactionUnavailable:
            "这笔交易已被删除或不存在。当前输入已保留。"
        case .unavailableReference:
            "所选账户、分类、标签或关联记录已变化，请重新确认。草稿已保留。"
        }
    }
}

struct TransactionDraft {
    let ledgerGeneration = LedgerSaveRevision.shared.restoreGeneration
    private(set) var editBaseline: TransactionEditBaseline?
    var type: TransactionType = .expense
    var amountText = ""
    var currencyCode = Money.cnyCode
    var accountID: UUID?
    var destinationAccountID: UUID?
    var categoryID: UUID?
    var merchantID: UUID?
    var rawMerchantText = ""
    var occurredAt = Date()
    var timeZoneIdentifier = TimeZone.current.identifier
    var note = ""
    var tagIDs: Set<UUID> = []

    init() {}

    init(transaction: FinanceTransaction) {
        editBaseline = TransactionEditBaseline(transaction)
        type = transaction.type
        amountText = (try? Money(
            minorUnits: transaction.amountMinorUnits,
            currencyCode: transaction.currencyCode
        ).decimalString) ?? ""
        currencyCode = transaction.currencyCode
        accountID = transaction.accountID
        destinationAccountID = transaction.destinationAccountID
        categoryID = transaction.categoryID
        merchantID = transaction.merchantID
        rawMerchantText = transaction.rawMerchantText
        occurredAt = transaction.occurredAt
        timeZoneIdentifier = transaction.timeZoneIdentifier
        note = transaction.note
        tagIDs = Set(transaction.tags.map(\.id))
    }
}

enum TransactionLifecycleService {
    @MainActor
    @discardableResult
    static func save(
        draft: TransactionDraft,
        editing original: FinanceTransaction? = nil,
        accounts: [Account],
        categories: [Category],
        tags: [Tag] = [],
        categoryDecisionSource: CategoryDecisionSource = .unchanged,
        in context: ModelContext,
        timeZone: TimeZone? = nil,
        now: Date = Date()
    ) throws -> FinanceTransaction {
        do {
            return try LedgerSaveRevision.shared.withProjectionBoundary {
                guard draft.ledgerGeneration == LedgerSaveRevision.shared.restoreGeneration else {
                    throw TransactionDraftError.staleDraft
                }
                guard !context.hasChanges else { throw TransactionDraftError.pendingChanges }
                let currentContext = ModelContext(context.container)
                if let original {
                    let id = original.id
                    var descriptor = FetchDescriptor<FinanceTransaction>(predicate: #Predicate { $0.id == id })
                    descriptor.fetchLimit = 1
                    guard let current = try currentContext.fetch(descriptor).first, current.deletedAt == nil else {
                        throw TransactionDraftError.transactionUnavailable
                    }
                    guard let baseline = draft.editBaseline,
                          baseline == TransactionEditBaseline(current),
                          baseline == TransactionEditBaseline(original) else {
                        throw TransactionDraftError.staleDraft
                    }
                }
                let currentAccounts = try currentContext.fetch(FetchDescriptor<Account>())
                let currentCategories = try currentContext.fetch(FetchDescriptor<Category>())
                let currentTags = try currentContext.fetch(FetchDescriptor<Tag>())
                for id in [draft.accountID, draft.type == .transfer ? draft.destinationAccountID : nil].compactMap({ $0 }) {
                    guard let account = currentAccounts.first(where: { $0.id == id }),
                          account.archivedAt == nil || id == original?.accountID || id == original?.destinationAccountID else {
                        throw TransactionDraftError.unavailableReference
                    }
                }
                if draft.type != .transfer, let id = draft.categoryID {
                    guard let category = currentCategories.first(where: { $0.id == id }) else {
                        throw TransactionDraftError.unavailableReference
                    }
                    let hierarchy = CategoryHierarchy(categories: currentCategories)
                    if id != original?.categoryID {
                        guard hierarchy.isEligibleForSelection(category) else {
                            throw TransactionDraftError.unavailableReference
                        }
                    }
                }
                for id in draft.tagIDs {
                    guard let tag = currentTags.first(where: { $0.id == id }),
                          tag.archivedAt == nil || original?.tags.contains(where: { $0.id == id }) == true else {
                        throw TransactionDraftError.unavailableReference
                    }
                }
                if let id = draft.merchantID {
                    var descriptor = FetchDescriptor<Merchant>(predicate: #Predicate { $0.id == id })
                    descriptor.fetchLimit = 1
                    guard let merchant = try currentContext.fetch(descriptor).first,
                          merchant.archivedAt == nil || id == original?.merchantID else {
                        throw TransactionDraftError.unavailableReference
                    }
                }
                if draft.type == .refund, original?.type == .refund,
                   let id = original?.relatedTransactionID {
                    var descriptor = FetchDescriptor<FinanceTransaction>(predicate: #Predicate { $0.id == id })
                    descriptor.fetchLimit = 1
                    guard let related = try currentContext.fetch(descriptor).first, related.type == .expense else {
                        throw TransactionDraftError.unavailableReference
                    }
                }
                // Resolve relationship models in the writing context only after validating
                // their authoritative existence; never attach models from another context.
                let writingTags = try context.fetch(FetchDescriptor<Tag>()).filter { draft.tagIDs.contains($0.id) }
                guard Set(writingTags.map(\.id)) == draft.tagIDs else {
                    throw TransactionDraftError.unavailableReference
                }
                return try saveValidated(
                    draft: draft, editing: original, accounts: currentAccounts, categories: currentCategories,
                    tags: writingTags, categoryDecisionSource: categoryDecisionSource,
                    in: context, timeZone: timeZone, now: now
                )
            }
        } catch ReconcileRevision.Failure.stalePlan {
            throw TransactionDraftError.busy
        }
    }

    @MainActor
    private static func saveValidated(
        draft: TransactionDraft, editing original: FinanceTransaction?, accounts: [Account],
        categories: [Category], tags: [Tag], categoryDecisionSource: CategoryDecisionSource,
        in context: ModelContext, timeZone: TimeZone?, now: Date
    ) throws -> FinanceTransaction {
        let resolvedTimeZone = timeZone
            ?? TimeZone(identifier: draft.timeZoneIdentifier)
            ?? .current
        let money: Money
        do {
            money = try AmountExpression.evaluateMoney(
                draft.amountText,
                currencyCode: draft.currencyCode
            )
        } catch {
            throw TransactionDraftError.invalidAmount
        }
        guard money.minorUnits > 0 else {
            throw TransactionDraftError.invalidAmount
        }
        guard draft.accountID != nil else {
            throw TransactionDraftError.missingAccount
        }
        guard draft.type == .transfer || draft.categoryID != nil else {
            throw TransactionDraftError.missingCategory
        }
        let resolvedCategoryDecisionSource: CategoryDecisionSource
        if let original,
           original.categoryID == draft.categoryID,
           categoryDecisionSource == .unchanged {
            resolvedCategoryDecisionSource = original.categoryDecisionSource
        } else {
            resolvedCategoryDecisionSource = categoryDecisionSource
        }

        let candidate = FinanceTransaction(
            id: original?.id ?? UUID(),
            type: draft.type,
            amountMinorUnits: money.minorUnits,
            currencyCode: money.currencyCode,
            occurredAt: draft.occurredAt,
            localDayKey: LocalDayKey.make(for: draft.occurredAt, timeZone: resolvedTimeZone),
            timeZoneIdentifier: resolvedTimeZone.identifier,
            accountID: draft.accountID,
            destinationAccountID: draft.type == .transfer ? draft.destinationAccountID : nil,
            categoryID: draft.type == .transfer ? nil : draft.categoryID,
            merchantID: draft.merchantID,
            rawMerchantText: draft.rawMerchantText.trimmingCharacters(in: .whitespacesAndNewlines),
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
            categoryDecisionSource: resolvedCategoryDecisionSource,
            reviewStatus: original?.reviewStatus ?? .complete,
            reviewReasons: original?.reviewReasons ?? [],
            relatedTransactionID: draft.type == .refund && original?.type == .refund
                ? original?.relatedTransactionID
                : nil,
            importBatchID: original?.importBatchID,
            externalSource: original?.externalSource,
            externalTransactionID: original?.externalTransactionID ?? "",
            importFingerprint: original?.importFingerprint ?? "",
            createdAt: original?.createdAt ?? now,
            updatedAt: now,
            deletedAt: original?.deletedAt,
            tags: tags.filter { draft.tagIDs.contains($0.id) }
        )

        try TransactionValidator.validate(
            candidate,
            context: TransactionValidationContext(
                accounts: accounts,
                categories: categories
            )
        )

        if let original {
            let previous = TransactionDraftSnapshot(transaction: original)
            // Keep the pre-edit wire key and merchant evidence together for Build 33
            // imports. The revised fingerprint embeds the original digest for old lookups.
            let merchantChanged = original.rawMerchantText != candidate.rawMerchantText
            if original.type != candidate.type || merchantChanged,
               let origin = LedgerSyncIdentity.baseOrigin(source: original.externalSource, type: original.type,
                   externalID: original.externalTransactionID, fingerprint: original.importFingerprint) {
                let key = "transactions:" + original.id.uuidString
                var query = FetchDescriptor<ImportEntityOrigin>(predicate: #Predicate { $0.entityKey == key })
                query.fetchLimit = 1
                if try context.fetch(query).isEmpty {
                    context.insert(ImportEntityOrigin(entityKey: key, semanticKey: origin))
                }
            }
            if merchantChanged, let source = original.externalSource, !original.importFingerprint.isEmpty {
                original.importFingerprint = BillParserSupport.merchantFingerprint(source: source,
                    legacy: original.importFingerprint, merchant: original.rawMerchantText, externalID: original.externalTransactionID)
            }
            original.type = candidate.type
            original.amountMinorUnits = candidate.amountMinorUnits
            original.currencyCode = candidate.currencyCode
            original.occurredAt = candidate.occurredAt
            original.localDayKey = candidate.localDayKey
            original.timeZoneIdentifier = candidate.timeZoneIdentifier
            original.accountID = candidate.accountID
            original.destinationAccountID = candidate.destinationAccountID
            if candidate.categoryID != nil,
               original.categoryID != candidate.categoryID || categoryDecisionSource == .manualConfirmed {
                original.resolveCategoryReview()
            }
            original.categoryID = candidate.categoryID
            original.merchantID = candidate.merchantID
            original.rawMerchantText = candidate.rawMerchantText
            original.note = candidate.note
            original.categoryDecisionSource = candidate.categoryDecisionSource
            original.relatedTransactionID = candidate.relatedTransactionID
            original.tags = candidate.tags
            original.updatedAt = now
            do {
                try context.save()
            } catch {
                previous.restore(original)
                context.rollbackNotifyingSync()
                throw error
            }
            return original
        }

        context.insert(candidate)
        do {
            try context.save()
        } catch {
            context.rollbackNotifyingSync()
            throw error
        }
        return candidate
    }

    @MainActor
    static func softDelete(
        _ transaction: FinanceTransaction,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        do {
            try LedgerSaveRevision.shared.withProjectionBoundary {
                guard !context.hasChanges else { throw TransactionDraftError.pendingChanges }
                let currentContext = ModelContext(context.container)
                let id = transaction.id
                var descriptor = FetchDescriptor<FinanceTransaction>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                guard let current = try currentContext.fetch(descriptor).first, current.deletedAt == nil else {
                    throw TransactionDraftError.transactionUnavailable
                }
                guard TransactionEditBaseline(current) == TransactionEditBaseline(transaction) else {
                    throw TransactionDraftError.staleDraft
                }
                try softDeleteValidated(transaction, in: context, now: now)
            }
        } catch ReconcileRevision.Failure.stalePlan {
            throw TransactionDraftError.busy
        }
    }

    @MainActor
    private static func softDeleteValidated(
        _ transaction: FinanceTransaction, in context: ModelContext, now: Date
    ) throws {
        let previousDeletedAt = transaction.deletedAt
        let previousUpdatedAt = transaction.updatedAt
        transaction.softDelete(at: now)
        do {
            try context.save()
        } catch {
            transaction.deletedAt = previousDeletedAt
            transaction.updatedAt = previousUpdatedAt
            context.rollbackNotifyingSync()
            throw error
        }
    }

    static func sortedActive(_ transactions: [FinanceTransaction]) -> [FinanceTransaction] {
        transactions
            .filter { $0.deletedAt == nil }
            .sorted {
                if $0.occurredAt != $1.occurredAt {
                    return $0.occurredAt > $1.occurredAt
                }
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.id.uuidString > $1.id.uuidString
            }
    }
}

/// Immutable form-open facts. Equal timestamps alone cannot establish an unchanged row.
struct TransactionEditBaseline: Equatable {
    let id: UUID
    let typeRawValue: String
    let amountMinorUnits: Int64
    let currencyCode: String
    let occurredAt: Date
    let localDayKey: String
    let timeZoneIdentifier: String
    let accountID: UUID?
    let destinationAccountID: UUID?
    let categoryID: UUID?
    let merchantID: UUID?
    let rawMerchantText: String
    let note: String
    let categoryDecisionSourceRawValue: String
    let reviewStatusRawValue: String
    let reviewReasonsStorage: String
    let relatedTransactionID: UUID?
    let importBatchID: UUID?
    let externalSourceRawValue: String
    let externalTransactionID: String
    let importFingerprint: String
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let tagIDs: Set<UUID>

    init(_ transaction: FinanceTransaction) {
        id = transaction.id
        typeRawValue = transaction.typeRawValue
        amountMinorUnits = transaction.amountMinorUnits
        currencyCode = transaction.currencyCode
        occurredAt = transaction.occurredAt
        localDayKey = transaction.localDayKey
        timeZoneIdentifier = transaction.timeZoneIdentifier
        accountID = transaction.accountID
        destinationAccountID = transaction.destinationAccountID
        categoryID = transaction.categoryID
        merchantID = transaction.merchantID
        rawMerchantText = transaction.rawMerchantText
        note = transaction.note
        categoryDecisionSourceRawValue = transaction.categoryDecisionSourceRawValue
        reviewStatusRawValue = transaction.reviewStatusRawValue
        reviewReasonsStorage = transaction.reviewReasonsStorage
        relatedTransactionID = transaction.relatedTransactionID
        importBatchID = transaction.importBatchID
        externalSourceRawValue = transaction.externalSourceRawValue
        externalTransactionID = transaction.externalTransactionID
        importFingerprint = transaction.importFingerprint
        createdAt = transaction.createdAt
        updatedAt = transaction.updatedAt
        deletedAt = transaction.deletedAt
        tagIDs = Set(transaction.tags.map(\.id))
    }
}

extension FinanceTransaction {
    func resolveCategoryReview() {
        let remaining = reviewReasons.subtracting([.uncategorized, .importUncertain])
        guard remaining != reviewReasons else { return }
        reviewReasons = remaining
        if remaining.isEmpty { reviewStatus = .complete }
    }
}

private struct TransactionDraftSnapshot {
    let importFingerprint: String
    let reviewReasons: Set<ReviewReason>
    let reviewStatus: ReviewStatus
    let type: TransactionType
    let amountMinorUnits: Int64
    let currencyCode: String
    let occurredAt: Date
    let localDayKey: String
    let timeZoneIdentifier: String
    let accountID: UUID?
    let destinationAccountID: UUID?
    let categoryID: UUID?
    let merchantID: UUID?
    let rawMerchantText: String
    let note: String
    let categoryDecisionSource: CategoryDecisionSource
    let relatedTransactionID: UUID?
    let tags: [Tag]
    let updatedAt: Date

    init(transaction: FinanceTransaction) {
        importFingerprint = transaction.importFingerprint
        reviewReasons = transaction.reviewReasons
        reviewStatus = transaction.reviewStatus
        type = transaction.type
        amountMinorUnits = transaction.amountMinorUnits
        currencyCode = transaction.currencyCode
        occurredAt = transaction.occurredAt
        localDayKey = transaction.localDayKey
        timeZoneIdentifier = transaction.timeZoneIdentifier
        accountID = transaction.accountID
        destinationAccountID = transaction.destinationAccountID
        categoryID = transaction.categoryID
        merchantID = transaction.merchantID
        rawMerchantText = transaction.rawMerchantText
        note = transaction.note
        categoryDecisionSource = transaction.categoryDecisionSource
        relatedTransactionID = transaction.relatedTransactionID
        tags = transaction.tags
        updatedAt = transaction.updatedAt
    }

    func restore(_ transaction: FinanceTransaction) {
        transaction.importFingerprint = importFingerprint
        transaction.reviewReasons = reviewReasons
        transaction.reviewStatus = reviewStatus
        transaction.type = type
        transaction.amountMinorUnits = amountMinorUnits
        transaction.currencyCode = currencyCode
        transaction.occurredAt = occurredAt
        transaction.localDayKey = localDayKey
        transaction.timeZoneIdentifier = timeZoneIdentifier
        transaction.accountID = accountID
        transaction.destinationAccountID = destinationAccountID
        transaction.categoryID = categoryID
        transaction.merchantID = merchantID
        transaction.rawMerchantText = rawMerchantText
        transaction.note = note
        transaction.categoryDecisionSource = categoryDecisionSource
        transaction.relatedTransactionID = relatedTransactionID
        transaction.tags = tags
        transaction.updatedAt = updatedAt
    }
}
