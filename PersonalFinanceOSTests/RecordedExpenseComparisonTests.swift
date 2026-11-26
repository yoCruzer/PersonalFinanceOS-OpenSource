import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class RecordedExpenseComparisonTests: XCTestCase {
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func context() throws -> ModelContext { _ = LedgerSaveRevision.shared.contentRevision; return ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true)) }
    @discardableResult
    private func row(_ amount: Int64, _ timestamp: String, type: TransactionType = .expense, category: UUID? = nil, account: UUID? = nil, tags: [Tag] = [], in context: ModelContext) -> FinanceTransaction {
        let value = FinanceTransaction(type: type, amountMinorUnits: amount, occurredAt: date(timestamp), localDayKey: String(timestamp.prefix(10)), timeZoneIdentifier: "GMT", accountID: account, categoryID: category)
        value.tags = tags; context.insert(value); return value
    }
    private func category(_ name: String, new: Bool = false, in context: ModelContext) -> PersonalFinanceOS.Category {
        let value = PersonalFinanceOS.Category(kind: .expense, name: name, symbolName: "star", colorToken: "blue",
            createdAt: new ? date("2026-10-01T00:00:00Z") : date("2025-01-01T00:00:00Z"),
            updatedAt: new ? date("2026-10-01T00:00:00Z") : date("2025-01-01T00:00:00Z"))
        context.insert(value); return value
    }

    func testPeriodsShareCutoffClipUnequalMonthsAndSeparateHistoricalWholeMonths() throws {
        let now = date("2026-03-31T12:00:00Z")
        let clipped = try XCTUnwrap(RecordedExpenseComparison.periods(filter: .month(now, calendar: calendar), asOf: now, calendar: calendar))
        XCTAssertEqual(clipped.commonDay, 28)
        XCTAssertEqual(clipped.current.dateRange?.upperBound, "2026-03-29")
        XCTAssertEqual(clipped.previous.dateRange?.upperBound, "2026-03-01")
        let partial = date("2026-10-07T12:34:56Z")
        let matching = try XCTUnwrap(RecordedExpenseComparison.periods(filter: .month(partial, calendar: calendar), asOf: partial, calendar: calendar))
        XCTAssertEqual(matching.previous.occurredThrough, date("2026-09-07T12:34:56Z"))
        XCTAssertEqual(matching.current.occurredThrough, partial)
        let historical = try XCTUnwrap(RecordedExpenseComparison.periods(filter: .month(date("2026-09-01T00:00:00Z"), calendar: calendar), asOf: partial, calendar: calendar))
        XCTAssertTrue(historical.isWholeMonth)
        XCTAssertNil(historical.commonDay)
        XCTAssertEqual(historical.current.dateRange?.upperBound, "2026-10-01")
        XCTAssertEqual(historical.previous.dateRange?.upperBound, "2026-09-01")
        XCTAssertNil(RecordedExpenseComparison.periods(filter: LedgerFilter(), asOf: partial, calendar: calendar))
        XCTAssertNil(RecordedExpenseComparison.periods(filter: .day(partial, calendar: calendar), asOf: partial, calendar: calendar))
        XCTAssertNil(RecordedExpenseComparison.periods(filter: .month(date("2026-11-01T00:00:00Z"), calendar: calendar), asOf: partial, calendar: calendar))
    }

    func testTwoCompletePeriodsPreserveScopeRefundsFutureCutoffAndPaginationEvidence() async throws {
        let context = try context(), account = UUID(), other = UUID()
        let tag = Tag(name: "限定", colorToken: "blue"); context.insert(tag)
        let stable = category("稳定小类", in: context)
        for _ in 0..<301 {
            row(100, "2026-09-02T10:00:00Z", category: stable.id, account: account, tags: [tag], in: context)
            row(200, "2026-10-02T10:00:00Z", category: stable.id, account: account, tags: [tag], in: context)
        }
        row(50_000, "2026-10-02T10:00:00Z", type: .refund, category: stable.id, account: account, tags: [tag], in: context)
        row(999_999, "2026-10-07T13:00:00Z", category: stable.id, account: account, tags: [tag], in: context)
        row(999_999, "2026-10-08T01:00:00Z", category: stable.id, account: account, tags: [tag], in: context)
        row(999_999, "2026-09-07T13:00:00Z", category: stable.id, account: account, tags: [tag], in: context)
        row(999_999, "2026-10-02T10:00:00Z", account: other, tags: [tag], in: context)
        row(999_999, "2026-10-02T10:00:00Z", account: account, in: context)
        try context.save()
        let asOf = date("2026-10-07T12:00:00Z")
        var filter = LedgerFilter.month(asOf, calendar: calendar)
        filter.accountID = account; filter.tagIDs = [tag.id]; filter.category = .direct(stable.id)
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let value = try await actor.recordedExpenseComparison(filter: filter, asOf: asOf, calendar: calendar)
        let comparison = try XCTUnwrap(value)
        XCTAssertEqual(comparison.facts.count, 1)
        let fact = try XCTUnwrap(comparison.facts.first)
        XCTAssertEqual(fact.current.grossExpenseMinorUnits, 60_200)
        XCTAssertEqual(fact.current.refundMinorUnits, 50_000)
        XCTAssertEqual(fact.previous.netExpenseMinorUnits, 30_100)
        XCTAssertEqual(fact.delta, -19_900, "Refund-caused drop must retain gross and refund evidence")
        XCTAssertEqual(fact.currentFilter.accountID, account)
        XCTAssertEqual(fact.previousFilter.tagIDs, [tag.id])
        XCTAssertEqual(fact.previousFilter.category, .direct(stable.id))
        let snapshot = try await actor.snapshot(filter: fact.currentFilter)
        XCTAssertEqual(snapshot.transactionIDs.count, 302)
        XCTAssertEqual(snapshot.firstPage.count, 100)
        let next = try await actor.page(snapshot: snapshot, offset: 100)
        XCTAssertEqual(next.count, 100)
        let csv = try await actor.exportData(snapshot: snapshot)
        XCTAssertEqual(csv.split(separator: 10).count, 303)
        for evidence in [fact.currentFilter, fact.previousFilter] {
            var sorted = evidence; sorted.sortOrder = .timeOldest
            let full = try await actor.snapshot(filter: sorted)
            let expectedCount = evidence == fact.currentFilter ? 302 : 301
            XCTAssertEqual(full.transactionIDs.count, expectedCount)
            XCTAssertEqual(full.filter.occurredThrough, evidence.occurredThrough)
            XCTAssertEqual(full.revision, comparison.revision)
            var pagedIDs = full.firstPage.map(\.id)
            while pagedIDs.count < full.transactionIDs.count {
                let page = try await actor.page(snapshot: full, offset: pagedIDs.count)
                pagedIDs += page.map(\.id)
            }
            XCTAssertEqual(pagedIDs, full.transactionIDs)
            let export = try await actor.exportData(snapshot: full)
            XCTAssertEqual(export.split(separator: 10).count, expectedCount + 1)
        }
        row(1, "2026-10-03T10:00:00Z", in: context); try context.save()
        do { _ = try await actor.page(snapshot: snapshot, offset: 200); XCTFail("Old evidence revoked") } catch LedgerAnalysisError.staleSnapshot { }
        let store = LedgerAnalysisStore()
        await store.reload(filter: fact.currentFilter, actor: actor, requiresExactRevision: true)
        XCTAssertNil(store.snapshot)
        XCTAssertTrue(store.rows.isEmpty)
    }

    func testLargestAbsoluteIncreaseOnlyAmongProvenCategoriesAndNoPercentageClaims() async throws {
        let context = try context()
        let stable = category("稳定小类", in: context), fresh = category("新分类", new: true, in: context)
        let mixed = category("旅行交通", in: context), edited = category("改名类", in: context)
        mixed.defaultDefinitionKey = "expense.travel.transport"
        edited.updatedAt = date("2026-10-01T00:00:00Z")
        for (category, now) in [(stable, Int64(5_000)), (fresh, 50_000), (mixed, 60_000), (edited, 70_000)] {
            row(2_000, "2026-09-02T10:00:00Z", category: category.id, in: context)
            row(now, "2026-10-02T10:00:00Z", category: category.id, in: context)
        }
        try context.save()
        let asOf = date("2026-10-07T12:00:00Z")
        let value = try await LedgerAnalysisActor(modelContainer: context.container).recordedExpenseComparison(filter: .month(asOf, calendar: calendar), asOf: asOf, calendar: calendar)
        let comparison = try XCTUnwrap(value)
        XCTAssertEqual(comparison.facts.count, 2)
        XCTAssertEqual(comparison.facts.last?.categoryID, stable.id)
        XCTAssertEqual(comparison.facts.last?.delta, 3_000)
        XCTAssertEqual(comparison.facts.last?.currentFilter.category, .direct(stable.id))
        XCTAssertEqual(comparison.facts.last?.previousFilter.revision, comparison.revision)
    }

    func testMissingHistoryNoiseAndUncomparableCategoriesAreSuppressed() async throws {
        let context = try context()
        row(50_000, "2026-10-02T10:00:00Z", in: context); try context.save()
        let asOf = date("2026-10-07T12:00:00Z"), actor = LedgerAnalysisActor(modelContainer: context.container)
        let filter = LedgerFilter.month(asOf, calendar: calendar)
        let value = try await actor.recordedExpenseComparison(filter: filter, asOf: asOf, calendar: calendar)
        XCTAssertTrue(try XCTUnwrap(value).facts.isEmpty)
        row(50_001, "2026-09-02T10:00:00Z", in: context); try context.save()
        let unchanged = try await actor.recordedExpenseComparison(filter: filter, asOf: asOf, calendar: calendar)
        XCTAssertTrue(try XCTUnwrap(unchanged).facts.isEmpty)
    }

    func testNegativeAndTinyBasesUseAbsoluteAmountsAndCategoryIncreaseCanExceedTotal() async throws {
        let context = try context()
        let stable = category("稳定小类", in: context), other = category("另一小类", in: context)
        row(1, "2026-09-02T10:00:00Z", category: stable.id, in: context)
        row(2_001, "2026-10-02T10:00:00Z", category: stable.id, in: context)
        row(5_000, "2026-09-02T10:00:00Z", category: other.id, in: context)
        row(4_000, "2026-10-02T10:00:00Z", category: other.id, in: context)
        row(10_000, "2026-09-02T10:00:00Z", type: .refund, category: other.id, in: context)
        row(10_000, "2026-10-02T10:00:00Z", type: .refund, category: other.id, in: context)
        try context.save()
        let asOf = date("2026-10-07T12:00:00Z")
        let value = try await LedgerAnalysisActor(modelContainer: context.container).recordedExpenseComparison(filter: .month(asOf, calendar: calendar), asOf: asOf, calendar: calendar)
        let comparison = try XCTUnwrap(value)
        XCTAssertEqual(comparison.facts.count, 2)
        XCTAssertEqual(comparison.facts[0].previous.netExpenseMinorUnits, -4_999)
        XCTAssertEqual(comparison.facts[0].delta, 1_000)
        XCTAssertEqual(comparison.facts[1].delta, 2_000)
        XCTAssertGreaterThan(comparison.facts[1].delta, comparison.facts[0].delta)
    }

    func testInterveningRevisionCannotSplicePeriodsAndCancelledQueryCannotPublish() async throws {
        let context = try context()
        row(2_000, "2026-09-02T10:00:00Z", in: context); row(4_000, "2026-10-02T10:00:00Z", in: context); try context.save()
        let asOf = date("2026-10-07T12:00:00Z"), actor = LedgerAnalysisActor(modelContainer: context.container)
        let filter = LedgerFilter.month(asOf, calendar: calendar)
        do {
            _ = try await actor.recordedExpenseComparison(filter: filter, asOf: asOf, calendar: calendar, betweenPeriods: {
                NotificationCenter.default.post(name: ModelContext.didSave, object: nil)
            }); XCTFail("Mixed revision must fail")
        } catch LedgerAnalysisError.staleSnapshot { }
        let task = Task { try await actor.recordedExpenseComparison(filter: filter, asOf: asOf, calendar: calendar) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must fail") } catch is CancellationError { }
    }
}
