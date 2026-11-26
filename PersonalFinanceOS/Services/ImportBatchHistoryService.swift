import Foundation
import SwiftData

struct ImportBatchHistorySummary: Equatable {
    let currentActiveCount: Int
    let editedCount: Int
    let uncertainCount: Int
    let reviewRevision: UInt64
    var safelyUnmodifiedCount: Int { currentActiveCount - editedCount - uncertainCount }
    let manuallyDeletedCount: Int
    let incomeMinorUnits: Int64
    let expenseMinorUnits: Int64
}

struct ImportRollbackResult: Equatable {
    let deletedCount: Int
    let preservedEditedCount: Int
    let preservedUncertainCount: Int
    let alreadyRolledBack: Bool
}

enum ImportBatchHistoryError: Error, Equatable {
    case batchUnavailable
    case reviewRequired
    case staleReview
}

enum ImportBatchEditEvidence {
    enum Assessment { case safelyUnmodified, manualCategoryConfirmed, uncertain }

    static func assess(_ transaction: FinanceTransaction) -> Assessment {
        // This field proves a manual category decision, not arbitrary edit history.
        // Imports start unchanged; automatic/time-prior decisions and timestamps
        // cannot distinguish human edits from maintenance or sync projection.
        if transaction.categoryDecisionSource == .manualConfirmed { return .manualCategoryConfirmed }
        // Frozen records contain no original editable-payload baseline. No current
        // record can positively establish the safelyUnmodified case.
        return .uncertain
    }

    static func validateReview(preserveEdited: Bool, includeUncertain: Bool, revision: UInt64?) throws {
        if !preserveEdited || includeUncertain {
            guard revision != nil else { throw ImportBatchHistoryError.reviewRequired }
        }
        if let revision, revision != LedgerSaveRevision.shared.contentRevision {
            throw ImportBatchHistoryError.staleReview
        }
    }

    static func shouldDelete(_ transaction: FinanceTransaction, preserveEdited: Bool, includeUncertain: Bool) -> Bool {
        switch assess(transaction) {
        case .safelyUnmodified: true
        case .manualCategoryConfirmed: !preserveEdited
        case .uncertain: includeUncertain
        }
    }
}

extension ImportBatchHistoryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .batchUnavailable: "此导入批次已不可用。"
        case .reviewRequired: "请先查看当前交易状态并确认需要撤销的范围。"
        case .staleReview: "账本在确认期间发生了变化。请重新查看数量并选择撤销范围。"
        }
    }
}

enum ImportBatchHistoryService {
    // The writer persisted both totals before the optional duplicate counter was
    // introduced. Older all-zero batches without that counter lack definitive evidence.
    static func hasRecordedTotals(_ batch: ImportBatch) -> Bool {
        batch.duplicateRowCount != nil || batch.incomeMinorUnits != 0 || batch.expenseMinorUnits != 0
    }

    static func summary(
        batch: ImportBatch,
        transactions: [FinanceTransaction]
    ) -> ImportBatchHistorySummary {
        let batchTransactions = transactions.filter { $0.importBatchID == batch.id }
        let active = batchTransactions.filter { $0.deletedAt == nil }
        let edited = active.filter { ImportBatchEditEvidence.assess($0) == .manualCategoryConfirmed }.count
        let manuallyDeleted = batchTransactions.filter { transaction in
            guard let deletedAt = transaction.deletedAt else { return false }
            guard let rolledBackAt = batch.rolledBackAt else { return true }
            return deletedAt < rolledBackAt
        }.count
        var derivedIncome: Int64 = 0
        var derivedExpense: Int64 = 0
        let recorded = hasRecordedTotals(batch)
        for transaction in recorded ? [] : batchTransactions {
            switch transaction.type {
            case .income:
                derivedIncome = safeAdd(derivedIncome, transaction.amountMinorUnits)
            case .expense:
                derivedExpense = safeAdd(derivedExpense, transaction.amountMinorUnits)
            case .refund:
                derivedExpense = safeSubtract(derivedExpense, transaction.amountMinorUnits)
            case .transfer:
                break
            }
        }
        return ImportBatchHistorySummary(
            currentActiveCount: active.count,
            editedCount: edited,
            uncertainCount: active.count - edited,
            reviewRevision: LedgerSaveRevision.shared.contentRevision,
            manuallyDeletedCount: manuallyDeleted,
            incomeMinorUnits: recorded ? batch.incomeMinorUnits : derivedIncome,
            expenseMinorUnits: recorded ? batch.expenseMinorUnits : derivedExpense
        )
    }

    @MainActor
    static func rollback(
        batch: ImportBatch,
        transactions: [FinanceTransaction],
        preserveEdited: Bool = true,
        includeUncertain: Bool = false,
        reviewedRevision: UInt64? = nil,
        in context: ModelContext,
        now: Date = Date(),
        save: (() throws -> Void)? = nil
    ) throws -> ImportRollbackResult {
        try LedgerSaveRevision.shared.withProjectionBoundary {
            let batchID = batch.id
            guard let currentBatch = try context.fetch(FetchDescriptor<ImportBatch>(
                predicate: #Predicate { $0.id == batchID }
            )).first else {
                throw ImportBatchHistoryError.batchUnavailable
            }
            if currentBatch.status == .rolledBack {
                return ImportRollbackResult(
                    deletedCount: 0,
                    preservedEditedCount: 0,
                    preservedUncertainCount: 0,
                    alreadyRolledBack: true
                )
            }
            try ImportBatchEditEvidence.validateReview(preserveEdited: preserveEdited,
                includeUncertain: includeUncertain, revision: reviewedRevision)
            let active = try LedgerQueryService.fetchImportBatch(currentBatch.id, in: context)
                .filter { $0.deletedAt == nil }
            let edited = active.filter { ImportBatchEditEvidence.assess($0) == .manualCategoryConfirmed }
            let targets = active.filter { ImportBatchEditEvidence.shouldDelete($0,
                preserveEdited: preserveEdited, includeUncertain: includeUncertain) }
            guard !targets.isEmpty else {
                return ImportRollbackResult(deletedCount: 0, preservedEditedCount: edited.count,
                    preservedUncertainCount: active.count - edited.count, alreadyRolledBack: false)
            }
            let transactionSnapshots = targets.map { ($0, $0.deletedAt, $0.updatedAt) }
            let batchSnapshot = (currentBatch.status, currentBatch.rolledBackAt, currentBatch.updatedAt)

            for transaction in targets {
                transaction.deletedAt = now
                transaction.updatedAt = now
            }
            currentBatch.status = .rolledBack
            currentBatch.rolledBackAt = now
            currentBatch.updatedAt = now
            do {
                if let save { try save() } else { try context.save() }
            } catch {
                for (transaction, deletedAt, updatedAt) in transactionSnapshots {
                    transaction.deletedAt = deletedAt
                    transaction.updatedAt = updatedAt
                }
                currentBatch.status = batchSnapshot.0
                currentBatch.rolledBackAt = batchSnapshot.1
                currentBatch.updatedAt = batchSnapshot.2
                context.rollbackNotifyingSync()
                throw error
            }
            return ImportRollbackResult(
                deletedCount: targets.count,
                preservedEditedCount: preserveEdited ? edited.count : 0,
                preservedUncertainCount: includeUncertain ? 0 : active.count - edited.count,
                alreadyRolledBack: false
            )
        }
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
