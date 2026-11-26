import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class LedgerChangeCenterTests: XCTestCase {
    func testSuccessfulMutationsAdvanceRevisionMonotonically() {
        let center = LedgerChangeCenter()

        XCTAssertEqual(center.revision, 0)
        center.recordMutation(contentRevision: 10)
        XCTAssertEqual(center.revision, 1)
        center.recordMutation(contentRevision: 10)
        center.recordMutation(contentRevision: 9)
        XCTAssertEqual(center.revision, 1)
        center.recordMutation(contentRevision: 11)
        XCTAssertEqual(center.revision, 2)
    }

    func testModelActorMutationIsVisibleToBoundedRefetchInExistingMainContext() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let mainContext = ModelContext(container)
        let account = Account(name: "Main", type: .cash, isDefault: true)
        let category = Category(
            kind: .expense,
            name: "Dining",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let occurredAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-18T10:21:00+08:00")
        )
        let transaction = FinanceTransaction(
            type: .expense,
            amountMinorUnits: 1_021,
            occurredAt: occurredAt,
            localDayKey: "2026-08-18",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: account.id,
            categoryID: category.id
        )
        mainContext.insert(account)
        mainContext.insert(category)
        mainContext.insert(transaction)
        try mainContext.save()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        let initial = try LedgerQueryService.fetchMonth(
            occurredAt,
            in: mainContext,
            calendar: calendar
        )
        XCTAssertEqual(initial.map(\.id), [transaction.id])

        let actor = LedgerBatchOperationActor(modelContainer: container)
        let result = try await actor.softDelete(selectedIDs: [transaction.id])
        XCTAssertEqual(result.count, 1)
        let center = LedgerChangeCenter()
        center.recordMutation()

        let reloaded = try LedgerQueryService.fetchMonth(
            occurredAt,
            in: mainContext,
            calendar: calendar
        )
        XCTAssertEqual(center.revision, 1)
        XCTAssertTrue(reloaded.isEmpty)
    }
}
