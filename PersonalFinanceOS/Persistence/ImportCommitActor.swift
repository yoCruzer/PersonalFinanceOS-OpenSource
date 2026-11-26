import CryptoKit
import Foundation
import SwiftData

enum LedgerExportScope: Equatable, Sendable {
    case all
    case localDayRange(lowerBound: String, upperBound: String, includesUpperBound: Bool)
}

actor LedgerExportActor {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) { self.modelContainer = modelContainer }

    func count(scope: LedgerExportScope) throws -> Int {
        let revision = try LedgerSaveRevision.shared.readStamp()
        let count = try ModelContext(modelContainer).fetchCount(transactionDescriptor(for: scope))
        guard try LedgerSaveRevision.shared.readStamp() == revision else { throw ReconcileRevision.Failure.stalePlan }
        return count
    }

    func export(scope: LedgerExportScope, fileName: String,
                afterTransactionsRead: (@Sendable () throws -> Void)? = nil) throws -> URL {
        for _ in 0..<2 {
            try Task.checkCancellation()
            do {
                let revision = try LedgerSaveRevision.shared.readStamp()
                let context = ModelContext(modelContainer)
                let transactions = try context.fetch(transactionDescriptor(for: scope))
                try afterTransactionsRead?()
                let categories = try context.fetch(FetchDescriptor<Category>())
                let accounts = try context.fetch(FetchDescriptor<Account>())
                let data = FinanceCSVService.exportData(transactions: transactions, categories: categories, accounts: accounts)
                try Task.checkCancellation()
                guard try LedgerSaveRevision.shared.readStamp() == revision else { throw ReconcileRevision.Failure.stalePlan }
                return try FinanceCSVService.writeTemporaryExport(data: data, fileName: fileName)
            } catch ReconcileRevision.Failure.stalePlan { continue }
        }
        throw ReconcileRevision.Failure.stalePlan
    }

    private func transactionDescriptor(for scope: LedgerExportScope) -> FetchDescriptor<FinanceTransaction> {
        switch scope {
        case .all:
            FetchDescriptor(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\FinanceTransaction.occurredAt, order: .reverse)]
            )
        case let .localDayRange(lowerBound, upperBound, true):
            FetchDescriptor(
                predicate: #Predicate {
                    $0.deletedAt == nil &&
                    $0.localDayKey >= lowerBound &&
                    $0.localDayKey <= upperBound
                },
                sortBy: [SortDescriptor(\FinanceTransaction.occurredAt, order: .reverse)]
            )
        case let .localDayRange(lowerBound, upperBound, false):
            FetchDescriptor(
                predicate: #Predicate {
                    $0.deletedAt == nil &&
                    $0.localDayKey >= lowerBound &&
                    $0.localDayKey < upperBound
                },
                sortBy: [SortDescriptor(\FinanceTransaction.occurredAt, order: .reverse)]
            )
        }
    }
}

struct BatchCategoryCorrection: Sendable {
    let summary: TransactionBatchSummary
    let learningEvents: [ClassificationLearningEvent]
}

enum LedgerBatchOperation: Equatable, Sendable {
    case delete, account(UUID), category(UUID), tags(TransactionBatchTagOperation)
}

struct LedgerBatchPlan: Sendable {
    let selectedIDs: Set<UUID>
    let operation: LedgerBatchOperation
    let revision: UInt64
    let totals: LedgerTotals
}

