import Darwin
import SwiftData
import XCTest
@testable import PersonalFinanceOS

/// Isolated SQLite only. No sync controller, account access, or real ledger URL.
@MainActor
final class Build28AuditPerformanceTests: XCTestCase {
    func testTwelveThousandColdWarmAndMutation() async throws {
        try await benchmark(count: 12_000, repetitions: 5)
    }

    func testFiftyThousandColdWarmAndMutation() async throws {
        try await benchmark(count: 50_000, repetitions: 3)
    }

    private func benchmark(count: Int, repetitions: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Build28Audit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Retain temporary SQLite files for Core Data's asynchronous teardown.
        let container = try ModelContainerFactory.make(configuration: ModelConfiguration(
            "Build28Audit", schema: AppSchema.schema, url: directory.appendingPathComponent("synthetic.store"),
            cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(AppMetadata(createdAt: createdAt))
        let category = Category(kind: .expense, name: "合成餐饮", symbolName: "fork.knife", colorToken: "orange")
        context.insert(category)
        let start = ISO8601DateFormatter().date(from: "2026-05-01T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // 180 natural days, four types, one fixed cent amount; independent expected totals below.
        let types: [TransactionType] = [.expense, .income, .refund, .transfer]
        for index in 0..<count {
            let date = start.addingTimeInterval(TimeInterval(index % 180) * 86_400)
            context.insert(FinanceTransaction(type: types[index % 4], amountMinorUnits: 100,
                occurredAt: date, localDayKey: LocalDayKey.make(for: date, timeZone: calendar.timeZone),
                timeZoneIdentifier: "GMT", categoryID: category.id, note: "合成测试"))
            if (index + 1).isMultiple(of: 1000) { try context.save() }
        }
        try context.save()
        let actor = LedgerAnalysisActor(modelContainer: container)
        let usage = LedgerUsageMetricsActor(modelContainer: container)
        let filter = LedgerFilter(dateRange: nil)
        let month = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!
        for repetition in 0..<repetitions {
            var clock = ContinuousClock.now
            let result = try await actor.snapshot(filter: filter)
            report(count, repetition, "analysis_fresh_context", clock)
            XCTAssertEqual(result.totals.totalCount, count)
            XCTAssertEqual(result.totals.netExpenseMinorUnits, 0)
            XCTAssertEqual(result.totals.grossExpenseMinorUnits, Int64(count / 4) * 100)
            XCTAssertEqual(result.firstPage.count, 100)
            clock = .now
            let metrics = try await usage.compute()
            report(count, repetition, "usage_fresh_context", clock)
            XCTAssertEqual(metrics.metrics.activeTransactionCount, count)
            XCTAssertEqual(metrics.metrics.distinctActiveDayCount, 180)
            XCTAssertEqual(metrics.metrics.earliestLocalDayKey, "2026-05-01")
            XCTAssertEqual(metrics.metrics.appCreatedAt, createdAt)
            let store = LedgerAnalysisStore()
            await store.reload(filter: filter, actor: actor)
            clock = .now
            await store.reload(filter: filter, actor: actor)
            report(count, repetition, "ledger_warm_store", clock)
            XCTAssertEqual(store.snapshot?.totals.totalCount, count)
            let display = InsightsDisplayStore()
            clock = .now
            await display.reload(filter: filter, month: month, actor: actor)
            report(count, repetition, "insights_cold_store", clock)
            XCTAssertEqual(display.currentTotals.totalCount, count)
            clock = .now
            await display.reload(filter: filter, month: month, actor: actor)
            report(count, repetition, "insights_warm_store", clock)
            XCTAssertEqual(display.trendState, .ready)
        }
        let store = LedgerAnalysisStore()
        await store.reload(filter: filter, actor: actor)
        context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 321,
            occurredAt: start, localDayKey: "2026-05-01", timeZoneIdentifier: "GMT", categoryID: category.id))
        try context.save()
        let clock = ContinuousClock.now
        await store.reload(filter: filter, actor: actor)
        report(count, 0, "ledger_after_insert", clock)
        XCTAssertEqual(store.snapshot?.totals.totalCount, count + 1)
        XCTAssertEqual(store.snapshot?.totals.netExpenseMinorUnits, 321)
        let metrics = try await usage.compute()
        XCTAssertEqual(metrics.metrics.activeTransactionCount, count + 1)
        XCTAssertEqual(metrics.metrics.distinctActiveDayCount, 180)
    }

    private func report(_ count: Int, _ repetition: Int, _ stage: String, _ start: ContinuousClock.Instant) {
        let value = start.duration(to: .now).components
        let ms = Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        print("BUILD28_PERF count=\(count) repetition=\(repetition) stage=\(stage) ms=\(ms) process_peak_rss_bytes=\(usage.ru_maxrss)")
    }
}
