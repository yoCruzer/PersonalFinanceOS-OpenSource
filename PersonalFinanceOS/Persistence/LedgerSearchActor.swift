import Foundation
import Observation
import SwiftData

struct LedgerSearchRequest: Equatable, Hashable, Sendable {
    let query: String
    let typeRawValue: String?
    let categoryFilterIDs: Set<UUID>
    let accountID: UUID?
    let tagID: UUID?
    let queryCategoryIDs: Set<UUID>
    let queryAccountIDs: Set<UUID>
    let queryTagIDs: Set<UUID>
    let matchesUncategorized: Bool
    let sortOrder: TransactionSortOrder

    var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool { !normalizedQuery.isEmpty }
}

struct SearchRequestGenerationGate {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    func accepts(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}

struct LedgerSearchPage: Equatable, Sendable {
    let transactionIDs: [UUID]
    let nextCursor: Int?
    let scannedRecordCount: Int
    let maximumBatchCount: Int
}

typealias LedgerSearchPageLoader = @Sendable (
    _ request: LedgerSearchRequest,
    _ cursor: Int
) async throws -> LedgerSearchPage

@ModelActor
actor LedgerSearchActor {
    func page(
        request: LedgerSearchRequest,
        cursor: Int = 0,
        pageSize: Int = 100,
        batchSize: Int = 256
    ) throws -> LedgerSearchPage {
        guard request.isValid, pageSize > 0, batchSize > 0 else {
            return LedgerSearchPage(
                transactionIDs: [],
                nextCursor: nil,
                scannedRecordCount: 0,
                maximumBatchCount: 0
            )
        }

        let query = request.normalizedQuery
        var fetchOffset = max(0, cursor)
        var matches: [UUID] = []
        var scannedRecordCount = 0
        var maximumBatchCount = 0

        while true {
            try Task.checkCancellation()
            var descriptor = descriptor(sortOrder: request.sortOrder)
            descriptor.fetchOffset = fetchOffset
            descriptor.fetchLimit = batchSize
            let batch = try modelContext.fetch(descriptor)
            maximumBatchCount = max(maximumBatchCount, batch.count)
            guard !batch.isEmpty else {
                return LedgerSearchPage(
                    transactionIDs: matches,
                    nextCursor: nil,
                    scannedRecordCount: scannedRecordCount,
                    maximumBatchCount: maximumBatchCount
                )
            }

            for (index, transaction) in batch.enumerated() {
                try Task.checkCancellation()
                scannedRecordCount += 1
                guard matchesFilters(transaction, request: request),
                      matchesQuery(transaction, query: query, request: request) else {
                    continue
                }
                if matches.count == pageSize {
                    return LedgerSearchPage(
                        transactionIDs: matches,
                        nextCursor: fetchOffset + index,
                        scannedRecordCount: scannedRecordCount,
                        maximumBatchCount: maximumBatchCount
                    )
                }
                matches.append(transaction.id)
            }

            fetchOffset += batch.count
            if batch.count < batchSize {
                return LedgerSearchPage(
                    transactionIDs: matches,
                    nextCursor: nil,
                    scannedRecordCount: scannedRecordCount,
                    maximumBatchCount: maximumBatchCount
                )
            }
        }
    }

    private func descriptor(
        sortOrder: TransactionSortOrder
    ) -> FetchDescriptor<FinanceTransaction> {
        let sortDescriptors: [SortDescriptor<FinanceTransaction>] = switch sortOrder {
        case .timeNewest:
            [
                SortDescriptor(\FinanceTransaction.occurredAt, order: .reverse),
                SortDescriptor(\FinanceTransaction.createdAt, order: .reverse),
                SortDescriptor(\FinanceTransaction.id, order: .reverse)
            ]
        case .timeOldest:
            [
                SortDescriptor(\FinanceTransaction.occurredAt),
                SortDescriptor(\FinanceTransaction.createdAt),
                SortDescriptor(\FinanceTransaction.id)
            ]
        case .amountHigh:
            [
                SortDescriptor(\FinanceTransaction.amountMinorUnits, order: .reverse),
                SortDescriptor(\FinanceTransaction.occurredAt, order: .reverse),
                SortDescriptor(\FinanceTransaction.createdAt, order: .reverse),
                SortDescriptor(\FinanceTransaction.id, order: .reverse)
            ]
        case .amountLow:
            [
                SortDescriptor(\FinanceTransaction.amountMinorUnits),
                SortDescriptor(\FinanceTransaction.occurredAt, order: .reverse),
                SortDescriptor(\FinanceTransaction.createdAt, order: .reverse),
                SortDescriptor(\FinanceTransaction.id, order: .reverse)
            ]
        }
        return FetchDescriptor(
            predicate: #Predicate<FinanceTransaction> { $0.deletedAt == nil },
            sortBy: sortDescriptors
        )
    }

    private func matchesFilters(
        _ transaction: FinanceTransaction,
        request: LedgerSearchRequest
    ) -> Bool {
        guard request.typeRawValue.map({ transaction.typeRawValue == $0 }) ?? true,
              request.categoryFilterIDs.isEmpty || transaction.categoryID.map(
                request.categoryFilterIDs.contains
              ) == true,
              request.accountID.map({ transaction.accountID == $0 }) ?? true,
              request.tagID.map({ id in transaction.tags.contains { $0.id == id } }) ?? true else {
            return false
        }
        return true
    }

    private func matchesQuery(
        _ transaction: FinanceTransaction,
        query: String,
        request: LedgerSearchRequest
    ) -> Bool {
        if transaction.note.localizedCaseInsensitiveContains(query) ||
            transaction.rawMerchantText.localizedCaseInsensitiveContains(query) {
            return true
        }
        if transaction.categoryID.map(request.queryCategoryIDs.contains) == true ||
            (transaction.categoryID == nil && request.matchesUncategorized) ||
            transaction.accountID.map(request.queryAccountIDs.contains) == true {
            return true
        }
        guard !request.queryTagIDs.isEmpty else { return false }
        return transaction.tags.contains { request.queryTagIDs.contains($0.id) }
    }
}

@MainActor
@Observable
final class LedgerSearchStore {
    private(set) var transactions: [FinanceTransaction] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var pageNumber = 1
    private(set) var hasPreviousPage = false
    private(set) var hasNextPage = false
    private(set) var lastScannedRecordCount = 0
    private(set) var lastMaximumBatchCount = 0