actor LedgerBatchOperationActor {
    let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) { self.modelContainer = modelContainer }
    func softDelete(selectedIDs: Set<UUID>, now: Date = Date()) throws -> TransactionBatchSummary {
        try mutate { try $0.softDelete(selectedIDs: selectedIDs, now: now) }
    }

    func migrateAccount(selectedIDs: Set<UUID>, targetID: UUID, now: Date = Date()) throws -> TransactionBatchSummary {
        try mutate { try $0.migrateAccount(selectedIDs: selectedIDs, targetID: targetID, now: now) }
    }

    func migrateCategory(
        selectedIDs: Set<UUID>, targetID: UUID, now: Date = Date(),
        onBoundaryContention: (@Sendable () -> Void)? = nil
    ) throws -> TransactionBatchSummary {
        try mutate(onContention: onBoundaryContention) {
            try $0.migrateCategory(selectedIDs: selectedIDs, targetID: targetID, now: now).summary
        }
    }

    func correctCategory(selectedIDs: Set<UUID>, targetID: UUID, now: Date = Date()) throws -> BatchCategoryCorrection {
        try mutate { try $0.migrateCategory(selectedIDs: selectedIDs, targetID: targetID, now: now) }
    }

    func updateTags(selectedIDs: Set<UUID>, operation: TransactionBatchTagOperation, now: Date = Date()) throws -> TransactionBatchSummary {
        try mutate { try $0.updateTags(selectedIDs: selectedIDs, operation: operation, now: now) }
    }

    func selectionTotals(selectedIDs: Set<UUID>, revision: UInt64) throws -> LedgerTotals {
        guard try LedgerSaveRevision.shared.readContentStamp() == revision else { throw LedgerAnalysisError.staleSnapshot }
        let context = ModelContext(modelContainer)
        let totals = try LedgerBatchOperationWriter(modelContext: context).selectionTotals(selectedIDs)
        guard totals.totalCount == selectedIDs.count,
              try LedgerSaveRevision.shared.readContentStamp() == revision else { throw LedgerAnalysisError.staleSnapshot }
        return totals
    }

    func plan(selectedIDs: Set<UUID>, operation: LedgerBatchOperation, revision: UInt64) throws -> LedgerBatchPlan {
        guard try LedgerSaveRevision.shared.readContentStamp() == revision else { throw LedgerAnalysisError.staleSnapshot }
        let context = ModelContext(modelContainer)
        let writer = LedgerBatchOperationWriter(modelContext: context)
        guard try writer.selectionTotals(selectedIDs).totalCount == selectedIDs.count else { throw LedgerAnalysisError.staleSnapshot }
        let totals = try writer.preview(selectedIDs: selectedIDs, operation: operation)
        guard try LedgerSaveRevision.shared.readContentStamp() == revision else { throw LedgerAnalysisError.staleSnapshot }
        return LedgerBatchPlan(selectedIDs: selectedIDs, operation: operation, revision: revision, totals: totals)
    }

    func execute(_ plan: LedgerBatchPlan, now: Date = Date()) throws -> BatchCategoryCorrection {
        try mutate { writer in
            guard LedgerSaveRevision.shared.contentRevision == plan.revision else { throw LedgerAnalysisError.staleSnapshot }
            return try writer.apply(selectedIDs: plan.selectedIDs, operation: plan.operation, now: now)
        }
    }

    private func mutate<Result>(
        onContention: (@Sendable () -> Void)? = nil,
        _ body: (LedgerBatchOperationWriter) throws -> Result
    ) rethrows -> Result {
        try LedgerSaveRevision.shared.withImportBoundary(onContention: onContention) {
            let context = ModelContext(modelContainer)
            do { return try body(LedgerBatchOperationWriter(modelContext: context)) }
            catch { context.rollbackNotifyingSync(); throw error }
        }
    }
}

private struct LedgerBatchOperationWriter {
    let modelContext: ModelContext

    func softDelete(selectedIDs: Set<UUID>, now: Date) throws -> TransactionBatchSummary {
        try apply(selectedIDs: selectedIDs, operation: .delete, now: now).summary
    }

    func migrateAccount(selectedIDs: Set<UUID>, targetID: UUID, now: Date) throws -> TransactionBatchSummary {
        try apply(selectedIDs: selectedIDs, operation: .account(targetID), now: now).summary
    }

    func migrateCategory(selectedIDs: Set<UUID>, targetID: UUID, now: Date) throws -> BatchCategoryCorrection {
        try apply(selectedIDs: selectedIDs, operation: .category(targetID), now: now)
    }

    func updateTags(selectedIDs: Set<UUID>, operation: TransactionBatchTagOperation, now: Date) throws -> TransactionBatchSummary {
        try apply(selectedIDs: selectedIDs, operation: .tags(operation), now: now).summary
    }

    func selectionTotals(_ ids: Set<UUID>) throws -> LedgerTotals {
        try totals(activeSelection(ids))
    }

    func preview(selectedIDs: Set<UUID>, operation: LedgerBatchOperation) throws -> LedgerTotals {
        try totals(changes(selectedIDs: selectedIDs, operation: operation).transactions)
    }

