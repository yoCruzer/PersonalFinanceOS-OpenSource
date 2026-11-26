import Foundation
import SwiftData
import XCTest
@testable import PersonalFinanceOS

private final class LedgerReadGate: @unchecked Sendable {
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    func checkpoint() throws {
        XCTAssertFalse(Thread.isMainThread)
        lock.lock()
        count += 1
        let first = count == 1
        lock.unlock()
        guard first else { return }
        reached.signal()
        guard release.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
    }
    func wait() -> Bool { reached.wait(timeout: .now() + 10) == .success }
    var checkpoints: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
final class LedgerReadConsistencyTests: XCTestCase {
    func testUsageRetriesOffsetScanAfterRealOrdinarySave() async throws {
        let context = try fixture()
        _ = try save(in: context, note: "初始一笔")
        let gate = LedgerReadGate()
        let actor = LedgerUsageMetricsActor(modelContainer: context.container)
        let reading = Task { try await actor.compute(batchSize: 1, afterBatch: { try gate.checkpoint() }) }
        let reached = await Task.detached { gate.wait() }.value
        XCTAssertTrue(reached)
        _ = try save(in: context, note: "扫描期间新增")
        gate.release.signal()
        let result = try await reading.value
        XCTAssertEqual(result.metrics.activeTransactionCount, 2)
        XCTAssertEqual(result.scannedRecordCount, 2)
        XCTAssertEqual(result.maximumBatchCount, 1)
        XCTAssertEqual(result.saveRevision, try LedgerSaveRevision.shared.readContentStamp())
        XCTAssertEqual(gate.checkpoints, 3)
    }

    func testUsageStoreDoesNotInstallComputationAfterInterveningSave() async throws {
        let context = try fixture()
        _ = try save(in: context, note: "初始一笔")
        let snapshot = try await LedgerUsageMetricsActor(modelContainer: context.container).compute()
        _ = try save(in: context, note: "结果安装前新增")
        let store = LedgerUsageMetricsStore()
        await store.refreshIfNeeded(revision: 0) { snapshot }
        XCTAssertNil(store.metrics)
        XCTAssertNil(store.revisionAtComputation)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
    }

    func testCSVExportRetriesTransactionsAndMetadataTogetherAfterRealRenameAndSave() async throws {
        let context = try fixture()
        let row = try save(in: context, note: "旧备注")
        let gate = LedgerReadGate()
        let exporter = LedgerExportActor(modelContainer: context.container)
        let exporting = Task { try await exporter.export(scope: .all, fileName: "consistency.csv", afterTransactionsRead: { try gate.checkpoint() }) }
        let reached = await Task.detached { gate.wait() }.value
        XCTAssertTrue(reached)
        let category = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.id == row.categoryID })
        try FinanceDataManagementService.rename(category: category, to: "新的午餐名称", in: context)
        var draft = TransactionDraft(transaction: row)
        draft.note = "新的备注"
        _ = try TransactionLifecycleService.save(draft: draft, editing: row,
            accounts: context.fetch(FetchDescriptor<Account>()), categories: context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), in: context)
        gate.release.signal()
        let url = try await exporting.value
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let fresh = ModelContext(context.container)
        let expected = FinanceCSVService.exportData(transactions: try fresh.fetch(FetchDescriptor<FinanceTransaction>()),
            categories: try fresh.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), accounts: try fresh.fetch(FetchDescriptor<Account>()))
        XCTAssertEqual(data, expected)
        XCTAssertEqual(gate.checkpoints, 2)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("新的午餐名称"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("新的备注"))
    }

    func testImportPreviewRetriesAfterRealConcurrentImport() async throws {
        let context = try fixture()
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let account = try XCTUnwrap(accounts.first)
        let csv = "transaction_id,type,amount,date_time,category,account\nread-case,expense,12.34,2026-01-01 10:00,餐饮 / 午餐,\(account.name)"
        let document = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: "read.csv")
        let parsed = try FinanceCSVService.parsePlan(document: document, mapping: FinanceCSVService.autoMapping(headers: document.headers), fileName: "read.csv")
        let plan = FinanceCSVService.assessDuplicates(parsed, existingRecords: [])
        let request = try FinanceCSVService.makeBackgroundCommitRequest(plan: plan,
            modelSnapshot: FinanceCSVService.makeImportModelSnapshot(accounts: accounts, categories: categories, tags: []),
            createMissingCategories: false, rememberedCategoryMappings: [:])
        let gate = LedgerReadGate()
        let planner = ImportPlanningActor(modelContainer: context.container)
        let reading = Task { try await planner.duplicateRecords(for: parsed, afterRead: { try gate.checkpoint() }) }
        let reached = await Task.detached { gate.wait() }.value
        XCTAssertTrue(reached)
        _ = try await ImportCommitActor(modelContainer: context.container).commit(request)
        gate.release.signal()
        let records = try await reading.value
        let currentPlan = FinanceCSVService.assessDuplicates(parsed, existingRecords: records)
        XCTAssertEqual(currentPlan.duplicateCount, 1)
        XCTAssertEqual(gate.checkpoints, 2)
    }

    private func fixture() throws -> ModelContext {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: context)
        return context
    }

    private func save(in context: ModelContext, note: String) throws -> FinanceTransaction {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        var draft = TransactionDraft()
        draft.amountText = "12.34"
        draft.accountID = accounts.first?.id
        draft.categoryID = categories.first { $0.defaultDefinitionKey == "expense.dining.lunch" }?.id
        draft.note = note
        return try TransactionLifecycleService.save(draft: draft, accounts: accounts, categories: categories, in: context)
    }
}
