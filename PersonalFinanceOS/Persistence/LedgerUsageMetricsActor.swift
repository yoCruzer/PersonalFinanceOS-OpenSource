import Foundation
import Observation
import SwiftData

struct LedgerUsageMetrics: Equatable, Sendable {
    let appCreatedAt: Date
    let activeTransactionCount: Int
    let earliestLocalDayKey: String?
    let distinctActiveDayCount: Int
}

struct LedgerUsageMetricsComputation: Equatable, Sendable {
    let metrics: LedgerUsageMetrics
    let scannedRecordCount: Int
    // Derived from min(configured batch size, scanned count), NOT measured resident
    // models or peak memory; SwiftData may cache/prefetch beyond an enumeration batch.
    let maximumBatchCount: Int
    // Business content stamp; receipt-only saves must not invalidate these metrics.
    var saveRevision: UInt64? = nil
}

struct LedgerUsageSummaryLines: Equatable {
    let primary: String
    let secondary: String
}

enum LedgerUsageMetricsPresentation {
    static func companionDayCount(
        createdAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let createdDay = calendar.startOfDay(for: createdAt)
        let currentDay = calendar.startOfDay(for: now)
        let elapsed = calendar.dateComponents([.day], from: createdDay, to: currentDay).day ?? 0
        return max(1, elapsed + 1)
    }

    static func summaryLines(
        for metrics: LedgerUsageMetrics,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> LedgerUsageSummaryLines {
        let companionDays = companionDayCount(
            createdAt: metrics.appCreatedAt,
            now: now,
            calendar: calendar
        )
        let daysText = companionDays.formatted(.number.locale(locale))
        let countText = metrics.activeTransactionCount.formatted(.number.locale(locale))
        let activeDaysText = metrics.distinctActiveDayCount.formatted(.number.locale(locale))
        return LedgerUsageSummaryLines(
            primary: "已陪伴你 \(daysText) 天，共 \(countText) 笔交易记录",
            secondary: "最早 \(metrics.earliestLocalDayKey ?? "暂无记录")，共 \(activeDaysText) 个有账日"
        )
    }
}

enum LedgerUsageMetricsError: LocalizedError {
    case invalidMetadata

    var errorDescription: String? { "使用日期暂时无法确认，请重试读取账本概况。" }
}

actor LedgerUsageMetricsActor {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) { self.modelContainer = modelContainer }

    func compute(batchSize: Int = 256, afterBatch: (@Sendable () throws -> Void)? = nil) throws -> LedgerUsageMetricsComputation {
        for _ in 0..<2 {
            try Task.checkCancellation()
            do {
                let revision = try LedgerSaveRevision.shared.readContentStamp()
                return try compute(in: ModelContext(modelContainer), revision: revision, batchSize: batchSize, afterBatch: afterBatch)
            } catch ReconcileRevision.Failure.stalePlan { continue }
        }
        throw ReconcileRevision.Failure.stalePlan
    }

    private func compute(in modelContext: ModelContext, revision: UInt64, batchSize: Int,
                         afterBatch: (@Sendable () throws -> Void)?) throws -> LedgerUsageMetricsComputation {
        precondition(batchSize > 0)
        var metadataRequest = FetchDescriptor<AppMetadata>()
        metadataRequest.fetchLimit = 2
        let metadata = try modelContext.fetch(metadataRequest)
        guard metadata.count == 1, let appCreatedAt = metadata.first?.createdAt else {
            throw LedgerUsageMetricsError.invalidMetadata
        }
        var activeCount = 0
        var earliestLocalDayKey: String?
        var distinctDayCount = 0
        var previousLocalDayKey: String?
        var descriptor = FetchDescriptor<FinanceTransaction>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\FinanceTransaction.localDayKey), SortDescriptor(\FinanceTransaction.id)]
        )
        descriptor.propertiesToFetch = [\FinanceTransaction.localDayKey, \FinanceTransaction.id]
        // One ordered cursor, rather than re-sorting and skipping each growing OFFSET.
        // Keep per-batch version checks and bounded model materialization.
        try modelContext.enumerate(descriptor, batchSize: batchSize) { transaction in
            try Task.checkCancellation()
            if activeCount.isMultiple(of: batchSize) { try check(revision) }
            activeCount += 1
            if earliestLocalDayKey == nil { earliestLocalDayKey = transaction.localDayKey }
            if previousLocalDayKey != transaction.localDayKey {
                distinctDayCount += 1
                previousLocalDayKey = transaction.localDayKey
            }
            if activeCount.isMultiple(of: batchSize) {
                try afterBatch?()
                try check(revision)
            }
        }
        if activeCount == 0 || !activeCount.isMultiple(of: batchSize) { try afterBatch?() }
        let maximumBatchCount = min(batchSize, activeCount)

        try check(revision)
        return LedgerUsageMetricsComputation(
            metrics: LedgerUsageMetrics(
                appCreatedAt: appCreatedAt,
                activeTransactionCount: activeCount,
                earliestLocalDayKey: earliestLocalDayKey,
                distinctActiveDayCount: distinctDayCount
            ),
            scannedRecordCount: activeCount,
            maximumBatchCount: maximumBatchCount,
            saveRevision: revision
        )
    }

    private func check(_ revision: UInt64) throws {
        guard try LedgerSaveRevision.shared.readContentStamp() == revision else {
            throw ReconcileRevision.Failure.stalePlan
        }
    }

}

@MainActor
@Observable
final class LedgerUsageMetricsStore {
    private(set) var metrics: LedgerUsageMetrics?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var revisionAtComputation: UInt64?
    private var requestGeneration: UInt64 = 0

    func refreshIfNeeded(
        revision: UInt64,
        loader: @escaping @Sendable () async throws -> LedgerUsageMetricsComputation
    ) async {
        guard revisionAtComputation != revision else { return }
        requestGeneration &+= 1
        let generation = requestGeneration
        isLoading = true
        errorMessage = nil
        // Retry only revision/admission conflicts. Sleeping yields the main actor,
        // keeps the last good values, and is cancelled with the view's task.
        // Five attempts total, at most 1.85s of backoff; no notification is needed.
        let delays: [Duration] = [.milliseconds(100), .milliseconds(250), .milliseconds(500), .seconds(1)]
        for attempt in 0...delays.count {
            guard generation == requestGeneration else { return }
            do {
                try Task.checkCancellation()
                let computation = try await loader()
                guard generation == requestGeneration else { return }
                try Task.checkCancellation()
                if let saveRevision = computation.saveRevision,
                   try LedgerSaveRevision.shared.readContentStamp() != saveRevision {
                    throw ReconcileRevision.Failure.stalePlan
                }
                metrics = computation.metrics
                revisionAtComputation = revision
                isLoading = false
                return
            } catch {
                guard generation == requestGeneration else { return }
                if error is CancellationError || Task.isCancelled {
                    isLoading = false
                    return
                }
                if case ReconcileRevision.Failure.stalePlan = error {
                    if attempt < delays.count {
                        do { try await Task.sleep(for: delays[attempt]) }
                        catch {
                            guard generation == requestGeneration else { return }
                            isLoading = false
                            return
                        }
                        continue
                    }
                    errorMessage = "账本正在更新，暂时无法刷新，请稍后重试。"
                } else {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
                return
            }
        }
    }

    func invalidatePendingRequest() {
        requestGeneration &+= 1
        isLoading = false
    }
}