    func apply(selectedIDs: Set<UUID>, operation: LedgerBatchOperation, now: Date) throws -> BatchCategoryCorrection {
        let change = try changes(selectedIDs: selectedIDs, operation: operation)
        let totals = try totals(change.transactions)
        let summary = TransactionBatchSummary(count: totals.totalCount,
            incomeMinorUnits: totals.incomeMinorUnits, expenseMinorUnits: totals.netExpenseMinorUnits)
        var events: [ClassificationLearningEvent] = []
        if case let .category(id) = operation {
            events = change.transactions.sorted { $0.id.uuidString < $1.id.uuidString }.prefix(4_000).map {
                ClassificationLearningEvent(transactionID: $0.id, recordedAt: now, type: $0.type,
                    note: $0.note, merchant: $0.rawMerchantText, categoryID: id,
                    rejectedCategoryID: $0.categoryID, source: .explicitCorrection)
            }
        }
        for transaction in change.transactions {
            switch operation {
            case .delete: transaction.deletedAt = now
            case let .account(id): transaction.accountID = id
            case let .category(id):
                transaction.categoryID = id
                transaction.categoryDecisionSource = .manualConfirmed
                transaction.resolveCategoryReview()
            case let .tags(operation):
                switch operation {
                case .add:
                    if let tag = change.targetTag { transaction.tags.append(tag) }
                case let .remove(id): transaction.tags.removeAll { $0.id == id }
                case let .replace(sourceID, targetID):
                    transaction.tags.removeAll { $0.id == sourceID || $0.id == targetID }
                    if let tag = change.targetTag { transaction.tags.append(tag) }
                }
            }
            transaction.updatedAt = now
        }
        if !change.transactions.isEmpty {
            do { try modelContext.save() }
            catch { modelContext.rollbackNotifyingSync(); throw error }
        }
        return BatchCategoryCorrection(summary: summary, learningEvents: events)
    }

    private struct Changes {
        let transactions: [FinanceTransaction]
        var targetTag: Tag? = nil
    }

    /// Preview and mutation share the exact same selection and eligibility rules.
    private func changes(selectedIDs: Set<UUID>, operation: LedgerBatchOperation) throws -> Changes {
        let selected = try activeSelection(selectedIDs)
        switch operation {
        case .delete: return Changes(transactions: selected)
        case let .account(id):
            guard let target = try account(id: id), target.archivedAt == nil else {
                throw TransactionBatchOperationError.invalidAccount
            }
            guard selected.allSatisfy({ $0.currencyCode == target.currencyCode }) else {
                throw TransactionBatchOperationError.incompatibleCurrency
            }
            guard !selected.contains(where: { $0.type == .transfer && $0.destinationAccountID == id && $0.accountID != id }) else {
                throw TransactionBatchOperationError.transferConflict
            }
            return Changes(transactions: selected.filter { $0.accountID != id })
        case let .category(id):
            guard let target = try category(id: id), target.archivedAt == nil, !target.isHidden else {
                throw TransactionBatchOperationError.invalidCategory
            }
            if let parentID = target.parentID {
                guard let parent = try category(id: parentID), parent.parentID == nil, parent.kind == target.kind,
                      parent.archivedAt == nil, !parent.isHidden else { throw TransactionBatchOperationError.invalidCategory }
            }
            guard selected.allSatisfy({ $0.type != .transfer && target.kind == ($0.type == .income ? .income : .expense) }) else {
                throw TransactionBatchOperationError.categoryKindMismatch
            }
            return Changes(transactions: selected.filter { $0.categoryID != id })
        case let .tags(operation):
            switch operation {
            case let .add(id):
                guard let tag = try tag(id: id), tag.archivedAt == nil else { throw TransactionBatchOperationError.invalidTag }
                return Changes(transactions: selected.filter { !$0.tags.contains(where: { $0.id == id }) }, targetTag: tag)
            case let .remove(id):
                guard try tag(id: id) != nil else { throw TransactionBatchOperationError.invalidTag }
                return Changes(transactions: selected.filter { $0.tags.contains(where: { $0.id == id }) })
            case let .replace(sourceID, targetID):
                guard sourceID != targetID else { throw TransactionBatchOperationError.sameTagReplacement }
                guard try tag(id: sourceID) != nil, let target = try tag(id: targetID), target.archivedAt == nil else {
                    throw TransactionBatchOperationError.invalidTag
                }
                return Changes(transactions: selected.filter { $0.tags.contains(where: { $0.id == sourceID }) }, targetTag: target)
            }
        }
    }

    private func activeSelection(_ ids: Set<UUID>) throws -> [FinanceTransaction] {
        guard !ids.isEmpty else { throw TransactionBatchOperationError.noSelection }
        let selected = ids.sorted { $0.uuidString < $1.uuidString }
        var transactions: [FinanceTransaction] = []
        for offset in stride(from: 0, to: selected.count, by: 256) {
            try Task.checkCancellation()
            let chunk = Array(selected.dropFirst(offset).prefix(256))
            transactions += try modelContext.fetch(FetchDescriptor<FinanceTransaction>(predicate: #Predicate {
                chunk.contains($0.id) && $0.deletedAt == nil
            }))
        }
        guard !transactions.isEmpty else { throw TransactionBatchOperationError.noSelection }
        return transactions
    }

    private func account(id: UUID) throws -> Account? {
        try modelContext.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })).first
    }
    private func category(id: UUID) throws -> Category? {
        try modelContext.fetch(FetchDescriptor<Category>(predicate: #Predicate { $0.id == id })).first
    }
    private func tag(id: UUID) throws -> Tag? {
        try modelContext.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.id == id })).first
    }
    private func totals(_ transactions: [FinanceTransaction]) throws -> LedgerTotals {
        var result = LedgerTotals()
        for row in transactions { try result.include(LedgerFilteredRow(row)) }
        return try result.validated()
    }
}

