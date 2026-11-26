import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class LedgerUsageMetricsTests: XCTestCase {
    func testMetricsUseAppCreationDateAndOnlyActiveLedgerDays() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-18T23:30:00+08:00"))
        context.insert(AppMetadata(createdAt: createdAt))
        let deletedEarliest = transaction(day: "2017-01-01", deleted: true)
        let importedOld = transaction(day: "2018-03-26")
        let sameDay = transaction(day: "2018-03-26")
        let recent = transaction(day: "2026-08-20")
        [deletedEarliest, importedOld, sameDay, recent].forEach(context.insert)
        try context.save()

        let result = try await LedgerUsageMetricsActor(modelContainer: container).compute(batchSize: 2)
        XCTAssertEqual(result.metrics.appCreatedAt, createdAt)
        XCTAssertEqual(result.metrics.activeTransactionCount, 3)
        XCTAssertEqual(result.metrics.earliestLocalDayKey, "2018-03-26")
        XCTAssertEqual(result.metrics.distinctActiveDayCount, 2)
        XCTAssertEqual(result.scannedRecordCount, 3)
        XCTAssertLessThanOrEqual(result.maximumBatchCount, 2)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let sameDayNow = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-18T23:59:00+08:00"))
        let thirdDay = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T00:01:00+08:00"))
        XCTAssertEqual(
            LedgerUsageMetricsPresentation.companionDayCount(
                createdAt: createdAt,
                now: sameDayNow,
                calendar: calendar
            ),
            1
        )
        XCTAssertEqual(
            LedgerUsageMetricsPresentation.companionDayCount(
                createdAt: createdAt,
                now: thirdDay,
                calendar: calendar
            ),
            3
        )
    }

    func testCompactUsageSummaryKeepsAllFourMetricsInTwoLines() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let createdAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-18T12:00:00+08:00")
        )
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-20T12:00:00+08:00")
        )
        let lines = LedgerUsageMetricsPresentation.summaryLines(
            for: LedgerUsageMetrics(
                appCreatedAt: createdAt,
                activeTransactionCount: 11_742,
                earliestLocalDayKey: "2018-03-12",
                distinctActiveDayCount: 1_386
            ),
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(lines.primary, "已陪伴你 3 天，共 11,742 笔交易记录")
        XCTAssertEqual(lines.secondary, "最早 2018-03-12，共 1,386 个有账日")
    }

    func testCompactUsageSummaryRepresentsEmptyLedger() {
        let lines = LedgerUsageMetricsPresentation.summaryLines(
            for: LedgerUsageMetrics(
                appCreatedAt: Date(),
                activeTransactionCount: 0,
                earliestLocalDayKey: nil,
                distinctActiveDayCount: 0
            ),
            now: Date(),
            locale: Locale(identifier: "en_US")
        )

        XCTAssertTrue(lines.primary.contains("0 笔交易记录"))
        XCTAssertEqual(lines.secondary, "最早 暂无记录，共 0 个有账日")
    }

    func testRevisionCacheSkipsUnchangedLedgerAndRefreshesAfterMutation() async {
        let metrics = LedgerUsageMetrics(
            appCreatedAt: Date(timeIntervalSince1970: 1),
            activeTransactionCount: 2,
            earliestLocalDayKey: "2026-08-19",
            distinctActiveDayCount: 2
        )
        let counter = MetricsLoaderCounter(metrics: metrics)
        let store = LedgerUsageMetricsStore()

        await store.refreshIfNeeded(revision: 0) { await counter.load() }
        await store.refreshIfNeeded(revision: 0) { await counter.load() }
        let unchangedCount = await counter.count
        XCTAssertEqual(unchangedCount, 1)
        XCTAssertEqual(store.revisionAtComputation, 0)

        await store.refreshIfNeeded(revision: 1) { await counter.load() }
        let changedCount = await counter.count
        XCTAssertEqual(changedCount, 2)
        XCTAssertEqual(store.revisionAtComputation, 1)
    }

    func testMetricsOffsetBatchesIdenticalDaysWithoutLoss() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.insert(AppMetadata(createdAt: Date(timeIntervalSinceReferenceDate: 1)))
        let transactions = (0..<11).map { _ in transaction(day: "2026-08-20") }
            + [transaction(day: "2026-08-21")]
        transactions.forEach(context.insert)
        try context.save()

        let result = try await LedgerUsageMetricsActor(modelContainer: container).compute(
            batchSize: 3
        )

        XCTAssertEqual(result.metrics.activeTransactionCount, 12)
        XCTAssertEqual(result.metrics.earliestLocalDayKey, "2026-08-20")
        XCTAssertEqual(result.metrics.distinctActiveDayCount, 2)
        XCTAssertEqual(result.scannedRecordCount, 12)
        XCTAssertLessThanOrEqual(result.maximumBatchCount, 3)
    }

    private func transaction(day: String, deleted: Bool = false) -> FinanceTransaction {
        let date = ISO8601DateFormatter().date(from: "\(day)T12:00:00+08:00")!
        return FinanceTransaction(
            type: .expense,
            amountMinorUnits: 100,
            occurredAt: date,
            localDayKey: day,
            timeZoneIdentifier: "Asia/Shanghai",
            deletedAt: deleted ? date : nil
        )
    }
}

private actor MetricsLoaderCounter {
    private(set) var count = 0
    let metrics: LedgerUsageMetrics

    init(metrics: LedgerUsageMetrics) {
        self.metrics = metrics
    }

    func load() -> LedgerUsageMetricsComputation {
        count += 1
        return LedgerUsageMetricsComputation(
            metrics: metrics,
            scannedRecordCount: 2,
            maximumBatchCount: 2
        )
    }
}
