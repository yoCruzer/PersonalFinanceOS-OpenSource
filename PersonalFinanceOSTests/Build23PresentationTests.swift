import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class Build23PresentationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testRangeRoundTripInclusiveSameDayCrossMonthCancellationInputsAndAnchors() throws {
        let now = date("2026-10-07T12:30:00Z")
        let start = date("2026-09-30T22:00:00Z"), end = date("2026-10-02T01:00:00Z")
        let range = try XCTUnwrap(LedgerRangeSelection.inclusiveRange(start: start, end: end, calendar: calendar))
        XCTAssertEqual(range, LocalDayRange(lowerBound: "2026-09-30", upperBound: "2026-10-03"))
        let filter = LedgerFilter(dateRange: range)
        let editor = LedgerRangeSelection.editorDates(filter, asOf: now, calendar: calendar)
        XCTAssertEqual(editor.start, calendar.startOfDay(for: start))
        XCTAssertEqual(editor.end, calendar.startOfDay(for: end))
        XCTAssertEqual(LedgerRangeSelection.inclusiveRange(start: editor.start, end: editor.end, calendar: calendar), range)
        XCTAssertEqual(LedgerRangeSelection.inclusiveRange(start: start, end: start, calendar: calendar)?.upperBound, "2026-10-01")
        XCTAssertNil(LedgerRangeSelection.inclusiveRange(start: end, end: start, calendar: calendar))
        XCTAssertEqual(filter.dateRange, range, "Opening/editing local draft dates must not mutate the source filter")
        XCTAssertEqual(LedgerRangeSelection.trendAnchor(filter, asOf: now, calendar: calendar), editor.end)
        XCTAssertEqual(LedgerRangeSelection.trendAnchor(LedgerFilter(), asOf: now, calendar: calendar), now)
        let year = LedgerFilter(dateRange: LocalDayRange(lowerBound: "2026-01-01", upperBound: "2027-01-01"))
        XCTAssertEqual(LedgerRangeSelection.trendAnchor(year, asOf: now, calendar: calendar), now)
        let month = LedgerFilter.month(now, calendar: calendar)
        XCTAssertEqual(LedgerRangeSelection.wholeMonth(month, calendar: calendar), date("2026-10-01T00:00:00Z"))
        XCTAssertEqual(LedgerRangeSelection.trendAnchor(month, asOf: now, calendar: calendar), date("2026-10-01T00:00:00Z"))
    }

    func testSignedAmountsStoredTimeZoneAndHiddenSearchReasons() {
        let locale = Locale(identifier: "en_US")
        XCTAssertTrue(SignedAmountFormatting.text(-20_00, locale: locale).contains("-"))
        XCTAssertTrue(SignedAmountFormatting.text(Int64.min, locale: locale).contains("92,233,720,368,547,758.08"))
        let value = FinanceTransaction(type: .expense, amountMinorUnits: 100, occurredAt: date("2026-10-07T01:23:00Z"),
            localDayKey: "2026-10-07", timeZoneIdentifier: "Asia/Shanghai", rawMerchantText: "铁路商店")
        let tag = Tag(name: "差旅", colorToken: "blue"); value.tags = [tag]
        let metadata = LedgerFilterMetadata(categories: [:], accounts: [:], tags: [tag.id: tag.name])
        XCTAssertEqual(LedgerRowPresentation.time(LedgerFilteredRow(value), locale: Locale(identifier: "zh_CN")), "9:23")
        XCTAssertEqual(LedgerRowPresentation.searchExplanation(query: "铁路", row: LedgerFilteredRow(value), metadata: metadata), "商户：铁路商店")
        XCTAssertEqual(LedgerRowPresentation.searchExplanation(query: "差旅", row: LedgerFilteredRow(value), metadata: metadata), "标签：差旅")
        value.note = "差旅发票"
        XCTAssertNil(LedgerRowPresentation.searchExplanation(query: "差旅", row: LedgerFilteredRow(value), metadata: metadata))
        value.timeZoneIdentifier = "invalid-zone"
        XCTAssertEqual(LedgerRowPresentation.time(LedgerFilteredRow(value), locale: locale), "时间待核实")
    }

    func testAccountCountsIncludeDestinationIgnoreDeletedAndRefreshAfterMoveAndDelete() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        _ = LedgerSaveRevision.shared.contentRevision
        let first = UUID(), second = UUID(), third = UUID()
        let expense = FinanceTransaction(type: .expense, amountMinorUnits: 100, occurredAt: Date(), localDayKey: "2026-10-07", timeZoneIdentifier: "GMT", accountID: first)
        let transfer = FinanceTransaction(type: .transfer, amountMinorUnits: 200, occurredAt: Date(), localDayKey: "2026-10-07", timeZoneIdentifier: "GMT", accountID: first, destinationAccountID: second)
        let deleted = FinanceTransaction(type: .income, amountMinorUnits: 300, occurredAt: Date(), localDayKey: "2026-10-07", timeZoneIdentifier: "GMT", accountID: second, deletedAt: Date())
        [expense, transfer, deleted].forEach { context.insert($0) }; try context.save()
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let initial = try await actor.accountTransactionCounts(ids: [first, second, third])
        XCTAssertEqual(initial.values, [first: 2, second: 1, third: 0])
        expense.accountID = third; transfer.deletedAt = Date(); try context.save()
        let changed = try await actor.accountTransactionCounts(ids: [first, second, third])
        XCTAssertGreaterThan(changed.revision, initial.revision)
        XCTAssertEqual(changed.values, [first: 0, second: 0, third: 1])
        let task = Task { try await actor.accountTransactionCounts(ids: [first]) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled count cannot be represented as zero") } catch is CancellationError { }
    }
}