actor ImportPlanningActor {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) { self.modelContainer = modelContainer }

    func duplicateRecords(for plan: ParsedImportPlan,
                          afterRead: (@Sendable () throws -> Void)? = nil) throws -> [ImportDuplicateRecord] {
        for _ in 0..<2 {
            try Task.checkCancellation()
            do {
                let revision = try LedgerSaveRevision.shared.readStamp()
                let result = try duplicateRecords(for: plan, in: ModelContext(modelContainer), revision: revision)
                try afterRead?()
                try Task.checkCancellation()
                guard try LedgerSaveRevision.shared.readStamp() == revision else { throw ReconcileRevision.Failure.stalePlan }
                return result
            } catch ReconcileRevision.Failure.stalePlan { continue }
        }
        throw ReconcileRevision.Failure.stalePlan
    }

    private func duplicateRecords(for plan: ParsedImportPlan, in modelContext: ModelContext,
                                  revision: UInt64) throws -> [ImportDuplicateRecord] {
        var transactionsByID: [UUID: FinanceTransaction] = [:]

        if let localDayRange = plan.localDayRange {
            let lowerBound = localDayRange.lowerBound
            let upperBound = localDayRange.upperBound
            let descriptor = FetchDescriptor<FinanceTransaction>(predicate: #Predicate {
                $0.localDayKey >= lowerBound && $0.localDayKey <= upperBound
            })
            for transaction in try modelContext.fetch(descriptor) {
                transactionsByID[transaction.id] = transaction
            }
        }

        let requestedSourceRawValue = plan.source.rawValue
        for type in TransactionType.allCases {
            let requestedTypeRawValue = type.rawValue
            let sourceIdentities = Set(plan.candidates.filter { $0.type == type }.flatMap {
                [$0.externalTransactionID, $0.stableEventIdentity]
            }.filter { !$0.isEmpty })
            for chunk in sourceIdentities.chunked(maxCount: 200) {
                try check(revision)
                let descriptor = FetchDescriptor<FinanceTransaction>(predicate: #Predicate {
                    $0.externalSourceRawValue == requestedSourceRawValue &&
                    $0.typeRawValue == requestedTypeRawValue &&
                    chunk.contains($0.externalTransactionID)
                })
                for transaction in try modelContext.fetch(descriptor) {
                    transactionsByID[transaction.id] = transaction
                }
            }
        }

        let fingerprints = Set(plan.candidates.flatMap { candidate in
            [candidate.fingerprint, BillParserSupport.legacyFingerprint(candidate.fingerprint)]
        }.filter { !$0.isEmpty })
        for chunk in fingerprints.chunked(maxCount: 200) {
            try check(revision)
            let descriptor = FetchDescriptor<FinanceTransaction>(predicate: #Predicate {
                $0.externalSourceRawValue == requestedSourceRawValue &&
                chunk.contains($0.importFingerprint)
            })
            for transaction in try modelContext.fetch(descriptor) {
                transactionsByID[transaction.id] = transaction
            }
        }

        try check(revision)
        return try ImportDuplicateRecord.snapshot(Array(transactionsByID.values), in: modelContext)
    }

    private func check(_ revision: UInt64) throws {
        try Task.checkCancellation()
        guard try LedgerSaveRevision.shared.readStamp() == revision else { throw ReconcileRevision.Failure.stalePlan }
    }

}

private extension Set where Element == String {
    func chunked(maxCount: Int) -> [[String]] {
        let values = Array(self)
        return stride(from: 0, to: values.count, by: maxCount).map { start in
            Array(values[start..<Swift.min(start + maxCount, values.count)])
        }
    }
}

struct ImportCommitRequest: Sendable {
    enum RowIntent: Sendable {
        case normal
        case withinFileRetained(semanticOrigin: String?)
        case confirmedExistingRetained(instance: UUID)
    }

    struct AccountPayload: Sendable {
        let id: UUID
        let name: String
        let sortOrder: Int
    }

