import Foundation
import Observation

@MainActor
@Observable
final class LedgerAnalysisStore {
    private(set) var snapshot: LedgerAnalysisSnapshot?
    private(set) var rows: [LedgerFilteredRow] = []
    private(set) var isLoading = false
    private(set) var isLoadingPage = false
    private(set) var errorMessage: String?
    private(set) var wasCancelled = false
    private(set) var resolvedAnchorID: UUID?
    private(set) var restorationSourceAnchorID: UUID?
    private(set) var loadedRange: Range<Int> = 0..<0
    private(set) var isPresentationStale = false
    private var generation = UUID()
    var requestIdentifier: UUID { generation }
    private var isRevisionPinned = false
    enum ReadStage: String { case snapshot, window, anchor, publication }

    var hasMore: Bool { loadedRange.upperBound < (snapshot?.transactionIDs.count ?? 0) }
    var hasPrevious: Bool { loadedRange.lowerBound > 0 }
    var permitsPresentationActions: Bool { !isLoading && !isPresentationStale && errorMessage == nil }

    func reload(filter: LedgerFilter, actor: LedgerAnalysisActor, anchorID: UUID? = nil, anchorProvider: (() -> UUID?)? = nil,
                requiresExactRevision: Bool = false, beforeQuery: (() async throws -> Void)? = nil, beforePublication: (() throws -> Void)? = nil,
                onConflict: ((ReadStage, Int) -> Void)? = nil) async {
        var query = filter
        if !requiresExactRevision { query.revision = nil }
        // Even a cache hit is a new request: a suspended older filter must lose ownership.
        let request = UUID()
        generation = request
        isRevisionPinned = requiresExactRevision
        isLoading = false
        isLoadingPage = false
        wasCancelled = false
        errorMessage = nil
        if let snapshot, (try? LedgerSaveRevision.shared.readContentStamp()) == snapshot.revision {
            var previous = snapshot.filter
            if !requiresExactRevision { previous.revision = nil }
            let candidate = anchorProvider != nil ? anchorProvider!() : anchorID
            if previous == query, candidate == nil || rows.contains(where: { $0.id == candidate }) {
                isPresentationStale = false
                restorationSourceAnchorID = candidate
                resolvedAnchorID = candidate
                return
            }
        }
        let previousIDs = snapshot?.transactionIDs ?? []
        let previousRange = loadedRange
        let keepsPresentation = snapshot?.filter.withoutRevision == query.withoutRevision && !requiresExactRevision
        isLoading = true
        if !keepsPresentation {
            snapshot = nil
            rows = []
            loadedRange = 0..<0
        }
        isPresentationStale = keepsPresentation
        resolvedAnchorID = nil
        restorationSourceAnchorID = nil
        defer { if generation == request { isLoading = false } }
        do {
            let delays: [Duration] = [.milliseconds(100), .milliseconds(250), .milliseconds(500), .seconds(1)]
            var stage = ReadStage.snapshot
            for attempt in 0...delays.count {
                guard generation == request else { return }
                try Task.checkCancellation()
                do {
                    stage = .snapshot
                    try await beforeQuery?()
                    let result = try await actor.snapshot(filter: query)
                    let latestAnchor = anchorProvider != nil ? anchorProvider!() : anchorID
                    let available = Set(result.transactionIDs)
                    let restoredAnchor: UUID?
                    if keepsPresentation, let anchorID = latestAnchor, available.contains(anchorID) { restoredAnchor = anchorID }
                    else if let anchorID = latestAnchor, let oldIndex = previousIDs.firstIndex(of: anchorID), keepsPresentation {
                        // Prefer the next surviving row, then the preceding row, when an edit/delete removes the target.
                        restoredAnchor = previousIDs.dropFirst(oldIndex + 1).first(where: { available.contains($0) })
                            ?? previousIDs.prefix(oldIndex).reversed().first(where: { available.contains($0) })
                            ?? result.transactionIDs.first
                    } else { restoredAnchor = nil }
                    let range = LedgerLoadedRangeRestoration.range(resultIDs: result.transactionIDs,
                        previousIDs: previousIDs, previousRange: previousRange, anchorID: restoredAnchor,
                        keepsPresentation: keepsPresentation)
                    stage = .window
                    let initial: [LedgerFilteredRow]
                    if range.lowerBound == 0 {
                        var prefix = Array(result.firstPage.prefix(range.count))
                        if range.count > prefix.count {
                            prefix += try await actor.page(snapshot: result, offset: prefix.count, limit: range.count - prefix.count)
                        }
                        initial = prefix
                    } else {
                        initial = try await actor.page(snapshot: result, offset: range.lowerBound, limit: range.count)
                    }
                    try Task.checkCancellation()
                    stage = .anchor
                    try beforePublication?()
                    if let anchorProvider {
                        let current = anchorProvider()
                        if let current {
                            if let index = result.transactionIDs.firstIndex(of: current) {
                                guard range.contains(index) else { throw LedgerAnalysisError.staleSnapshot }
                            } else if current != latestAnchor {
                                throw LedgerAnalysisError.staleSnapshot
                            }
                        } else if latestAnchor != nil, range.lowerBound > 0 {
                            throw LedgerAnalysisError.staleSnapshot
                        }
                    }
                    stage = .publication
                    try LedgerSaveRevision.shared.withProjectionBoundary {
                        guard generation == request, LedgerSaveRevision.shared.contentRevision == result.revision else {
                            throw LedgerAnalysisError.staleSnapshot
                        }
                        snapshot = result
                        rows = initial
                        loadedRange = range
                        isPresentationStale = false
                        restorationSourceAnchorID = latestAnchor
                        resolvedAnchorID = restoredAnchor
                    }
                    return
                } catch {
                    guard generation == request else { return }
                    guard Self.isTransient(error), !requiresExactRevision, attempt < delays.count else { throw error }
                    try Task.checkCancellation()
                    onConflict?(stage, attempt + 1)
                    try await Task.sleep(for: delays[attempt])
                }
            }
        } catch is CancellationError {
            if generation == request {
                if !keepsPresentation { snapshot = nil; rows = []; loadedRange = 0..<0 }
                isPresentationStale = keepsPresentation
                wasCancelled = true
                errorMessage = "查询已取消，请重新加载。"
            }
        } catch {
            if generation == request {
                if !keepsPresentation { snapshot = nil; rows = []; loadedRange = 0..<0 }
                isPresentationStale = keepsPresentation
                errorMessage = Self.message(for: error)
            }
        }
    }

