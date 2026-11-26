import Darwin
import SwiftData
import XCTest
@testable import PersonalFinanceOS

/// Explicitly armed, synthetic-only multi-process checks. Ordinary suite runs skip
/// these phases; the host creates control.txt only inside this dedicated folder.
@MainActor
final class RemediationRecoveryCompatibilityTests: XCTestCase {
    private var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PFOSRemediationFixturesV3", isDirectory: true)
    }

    private func require(_ mode: String) throws {
        let control = directory.appendingPathComponent("control.txt")
        let value = try? String(contentsOf: control, encoding: .utf8)
        try XCTSkipUnless(value == mode, "Dedicated host-controlled synthetic phase is not armed")
        try FileManager.default.removeItem(at: control)
    }

    #if !PFOS_PERFORMANCE_BASELINE
    func testInterruptAfterCatalogSaveBeforeNotification() async throws {
        try require("catalog-crash")
        let configuration = ModelConfiguration("RemediationCrash", schema: AppSchema.schema,
            url: directory.appendingPathComponent("catalog-crash.store"), cloudKitDatabase: .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.url.path))
        let container = try ModelContainerFactory.make(configuration: configuration)
        let context = ModelContext(container)
        try seedFrozenV3Ledger(in: context)
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        var draft = TransactionDraft()
        draft.amountText = "12.34"
        draft.accountID = try context.fetch(FetchDescriptor<Account>()).first?.id
        draft.categoryID = categories.first { $0.defaultDefinitionKey == "expense.dining.lunch" }?.id
        draft.note = "合成保存后中断"
        _ = try TransactionLifecycleService.save(draft: draft, accounts: context.fetch(FetchDescriptor<Account>()),
            categories: categories, in: context)
        let before = try LedgerSnapshotCodec.capture(in: context)
        try JSONEncoder().encode(before).write(to: directory.appendingPathComponent("before-crash.json"), options: .atomic)
        let sync = ICloudSyncController()
        await sync.disable()
        let preview = try await CategoryCatalogService.preview(in: context, sync: sync)
        let checkpoint = directory.appendingPathComponent("after-save-checkpoint.txt")
        let token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { note in
            guard let sender = note.object as? ModelContext, sender.container === container else { return }
            // didSave runs synchronously inside fresh.save(), before the service's
            // next statement changes.recordMutation(). Kill only this test host.
            try? Data("catalog-save-committed-before-service-notification".utf8).write(to: checkpoint, options: .atomic)
            Darwin.kill(Darwin.getpid(), SIGKILL)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = try CategoryCatalogService.commit(preview, selected: Set(preview.plan.entries.filter(\.selectedByDefault).map(\.id)),
            in: context, sync: sync, changes: LedgerChangeCenter())
        XCTFail("Expected the explicitly armed test process to be killed at didSave")
    }

    func testReopenAfterInterruptedCatalogNotification() async throws {
        try require("catalog-reopen")
        let checkpoint = try String(contentsOf: directory.appendingPathComponent("after-save-checkpoint.txt"), encoding: .utf8)
        XCTAssertEqual(checkpoint, "catalog-save-committed-before-service-notification")
        let before = try JSONDecoder().decode(NativeBackupPackage.self,
            from: Data(contentsOf: directory.appendingPathComponent("before-crash.json")))
        let configuration = ModelConfiguration("RemediationCrash", schema: AppSchema.schema,
            url: directory.appendingPathComponent("catalog-crash.store"), cloudKitDatabase: .none)
        let context = ModelContext(try ModelContainerFactory.make(configuration: configuration))
        let after = try LedgerSnapshotCodec.capture(in: context)
        XCTAssertEqual(after.categories.count, 267)
        XCTAssertEqual(after.appMetadata.first?.defaultCategorySeedVersion, 4)
        XCTAssertEqual(try LedgerSnapshotCodec.records(before).filter { $0.key.hasPrefix("transactions:") },
            try LedgerSnapshotCodec.records(after).filter { $0.key.hasPrefix("transactions:") })
        for category in before.categories {
            XCTAssertEqual(after.categories.first { $0.id == category.id }?.defaultDefinitionKey, category.defaultDefinitionKey)
        }
        XCTAssertNoThrow(try NativeBackupService.validate(after))
        let revision = LedgerSaveRevision.shared.revision
        try DefaultFinanceDataService.ensureDefaults(in: context)
        XCTAssertEqual(revision, LedgerSaveRevision.shared.revision)
        let sync = ICloudSyncController()
        await sync.disable()
        let preview = try await CategoryCatalogService.preview(in: context, sync: sync)
        XCTAssertTrue(preview.plan.entries.filter(\.selectedByDefault).isEmpty)
        try Data("CATALOG_CRASH_REOPEN_PASS".utf8).write(to: directory.appendingPathComponent("crash-result.txt"), options: .atomic)
    }

    func testCreateNewCandidateCompatibilityFixture() async throws {
        try require("compat-create")
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: context)
        let sync = ICloudSyncController()
        await sync.disable()
        let preview = try await CategoryCatalogService.preview(in: context, sync: sync)
        _ = try CategoryCatalogService.commit(preview, selected: Set(preview.plan.entries.filter(\.selectedByDefault).map(\.id)),
            in: context, sync: sync, changes: LedgerChangeCenter())
        let fresh = ModelContext(context.container)
        let categories = try fresh.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        var draft = TransactionDraft()
        draft.amountText = "12.34"
        draft.accountID = try fresh.fetch(FetchDescriptor<Account>()).first?.id
        draft.categoryID = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.dining.coffee" }?.id)
        draft.note = "新客户端第一轮"
        _ = try TransactionLifecycleService.save(draft: draft, accounts: fresh.fetch(FetchDescriptor<Account>()), categories: categories, in: fresh)
        let metadata = try XCTUnwrap(fresh.fetch(FetchDescriptor<AppMetadata>()).first)
        metadata.defaultCategorySeedVersion = 999
        try fresh.save()
        let package = try LedgerSnapshotCodec.capture(in: fresh)
        try JSONEncoder().encode(package).write(to: directory.appendingPathComponent("compat-initial.json"), options: .atomic)
        try JSONEncoder().encode(package).write(to: directory.appendingPathComponent("compat-input.json"), options: .atomic)
    }
    #endif

    func testEditCompatibilityFixtureOnThisBinary() throws {
        #if PFOS_PERFORMANCE_BASELINE
        try require("compat-e30-edit")
        let expectedNote = "新客户端第一轮", nextNote = "e30第二轮"
        let expectedAmount: Int64 = 1234
        let nextAmount = "23.45"
        #else
        try require("compat-candidate-edit")
        let expectedNote = "e30第二轮", nextNote = "新客户端第三轮"
        let expectedAmount: Int64 = 2345
        let nextAmount = "34.56"
        #endif
        let input = try JSONDecoder().decode(NativeBackupPackage.self,
            from: Data(contentsOf: directory.appendingPathComponent("compat-input.json")))
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try LedgerSnapshotCodec.apply(input, in: context)
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let rows = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.amountMinorUnits, expectedAmount)
        XCTAssertEqual(row.note, expectedNote)
        var draft = TransactionDraft(transaction: row)
        draft.amountText = nextAmount
        draft.note = nextNote
        _ = try TransactionLifecycleService.save(draft: draft, editing: row,
            accounts: context.fetch(FetchDescriptor<Account>()), categories: context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), in: context)
        let output = try LedgerSnapshotCodec.capture(in: ModelContext(context.container))
        XCTAssertEqual(output.categories.count, 267)
        XCTAssertEqual(output.appMetadata.first?.defaultCategorySeedVersion, 999)
        XCTAssertEqual(output.transactions.first?.id, input.transactions.first?.id)
        XCTAssertEqual(output.transactions.first?.categoryID, input.transactions.first?.categoryID)
        XCTAssertEqual(output.transactions.first?.type, input.transactions.first?.type)
        let originalRow = try XCTUnwrap(input.transactions.first)
        var normalizedRow = try XCTUnwrap(output.transactions.first)
        normalizedRow.amountMinorUnits = originalRow.amountMinorUnits
        normalizedRow.note = originalRow.note
        normalizedRow.updatedAt = originalRow.updatedAt
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(normalizedRow), try encoder.encode(originalRow),
            "Alternating clients may change only the explicitly edited amount/note and update timestamp")
        let unchanged: (String) -> Bool = { !$0.hasPrefix("transactions:") }
        XCTAssertEqual(try LedgerSnapshotCodec.records(input).filter { unchanged($0.key) },
            try LedgerSnapshotCodec.records(output).filter { unchanged($0.key) })
        var beforeIdentity = LedgerSyncIdentity(), afterIdentity = LedgerSyncIdentity()
        XCTAssertEqual(Set(try beforeIdentity.capture(input).keys), Set(try afterIdentity.capture(output).keys))
        XCTAssertNoThrow(try NativeBackupService.validate(output))
        try JSONEncoder().encode(output).write(to: directory.appendingPathComponent("compat-output.json"), options: .atomic)
    }

    func testReadFinalCompatibilityFixtureOnOldBinary() throws {
        #if PFOS_PERFORMANCE_BASELINE
        try require("compat-e30-final")
        let package = try JSONDecoder().decode(NativeBackupPackage.self,
            from: Data(contentsOf: directory.appendingPathComponent("compat-input.json")))
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try LedgerSnapshotCodec.apply(package, in: context)
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let output = try LedgerSnapshotCodec.capture(in: context)
        XCTAssertEqual(output.transactions.first?.amountMinorUnits, 3456)
        XCTAssertEqual(output.transactions.first?.note, "新客户端第三轮")
        XCTAssertEqual(output.appMetadata.first?.defaultCategorySeedVersion, 999)
        XCTAssertEqual(try LedgerSnapshotCodec.records(package), try LedgerSnapshotCodec.records(output))
        try Data("E30_CANDIDATE_ALTERNATING_EDIT_PASS".utf8).write(to: directory.appendingPathComponent("compat-result.txt"), options: .atomic)
        #else
        throw XCTSkip("Final read is deliberately executed by the exact e30 binary")
        #endif
    }
}