    struct CategoryPayload: Sendable {
        let id: UUID
        let kind: CategoryKind
        let name: String
        let parentID: UUID
        let symbolName: String
        let colorToken: String
        let sortOrder: Int
    }

    struct TagPayload: Sendable {
        let id: UUID
        let name: String
        let sortOrder: Int
    }

    struct TransactionPayload: Sendable {
        let id: UUID
        let type: TransactionType
        let amountMinorUnits: Int64
        let occurredAt: Date
        let localDayKey: String
        let timeZoneIdentifier: String
        let accountID: UUID
        let categoryID: UUID?
        let merchantName: String
        let note: String
        let reviewStatus: ReviewStatus
        let reviewReasons: Set<ReviewReason>
        let externalTransactionID: String
        let fingerprint: String
        let tagIDs: [UUID]
        var intent: RowIntent = .normal
        var duplicateCheckID: String? = nil

        var explicitDuplicateInstance: UUID? {
            if case let .confirmedExistingRetained(instance) = intent { return instance }
            return nil
        }

        var importSemanticOrigin: String? {
            switch intent {
            case .normal: nil
            case let .withinFileRetained(origin): origin
            case let .confirmedExistingRetained(instance): "duplicate-v1:" + instance.uuidString
            }
        }
    }

    let batchID: UUID
    let source: ImportSourceType
    let sourceDisplayName: String
    let sourceFormatVersion: String
    let startedAt: Date
    let totalRowCount: Int
    let skippedRowCount: Int
    let duplicateRowCount: Int
    let errorRowCount: Int
    let accountsToCreate: [AccountPayload]
    let categoriesToCreate: [CategoryPayload]
    let tagsToCreate: [TagPayload]
    let transactions: [TransactionPayload]
    let result: ImportResult
    var categoryBaselines: [ImportCategorySnapshot] = []
    var ledgerGeneration: UUID = LedgerSaveRevision.shared.restoreGeneration
}

actor ImportCommitActor {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) { self.modelContainer = modelContainer }

    func commit(
        _ request: ImportCommitRequest, progress: AsyncStream<Int>.Continuation? = nil,
        afterDependencyValidation: (@Sendable () throws -> Void)? = nil
    ) throws -> ImportResult {
        try ImportCommitWriter(modelContext: ModelContext(modelContainer)).commit(
            request, progress: progress, afterDependencyValidation: afterDependencyValidation
        )
    }
}

enum ImportCommitError: LocalizedError {
    case staleMetadata(String)

    var errorDescription: String? {
        switch self {
        case let .staleMetadata(dependency): "导入预览中的\(dependency)已失效，请重新准备后导入。"
        }
    }
}

struct ImportCommitWriter {
    let modelContext: ModelContext
    func commit(
        _ request: ImportCommitRequest,
        progress: AsyncStream<Int>.Continuation? = nil,
        afterRecheck: (() throws -> Void)? = nil,
        afterDependencyValidation: (() throws -> Void)? = nil
    ) throws -> ImportResult {
        defer { progress?.finish() }
        let revision = LedgerSaveRevision.shared.revision
        let checked = try rechecked(request)
        try afterRecheck?()
        return try LedgerSaveRevision.shared.withImportBoundary {
            guard request.ledgerGeneration == LedgerSaveRevision.shared.restoreGeneration else {
                throw ImportCommitError.staleMetadata("账本")
            }
            let current = revision == LedgerSaveRevision.shared.revision ? checked : try rechecked(request)
            do { return try write(current, progress: progress, afterDependencyValidation: afterDependencyValidation) }
            catch { modelContext.rollbackNotifyingSync(); throw error }
        }
    }

