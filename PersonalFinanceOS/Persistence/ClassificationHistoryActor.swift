import Foundation
import SwiftData

struct ClassificationHistoryComputation: Sendable {
    let history: [SuggestionHistory]
    let eventLookups: [UUID: ClassificationEventLookup]
    let categories: [SuggestionCategory]
    let tags: [SuggestionTag]
    let contentRevision: UInt64
    let fetchedRecordCount: Int
    let maximumBatchCount: Int
    let attemptCount: Int
}

actor ClassificationHistoryActor {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    enum Failure: Error { case changedWhileReading, tooManyEvents }

    func fetchRollingHistory(
        cutoff: Date, excluding transactionID: UUID? = nil, batchSize: Int = 256
    ) throws -> ClassificationHistoryComputation {
        try fetchProfileInputs(cutoff: cutoff, excluding: transactionID, eventIDs: [], batchSize: batchSize)
    }

    /// History and up to 4,000 sidecar IDs share one checked read version, including
    /// event transactions outside the rolling window. A failed read never prunes events.
    func fetchProfileInputs(
        cutoff: Date, excluding transactionID: UUID? = nil, eventIDs: [UUID], batchSize: Int = 256,
        afterHistoryBatch: (@Sendable () throws -> Void)? = nil
    ) throws -> ClassificationHistoryComputation {
        precondition(batchSize > 0)
        guard eventIDs.count <= 4_000 else { throw Failure.tooManyEvents }
        let ids = Set(eventIDs.filter { $0 != transactionID }).sorted { $0.uuidString < $1.uuidString }
        for attempt in 1...2 {
            try Task.checkCancellation()
            do {
                let revision = try LedgerSaveRevision.shared.readContentStamp()
                let context = ModelContext(modelContainer)
                var history: [SuggestionHistory] = []
                var scannedCount = 0
                let descriptor = FetchDescriptor<FinanceTransaction>(
                    predicate: #Predicate { $0.deletedAt == nil && $0.occurredAt >= cutoff },
                    sortBy: [SortDescriptor(\FinanceTransaction.occurredAt, order: .reverse), SortDescriptor(\FinanceTransaction.id)]
                )
                try context.enumerate(descriptor, batchSize: batchSize) { value in
                    if scannedCount.isMultiple(of: batchSize) { try check(revision) }
                    if value.id != transactionID { history.append(Self.snapshot(value)) }
                    scannedCount += 1
                    if scannedCount.isMultiple(of: batchSize) {
                        try afterHistoryBatch?()
                        try check(revision)
                    }
                }
                if scannedCount > 0 && !scannedCount.isMultiple(of: batchSize) { try afterHistoryBatch?() }
                try check(revision)
                let maximumBatchCount = min(batchSize, scannedCount)
                var lookups: [UUID: ClassificationEventLookup] = [:]
                for start in stride(from: 0, to: ids.count, by: 200) {
                    try check(revision)
                    let chunk = Array(ids[start..<min(start + 200, ids.count)])
                    let descriptor = FetchDescriptor<FinanceTransaction>(predicate: #Predicate { chunk.contains($0.id) })
                    let found = try context.fetch(descriptor)
                    for id in chunk { lookups[id] = .missing }
                    for value in found { lookups[value.id] = .present(Self.snapshot(value)) }
                    try check(revision)
                }
                let categories = try context.fetch(FetchDescriptor<Category>()).map {
                    SuggestionCategory(id: $0.id, name: $0.name, kind: $0.kind,
                                       isActive: $0.isActiveForSelection, parentID: $0.parentID,
                                       defaultDefinitionKey: $0.defaultDefinitionKey)
                }
                let tags = try context.fetch(FetchDescriptor<Tag>()).map {
                    SuggestionTag(id: $0.id, name: $0.name, isActive: $0.archivedAt == nil)
                }
                try check(revision)
                return .init(history: history, eventLookups: lookups, categories: categories, tags: tags, contentRevision: revision,
                             fetchedRecordCount: history.count, maximumBatchCount: maximumBatchCount, attemptCount: attempt)
            } catch ReconcileRevision.Failure.stalePlan {
                continue
            } catch Failure.changedWhileReading {
                continue
            }
        }
        throw Failure.changedWhileReading
    }

    private func check(_ revision: UInt64) throws {
        try Task.checkCancellation()
        guard try LedgerSaveRevision.shared.readContentStamp() == revision else { throw Failure.changedWhileReading }
    }

    private static func snapshot(_ transaction: FinanceTransaction) -> SuggestionHistory {
        SuggestionHistory(
            id: transaction.id, type: transaction.type, note: transaction.note,
            merchant: transaction.rawMerchantText, categoryID: transaction.categoryID,
            tagIDs: Set(transaction.tags.map(\.id)), occurredAt: transaction.occurredAt,
            updatedAt: transaction.updatedAt, isDeleted: transaction.deletedAt != nil,
            isImported: transaction.importBatchID != nil || transaction.externalSource != nil,
            decisionSource: transaction.categoryDecisionSource
        )
    }
}
