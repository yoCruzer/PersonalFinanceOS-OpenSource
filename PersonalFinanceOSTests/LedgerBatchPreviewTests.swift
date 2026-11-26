import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class LedgerBatchPreviewTests: XCTestCase {
    func testCompleteFilterSelectionPreviewExportAndActualCorrectionIncludeUnloadedPages() async throws {
        let fixture = try Fixture(count: 305)
        let reader = LedgerAnalysisActor(modelContainer: fixture.context.container)
        var filter = LedgerFilter(dateRange: nil)
        filter.query = "跨页选择"
        let snapshot = try await reader.snapshot(filter: filter)
        XCTAssertEqual(snapshot.firstPage.count, 100)
        XCTAssertEqual(snapshot.transactionIDs.count, 305)
        let selected = Set(snapshot.transactionIDs)
        let writer = LedgerBatchOperationActor(modelContainer: fixture.context.container)
        let totals = try await writer.selectionTotals(selectedIDs: selected, revision: snapshot.revision)
        XCTAssertEqual(totals, snapshot.totals)
        XCTAssertEqual(totals.grossExpenseMinorUnits, 30_500)
        let plan = try await writer.plan(selectedIDs: selected, operation: .category(fixture.target.id), revision: snapshot.revision)
        XCTAssertEqual(plan.totals.totalCount, 305)
        XCTAssertEqual(plan.totals, snapshot.totals)
        let csv = String(decoding: try await reader.exportData(snapshot: snapshot, selectedIDs: selected), as: UTF8.self)
        XCTAssertEqual(csv.components(separatedBy: "\r\n").count, 306)
        for id in selected { XCTAssertTrue(csv.contains(id.uuidString)) }
        let result = try await writer.execute(plan)
        XCTAssertEqual(result.summary.count, 305)
        XCTAssertEqual(result.learningEvents.count, 305)
        let persisted = try ModelContext(fixture.context.container).fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(Set(persisted.filter { $0.categoryID == fixture.target.id }.map(\.id)), selected)
        XCTAssertTrue(persisted.filter { selected.contains($0.id) }.allSatisfy { $0.categoryDecisionSource == .manualConfirmed })
        XCTAssertEqual(persisted.first { $0.id == fixture.outside.id }?.categoryID, fixture.source.id)
        do { _ = try await writer.execute(plan); XCTFail("Applied plans are stale after their own save") }
        catch { XCTAssertTrue(error is LedgerAnalysisError) }
    }

    func testCategoryPreviewIsReadOnlyAndConfirmationPreservesEachAmount() async throws {
        let fixture = try Fixture(count: 2)
        fixture.rows.forEach { $0.amountMinorUnits = 16_800 }
        try fixture.context.save()
        let ids = Set(fixture.rows.map(\.id))
        let before = try ModelContext(fixture.context.container).fetch(FetchDescriptor<FinanceTransaction>()).map(LedgerFilteredRow.init)
        let revision = try LedgerSaveRevision.shared.readContentStamp()
        let writer = LedgerBatchOperationActor(modelContainer: fixture.context.container)
        // Discarding a preview is what the UI's Cancel does: no writer execution.
        _ = try await writer.plan(selectedIDs: ids, operation: .category(fixture.target.id), revision: revision)
        XCTAssertEqual(try LedgerSaveRevision.shared.readContentStamp(), revision)
        let cancelled = try ModelContext(fixture.context.container).fetch(FetchDescriptor<FinanceTransaction>()).map(LedgerFilteredRow.init)
        XCTAssertEqual(Set(before.map(\.id)), Set(cancelled.map(\.id)))
        for original in before {
            let row = try XCTUnwrap(cancelled.first { $0.id == original.id })
            XCTAssertEqual(row.categoryID, original.categoryID)
            XCTAssertEqual(row.amountMinorUnits, original.amountMinorUnits)
            XCTAssertEqual(row.updatedAt, original.updatedAt)
            XCTAssertEqual(row.deletedAt, original.deletedAt)
        }
        let confirmed = try await writer.plan(selectedIDs: ids, operation: .category(fixture.target.id), revision: revision)
        XCTAssertEqual(confirmed.totals.netExpenseMinorUnits, 33_600)
        _ = try await writer.execute(confirmed)
        let after = try ModelContext(fixture.context.container).fetch(FetchDescriptor<FinanceTransaction>())
        for original in before {
            let row = try XCTUnwrap(after.first { $0.id == original.id })
            XCTAssertEqual(row.amountMinorUnits, original.amountMinorUnits)
            XCTAssertEqual(row.currencyCode, original.currencyCode)
            XCTAssertEqual(row.occurredAt, original.occurredAt)
            XCTAssertEqual(row.note, original.note)
            XCTAssertEqual(row.type, original.type)
            XCTAssertEqual(row.categoryID, ids.contains(row.id) ? fixture.target.id : fixture.source.id)
        }
        XCTAssertEqual(after.filter { ids.contains($0.id) }.reduce(Int64(0)) { $0 + $1.amountMinorUnits }, 33_600)
    }

    func testTargetRepurposeAndSameTimestampTransactionEditInvalidateConfirmation() async throws {
        let fixture = try Fixture(count: 2)
        let ids = Set(fixture.rows.map(\.id))
        let writer = LedgerBatchOperationActor(modelContainer: fixture.context.container)
        let first = try await writer.plan(selectedIDs: ids, operation: .category(fixture.target.id),
            revision: LedgerSaveRevision.shared.readContentStamp())
        fixture.target.name = "重新定义用途"
        try fixture.context.save()
        do { _ = try await writer.execute(first); XCTFail("Active UUID cannot authorize a repurposed target") }
        catch { XCTAssertTrue(error is LedgerAnalysisError) }
        let second = try await writer.plan(selectedIDs: ids, operation: .delete, revision: LedgerSaveRevision.shared.readContentStamp())
        let timestamp = fixture.rows[0].updatedAt
        fixture.rows[0].note = "确认期间修改"
        fixture.rows[0].updatedAt = timestamp
        try fixture.context.save()
        do { _ = try await writer.execute(second); XCTFail("Same timestamp edit still changes save revision") }
        catch { XCTAssertTrue(error is LedgerAnalysisError) }
        let current = try ModelContext(fixture.context.container).fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertTrue(current.allSatisfy { $0.deletedAt == nil && $0.categoryID == fixture.source.id })
    }

    func testPlansUseActualChangedSubsetAndNoOpDoesNotSave() async throws {
        let fixture = try Fixture(count: 2)
        let tag = Tag(name: "测试标签")
        fixture.context.insert(tag)
        fixture.rows[0].tags = [tag]
        try fixture.context.save()
        let ids = Set(fixture.rows.map(\.id))
        let writer = LedgerBatchOperationActor(modelContainer: fixture.context.container)
        let revision = try LedgerSaveRevision.shared.readContentStamp()
        let unchanged = try await writer.plan(selectedIDs: ids, operation: .category(fixture.source.id), revision: revision)
        XCTAssertEqual(unchanged.totals.totalCount, 0)
        let noOp = try await writer.execute(unchanged)
        XCTAssertEqual(noOp.summary.count, 0)
        XCTAssertEqual(try LedgerSaveRevision.shared.readContentStamp(), revision)
        let add = try await writer.plan(selectedIDs: ids, operation: .tags(.add(tag.id)), revision: revision)
        XCTAssertEqual(add.totals.totalCount, 1)
        let added = try await writer.execute(add)
        XCTAssertEqual(added.summary.count, 1)
        let remove = try await writer.plan(selectedIDs: ids, operation: .tags(.remove(tag.id)), revision: LedgerSaveRevision.shared.readContentStamp())
        XCTAssertEqual(remove.totals.totalCount, 2)
        let removed = try await writer.execute(remove)
        XCTAssertEqual(removed.summary.count, 2)
    }

    func testHiddenParentAndMissingSelectedRowsCannotProduceConfirmation() async throws {
        let fixture = try Fixture(count: 1)
        let parent = Category(kind: .expense, name: "隐藏父级", symbolName: "folder", colorToken: "blue")
        parent.isHidden = true
        fixture.context.insert(parent)
        fixture.target.parentID = parent.id
        try fixture.context.save()
        let writer = LedgerBatchOperationActor(modelContainer: fixture.context.container)
        let revision = try LedgerSaveRevision.shared.readContentStamp()
        do {
            _ = try await writer.plan(selectedIDs: [fixture.rows[0].id], operation: .category(fixture.target.id), revision: revision)
            XCTFail("Hidden parent excludes target")
        } catch { XCTAssertEqual(error as? TransactionBatchOperationError, .invalidCategory) }
        do {
            _ = try await writer.plan(selectedIDs: [fixture.rows[0].id, UUID()], operation: .delete, revision: revision)
            XCTFail("Missing selection cannot silently reduce preview")
        } catch { XCTAssertTrue(error is LedgerAnalysisError) }
    }

    func testOverflowRejectsPreviewAndActualWriterBeforeMutation() async throws {
        let fixture = try Fixture(count: 2)
        fixture.rows[0].amountMinorUnits = .max
        try fixture.context.save()
        let writer = LedgerBatchOperationActor(modelContainer: fixture.context.container)
        let ids = Set(fixture.rows.map(\.id))
        do {
            _ = try await writer.plan(selectedIDs: ids, operation: .delete, revision: LedgerSaveRevision.shared.readContentStamp())
            XCTFail("Overflow cannot be saturated in preview")
        } catch { XCTAssertTrue(error is LedgerAnalysisError) }
        do { _ = try await writer.softDelete(selectedIDs: ids); XCTFail("Writer shares checked sums") }
        catch { XCTAssertTrue(error is LedgerAnalysisError) }
        let current = try ModelContext(fixture.context.container).fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertTrue(current.allSatisfy { $0.deletedAt == nil })
    }

    @MainActor
    private struct Fixture {
        let context: ModelContext
        let source: PersonalFinanceOS.Category
        let target: PersonalFinanceOS.Category
        let rows: [FinanceTransaction]
        let outside: FinanceTransaction
        init(count: Int) throws {
            context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
            let account = Account(name: "合成账户", type: .cash, currencyCode: "CNY")
            source = Category(kind: .expense, name: "原分类", symbolName: "folder", colorToken: "blue")
            target = Category(kind: .expense, name: "新分类", symbolName: "folder", colorToken: "green")
            context.insert(account)
            context.insert(source)
            context.insert(target)
            let date = Date(timeIntervalSince1970: 1_790_000_000)
            var values: [FinanceTransaction] = []
            for index in 0...count {
                let row = FinanceTransaction(type: .expense, amountMinorUnits: 100, occurredAt: date,
                    localDayKey: LocalDayKey.make(for: date, timeZone: .gmt), timeZoneIdentifier: "GMT",
                    accountID: account.id, categoryID: source.id,
                    note: index == count ? "范围外" : "跨页选择-\(index)", createdAt: date, updatedAt: date)
                context.insert(row)
                values.append(row)
            }
            outside = values.removeLast()
            rows = values
            try context.save()
        }
    }
}