    private func write(_ request: ImportCommitRequest, progress: AsyncStream<Int>.Continuation?,
                       afterDependencyValidation: (() throws -> Void)?) throws -> ImportResult {
        guard !request.transactions.isEmpty else { return request.result }
        try validateDependencies(request)
        var accountsByID = try accounts(ids: Set(request.transactions.map(\.accountID)))
        var categoriesByID = try categories(ids: Set(
            request.transactions.compactMap(\.categoryID) + request.categoriesToCreate.map(\.parentID)
        ))
        var tagsByID = try tags(ids: Set(request.transactions.flatMap(\.tagIDs)))
        try afterDependencyValidation?()

        // Only this actual import-created metadata receives an origin. Existing user
        // objects with the same display name retain their independent identities.
        let identities = request.transactions.map {
            let eventID = $0.duplicateCheckID ?? $0.externalTransactionID
            return [$0.type.rawValue, eventID.isEmpty ? $0.fingerprint : eventID]
        }.sorted { $0.lexicographicallyPrecedes($1) }
        let encoded = try JSONEncoder().encode(identities)
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        let billOrigin = "import-v1:" + request.source.rawValue + ":" + digest
        let origins = try modelContext.fetch(FetchDescriptor<ImportEntityOrigin>())
        let attempt = origins.filter { $0.entityKey.hasPrefix("importBatches:") && $0.semanticKey.hasPrefix(billOrigin + ":attempt:") }.count
        let batchOrigin = request.transactions.contains { $0.explicitDuplicateInstance != nil }
            ? billOrigin + ":explicit:" + request.batchID.uuidString
            : billOrigin + ":attempt:" + String(attempt)
        func remember(_ kind: String, _ id: UUID, _ components: [String]) throws {
            let suffix = try JSONEncoder().encode(components).base64EncodedString()
            modelContext.insert(ImportEntityOrigin(entityKey: "\(kind):\(id.uuidString)", semanticKey: batchOrigin + ":" + suffix))
        }
        modelContext.insert(ImportEntityOrigin(entityKey: "importBatches:\(request.batchID.uuidString)", semanticKey: batchOrigin))
        for payload in request.accountsToCreate {
            let account = Account(
                id: payload.id,
                name: payload.name,
                type: .other,
                sortOrder: payload.sortOrder,
                createdAt: request.startedAt,
                updatedAt: request.startedAt
            )
            try remember("accounts", payload.id, [payload.name])
            modelContext.insert(account)
            accountsByID[payload.id] = account
        }

        for payload in request.categoriesToCreate {
            let category = Category(
                id: payload.id,
                kind: payload.kind,
                name: payload.name,
                parentID: payload.parentID,
                symbolName: payload.symbolName,
                colorToken: payload.colorToken,
                sortOrder: payload.sortOrder,
                createdAt: request.startedAt,
                updatedAt: request.startedAt
            )
            guard let parent = categoriesByID[payload.parentID] else { throw ImportCommitError.staleMetadata("父分类") }
            let parentIdentity = parent.defaultDefinitionKey.isEmpty ? parent.id.uuidString : parent.defaultDefinitionKey
            try remember("categories", payload.id, [payload.kind.rawValue, parentIdentity, payload.name])
            modelContext.insert(category)
            categoriesByID[payload.id] = category
        }

        for payload in request.tagsToCreate {
            let tag = Tag(
                id: payload.id,
                name: payload.name,
                sortOrder: payload.sortOrder,
                createdAt: request.startedAt,
                updatedAt: request.startedAt
            )
            try remember("tags", payload.id, [payload.name])
            modelContext.insert(tag)
            tagsByID[payload.id] = tag
        }

        let batch = ImportBatch(
            id: request.batchID,
            sourceType: request.source,
            sourceDisplayName: request.sourceDisplayName,
            sourceFormatVersion: request.sourceFormatVersion,
            startedAt: request.startedAt,
            status: .importing,
            totalRowCount: request.totalRowCount,
            skippedRowCount: request.skippedRowCount,
            duplicateRowCount: request.duplicateRowCount,
            errorRowCount: request.errorRowCount,
            createdAt: request.startedAt,
            updatedAt: request.startedAt
        )
        modelContext.insert(batch)

        for (index, payload) in request.transactions.enumerated() {
            let origin = payload.importSemanticOrigin ?? LedgerSyncIdentity.baseOrigin(
                source: request.source, type: payload.type, externalID: payload.externalTransactionID,
                fingerprint: payload.fingerprint)
            if let origin {
                modelContext.insert(ImportEntityOrigin(entityKey: "transactions:\(payload.id.uuidString)",
                    semanticKey: origin))
            }
            guard accountsByID[payload.accountID] != nil else {
                throw TransactionDraftError.missingAccount
            }
            if let categoryID = payload.categoryID, categoriesByID[categoryID] == nil {
                throw ImportCommitError.staleMetadata("分类")
            }
            let rowTags = try payload.tagIDs.map { id in
                guard let tag = tagsByID[id] else { throw ImportCommitError.staleMetadata("标签") }
                return tag
            }
            modelContext.insert(FinanceTransaction(
                id: payload.id,
                type: payload.type,
                amountMinorUnits: payload.amountMinorUnits,
                occurredAt: payload.occurredAt,
                localDayKey: payload.localDayKey,
                timeZoneIdentifier: payload.timeZoneIdentifier,
                accountID: payload.accountID,
                categoryID: payload.categoryID,
                rawMerchantText: payload.merchantName,
                note: payload.note,
                reviewStatus: payload.reviewStatus,
                reviewReasons: payload.reviewReasons,
                importBatchID: batch.id,
                externalSource: request.source,
                externalTransactionID: payload.externalTransactionID,
                importFingerprint: payload.fingerprint,
                createdAt: request.startedAt,
                updatedAt: request.startedAt,
                tags: rowTags
            ))
            let completed = index + 1
            if completed.isMultiple(of: 250) || completed == request.transactions.count {
                progress?.yield(completed)
            }
        }

        batch.importedRowCount = request.transactions.count
        batch.incomeMinorUnits = request.result.incomeMinorUnits
        batch.expenseMinorUnits = request.result.expenseMinorUnits
        batch.status = .completed
        batch.completedAt = request.startedAt
        batch.updatedAt = request.startedAt
        do {
            try modelContext.save()
        } catch {
            modelContext.rollbackNotifyingSync()
            throw error
        }
        return request.result
    }

