import Foundation
import SwiftData

struct LedgerAnalysisSnapshot: Sendable {
    let filter: LedgerFilter
    let revision: UInt64
    let totals: LedgerTotals
    let rootTotals: [UUID?: LedgerTotals]
    let directCategoryTotals: [UUID?: LedgerTotals]
    let monthTotals: [String: LedgerTotals]
    let dayTotals: [String: LedgerTotals]
    let monthRootTotals: [String: [UUID?: LedgerTotals]]
    let monthCategoryTotals: [String: [UUID?: LedgerTotals]]
    let transactionIDs: [UUID]
    let firstPage: [LedgerFilteredRow]
    let metadata: LedgerFilterMetadata
    let scannedRecordCount: Int
    let maximumBatchCount: Int
}

/// A MainActor-created instance still reads on its own executor. Every scan is
/// date/type/currency bounded in persistence, then applies the shared predicate.
actor LedgerAnalysisActor {
    private let modelContainer: ModelContainer
    init(modelContainer: ModelContainer) { self.modelContainer = modelContainer }

    struct AccountCounts: Sendable {
        let revision: UInt64
        let values: [UUID: Int]
    }

    func accountTransactionCounts(ids: [UUID]) throws -> AccountCounts {
        let revision = try LedgerSaveRevision.shared.readContentStamp()
        let context = ModelContext(modelContainer)
        var values: [UUID: Int] = [:]
        for id in ids {
            try check(revision)
            values[id] = try context.fetchCount(FetchDescriptor<FinanceTransaction>(predicate: #Predicate {
                $0.deletedAt == nil && ($0.accountID == id || $0.destinationAccountID == id)
            }))
        }
        try check(revision)
        return AccountCounts(revision: revision, values: values)
    }

    func snapshot(filter: LedgerFilter, pageSize: Int = 100,
                  afterBatch: (@Sendable () throws -> Void)? = nil) throws -> LedgerAnalysisSnapshot {
        let diagnosticStart = ContinuousClock.now
        for _ in 0..<2 {
            try Task.checkCancellation()
            do {
                let revision = try LedgerSaveRevision.shared.readContentStamp()
                if let expected = filter.revision, expected != revision { throw LedgerAnalysisError.staleSnapshot }
                let context = ModelContext(modelContainer)
                let metadata = try metadata(in: context)
                var totals = LedgerTotals()
                var rootTotals: [UUID?: LedgerTotals] = [:]
                var directTotals: [UUID?: LedgerTotals] = [:]
                var monthTotals: [String: LedgerTotals] = [:]
                var dayTotals: [String: LedgerTotals] = [:]
                var monthRootTotals: [String: [UUID?: LedgerTotals]] = [:]
                var monthCategoryTotals: [String: [UUID?: LedgerTotals]] = [:]
                var ids: [UUID] = []
                var firstPage: [LedgerFilteredRow] = []
                var offset = 0
                // One batched enumeration avoids repeatedly sorting/skipping an
                // ever-growing offset while retaining bounded model materialization.
                try context.enumerate(descriptor(filter), batchSize: 256) { value in
                    if offset.isMultiple(of: 256) { try check(revision) }
                    let row = LedgerFilteredRow(value)
                    if filter.matches(row, metadata: metadata) {
                        try totals.include(row)
                        try dayTotals[row.localDayKey, default: LedgerTotals()].include(row)
                        try rootTotals[metadata.rootID(row.categoryID), default: LedgerTotals()].include(row)
                        let categoryID = row.categoryID.flatMap { metadata.categories[$0] == nil ? nil : $0 }
                        try directTotals[categoryID, default: LedgerTotals()].include(row)
                        let month = String(row.localDayKey.prefix(7))
                        try monthTotals[month, default: LedgerTotals()].include(row)
                        try monthRootTotals[month, default: [:]][metadata.rootID(row.categoryID), default: LedgerTotals()].include(row)
                        try monthCategoryTotals[month, default: [:]][categoryID, default: LedgerTotals()].include(row)
                        ids.append(row.id)
                        if firstPage.count < max(0, pageSize) { firstPage.append(row) }
                    }
                    offset += 1
                    if offset.isMultiple(of: 256) {
                        try afterBatch?()
                        try check(revision)
                    }
                }
                if offset == 0 || !offset.isMultiple(of: 256) { try afterBatch?() }
                try check(revision)
                let maximumBatchCount = min(256, offset)
                var completedFilter = filter
                completedFilter.revision = revision
                let result = LedgerAnalysisSnapshot(filter: completedFilter, revision: revision,
                    totals: try totals.validated(), rootTotals: try rootTotals.mapValues { try $0.validated() },
                    directCategoryTotals: try directTotals.mapValues { try $0.validated() },
                    monthTotals: try monthTotals.mapValues { try $0.validated() },
                    dayTotals: try dayTotals.mapValues { try $0.validated() },
                    monthRootTotals: try monthRootTotals.mapValues { try $0.mapValues { try $0.validated() } },
                    monthCategoryTotals: try monthCategoryTotals.mapValues { try $0.mapValues { try $0.validated() } }, transactionIDs: ids,
                    firstPage: firstPage, metadata: metadata, scannedRecordCount: offset, maximumBatchCount: maximumBatchCount)
                try check(revision)
                LocalDiagnostics.shared.analysis(stage: .analysis, filter: completedFilter, revision: revision,
                    expectedCount: result.totals.totalCount, actualCount: ids.count, scannedCount: offset,
                    elapsed: diagnosticStart.duration(to: .now))
                return result
            } catch LedgerAnalysisError.staleSnapshot {
                if filter.revision != nil { throw LedgerAnalysisError.staleSnapshot }
            } catch ReconcileRevision.Failure.stalePlan {
                if filter.revision != nil { throw LedgerAnalysisError.staleSnapshot }
            }
        }
        throw LedgerAnalysisError.staleSnapshot
    }

    func recordedExpenseComparison(filter: LedgerFilter, asOf: Date, calendar: Calendar = .current,
        betweenPeriods: (@Sendable () throws -> Void)? = nil) throws -> RecordedExpenseComparison? {
        guard let periods = RecordedExpenseComparison.periods(filter: filter, asOf: asOf, calendar: calendar) else { return nil }
        let revision = try LedgerSaveRevision.shared.readContentStamp()
        var currentFilter = periods.current, previousFilter = periods.previous
        currentFilter.revision = revision; previousFilter.revision = revision
        let current = try snapshot(filter: currentFilter, pageSize: 0)
        try betweenPeriods?()
        try check(revision)
        let previous = try snapshot(filter: previousFilter, pageSize: 0)
        try check(revision)
        return try RecordedExpenseComparison.make(periods: periods, current: current, previous: previous)
    }

    func page(snapshot: LedgerAnalysisSnapshot, offset: Int, limit: Int = 100, recordDiagnostics: Bool = true) throws -> [LedgerFilteredRow] {
        let diagnosticStart = ContinuousClock.now
        try Task.checkCancellation()
        try check(snapshot.revision)
        let ids = Array(snapshot.transactionIDs.dropFirst(max(0, offset)).prefix(max(0, limit)))
        guard !ids.isEmpty else { return [] }
        var result: [LedgerFilteredRow] = []
        for offset in stride(from: 0, to: ids.count, by: 256) {
            let chunk = Array(ids.dropFirst(offset).prefix(256))
            let context = ModelContext(modelContainer)
            let values = try context.fetch(FetchDescriptor<FinanceTransaction>(predicate: #Predicate { chunk.contains($0.id) }))
            let rows = Dictionary(uniqueKeysWithValues: values.map { ($0.id, LedgerFilteredRow($0)) })
            guard rows.count == chunk.count else { throw LedgerAnalysisError.staleSnapshot }
            result += chunk.compactMap { rows[$0] }
            try check(snapshot.revision)
        }
        try check(snapshot.revision)
        if recordDiagnostics {
            LocalDiagnostics.shared.analysis(stage: .page, filter: snapshot.filter, revision: snapshot.revision,
                expectedCount: ids.count, actualCount: result.count, elapsed: diagnosticStart.duration(to: .now))
        }
        return result
    }

    /// Uses the complete snapshot ID set, never only the currently displayed page.
    func exportData(snapshot: LedgerAnalysisSnapshot, selectedIDs: Set<UUID>? = nil) throws -> Data {
        let diagnosticStart = ContinuousClock.now
        if let selectedIDs, !selectedIDs.isSubset(of: Set(snapshot.transactionIDs)) { throw LedgerAnalysisError.staleSnapshot }
        var rows: [LedgerFilteredRow] = []
        rows.reserveCapacity(snapshot.transactionIDs.count)
        for offset in stride(from: 0, to: snapshot.transactionIDs.count, by: 256) {
            let batch = try page(snapshot: snapshot, offset: offset, limit: 256, recordDiagnostics: false)
            rows.append(contentsOf: batch.filter { selectedIDs?.contains($0.id) ?? true })
        }
        try check(snapshot.revision)
        let data = FinanceCSVService.exportData(rows: rows, metadata: snapshot.metadata)
        try check(snapshot.revision)
        LocalDiagnostics.shared.analysis(stage: .export, filter: snapshot.filter, revision: snapshot.revision,
            expectedCount: selectedIDs?.count ?? snapshot.transactionIDs.count, actualCount: rows.count,
            selectedSubset: selectedIDs != nil, elapsed: diagnosticStart.duration(to: .now))
        return data
    }

    private func check(_ revision: UInt64) throws {
        try Task.checkCancellation()
        guard try LedgerSaveRevision.shared.readContentStamp() == revision else { throw LedgerAnalysisError.staleSnapshot }
    }

    private func metadata(in context: ModelContext) throws -> LedgerFilterMetadata {
        let catalog = try? CategoryCatalog.load()
        let retained = catalog?.legacyMappings.filter { $0.action != .reuse } ?? []
        let mixedKeys = Set(retained.map(\.oldKey))
        let mixedNames = Set(retained.map { String($0.oldName.split(separator: "/").last ?? "") })
        let categories = try context.fetch(FetchDescriptor<Category>()).map {
            LedgerFilterMetadata.CategoryValue(id: $0.id, name: $0.name, parentID: $0.parentID,
                symbolName: $0.symbolName, colorToken: $0.colorToken, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                inactive: $0.isHidden || $0.archivedAt != nil,
                comparisonAllowed: catalog != nil && !mixedKeys.contains($0.defaultDefinitionKey) && !mixedNames.contains($0.name))
        }
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let tags = try context.fetch(FetchDescriptor<Tag>())
        return LedgerFilterMetadata(categories: Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) }),
            accounts: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) }),
            tags: Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0.name) }))
    }

    private func descriptor(_ filter: LedgerFilter) -> FetchDescriptor<FinanceTransaction> {
        let lower = filter.dateRange?.lowerBound ?? ""
        let upper = filter.dateRange?.upperBound ?? "9999-99-99"
        let types = filter.mode.types
        let currency = filter.currencyCode
        let active = filter.deletion == .active
        let deleted = filter.deletion == .deleted
        let predicate = #Predicate<FinanceTransaction> {
            $0.localDayKey >= lower && $0.localDayKey < upper && $0.currencyCode == currency &&
            types.contains($0.typeRawValue) && (!active || $0.deletedAt == nil) && (!deleted || $0.deletedAt != nil)
        }
        let sort: [SortDescriptor<FinanceTransaction>]
        switch filter.sortOrder {
        case .timeNewest:
            sort = [SortDescriptor(\.occurredAt, order: .reverse), SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.id, order: .reverse)]
        case .timeOldest:
            sort = [SortDescriptor(\.occurredAt), SortDescriptor(\.createdAt), SortDescriptor(\.id)]
        case .amountHigh:
            sort = [SortDescriptor(\.amountMinorUnits, order: .reverse), SortDescriptor(\.occurredAt, order: .reverse), SortDescriptor(\.id, order: .reverse)]
        case .amountLow:
            sort = [SortDescriptor(\.amountMinorUnits), SortDescriptor(\.occurredAt, order: .reverse), SortDescriptor(\.id, order: .reverse)]
        }
        return FetchDescriptor(predicate: predicate, sortBy: sort)
    }
}
