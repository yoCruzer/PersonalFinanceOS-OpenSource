import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class ImportOccurrencePlanningTests: XCTestCase {
    func testEmptyLedgerImportsBothOccurrences() async throws {
        let context = try fixture()
        let plan = try await preview(context)
        try await commit(plan, in: context, expectedImported: 2, expectedDuplicates: 0)
        try verify(context, count: 2, amount: 2468)
    }

    func testOccurrenceZeroBeforePreviewOnlyImportsMissingOneAndReprepareAgrees() async throws {
        let context = try fixture()
        try await commit(preview(context, count: 1), in: context, expectedImported: 1, expectedDuplicates: 0)
        let first = try await preview(context)
        let preparedAgain = try await preview(context)
        XCTAssertEqual(first.candidates.filter(\.isDuplicate).map(\.rowNumber), preparedAgain.candidates.filter(\.isDuplicate).map(\.rowNumber))
        try await commit(preparedAgain, in: context, expectedImported: 1, expectedDuplicates: 1)
        try verify(context, count: 2, amount: 2468)
    }

    func testBothOccurrencesBeforePreviewAreSkippedByDefault() async throws {
        let context = try fixture()
        try await commit(preview(context), in: context, expectedImported: 2, expectedDuplicates: 0)
        let plan = try await preview(context)
        XCTAssertEqual(plan.duplicateCount, 2)
        XCTAssertTrue(plan.effectiveRowsToImport(includeSuspectedDuplicates: true).isEmpty)
        XCTAssertThrowsError(try request(plan, in: context))
        try verify(context, count: 2, amount: 2468)
    }

    func testOccurrenceOneBeforePreviewOnlyImportsMissingZero() async throws {
        let context = try fixture()
        try await commit(preview(context), in: context, expectedImported: 2, expectedDuplicates: 0)
        let rows = try context.fetch(FetchDescriptor<FinanceTransaction>())
        let origins = try context.fetch(FetchDescriptor<ImportEntityOrigin>())
        let occurrenceIDs = Set(origins.filter { $0.semanticKey.hasPrefix("occurrence-v1:") }.map(\.entityKey))
        let zero = try XCTUnwrap(rows.first { !occurrenceIDs.contains("transactions:\($0.id.uuidString)") })
        context.delete(zero) // Synthetic projection: only occurrence 1 has arrived.
        try context.save()
        try await commit(preview(context), in: context, expectedImported: 1, expectedDuplicates: 1)
        try verify(context, count: 2, amount: 2468)
    }

    func testExplicitInstanceDoesNotConsumeOrdinaryOccurrences() async throws {
        let context = try fixture()
        try await commit(preview(context, count: 1), in: context, expectedImported: 1, expectedDuplicates: 0)
        let base = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first)
        let duplicatePlan = try await preview(context, count: 1)
        let explicit = try request(duplicatePlan, in: context, includeConfirmed: true)
        XCTAssertNotNil(explicit.transactions.first?.explicitDuplicateInstance)
        _ = try await ImportCommitActor(modelContainer: context.container).commit(explicit)
        context.delete(base) // Synthetic projection containing an explicit instance alone.
        try context.save()
        try await commit(preview(context), in: context, expectedImported: 2, expectedDuplicates: 0)
        try verify(context, count: 3, amount: 3702)
    }

    func testSoftDeletedBaseStillConsumesZeroWithoutRevivingIt() async throws {
        let context = try fixture()
        try await commit(preview(context, count: 1), in: context, expectedImported: 1, expectedDuplicates: 0)
        try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first).deletedAt = Date()
        try context.save()
        try await commit(preview(context), in: context, expectedImported: 1, expectedDuplicates: 1)
        let package = try verify(context, count: 2, amount: 2468)
        XCTAssertEqual(package.transactions.filter { $0.deletedAt != nil }.count, 1)
    }

    func testExplicitToggleRetainsOneExplicitAndFillsOneOrdinaryOccurrence() async throws {
        let context = try fixture()
        try await commit(preview(context, count: 1), in: context, expectedImported: 1, expectedDuplicates: 0)
        let plan = try await preview(context)
        XCTAssertEqual(plan.duplicateCount, 1)
        let request = try request(plan, in: context, includeConfirmed: true)
        XCTAssertEqual(request.transactions.filter { $0.explicitDuplicateInstance != nil }.count, 1)
        XCTAssertEqual(request.transactions.filter { $0.importSemanticOrigin?.hasPrefix("occurrence-v1:") == true }.count, 1)
        let result = try await ImportCommitActor(modelContainer: context.container).commit(request)
        XCTAssertEqual(result.importedCount, 2)
        XCTAssertEqual(result.duplicateCount, 0)
        XCTAssertEqual(result.expenseMinorUnits, 2468)
        let package = try verify(context, count: 3, amount: 3702)
        XCTAssertEqual(package.importBatches.first { $0.id == request.batchID }?.importedRowCount, 2)
        let preparedAgain = try await preview(context)
        XCTAssertEqual(preparedAgain.duplicateCount, 2)
    }

    func testUnknownLegacyTwinsStayIntactAndDoNotInventAnOccurrenceOrdinal() async throws {
        let context = try fixture()
        try await commit(preview(context, count: 1), in: context, expectedImported: 1, expectedDuplicates: 0)
        let base = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first)
        let legacyTwin = FinanceTransaction(type: base.type, amountMinorUnits: base.amountMinorUnits,
            occurredAt: base.occurredAt, localDayKey: base.localDayKey, timeZoneIdentifier: base.timeZoneIdentifier,
            accountID: base.accountID, categoryID: base.categoryID, note: base.note,
            importBatchID: base.importBatchID, externalSource: base.externalSource,
            externalTransactionID: base.externalTransactionID, importFingerprint: base.importFingerprint)
        context.insert(legacyTwin)
        try context.save()
        let legacyIDs = Set([base.id, legacyTwin.id])
        let plan = try await preview(context)
        XCTAssertEqual(plan.duplicateCount, 1)
        XCTAssertEqual(plan.candidates.filter { !$0.isDuplicate && $0.isSuspectedDuplicate }.count, 1)
        try await commit(plan, in: context, expectedImported: 1, expectedDuplicates: 1)
        let package = try verify(context, count: 3, amount: 3702)
        XCTAssertTrue(legacyIDs.isSubset(of: Set(package.transactions.map(\.id))))
        XCTAssertTrue(package.transactions.allSatisfy { $0.deletedAt == nil })
    }

    func testSoftDeletedOccurrenceOneRemainsConsumed() async throws {
        let context = try fixture()
        try await commit(preview(context), in: context, expectedImported: 2, expectedDuplicates: 0)
        let origin = try XCTUnwrap(context.fetch(FetchDescriptor<ImportEntityOrigin>()).first { $0.semanticKey.hasPrefix("occurrence-v1:") })
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first { origin.entityKey == "transactions:\($0.id.uuidString)" })
        row.deletedAt = Date()
        try context.save()
        let plan = try await preview(context)
        XCTAssertEqual(plan.duplicateCount, 2)
        XCTAssertTrue(plan.effectiveRowsToImport(includeSuspectedDuplicates: true).isEmpty)
        XCTAssertThrowsError(try request(plan, in: context))
        let package = try verify(context, count: 2, amount: 2468)
        XCTAssertEqual(package.transactions.filter { $0.deletedAt != nil }.count, 1)
    }

    @discardableResult
    private func verify(_ context: ModelContext, count: Int, amount: Int64) throws -> NativeBackupPackage {
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(context.container))
        XCTAssertEqual(package.transactions.count, count)
        XCTAssertEqual(package.transactions.reduce(0) { $0 + $1.amountMinorUnits }, amount)
        XCTAssertTrue(package.transactions.allSatisfy { row in package.importBatches.contains { $0.id == row.importBatchID } })
        XCTAssertNoThrow(try NativeBackupService.validate(package))
        var identity = LedgerSyncIdentity()
        XCTAssertEqual(try identity.capture(package).keys.filter { $0.hasPrefix("transactions:") }.count, count)
        return package
    }

    private func commit(_ plan: ImportPlan, in context: ModelContext, expectedImported: Int, expectedDuplicates: Int) async throws {
        XCTAssertEqual(plan.effectiveRowsToImport(includeSuspectedDuplicates: true).count, expectedImported)
        XCTAssertEqual(plan.duplicateCount, expectedDuplicates)
        guard !plan.effectiveRowsToImport(includeSuspectedDuplicates: true).isEmpty else { return }
        let request = try request(plan, in: context)
        XCTAssertEqual(request.result.importedCount, expectedImported)
        XCTAssertEqual(request.result.expenseMinorUnits, Int64(expectedImported) * 1234)
        let result = try await ImportCommitActor(modelContainer: context.container).commit(request)
        XCTAssertEqual(result.importedCount, expectedImported)
        XCTAssertEqual(result.duplicateCount, expectedDuplicates)
        XCTAssertEqual(result.confirmedDuplicateSkippedCount, expectedDuplicates)
        XCTAssertEqual(result.staleDuplicateCount, 0)
        XCTAssertEqual(result.expenseMinorUnits, Int64(expectedImported) * 1234)
        let batch = try XCTUnwrap(ModelContext(context.container).fetch(FetchDescriptor<ImportBatch>()).first { $0.id == request.batchID })
        XCTAssertEqual(batch.importedRowCount, expectedImported)
        XCTAssertEqual(batch.duplicateRowCount, expectedDuplicates)
        XCTAssertEqual(batch.expenseMinorUnits, Int64(expectedImported) * 1234)
    }

    private func fixture() throws -> ModelContext {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        context.insert(AppMetadata())
        context.insert(Account(name: "Review account", type: .cash, isDefault: true))
        context.insert(PersonalFinanceOS.Category(kind: .expense, name: "餐饮", symbolName: "fork.knife", colorToken: "orange"))
        try context.save()
        return context
    }

    private func preview(_ context: ModelContext, count: Int = 2) async throws -> ImportPlan {
        let csv = "type,amount,date_time,category,account,note\n" + Array(repeating:
            "expense,12.34,2026-01-01 10:00,餐饮,Review account,同一内容", count: count).joined(separator: "\n")
        let document = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: "review.csv")
        let parsed = try FinanceCSVService.parsePlan(document: document, mapping: FinanceCSVService.autoMapping(headers: document.headers), fileName: "review.csv")
        let records = try await ImportPlanningActor(modelContainer: context.container).duplicateRecords(for: parsed)
        return FinanceCSVService.assessDuplicates(parsed, existingRecords: records)
    }

    private func request(_ plan: ImportPlan, in context: ModelContext, includeConfirmed: Bool = false) throws -> ImportCommitRequest {
        let model = FinanceCSVService.makeImportModelSnapshot(accounts: try context.fetch(FetchDescriptor<Account>()), categories: try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), tags: [])
        return try FinanceCSVService.makeBackgroundCommitRequest(plan: plan, modelSnapshot: model, createMissingCategories: true, includeConfirmedDuplicates: includeConfirmed, rememberedCategoryMappings: [:])
    }
}