    /// Validate only dependencies of retained rows, inside the same final write boundary.
    /// A fresh context avoids accepting stale registered model values after another context saved.
    private func validateDependencies(_ request: ImportCommitRequest) throws {
        let reader = ImportCommitWriter(modelContext: ModelContext(modelContext.container))
        let accountIDs = Set(request.transactions.map(\.accountID))
        let currentAccounts = try reader.accounts(ids: accountIDs)
        let newAccounts = Set(request.accountsToCreate.map(\.id))
        let newCategories = Dictionary(uniqueKeysWithValues: request.categoriesToCreate.map { ($0.id, $0) })
        let newTags = Set(request.tagsToCreate.map(\.id))
        var currentCategories = try reader.categories(ids: Set(
            request.transactions.compactMap(\.categoryID) + request.categoriesToCreate.map(\.parentID)))
        let parentIDs = Set(currentCategories.values.compactMap(\.parentID))
        currentCategories.merge(try reader.categories(ids: parentIDs)) { old, _ in old }
        let currentTags = try reader.tags(ids: Set(request.transactions.flatMap(\.tagIDs)))
        if !request.categoryBaselines.isEmpty {
            let expected = Dictionary(uniqueKeysWithValues: request.categoryBaselines.map { ($0.id, $0) })
            for current in currentCategories.values {
                guard let original = expected[current.id], original.createdAt == current.createdAt,
                      original.kind == current.kind, original.parentID == current.parentID,
                      original.defaultDefinitionKey == current.defaultDefinitionKey,
                      ImportCategoryResolutionService.normalize(original.name) == ImportCategoryResolutionService.normalize(current.name) else {
                    throw ImportCommitError.staleMetadata("分类用途")
                }
            }
        }

        func validCategory(_ value: Category, kind: CategoryKind, rootOnly: Bool = false) -> Bool {
            guard value.kind == kind, value.archivedAt == nil, !value.isHidden else { return false }
            guard let parentID = value.parentID else { return true }
            guard !rootOnly, let parent = currentCategories[parentID] else { return false }
            return parent.parentID == nil && parent.kind == kind && parent.archivedAt == nil && !parent.isHidden
        }
        for value in request.accountsToCreate {
            guard currentAccounts[value.id] == nil, !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportCommitError.staleMetadata("账户")
            }
        }
        for value in request.categoriesToCreate {
            guard currentCategories[value.id] == nil,
                  let parent = currentCategories[value.parentID], validCategory(parent, kind: value.kind, rootOnly: true),
                  !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportCommitError.staleMetadata("父分类")
            }
        }
        for value in request.tagsToCreate {
            guard currentTags[value.id] == nil, !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportCommitError.staleMetadata("标签")
            }
        }
        for row in request.transactions {
            // Current import payloads have no destination account or currency override.
            // A transfer cannot be validated by silently inventing its second account.
            guard row.type != .transfer else { throw ImportCommitError.staleMetadata("转账账户") }
            if !newAccounts.contains(row.accountID) {
                guard let account = currentAccounts[row.accountID], account.archivedAt == nil,
                      account.currencyCode == Money.cnyCode else { throw ImportCommitError.staleMetadata("账户") }
            }
            if let categoryID = row.categoryID {
                let kind: CategoryKind = row.type == .income ? .income : .expense
                if let planned = newCategories[categoryID] {
                    guard planned.kind == kind else { throw ImportCommitError.staleMetadata("分类") }
                } else {
                    guard let category = currentCategories[categoryID], validCategory(category, kind: kind) else {
                        throw ImportCommitError.staleMetadata("分类")
                    }
                }
            }
            for tagID in row.tagIDs where !newTags.contains(tagID) {
                guard let tag = currentTags[tagID], tag.archivedAt == nil else { throw ImportCommitError.staleMetadata("标签") }
            }
        }
    }

    private func rechecked(_ request: ImportCommitRequest) throws -> ImportCommitRequest {
        let source = request.source.rawValue
        let existing = try modelContext.fetch(FetchDescriptor<FinanceTransaction>(predicate: #Predicate {
            $0.externalSourceRawValue == source
        }))
        let existingLocalIDs = Set(existing.map(\.id))
        let index = ImportOccurrenceIndex(records: try ImportDuplicateRecord.snapshot(existing, in: modelContext))
        let rows = request.transactions.filter { row in
            guard !existingLocalIDs.contains(row.id) else { return false }
            if case .confirmedExistingRetained = row.intent { return true }
            // Preview and final recheck use exactly the same persisted occurrence rule.
            return !index.contains(source: request.source, type: row.type,
                externalID: row.externalTransactionID, fingerprint: row.fingerprint,
                occurrenceOrigin: row.importSemanticOrigin)
        }
        let accountIDs = Set(rows.map(\.accountID))
        let categoryIDs = Set(rows.compactMap(\.categoryID))
        let tagIDs = Set(rows.flatMap(\.tagIDs))
        let accounts = request.accountsToCreate.filter { accountIDs.contains($0.id) }
        let categories = request.categoriesToCreate.filter { categoryIDs.contains($0.id) }
        let tags = request.tagsToCreate.filter { tagIDs.contains($0.id) }
        var income: Int64 = 0
        var expense: Int64 = 0
        for row in rows {
            switch row.type {
            case .income: income = FinanceCSVService.saturatingAdd(income, row.amountMinorUnits)
            case .expense: expense = FinanceCSVService.saturatingAdd(expense, row.amountMinorUnits)
            case .refund: expense = FinanceCSVService.saturatingSubtract(expense, row.amountMinorUnits)
            case .transfer: break
            }
        }
        let duplicates = request.duplicateRowCount + request.transactions.count - rows.count
        let result = ImportResult(importedCount: rows.count, duplicateCount: duplicates,
            skippedCount: request.result.skippedCount, failedCount: request.result.failedCount,
            invalidCount: request.result.invalidCount, createdCategoryCount: categories.count,
            createdAccountCount: accounts.count, createdTagCount: tags.count,
            incomeMinorUnits: income, expenseMinorUnits: expense,
            confirmedDuplicateSkippedCount: request.result.confirmedDuplicateSkippedCount,
            staleDuplicateCount: request.result.staleDuplicateCount + request.transactions.count - rows.count)
        return ImportCommitRequest(batchID: request.batchID, source: request.source,
            sourceDisplayName: request.sourceDisplayName, sourceFormatVersion: request.sourceFormatVersion,
            startedAt: request.startedAt, totalRowCount: request.totalRowCount,
            skippedRowCount: request.skippedRowCount, duplicateRowCount: duplicates,
            errorRowCount: request.errorRowCount, accountsToCreate: accounts, categoriesToCreate: categories,
            tagsToCreate: tags, transactions: rows, result: result,
            categoryBaselines: request.categoryBaselines, ledgerGeneration: request.ledgerGeneration)
    }

    private func accounts(ids: Set<UUID>) throws -> [UUID: Account] {
        try ids.reduce(into: [:]) { result, id in
            var descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let account = try modelContext.fetch(descriptor).first {
                result[id] = account
            }
        }
    }

    private func categories(ids: Set<UUID>) throws -> [UUID: Category] {
        try ids.reduce(into: [:]) { result, id in
            var descriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let category = try modelContext.fetch(descriptor).first {
                result[id] = category
            }
        }
    }

    private func tags(ids: Set<UUID>) throws -> [UUID: Tag] {
        try ids.reduce(into: [:]) { result, id in
            var descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let tag = try modelContext.fetch(descriptor).first {
                result[id] = tag
            }
        }
    }
}

extension ImportDuplicateRecord {
    static func snapshot(_ transactions: [FinanceTransaction], in context: ModelContext) throws -> [Self] {
        var origins: [String: String] = [:]
        let keys = Set(transactions.map { "transactions:\($0.id.uuidString)" })
        for origin in try context.fetch(FetchDescriptor<ImportEntityOrigin>()) where keys.contains(origin.entityKey) {
            guard origins.updateValue(origin.semanticKey, forKey: origin.entityKey) == nil else {
                throw NativeBackupError.duplicateIdentifier("ImportEntityOrigin")
            }
        }
        return transactions.map { transaction in
            var record = Self(transaction: transaction)
            record.importSemanticOrigin = origins["transactions:\(transaction.id.uuidString)"]
            return record
        }
    }
}
