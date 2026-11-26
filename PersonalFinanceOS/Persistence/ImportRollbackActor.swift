import Foundation
import SwiftData

actor ImportRollbackActor {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) { self.modelContainer = modelContainer }

    func summary(batchID: UUID) throws -> ImportBatchHistorySummary {
        try LedgerSaveRevision.shared.withImportBoundary {
            try ImportRollbackWriter(modelContext: ModelContext(modelContainer)).summary(batchID: batchID)
        }
    }

    func rollback(
        batchID: UUID, preserveEdited: Bool = true, includeUncertain: Bool = false,
        reviewedRevision: UInt64? = nil, now: Date = Date(),
        onBoundaryContention: (@Sendable () -> Void)? = nil
    ) throws -> ImportRollbackResult {
        try LedgerSaveRevision.shared.withImportBoundary(onContention: onBoundaryContention) {
            let context = ModelContext(modelContainer)
            do {
                return try ImportRollbackWriter(modelContext: context).rollback(
                    batchID: batchID, preserveEdited: preserveEdited, includeUncertain: includeUncertain,
                    reviewedRevision: reviewedRevision, now: now
                )
            } catch {
                context.rollbackNotifyingSync()
                throw error
            }
        }
    }
}

private struct ImportRollbackWriter {
    let modelContext: ModelContext
    func summary(batchID: UUID) throws -> ImportBatchHistorySummary {
        let batch = try fetchBatch(id: batchID)
        let transactions = try fetchTransactions(batchID: batchID)
        return ImportBatchHistoryService.summary(batch: batch, transactions: transactions)
    }

    func rollback(
        batchID: UUID,
        preserveEdited: Bool = true,
        includeUncertain: Bool = false,
        reviewedRevision: UInt64? = nil,
        now: Date = Date()
    ) throws -> ImportRollbackResult {
        let batch = try fetchBatch(id: batchID)
        if batch.status == .rolledBack {
            return ImportRollbackResult(
                deletedCount: 0,
                preservedEditedCount: 0,
                preservedUncertainCount: 0,
                alreadyRolledBack: true
            )
        }
        try ImportBatchEditEvidence.validateReview(preserveEdited: preserveEdited,
            includeUncertain: includeUncertain, revision: reviewedRevision)
        let active = try fetchTransactions(batchID: batchID).filter { $0.deletedAt == nil }
        let editedCount = active.filter { ImportBatchEditEvidence.assess($0) == .manualCategoryConfirmed }.count
        let targets = active.filter { ImportBatchEditEvidence.shouldDelete($0,
            preserveEdited: preserveEdited, includeUncertain: includeUncertain) }
        guard !targets.isEmpty else {
            return ImportRollbackResult(deletedCount: 0, preservedEditedCount: editedCount,
                preservedUncertainCount: active.count - editedCount, alreadyRolledBack: false)
        }

        for transaction in targets {
            transaction.deletedAt = now
            transaction.updatedAt = now
        }
        batch.status = .rolledBack
        batch.rolledBackAt = now
        batch.updatedAt = now
        do {
            try modelContext.save()
        } catch {
            modelContext.rollbackNotifyingSync()
            throw error
        }
        return ImportRollbackResult(
            deletedCount: targets.count,
            preservedEditedCount: preserveEdited ? editedCount : 0,
            preservedUncertainCount: includeUncertain ? 0 : active.count - editedCount,
            alreadyRolledBack: false
        )
    }

    private func fetchBatch(id: UUID) throws -> ImportBatch {
        var descriptor = FetchDescriptor<ImportBatch>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let batch = try modelContext.fetch(descriptor).first else {
            throw ImportBatchHistoryError.batchUnavailable
        }
        return batch
    }

    private func fetchTransactions(batchID: UUID) throws -> [FinanceTransaction] {
        try modelContext.fetch(FetchDescriptor<FinanceTransaction>(
            predicate: #Predicate { $0.importBatchID == batchID }
        ))
    }

}