    private var worker: LedgerSearchActor?
    private var pageCursors = [0]
    private var nextCursor: Int?
    private var request: LedgerSearchRequest?
    private var gate = SearchRequestGenerationGate()
    private var pagingTask: Task<Void, Never>?
    private var pagingGeneration: UInt64?

    func search(
        request newRequest: LedgerSearchRequest,
        modelContainer: ModelContainer,
        modelContext: ModelContext,
        debounce: Bool,
        pageLoader: LedgerSearchPageLoader? = nil
    ) async {
        cancelPaging()
        let generation = gate.begin()
        guard newRequest.isValid else {
            clear()
            return
        }
        request = newRequest
        pageCursors = [0]
        pageNumber = 1
        hasPreviousPage = false
        isLoading = true
        errorMessage = nil
        if debounce {
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
        }
        let loader = pageLoader ?? makePageLoader(modelContainer: modelContainer)
        await load(
            request: newRequest,
            cursor: 0,
            targetPageNumber: 1,
            generation: generation,
            pageLoader: loader,
            modelContext: modelContext
        )
    }

    func loadNext(
        modelContainer: ModelContainer,
        modelContext: ModelContext,
        pageLoader: LedgerSearchPageLoader? = nil
    ) {
        guard let request, let nextCursor else { return }
        cancelPaging()
        let generation = gate.begin()
        let targetPage = pageNumber + 1
        isLoading = true
        let loader = pageLoader ?? makePageLoader(modelContainer: modelContainer)
        startPagingTask(generation: generation) { [weak self] in
            guard let self else { return }
            await self.load(
                request: request,
                cursor: nextCursor,
                targetPageNumber: targetPage,
                generation: generation,
                pageLoader: loader,
                modelContext: modelContext
            )
        }
    }

    func loadPrevious(
        modelContainer: ModelContainer,
        modelContext: ModelContext,
        pageLoader: LedgerSearchPageLoader? = nil
    ) {
        guard let request, pageNumber > 1 else { return }
        cancelPaging()
        let generation = gate.begin()
        let targetPage = pageNumber - 1
        let cursor = pageCursors[targetPage - 1]
        isLoading = true
        let loader = pageLoader ?? makePageLoader(modelContainer: modelContainer)
        startPagingTask(generation: generation) { [weak self] in
            guard let self else { return }
            await self.load(
                request: request,
                cursor: cursor,
                targetPageNumber: targetPage,
                generation: generation,
                pageLoader: loader,
                modelContext: modelContext
            )
        }
    }

    func cancelPaging() {
        pagingTask?.cancel()
        pagingTask = nil
        pagingGeneration = nil
        _ = gate.begin()
        isLoading = false
    }

    func clear() {
        cancelPaging()
        transactions = []
        errorMessage = nil
        pageNumber = 1
        pageCursors = [0]
        nextCursor = nil
        request = nil
        hasPreviousPage = false
        hasNextPage = false
        lastScannedRecordCount = 0
        lastMaximumBatchCount = 0
    }

    private func makePageLoader(modelContainer: ModelContainer) -> LedgerSearchPageLoader {
        let worker = worker ?? LedgerSearchActor(modelContainer: modelContainer)
        self.worker = worker
        return { request, cursor in
            try await worker.page(request: request, cursor: cursor)
        }
    }

    private func startPagingTask(
        generation: UInt64,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        pagingGeneration = generation
        pagingTask = Task { [weak self] in
            await operation()
            self?.finishPagingTask(generation: generation)
        }
    }

    private func finishPagingTask(generation: UInt64) {
        guard pagingGeneration == generation else { return }
        pagingTask = nil
        pagingGeneration = nil
    }

    private func load(
        request: LedgerSearchRequest,
        cursor: Int,
        targetPageNumber: Int,
        generation: UInt64,
        pageLoader: LedgerSearchPageLoader,
        modelContext: ModelContext
    ) async {
        do {
            let page = try await pageLoader(request, cursor)
            try Task.checkCancellation()
            guard gate.accepts(generation) else { return }
            let fetched = try LedgerQueryService.fetchSelected(
                Set(page.transactionIDs),
                in: modelContext
            )
            let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
            transactions = page.transactionIDs.compactMap { byID[$0] }
            pageNumber = targetPageNumber
            if pageCursors.count < targetPageNumber {
                pageCursors.append(cursor)
            }
            nextCursor = page.nextCursor
            hasPreviousPage = targetPageNumber > 1
            hasNextPage = page.nextCursor != nil
            lastScannedRecordCount = page.scannedRecordCount
            lastMaximumBatchCount = page.maximumBatchCount
            isLoading = false
            errorMessage = nil
        } catch is CancellationError {
            guard gate.accepts(generation) else { return }
            isLoading = false
        } catch {
            guard gate.accepts(generation) else { return }
            transactions = []
            nextCursor = nil
            hasNextPage = false
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}
