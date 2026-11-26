import Foundation
import SwiftData
import XCTest
@testable import PersonalFinanceOS

private final class SnapshotReadGate: @unchecked Sendable {
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
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
final class LedgerVersionedSnapshotTests: XCTestCase {
    func testCategoryThenTransactionReadRejectsMixedGraphAfterRealCategoryAndCaptureSaves() async throws {
        let context = try fixture()
        let gate = SnapshotReadGate()
        let reader = LedgerSnapshotReader(modelContainer: context.container)
        let reading = Task { try await reader.capture(afterCategoriesRead: { try gate.checkpoint() }) }
        let reached = await Task.detached { gate.wait() }.value
        XCTAssertTrue(reached)
        let category = try FinanceDataManagementService.addCategory(name: "并发新分类", kind: .expense,
            categories: [], in: context)
        let accounts = try context.fetch(FetchDescriptor<Account>())
        var draft = TransactionDraft()
        draft.amountText = "42.00"
        draft.accountID = accounts.first?.id
        draft.categoryID = category.id
        let saved = try TransactionLifecycleService.save(draft: draft, accounts: accounts,
            categories: context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), in: context)
        gate.release.signal()
        let result = try await reading.value
        XCTAssertEqual(gate.attempts, 2)
        XCTAssertEqual(result.transactions.count, 2)
        XCTAssertTrue(result.categories.contains { $0.id == category.id })
        XCTAssertEqual(result.transactions.first { $0.id == saved.id }?.categoryID, category.id)
        XCTAssertNoThrow(try NativeBackupService.validate(result))
    }

    func testActualSnapshotReaderRetriesAfterOrdinarySaveWithoutHoldingWriteBoundary() async throws {
        let context = try fixture()
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>()).first)
        let gate = SnapshotReadGate()
        let reader = LedgerSnapshotReader(modelContainer: context.container)
        let reading = Task { try await reader.capture(afterRead: { try gate.checkpoint() }) }
        let reached = await Task.detached { gate.wait() }.value
        XCTAssertTrue(reached)
        var draft = TransactionDraft(transaction: row)
        draft.note = "读取期间已保存的新备注"
        _ = try TransactionLifecycleService.save(draft: draft, editing: row,
            accounts: context.fetch(FetchDescriptor<Account>()), categories: context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), in: context)
        gate.release.signal()
        let result = try await reading.value
        XCTAssertEqual(gate.attempts, 2)
        XCTAssertEqual(result.transactions.first { $0.id == row.id }?.note, draft.note)
        XCTAssertNoThrow(try NativeBackupService.validate(result))
    }

    func testVersionedCapturePersistsExistingLegacyDuplicateOriginsOnceAndMatchesBackup() async throws {
        let context = try fixture(duplicates: true)
        let reader = LedgerSnapshotReader(modelContainer: context.container)
        let first = try await reader.capture()
        XCTAssertEqual(first.transactions.count, 2)
        XCTAssertEqual(Set(first.transactions.compactMap(\.importSemanticOrigin)).count, 2)
        XCTAssertEqual(try ModelContext(context.container).fetchCount(FetchDescriptor<ImportEntityOrigin>()), 2)
        let revision = try LedgerSaveRevision.shared.readStamp()
        let second = try await reader.capture()
        XCTAssertEqual(try LedgerSaveRevision.shared.readStamp(), revision)
        XCTAssertEqual(try LedgerSnapshotCodec.records(first), try LedgerSnapshotCodec.records(second))
        let data = try await NativeBackupActor(modelContainer: context.container).exportData()
        let backup = try NativeBackupService.decode(data)
        XCTAssertEqual(try LedgerSnapshotCodec.records(first), try LedgerSnapshotCodec.records(backup))
    }

    func testCancelledReadDoesNotPersistLegacyOrigins() async throws {
        let context = try fixture(duplicates: true)
        let gate = SnapshotReadGate()
        let reader = LedgerSnapshotReader(modelContainer: context.container)
        let reading = Task { try await reader.capture(afterRead: { try gate.checkpoint() }) }
        let reached = await Task.detached { gate.wait() }.value
        XCTAssertTrue(reached)
        reading.cancel()
        gate.release.signal()
        do { _ = try await reading.value; XCTFail("Cancelled capture must not write provenance") }
        catch is CancellationError {}
        XCTAssertEqual(try ModelContext(context.container).fetchCount(FetchDescriptor<ImportEntityOrigin>()), 0)
        XCTAssertEqual(try ModelContext(context.container).fetchCount(FetchDescriptor<FinanceTransaction>()), 2)
    }

    private func fixture(duplicates: Bool = false) throws -> ModelContext {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first)
        let category = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining.lunch" })
        for _ in 0..<(duplicates ? 2 : 1) {
            context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 1234,
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000), localDayKey: "2023-11-14", timeZoneIdentifier: "UTC",
                accountID: account.id, categoryID: category.id, note: "原始备注",
                externalSource: duplicates ? .genericCSV : nil, externalTransactionID: duplicates ? "legacy-twin" : ""))
        }
        try context.save()
        return context
    }
}
