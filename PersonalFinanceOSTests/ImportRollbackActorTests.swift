import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class ImportRollbackActorTests: XCTestCase {
    func testTwelveThousandTransactionRollbackRunsInActorAndPreservesEdited() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let completedAt = startedAt.addingTimeInterval(60)
        let rollbackAt = completedAt.addingTimeInterval(3_600)
        let batch = ImportBatch(
            sourceType: .wacai,
            sourceDisplayName: "12K",
            startedAt: startedAt,
            completedAt: completedAt,
            status: .completed,
            totalRowCount: 12_000,
            importedRowCount: 12_000,
            createdAt: startedAt,
            updatedAt: completedAt
        )
        context.insert(batch)
        var editedActiveCount = 0
        var predeletedCount = 0
        for index in 0..<12_000 {
            let isPredeleted = index.isMultiple(of: 500)
            let isEdited = index.isMultiple(of: 997)
            if isPredeleted { predeletedCount += 1 }
            if isEdited, !isPredeleted { editedActiveCount += 1 }
            context.insert(FinanceTransaction(
                type: .expense,
                amountMinorUnits: Int64(index + 1),
                occurredAt: startedAt.addingTimeInterval(TimeInterval(index)),
                localDayKey: "2023-11-14",
                timeZoneIdentifier: "UTC",
                categoryDecisionSource: isEdited ? .manualConfirmed : .unchanged,
                importBatchID: batch.id,
                createdAt: startedAt,
                updatedAt: isEdited ? completedAt.addingTimeInterval(1) : completedAt,
                deletedAt: isPredeleted ? completedAt.addingTimeInterval(2) : nil
            ))
        }
        try context.save()

        let worker = ImportRollbackActor(modelContainer: container)
        let before = try await worker.summary(batchID: batch.id)
        XCTAssertEqual(before.currentActiveCount, 12_000 - predeletedCount)
        XCTAssertEqual(before.editedCount, editedActiveCount)
        XCTAssertEqual(before.manuallyDeletedCount, predeletedCount)

        let result = try await worker.rollback(
            batchID: batch.id,
            preserveEdited: true,
            includeUncertain: true,
            reviewedRevision: before.reviewRevision,
            now: rollbackAt
        )
        XCTAssertEqual(result.preservedEditedCount, editedActiveCount)
        XCTAssertEqual(result.deletedCount, 12_000 - predeletedCount - editedActiveCount)
        XCTAssertFalse(result.alreadyRolledBack)

        let verificationContext = ModelContext(container)
        let transactions = try verificationContext.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(transactions.filter { $0.deletedAt == nil }.count, editedActiveCount)
        let restoredBatch = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<ImportBatch>()).first
        )
        XCTAssertEqual(restoredBatch.status, .rolledBack)
        XCTAssertEqual(restoredBatch.rolledBackAt, rollbackAt)

        let repeated = try await worker.rollback(batchID: batch.id, now: rollbackAt)
        XCTAssertTrue(repeated.alreadyRolledBack)
        XCTAssertEqual(repeated.deletedCount, 0)
    }
}
