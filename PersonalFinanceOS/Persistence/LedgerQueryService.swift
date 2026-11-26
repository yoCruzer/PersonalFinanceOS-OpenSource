import Foundation
import SwiftData

/// Persistence boundary for ledger reads. Callers must request a concrete scope;
/// no normal screen should subscribe to the lifetime transaction table.
@MainActor
enum LedgerQueryService {
    struct CategoryTransactionPage {
        let transactions: [FinanceTransaction]
        let hasMore: Bool
    }

    static func fetchMonth(
        _ month: Date,
        in context: ModelContext,
        calendar: Calendar = .current
    ) throws -> [FinanceTransaction] {
        let range = localDayRange(for: month, calendar: calendar)
        let lowerBound = range.lowerBound
        let upperBound = range.upperBound
        let descriptor = FetchDescriptor<FinanceTransaction>(
            predicate: #Predicate {
                $0.deletedAt == nil &&
                $0.localDayKey >= lowerBound &&
                $0.localDayKey < upperBound
            },
            sortBy: [
                SortDescriptor(\FinanceTransaction.occurredAt, order: .reverse),
                SortDescriptor(\FinanceTransaction.createdAt, order: .reverse)
            ]
        )
        return try context.fetch(descriptor)
    }

    static func fetchMonthsEnding(
        at month: Date,
        count: Int,
        in context: ModelContext,
        calendar: Calendar = .current
    ) throws -> [FinanceTransaction] {
        guard count > 0,
              let firstMonth = calendar.date(byAdding: .month, value: 1 - count, to: month)
        else { return [] }
        let range = LocalDayRange(
            lowerBound: localDayRange(for: firstMonth, calendar: calendar).lowerBound,
            upperBound: localDayRange(for: month, calendar: calendar).upperBound
        )
        let lowerBound = range.lowerBound
        let upperBound = range.upperBound
        let descriptor = FetchDescriptor<FinanceTransaction>(
            predicate: #Predicate {
                $0.deletedAt == nil &&
                $0.localDayKey >= lowerBound &&
                $0.localDayKey < upperBound
            },
            sortBy: [SortDescriptor(\FinanceTransaction.occurredAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    static func fetchRecent(
        limit: Int,
        in context: ModelContext
    ) throws -> [FinanceTransaction] {
        var descriptor = FetchDescriptor<FinanceTransaction>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\FinanceTransaction.occurredAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return try context.fetch(descriptor)
    }

    static func fetchAllActive(in context: ModelContext) throws -> [FinanceTransaction] {
        let descriptor = FetchDescriptor<FinanceTransaction>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\FinanceTransaction.occurredAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    static func fetchRecentlyUpdated(
        limit: Int,
        in context: ModelContext
    ) throws -> [FinanceTransaction] {
        var descriptor = FetchDescriptor<FinanceTransaction>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\FinanceTransaction.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return try context.fetch(descriptor)
    }

    static func fetchImportBatch(
        _ batchID: UUID,
        limit: Int? = nil,
        in context: ModelContext
    ) throws -> [FinanceTransaction] {
        var descriptor = FetchDescriptor<FinanceTransaction>(
            predicate: #Predicate { $0.importBatchID == batchID },
            sortBy: [SortDescriptor(\FinanceTransaction.occurredAt, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = max(0, limit) }
        return try context.fetch(descriptor)
    }

    static func fetchDayRange(
        _ range: ClosedRange<String>,
        in context: ModelContext
    ) throws -> [FinanceTransaction] {
        let upperBound = range.upperBound + "\u{10FFFF}"
        let lowerBound = range.lowerBound
        let descriptor = FetchDescriptor<FinanceTransaction>(
            predicate: #Predicate {
                $0.localDayKey >= lowerBound && $0.localDayKey < upperBound
            }
        )
        return try context.fetch(descriptor)
    }

    static func fetchForAccount(_ accountID: UUID, in context: ModelContext) throws -> [FinanceTransaction] {
        let descriptor = FetchDescriptor<FinanceTransaction>(
            predicate: #Predicate {
                $0.accountID == accountID || $0.destinationAccountID == accountID
            }
        )
        return try context.fetch(descriptor)
    }

    static func fetchForCategory(_ categoryID: UUID, in context: ModelContext) throws -> [FinanceTransaction] {
        let descriptor = FetchDescriptor<FinanceTransaction>(
            predicate: #Predicate { $0.categoryID == categoryID }
        )
        return try context.fetch(descriptor)
    }

    static func countActiveForCategory(
        _ categoryID: UUID,
        in context: ModelContext
    ) throws -> Int {
        try context.fetchCount(FetchDescriptor<FinanceTransaction>(
            predicate: #Predicate {
                $0.categoryID == categoryID && $0.deletedAt == nil
            }
        ))
    }

    static func fetchActiveCategoryPage(
        categoryIDs: Set<UUID>,
        offset: Int = 0,
        limit: Int = 100,
        in context: ModelContext
    ) throws -> CategoryTransactionPage {
        guard !categoryIDs.isEmpty, limit > 0 else {
            return CategoryTransactionPage(transactions: [], hasMore: false)
        }
        let safeOffset = max(0, offset)
        let perCategoryLimit = safeOffset + limit + 1
        var values: [FinanceTransaction] = []
        for categoryID in categoryIDs {
            var descriptor = FetchDescriptor<FinanceTransaction>(
                predicate: #Predicate {
                    $0.deletedAt == nil && $0.categoryID == categoryID
                },
                sortBy: [
                    SortDescriptor(\FinanceTransaction.occurredAt, order: .reverse),
                    SortDescriptor(\FinanceTransaction.createdAt, order: .reverse),
                    SortDescriptor(\FinanceTransaction.id, order: .reverse)
                ]
            )
            descriptor.fetchLimit = perCategoryLimit
            values.append(contentsOf: try context.fetch(descriptor))
        }
        values.sort {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString > $1.id.uuidString
        }
        let remaining = values.dropFirst(min(safeOffset, values.count))
        return CategoryTransactionPage(
            transactions: Array(remaining.prefix(limit)),
            hasMore: remaining.count > limit
        )
    }

    /// Metadata deletion must include soft-deleted records because they still retain tag links.
    static func fetchForTag(_ tagID: UUID, in context: ModelContext) throws -> [FinanceTransaction] {
        let descriptor = FetchDescriptor<FinanceTransaction>(
            predicate: #Predicate { transaction in
                transaction.storedTags?.contains { tag in tag.id == tagID } == true
            }
        )
        return try context.fetch(descriptor)
    }

    static func fetchSelected(
        _ ids: Set<UUID>,
        includeDeleted: Bool = false,
        in context: ModelContext
    ) throws -> [FinanceTransaction] {
        guard !ids.isEmpty else { return [] }
        let selected = Array(ids)
        let descriptor = FetchDescriptor<FinanceTransaction>(
            predicate: #Predicate {
                selected.contains($0.id) && (includeDeleted || $0.deletedAt == nil)
            }
        )
        return try context.fetch(descriptor)
    }

    static func localDayRange(
        for month: Date,
        calendar: Calendar = .current
    ) -> LocalDayRange {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let end = calendar.date(byAdding: .month, value: 1, to: start)
        else {
            return LocalDayRange(lowerBound: "", upperBound: "")
        }
        return LocalDayRange(
            lowerBound: LocalDayKey.make(for: start, timeZone: calendar.timeZone),
            upperBound: LocalDayKey.make(for: end, timeZone: calendar.timeZone)
        )
    }
}

struct LocalDayRange: Sendable, Equatable {
    let lowerBound: String
    let upperBound: String
}
