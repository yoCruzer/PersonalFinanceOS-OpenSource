import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class ImportBatchHistoryServiceTests: XCTestCase {
    func testSummaryHandlesLegacyTotalsAndCountsEditedDeletedAndActiveRows() throws {
        let fixture = try makeFixture()
        fixture.edited.updatedAt = fixture.completedAt.addingTimeInterval(10)
        fixture.edited.categoryDecisionSource = .manualConfirmed
        fixture.manuallyDeleted.deletedAt = fixture.completedAt.addingTimeInterval(20)
        let refund = transaction(
            type: .refund,
            amount: 50,
            batchID: fixture.batch.id,
            updatedAt: fixture.completedAt
        )

        let summary = ImportBatchHistoryService.summary(
            batch: fixture.batch,
            transactions: fixture.allTransactions + [refund]
        )
        XCTAssertEqual(summary.currentActiveCount, 3)
        XCTAssertEqual(summary.editedCount, 1)
        XCTAssertEqual(summary.manuallyDeletedCount, 1)
        XCTAssertEqual(summary.incomeMinorUnits, 200)
        XCTAssertEqual(summary.expenseMinorUnits, 350)
        XCTAssertNil(fixture.batch.duplicateRowCount)
    }

    func testRollbackOnlyDeletesExactBatchAndPreservesEditedByDefault() throws {
        let fixture = try makeFixture()
        fixture.edited.updatedAt = fixture.completedAt.addingTimeInterval(10)
        fixture.edited.categoryDecisionSource = .manualConfirmed
        fixture.manuallyDeleted.deletedAt = fixture.completedAt.addingTimeInterval(20)
        let result = try ImportBatchHistoryService.rollback(
            batch: fixture.batch,
            transactions: fixture.allTransactions,
            includeUncertain: true,
            reviewedRevision: LedgerSaveRevision.shared.contentRevision,
            in: fixture.context,
            now: fixture.completedAt.addingTimeInterval(30)
        )

        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertEqual(result.preservedEditedCount, 1)
        XCTAssertNotNil(fixture.normal.deletedAt)
        XCTAssertNil(fixture.edited.deletedAt)
        XCTAssertNil(fixture.otherBatch.deletedAt)
        XCTAssertNil(fixture.manual.deletedAt)
        XCTAssertEqual(fixture.batch.status, .rolledBack)

        let repeated = try ImportBatchHistoryService.rollback(
            batch: fixture.batch,
            transactions: fixture.allTransactions,
            in: fixture.context
        )
        XCTAssertTrue(repeated.alreadyRolledBack)
    }

    func testRollbackRestoresEverythingWhenSaveFails() throws {
        let fixture = try makeFixture()
        enum Failure: Error { case save }
        XCTAssertThrowsError(try ImportBatchHistoryService.rollback(
            batch: fixture.batch,
            transactions: fixture.allTransactions,
            preserveEdited: false,
            includeUncertain: true,
            reviewedRevision: LedgerSaveRevision.shared.contentRevision,
            in: fixture.context,
            save: { throw Failure.save }
        ))
        XCTAssertEqual(fixture.batch.status, .completed)
        XCTAssertNil(fixture.batch.rolledBackAt)
        XCTAssertNil(fixture.normal.deletedAt)
        XCTAssertNil(fixture.edited.deletedAt)
    }

    func testRollbackRefetchesExactBatchTransactionsInsteadOfTrustingCallerSnapshot() throws {
        let fixture = try makeFixture()
        fixture.manuallyDeleted.deletedAt = fixture.completedAt.addingTimeInterval(20)

        let result = try ImportBatchHistoryService.rollback(
            batch: fixture.batch,
            transactions: [],
            preserveEdited: false,
            includeUncertain: true,
            reviewedRevision: LedgerSaveRevision.shared.contentRevision,
            in: fixture.context,
            now: fixture.completedAt.addingTimeInterval(30)
        )

        XCTAssertEqual(result.deletedCount, 2)
        XCTAssertNotNil(fixture.normal.deletedAt)
        XCTAssertNotNil(fixture.edited.deletedAt)
        XCTAssertNil(fixture.otherBatch.deletedAt)
        XCTAssertNil(fixture.manual.deletedAt)
    }

    private func makeFixture() throws -> BatchFixture {
        let config = ModelConfiguration(
            isStoredInMemoryOnly: true,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppSchema.schema, configurations: [config])
        let context = container.mainContext
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let batch = ImportBatch(
            sourceType: .wacai,
            sourceDisplayName: "账单.csv",
            completedAt: completedAt,
            status: .completed,
            importedRowCount: 3
        )
        let other = ImportBatch(
            sourceType: .wechat,
            sourceDisplayName: "微信.xlsx",
            completedAt: completedAt,
            status: .completed
        )
        let normal = transaction(type: .expense, amount: 100, batchID: batch.id, updatedAt: completedAt)
        let edited = transaction(type: .income, amount: 200, batchID: batch.id, updatedAt: completedAt)
        let manuallyDeleted = transaction(type: .expense, amount: 300, batchID: batch.id, updatedAt: completedAt)
        let otherBatch = transaction(type: .expense, amount: 400, batchID: other.id, updatedAt: completedAt)
        let manual = transaction(type: .expense, amount: 500, batchID: nil, updatedAt: completedAt)
        context.insert(batch)
        context.insert(other)
        [normal, edited, manuallyDeleted, otherBatch, manual].forEach(context.insert)
        try context.save()
        return BatchFixture(
            container: container,
            context: context,
            batch: batch,
            completedAt: completedAt,
            normal: normal,
            edited: edited,
            manuallyDeleted: manuallyDeleted,
            otherBatch: otherBatch,
            manual: manual
        )
    }

    private func transaction(
        type: TransactionType,
        amount: Int64,
        batchID: UUID?,
        updatedAt: Date
    ) -> FinanceTransaction {
        FinanceTransaction(
            type: type,
            amountMinorUnits: amount,
            occurredAt: updatedAt,
            localDayKey: "2023-11-15",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: UUID(),
            categoryID: type == .transfer ? nil : UUID(),
            importBatchID: batchID,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }
}

private struct BatchFixture {
    let container: ModelContainer
    let context: ModelContext
    let batch: ImportBatch
    let completedAt: Date
    let normal: FinanceTransaction
    let edited: FinanceTransaction
    let manuallyDeleted: FinanceTransaction
    let otherBatch: FinanceTransaction
    let manual: FinanceTransaction

    var allTransactions: [FinanceTransaction] {
        [normal, edited, manuallyDeleted, otherBatch, manual]
    }
}