    private static func message(for error: Error) -> String {
        isTransient(error) ? "账本暂时无法完成一致读取，请重新加载。" : error.localizedDescription
    }

    private static func isTransient(_ error: Error) -> Bool {
        switch error {
        case LedgerAnalysisError.staleSnapshot, ReconcileRevision.Failure.stalePlan: true
        default: false
        }
    }

    /// Apply only the plan sampled for this binding, never an older captured request target.
    func anchorAfterPublication(current: UUID?) -> UUID? {
        guard let source = restorationSourceAnchorID, current == source,
              !rows.contains(where: { $0.id == source }) else { return current }
        return resolvedAnchorID
    }

    func loadNextPage(actor: LedgerAnalysisActor, anchorProvider: (() -> UUID?)? = nil) async {
        guard permitsPresentationActions, !isLoadingPage, let snapshot, hasMore else { return }
        let request = generation
        let offset = loadedRange.upperBound
        isLoadingPage = true
        defer { if generation == request { isLoadingPage = false } }
        do {
            let page = try await actor.page(snapshot: snapshot, offset: offset)
            try Task.checkCancellation()
            try LedgerSaveRevision.shared.withProjectionBoundary {
                guard generation == request, loadedRange.upperBound == offset, LedgerSaveRevision.shared.contentRevision == snapshot.revision else {
                    throw LedgerAnalysisError.staleSnapshot
                }
                rows += page
                loadedRange = loadedRange.lowerBound..<(offset + page.count)
            }
        } catch is CancellationError { }
        catch {
            if generation == request {
                isPresentationStale = true
                if !isRevisionPinned, Self.isTransient(error) {
                    await reload(filter: snapshot.filter.withoutRevision, actor: actor, anchorID: anchorProvider == nil ? rows.first?.id : nil, anchorProvider: anchorProvider)
                } else { errorMessage = Self.message(for: error) }
            }
        }
    }

