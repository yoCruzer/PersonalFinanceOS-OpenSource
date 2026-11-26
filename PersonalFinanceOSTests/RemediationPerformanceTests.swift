import Darwin
import SwiftData
import XCTest
@testable import PersonalFinanceOS

/// Same synthetic fixture and harness can be compiled against exact e30 with
/// PFOS_PERFORMANCE_BASELINE. Catalog upgrade has no baseline equivalent.
@MainActor
final class RemediationPerformanceTests: XCTestCase {
    func testHarnessWithSmallFixture() async throws { try await measureLedger(count: 128) }
    func testProductionMatrixTwelveAndFiftyThousand() async throws {
        for count in [12_000, 50_000] { try await measureLedger(count: count) }
    }

    private func measureLedger(count: Int) async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        #if PFOS_PERFORMANCE_BASELINE
        try DefaultFinanceDataService.ensureDefaults(in: context)
        #else
        try seedFrozenV3Ledger(in: context)
        #endif
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let category = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.dining.lunch" })
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first)
        let date = Date(timeIntervalSince1970: 1_788_278_400)
        for index in 0..<count {
            let row = FinanceTransaction(type: .expense, amountMinorUnits: 100, occurredAt: date,
                localDayKey: "2026-09-01", timeZoneIdentifier: "Asia/Shanghai",
                accountID: account.id, categoryID: category.id, note: "公司午餐")
            row.categoryDecisionSource = .manualConfirmed
            context.insert(row)
            if index.isMultiple(of: 1000) { try context.save() }
        }
        try context.save()
        let historyStart = ContinuousClock.now
        let history = try await ClassificationHistoryActor(modelContainer: context.container).fetchRollingHistory(cutoff: date.addingTimeInterval(-1))
        let profile = ClassificationProfileBuilder.build(history: history.history, events: [], now: date)
        report(count, "profile_cold_read_build", historyStart)
        XCTAssertEqual(profile.sampleCount, count)
        let suggestionCategories = categories.map {
            SuggestionCategory(id: $0.id, name: $0.name, kind: $0.kind, isActive: true,
                parentID: $0.parentID, defaultDefinitionKey: $0.defaultDefinitionKey)
        }
        let lookupStart = ContinuousClock.now
        for _ in 0..<100 {
            let suggestion = SmartTransactionSuggestionService.suggest(note: "公司午餐", type: .expense,
                categories: suggestionCategories, tags: [], profile: profile)
            XCTAssertEqual(suggestion.categoryID, category.id)
        }
        report(count, "profile_hot_100_lookups", lookupStart)

        #if PFOS_PERFORMANCE_BASELINE
        let analysisStart = ContinuousClock.now
        let rows = try ModelContext(context.container).fetch(FetchDescriptor<FinanceTransaction>())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let snapshot = FinanceInsightsService.snapshot(for: rows, selectedMonth: date, categories: categories, calendar: calendar)
        report(count, "legacy_month_fetch_and_summary", analysisStart)
        XCTAssertEqual(snapshot.activity.totalCount, count)
        let search = LedgerSearchActor(modelContainer: context.container)
        let request = LedgerSearchRequest(query: "公司午餐", typeRawValue: nil, categoryFilterIDs: [],
            accountID: nil, tagID: nil, queryCategoryIDs: [], queryAccountIDs: [], queryTagIDs: [],
            matchesUncategorized: false, sortOrder: .timeNewest)
        let firstStart = ContinuousClock.now
        let first = try await search.page(request: request)
        report(count, "legacy_search_first_page", firstStart)
        let pageStart = ContinuousClock.now
        let second = try await search.page(request: request, cursor: try XCTUnwrap(first.nextCursor))
        report(count, "legacy_search_second_page", pageStart)
        XCTAssertEqual(first.transactionIDs.count + second.transactionIDs.count, min(count, 200))
        #else
        let analysis = LedgerAnalysisActor(modelContainer: context.container)
        let analysisStart = ContinuousClock.now
        let snapshot = try await analysis.snapshot(filter: LedgerFilter(dateRange: nil))
        report(count, "analysis_full_totals_and_first_page", analysisStart)
        XCTAssertEqual(snapshot.totals.totalCount, count)
        XCTAssertEqual(snapshot.totals.grossExpenseMinorUnits, Int64(count) * 100)
        XCTAssertEqual(snapshot.firstPage.count, min(count, 100))
        let pageStart = ContinuousClock.now
        let second = try await analysis.page(snapshot: snapshot, offset: 100)
        report(count, "analysis_second_page", pageStart)
        XCTAssertEqual(snapshot.firstPage.count + second.count, min(count, 200))
        let sync = ICloudSyncController()
        await sync.disable()
        let catalogStart = ContinuousClock.now
        let preview = try await CategoryCatalogService.preview(in: context, sync: sync)
        _ = try CategoryCatalogService.commit(preview, selected: Set(preview.plan.entries.filter(\.selectedByDefault).map(\.id)),
            in: context, sync: sync, changes: LedgerChangeCenter())
        report(count, "catalog_preview_and_commit", catalogStart)
        XCTAssertEqual(try ModelContext(context.container).fetchCount(FetchDescriptor<FinanceTransaction>()), count)
        XCTAssertEqual(try ModelContext(context.container).fetchCount(FetchDescriptor<PersonalFinanceOS.Category>()), 267)
        #endif
        let fresh = ModelContext(context.container)
        let currentCategories = try fresh.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let currentAccounts = try fresh.fetch(FetchDescriptor<Account>())
        var draft = TransactionDraft()
        draft.amountText = "1.00"
        draft.accountID = account.id
        draft.categoryID = category.id
        draft.note = "合成离线录入"
        let captureStart = ContinuousClock.now
        let saved = try TransactionLifecycleService.save(draft: draft, accounts: currentAccounts, categories: currentCategories, in: fresh)
        report(count, "ordinary_offline_capture", captureStart)
        XCTAssertEqual(saved.amountMinorUnits, 100)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<FinanceTransaction>()), count + 1)
    }

    private func report(_ count: Int, _ stage: String, _ start: ContinuousClock.Instant) {
        let duration = start.duration(to: .now).components
        let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        var usage = rusage()
        let status = getrusage(RUSAGE_SELF, &usage)
        #if PFOS_PERFORMANCE_BASELINE
        let variant = "e30"
        #else
        let variant = "candidate"
        #endif
        // Darwin reports bytes. This is cumulative process high-water RSS,
        // including fixture/setup and earlier stages, not stage-exclusive memory.
        print("REMEDIATION_PERF variant=\(variant) count=\(count) stage=\(stage) ms=\(milliseconds) process_peak_rss_bytes=\(status == 0 ? usage.ru_maxrss : -1)")
    }
}
