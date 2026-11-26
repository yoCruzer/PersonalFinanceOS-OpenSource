import SwiftData
import XCTest
@testable import PersonalFinanceOS

final class LargeLedgerRegressionTests: XCTestCase {
    @MainActor
    func testTwelveThousandLedgerSearchAndUsageMetricsStayBatchBounded() async throws {
        try await verifySearchAndMetricsScale(recordCount: 12_000)
    }

    @MainActor
    func testFiftyThousandLedgerSearchAndUsageMetricsStayBatchBounded() async throws {
        try await verifySearchAndMetricsScale(recordCount: 50_000)
    }

    func testTwelveThousandTransactionMonthUsesSingleSnapshotAndDayAggregation() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let month = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        let accountID = UUID()
        let category = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let transactions = (0..<12_000).map { index -> FinanceTransaction in
            let occurredAt = calendar.date(
                byAdding: .minute,
                value: index * 3,
                to: month
            )!
            let type: TransactionType = switch index % 4 {
            case 0: .income
            case 1: .expense
            case 2: .refund
            default: .transfer
            }
            return FinanceTransaction(
                type: type,
                amountMinorUnits: 100,
                occurredAt: occurredAt,
                localDayKey: LocalDayKey.make(for: occurredAt, timeZone: calendar.timeZone),
                timeZoneIdentifier: calendar.timeZone.identifier,
                accountID: accountID,
                categoryID: category.id
            )
        }

        let snapshot = FinanceInsightsService.snapshot(
            for: transactions,
            selectedMonth: month,
            categories: [category],
            calendar: calendar
        )
        let days = BillCalendarService.days(in: month, transactions: transactions, calendar: calendar)

        XCTAssertEqual(snapshot.activity.totalCount, 12_000)
        XCTAssertEqual(snapshot.summary.incomeMinorUnits, 300_000)
        XCTAssertEqual(snapshot.summary.expenseMinorUnits, 0)
        XCTAssertEqual(snapshot.trend.count, 6)
        XCTAssertEqual(days.compactMap { $0 }.reduce(0) { $0 + $1.transactionCount }, 9_000)
    }

    func testDuplicatePlanningScalesWithFiftyThousandExistingRecords() throws {
        let existing = (0..<50_000).map { index in
            ImportDuplicateRecord(
                externalSource: .wechat,
                type: .expense,
                externalTransactionID: "existing-\(index)",
                importFingerprint: "existing-fingerprint-\(index)",
                amountMinorUnits: 100,
                occurredAt: Date(timeIntervalSince1970: TimeInterval(index)),
                note: "existing-note-\(index)",
                deletedAt: nil
            )
        }
        let header = "type,amount,date_time,category,account,note,transaction_id\n"
        let rows = (0..<12_000).map { index in
            "expense,1.00,2026-07-10 12:00,餐饮,现金,row-\(index),new-\(index)"
        }.joined(separator: "\n")
        let document = try FinanceCSVService.readImportDocument(
            data: Data((header + rows).utf8),
            fileName: "large-ledger.csv"
        )

        let importPlan = try FinanceCSVService.makePlan(
            document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "large-ledger.csv",
            existingRecords: existing
        )

        XCTAssertEqual(importPlan.candidates.count, 12_000)
        XCTAssertEqual(importPlan.duplicateCount, 0)
        XCTAssertEqual(importPlan.suspectedDuplicateCount, 0)
        XCTAssertEqual(importPlan.effectiveRowsToImport(includeSuspectedDuplicates: true).count, 12_000)
    }

    @MainActor
    private func verifySearchAndMetricsScale(recordCount: Int) async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        context.insert(AppMetadata(createdAt: createdAt))
        var expectedID: UUID?
        for index in 0..<recordCount {
            let day = String(format: "2026-08-%02d", (index % 28) + 1)
            let transaction = FinanceTransaction(
                type: .expense,
                amountMinorUnits: Int64(index + 1),
                occurredAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index)),
                localDayKey: day,
                timeZoneIdentifier: "Asia/Shanghai",
                note: index == recordCount - 1 ? "唯一性能命中" : "普通记录"
            )
            if index == recordCount - 1 { expectedID = transaction.id }
            context.insert(transaction)
        }
        try context.save()

        let clock = ContinuousClock()
        let searchStart = clock.now
        let search = try await LedgerSearchActor(modelContainer: container).page(
            request: LedgerSearchRequest(
                query: "唯一性能命中",
                typeRawValue: nil,
                categoryFilterIDs: [],
                accountID: nil,
                tagID: nil,
                queryCategoryIDs: [],
                queryAccountIDs: [],
                queryTagIDs: [],
                matchesUncategorized: false,
                sortOrder: .timeOldest
            ),
            batchSize: 256
        )
        let searchDuration = searchStart.duration(to: clock.now)
        XCTAssertEqual(search.transactionIDs, [try XCTUnwrap(expectedID)])
        XCTAssertEqual(search.scannedRecordCount, recordCount)
        XCTAssertLessThanOrEqual(search.maximumBatchCount, 256)

        let metricsStart = clock.now
        let metrics = try await LedgerUsageMetricsActor(modelContainer: container).compute(
            batchSize: 256
        )
        let metricsDuration = metricsStart.duration(to: clock.now)
        XCTAssertEqual(metrics.metrics.appCreatedAt, createdAt)
        XCTAssertEqual(metrics.metrics.activeTransactionCount, recordCount)
        XCTAssertEqual(metrics.metrics.earliestLocalDayKey, "2026-08-01")
        XCTAssertEqual(metrics.metrics.distinctActiveDayCount, 28)
        XCTAssertEqual(metrics.scannedRecordCount, recordCount)
        XCTAssertLessThanOrEqual(metrics.maximumBatchCount, 256)

        print(
            "BUILD14_BENCHMARK records=\(recordCount) " +
            "search=\(searchDuration) metrics=\(metricsDuration) maxBatch=256"
        )
    }
}