    func loadPreviousPage(actor: LedgerAnalysisActor, anchorProvider: (() -> UUID?)? = nil) async {
        guard permitsPresentationActions, !isLoadingPage, let snapshot, hasPrevious else { return }
        let request = generation
        let end = loadedRange.lowerBound
        let start = max(0, end - 100)
        isLoadingPage = true
        defer { if generation == request { isLoadingPage = false } }
        do {
            let page = try await actor.page(snapshot: snapshot, offset: start, limit: end - start)
            try Task.checkCancellation()
            try LedgerSaveRevision.shared.withProjectionBoundary {
                guard generation == request, loadedRange.lowerBound == end,
                      LedgerSaveRevision.shared.contentRevision == snapshot.revision else {
                    throw LedgerAnalysisError.staleSnapshot
                }
                rows = page + rows
                loadedRange = start..<loadedRange.upperBound
            }
        } catch is CancellationError { }
        catch {
            if generation == request {
                isPresentationStale = true
                if !isRevisionPinned, Self.isTransient(error) {
                    await reload(filter: snapshot.filter.withoutRevision, actor: actor, anchorID: anchorProvider == nil ? rows.first?.id : nil, anchorProvider: anchorProvider)
                } else { errorMessage = Self.message(for: error) }
            }
        }
    }

}

/// Holds the last coherent range presentation while its independent trend query refreshes.
@MainActor
@Observable
final class InsightsDisplayStore {
    let rangeStore = LedgerAnalysisStore()
    let trendStore = LedgerAnalysisStore()
    private(set) var display: LedgerAnalysisSnapshot?
    private(set) var finance: FinanceInsightsSnapshot?
    private(set) var trendDisplay: LedgerAnalysisSnapshot?
    private(set) var trendFinance: FinanceInsightsSnapshot?
    private(set) var isRefreshing = false
    private(set) var trendState: TrendState = .idle
    private var generation = UUID()
    enum Stage { case rangeLoading, rangeLoaded, trendLoading, trendLoaded }
    enum TrendState: Equatable { case idle, loading, ready, failed(String), cancelled }

    var currentTotals: LedgerTotals { display?.totals ?? LedgerTotals() }

    func reload(filter: LedgerFilter, month: Date, actor: LedgerAnalysisActor,
                checkpoint: ((Stage) async throws -> Void)? = nil) async {
        let request = UUID()
        generation = request
        isRefreshing = true
        trendDisplay = nil
        trendFinance = nil
        trendState = .loading
        defer { if generation == request { isRefreshing = false } }
        await rangeStore.reload(filter: filter, actor: actor,
            beforeQuery: { try await checkpoint?(.rangeLoading) })
        guard generation == request else { return }
        guard !Task.isCancelled else { trendState = .cancelled; return }
        if rangeStore.wasCancelled || (rangeStore.snapshot == nil && rangeStore.errorMessage == nil) { trendState = .cancelled; return }
        if rangeStore.isPresentationStale || rangeStore.errorMessage != nil {
            trendState = .failed(rangeStore.errorMessage ?? "范围更新未完成，请重试。")
            return
        }
        // Store publication is checked; check again at the presentation publication boundary.
        if let result = rangeStore.snapshot, result.filter.withoutRevision == filter.withoutRevision {
            do {
                try LedgerSaveRevision.shared.withProjectionBoundary {
                    guard LedgerSaveRevision.shared.contentRevision == result.revision else {
                        throw LedgerAnalysisError.staleSnapshot
                    }
                    display = result
                    finance = .from(result, selectedMonth: month, wholeRange: true)
                }
            } catch { trendState = .failed(error.localizedDescription); return }
        }
        do { try await checkpoint?(.rangeLoaded) } catch { trendState = .failed(error.localizedDescription); return }
        guard generation == request, !Task.isCancelled else {
            if generation == request { trendState = .cancelled }
            return
        }
        let trendFilter = LedgerFilter.sixMonths(endingAt: month)
        await trendStore.reload(filter: trendFilter, actor: actor,
            beforeQuery: { try await checkpoint?(.trendLoading) })
        guard generation == request else { return }
        guard !Task.isCancelled else { trendState = .cancelled; return }
        if trendStore.wasCancelled { trendState = .cancelled; return }
        if trendStore.isPresentationStale || trendStore.errorMessage != nil {
            trendState = .failed(trendStore.errorMessage ?? "趋势更新未完成，请重试。")
            return
        }
        if let result = trendStore.snapshot, result.filter.withoutRevision == trendFilter.withoutRevision {
            do {
                try LedgerSaveRevision.shared.withProjectionBoundary {
                    guard LedgerSaveRevision.shared.contentRevision == result.revision else {
                        throw LedgerAnalysisError.staleSnapshot
                    }
                    trendDisplay = result
                    trendFinance = .from(result, selectedMonth: month)
                    trendState = .ready
                }
            } catch { trendState = .failed(error.localizedDescription) }
        } else { trendState = .failed(trendStore.errorMessage ?? "趋势暂未完成，请重试。") }
        do { try await checkpoint?(.trendLoaded) } catch { trendState = .failed(error.localizedDescription) }
    }
}
