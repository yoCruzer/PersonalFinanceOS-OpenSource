import CloudKit
import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class Build33AuditRegressionTests: XCTestCase {
    private func context() throws -> ModelContext {
        let ctx = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try DefaultFinanceDataService.ensureDefaults(in: ctx)
        return ctx
    }

    private func plan(_ csv: String, in ctx: ModelContext) throws -> ImportPlan {
        let doc = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: "fixture.csv")
        return try FinanceCSVService.makePlan(document: doc, mapping: FinanceCSVService.autoMapping(headers: doc.headers),
            fileName: "fixture.csv", existingTransactions: ctx.fetch(FetchDescriptor<FinanceTransaction>()))
    }

    @discardableResult
    private func commit(_ input: String, in ctx: ModelContext) throws -> ImportResult {
        try FinanceCSVService.commit(plan: plan(input, in: ctx), accounts: ctx.fetch(FetchDescriptor<Account>()),
            categories: ctx.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), tags: [], in: ctx)
    }

    private func wacai(merchant: String = "商户甲", currency: String = "CNY", date: String = "2026-10-15 12:00:00") -> String {
        "日期时间,类型,类别,金额,币种,收付款人,收付账户,参与人,标签,商家,属性,备注\n" +
        "\(date),支出,午餐,10.00,\(currency),,钱包,,,\(merchant),,"
    }

    func testDistinctMerchantsRemainImportableAcrossFiles() throws {
        let ctx = try context()
        XCTAssertEqual(try commit(wacai(), in: ctx).importedCount, 1)
        let repeated = try plan(wacai(), in: ctx)
        let different = try plan(wacai(merchant: "商户乙"), in: ctx)
        XCTAssertEqual(repeated.duplicateCount, 1)
        XCTAssertEqual(different.candidates.first?.merchantName, "商户乙")
        XCTAssertEqual(different.duplicateCount, 0)
        XCTAssertEqual(different.effectiveRowsToImport(includeSuspectedDuplicates: true, includeConfirmedDuplicates: false).count, 1)
        XCTAssertEqual(try plan(wacai(merchant: "商户乙", date: "2026-10-16 12:00:00"), in: ctx).duplicateCount, 0)
    }

    func testOnlySupportedCurrencyReachesLedger() throws {
        for currency in ["CNY", "USD"] {
            let ctx = try context()
            if currency == "USD" {
                XCTAssertEqual(try plan(wacai(currency: currency), in: ctx).skippedRows.first?.reason, .unsupportedCurrency)
                XCTAssertThrowsError(try commit(wacai(currency: currency), in: ctx))
                XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<FinanceTransaction>()), 0)
                continue
            }
            XCTAssertEqual(try commit(wacai(currency: currency), in: ctx).importedCount, 1)
            let tx = try XCTUnwrap(ctx.fetch(FetchDescriptor<FinanceTransaction>()).first)
            XCTAssertEqual(tx.currencyCode, "CNY")
            XCTAssertEqual(tx.amountMinorUnits, 1000)
        }
    }

    private func changeTypeToIncome(_ row: FinanceTransaction, in ctx: ModelContext) throws {
        let categories = try ctx.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        var draft = TransactionDraft(transaction: row)
        draft.type = .income
        draft.categoryID = try XCTUnwrap(categories.first(where: { $0.kind == .income && $0.parentID != nil && !$0.isHidden && $0.archivedAt == nil })).id
        try TransactionLifecycleService.save(draft: draft, editing: row, accounts: [], categories: [], in: ctx)
    }

    func testNewDeviceRetainsSourceKeyAcrossTypeAndNoteEdits() throws {
        let ctx = try context()
        try commit(wacai(), in: ctx)
        var a = LedgerSyncIdentity()
        var replica = ProtectedLedgerReplica(accountIdentifier: "fixture")
        try replica.captureLocal(a.capture(LedgerSnapshotCodec.capture(in: ctx)))
        var control = LedgerSyncIdentity()
        let first = try control.localPackage(from: replica)
        XCTAssertEqual(try control.capture(first), replica.livePayloads)
        try changeTypeToIncome(XCTUnwrap(ctx.fetch(FetchDescriptor<FinanceTransaction>()).first), in: ctx)
        try replica.captureLocal(a.capture(LedgerSnapshotCodec.capture(in: ctx)))
        var b = LedgerSyncIdentity()
        let received = try b.localPackage(from: replica)
        let accepted = try b.capture(received)
        XCTAssertEqual(Set(accepted.keys), Set(replica.livePayloads.keys))
        replica.acknowledgeLocalProjection(accepted)
        let newCtx = try context()
        try LedgerSnapshotCodec.apply(received, in: newCtx)
        let row = try XCTUnwrap(newCtx.fetch(FetchDescriptor<FinanceTransaction>()).first)
        var draft = TransactionDraft(transaction: row)
        draft.note = "新设备的备注"
        try TransactionLifecycleService.save(draft: draft, editing: row, accounts: [], categories: [], in: newCtx)
        try replica.captureLocal(b.capture(LedgerSnapshotCodec.capture(in: newCtx)))
        XCTAssertEqual(try LedgerSyncIdentity.wirePackage(from: replica.livePayloads).transactions.count, 1)
    }

    // Digest produced by the Build 33 Wacai parser for the unedited fixture.
    private let build33Fingerprint = "6ce4f95e48434185"

    private func repeatedWacai(_ count: Int) -> String {
        let lines = wacai().components(separatedBy: "\n")
        return ([lines[0]] + Array(repeating: lines[1], count: count)).joined(separator: "\n")
    }

    private func build33Ledger(count: Int = 1) throws -> ModelContext {
        let ctx = try context()
        try commit(repeatedWacai(count), in: ctx)
        let oldBase = try XCTUnwrap(LedgerSyncIdentity.importIdentity(source: .wacai, type: .expense,
            externalID: "", fingerprint: build33Fingerprint))
        let origins = try ctx.fetch(FetchDescriptor<ImportEntityOrigin>())
        for row in try ctx.fetch(FetchDescriptor<FinanceTransaction>()) {
            XCTAssertEqual(BillParserSupport.legacyFingerprint(row.importFingerprint), build33Fingerprint)
            row.importFingerprint = build33Fingerprint
            let key = "transactions:" + row.id.uuidString
            let origin = try XCTUnwrap(origins.first { $0.entityKey == key })
            if origin.semanticKey.hasPrefix("occurrence-v1:"), let ordinal = origin.semanticKey.split(separator: ":").last {
                origin.semanticKey = "occurrence-v1:\(oldBase.uuidString):\(ordinal)"
            } else { ctx.delete(origin) }
        }
        try ctx.save()
        return ctx
    }

    func testLegacyTypeEditAndSoftDeleteStillReserveOriginalMerchant() throws {
        let ctx = try build33Ledger()
        let row = try XCTUnwrap(ctx.fetch(FetchDescriptor<FinanceTransaction>()).first)
        let originalID = row.id
        var mapping = LedgerSyncIdentity()
        let before = try mapping.capture(LedgerSnapshotCodec.capture(in: ctx))
        try changeTypeToIncome(row, in: ctx)
        try TransactionLifecycleService.softDelete(row, in: ctx)
        XCTAssertEqual(try plan(wacai(), in: ctx).duplicateCount, 1)
        XCTAssertEqual(try plan(wacai(merchant: "商户乙"), in: ctx).duplicateCount, 0)
        let snapshot = try LedgerSnapshotCodec.capture(in: ctx)
        XCTAssertEqual(snapshot.transactions.first?.id, originalID)
        XCTAssertNotNil(snapshot.transactions.first?.deletedAt)
        XCTAssertEqual(Set(try mapping.capture(snapshot).keys), Set(before.keys))
        let restored = try context()
        try LedgerSnapshotCodec.apply(snapshot, in: restored)
        XCTAssertEqual(try plan(wacai(), in: restored).duplicateCount, 1)
        XCTAssertEqual(try commit(wacai(merchant: "商户乙"), in: restored).importedCount, 1)
        XCTAssertEqual(try restored.fetchCount(FetchDescriptor<FinanceTransaction>()), 2)
    }

    func testReceivingUnmarkedBuild33RecordUsesPublishedKeyAfterTypeCorrection() throws {
        let ctx = try build33Ledger()
        var mapping = LedgerSyncIdentity()
        var wire = try mapping.capture(LedgerSnapshotCodec.capture(in: ctx))
        let key = try XCTUnwrap(wire.keys.first { $0.hasPrefix("transactions:") })
        var old = try JSONDecoder().decode(NativeBackupPackage.TransactionPayload.self, from: XCTUnwrap(wire[key]))
        XCTAssertNil(old.importSemanticOrigin)
        old.type = .income
        old.categoryID = nil
        wire[key] = try JSONEncoder().encode(old)
        var replica = ProtectedLedgerReplica(accountIdentifier: "legacy")
        try replica.captureLocal(wire)
        var receiver = LedgerSyncIdentity()
        let received = try receiver.localPackage(from: replica)
        let projected = try receiver.capture(received)
        XCTAssertEqual(Set(projected.keys), Set(wire.keys))
        let restored = try context()
        try LedgerSnapshotCodec.apply(received, in: restored)
        XCTAssertEqual(try plan(wacai(), in: restored).duplicateCount, 1)
        XCTAssertEqual(try restored.fetchCount(FetchDescriptor<FinanceTransaction>()), 1)
    }

    func testIndependentImportsBridgeOldFingerprintOnlyForTheSameMerchant() throws {
        let legacy = try LedgerSnapshotCodec.capture(in: build33Ledger(count: 2))
        let current = try context()
        try commit(repeatedWacai(2), in: current)
        let modern = try LedgerSnapshotCodec.capture(in: current)
        let different = try context()
        try commit(wacai(merchant: "商户乙"), in: different)
        for (existing, joining) in [(legacy, modern), (modern, legacy)] {
            var published = LedgerSyncIdentity()
            var replica = ProtectedLedgerReplica(accountIdentifier: "ledger")
            try replica.captureLocal(published.capture(existing))
            let publishedKeys = Set(replica.records.keys.filter { $0.hasPrefix("transactions:") })
            var identity = LedgerSyncIdentity()
            try identity.adoptCompatibleImportKeys(in: joining, from: replica)
            let canonical = try identity.capture(joining)
            XCTAssertEqual(Set(canonical.keys.filter { $0.hasPrefix("transactions:") }), publishedKeys)
            XCTAssertEqual(publishedKeys.count, 2)
            let restored = try context()
            try LedgerSnapshotCodec.apply(identity.localPackage(fromWireRecords: canonical), in: restored)
            XCTAssertEqual(try plan(repeatedWacai(2), in: restored).duplicateCount, 2)
            var control = LedgerSyncIdentity()
            let second = try LedgerSnapshotCodec.capture(in: different)
            try control.adoptCompatibleImportKeys(in: second, from: replica)
            XCTAssertNotEqual(Set(try control.capture(second).keys.filter { $0.hasPrefix("transactions:") }), publishedKeys)
        }
    }

    func testInconsistentCurrencyFailsBeforePreviewOrRestore() async throws {
        let ctx = try context()
        try commit(wacai(), in: ctx)
        let data = try await NativeBackupActor(modelContainer: ctx.container).exportData()
        XCTAssertNoThrow(try ValidatedLedgerSnapshot(NativeBackupService.decode(data)))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try XCTUnwrap(json["transactions"] as? [[String: Any]])
        rows[0]["currencyCode"] = "USD"
        json["transactions"] = rows
        let inconsistent = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try NativeBackupService.preview(data: inconsistent))
        let dest = try context()
        do {
            _ = try await NativeBackupActor(modelContainer: dest.container).restore(data: inconsistent,
                admission: offlineRestoreTicket(for: dest.container))
            XCTFail("Currency mismatch must prevent restore")
        } catch is NativeBackupError {}
        XCTAssertEqual(try dest.fetchCount(FetchDescriptor<FinanceTransaction>()), 0)
    }

    func testEditingOneRowResolvesCategoryReview() throws {
        let ctx = try context()
        try commit(wacai().replacingOccurrences(of: ",午餐,", with: ",,"), in: ctx)
        let row = try XCTUnwrap(ctx.fetch(FetchDescriptor<FinanceTransaction>()).first)
        XCTAssertTrue(row.reviewReasons.contains(.uncategorized))
        let categories = try ctx.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        var draft = TransactionDraft(transaction: row)
        draft.categoryID = try XCTUnwrap(categories.first(where: { $0.kind == .expense && $0.parentID != nil && !$0.isHidden && $0.archivedAt == nil })).id
        try TransactionLifecycleService.save(draft: draft, editing: row, accounts: [], categories: [], categoryDecisionSource: .manualConfirmed, in: ctx)
        let saved = try XCTUnwrap(ModelContext(ctx.container).fetch(FetchDescriptor<FinanceTransaction>()).first)
        XCTAssertEqual(saved.categoryID, draft.categoryID)
        XCTAssertFalse(saved.reviewReasons.contains(.uncategorized))
        XCTAssertEqual(saved.reviewStatus, .complete)
    }
}

extension Build33AuditRegressionTests {
    func testIndependentExportsRetainTheirContent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let narrow = Data("only selected rows".utf8)
        let all = Data("all ledger rows".utf8)
        let first = try FinanceCSVService.writeTemporaryExport(data: narrow, fileName: "Transactions.csv", directory: dir)
        XCTAssertEqual(try Data(contentsOf: first), narrow)
        let second = try FinanceCSVService.writeTemporaryExport(data: all, fileName: "Transactions.csv", directory: dir)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: second), all)
        XCTAssertEqual(try Data(contentsOf: first), narrow)
        _ = try FinanceCSVService.writeTemporaryExport(data: Data("backup".utf8), fileName: "Backup.json", directory: dir)
        XCTAssertEqual(try Data(contentsOf: first), narrow)
    }
}

extension Build33AuditRegressionTests {
    func testSecondDeviceReconciliationKeepsCorrectedTransactionIdentity() async throws {
        let source = try context()
        try commit(wacai(), in: source)
        var mapping = LedgerSyncIdentity()
        var cloud = ProtectedLedgerReplica(accountIdentifier: "demo")
        try cloud.captureLocal(mapping.capture(LedgerSnapshotCodec.capture(in: source)))
        try changeTypeToIncome(XCTUnwrap(source.fetch(FetchDescriptor<FinanceTransaction>()).first), in: source)
        try cloud.captureLocal(mapping.capture(LedgerSnapshotCodec.capture(in: source)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try PrivateCloudReplicaSession(stateURL: dir.appendingPathComponent("state.json"), accountIdentifier: "demo", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "demo")
        let current = await session.engine
        let engine = try XCTUnwrap(current)
        let records = try cloud.records.map { key, value in
            let id = CKRecord.ID(recordName: PrivateCloudReplicaSession.recordName(for: key), zoneID: PrivateCloudReplicaSession.zoneID)
            let record = CKRecord(recordType: PrivateCloudReplicaSession.recordType, recordID: id)
            record["envelope"] = try JSONEncoder().encode(PrivateCloudReplicaSession.Envelope(format: 1, accountIdentifier: "demo", key: key, record: value)) as CKRecordValue
            return record
        }
        try await session.receiveRemoteRecords(records, syncEngine: engine)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        let controller = ICloudSyncController(confirmedSession: session, identity: LedgerSyncIdentity(), identityURL: dir.appendingPathComponent("identity.json"))
        let dest = try context()
        let changes = LedgerChangeCenter()
        await controller.reconcile(in: dest, changes: changes)
        let received = try dest.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(received.count, 1)
        let row = try XCTUnwrap(received.first)
        XCTAssertEqual(row.type, .income)
        var edit = TransactionDraft(transaction: row)
        edit.note = "新设备的备注"
        try TransactionLifecycleService.save(draft: edit, editing: row, accounts: [], categories: [], in: dest)
        await controller.reconcile(in: dest, changes: changes)
        let snapshot = await session.snapshot()
        XCTAssertEqual(try LedgerSyncIdentity.wirePackage(from: snapshot.livePayloads).transactions.count, 1)
        await session.stop()
    }

    func testReimportAfterTypeCorrectionReservesOriginalIdentity() throws {
        let ctx = try context()
        try commit(wacai(), in: ctx)
        var mapping = LedgerSyncIdentity()
        _ = try mapping.capture(LedgerSnapshotCodec.capture(in: ctx))
        let row = try XCTUnwrap(ctx.fetch(FetchDescriptor<FinanceTransaction>()).first)
        try changeTypeToIncome(row, in: ctx)
        XCTAssertEqual(try plan(wacai(), in: ctx).duplicateCount, 1)
        XCTAssertThrowsError(try commit(wacai(), in: ctx))
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<FinanceTransaction>()), 1)
        XCTAssertNoThrow(try mapping.capture(LedgerSnapshotCodec.capture(in: ctx)))
    }

    func testOriginallyZeroBatchSumSurvivesLaterEdit() async throws {
        let ctx = try context()
        let csv = "type,amount,date_time,transaction_id\nexpense,10.00,2026-10-15 12:00:00,a\nrefund,10.00,2026-10-16 12:00:00,b"
        try commit(csv, in: ctx)
        let batch = try XCTUnwrap(ctx.fetch(FetchDescriptor<ImportBatch>()).first)
        XCTAssertEqual(batch.expenseMinorUnits, 0)
        let tx = try XCTUnwrap(ctx.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.type == .expense })
        var draft = TransactionDraft(transaction: tx)
        let categories = try ctx.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        draft.categoryID = try XCTUnwrap(categories.first { $0.kind == .expense && $0.parentID != nil && !$0.isHidden }).id
        draft.amountText = "12.00"
        try TransactionLifecycleService.save(draft: draft, editing: tx, accounts: [], categories: [], in: ctx)
        let summary = try await ImportRollbackActor(modelContainer: ctx.container).summary(batchID: batch.id)
        XCTAssertEqual(batch.expenseMinorUnits, 0)
        XCTAssertEqual(summary.expenseMinorUnits, 0)
    }
}

extension Build33AuditRegressionTests {
    func testGenericCurrencyAndMissingTransactionID() throws {
        let ctx = try context()
        let csv = "account_id,type,amount,currency,date_time\na,expense,2.00,USD,2026-10-15\na,expense,1.00,CNY,2026-10-15"
        let parsed = try plan(csv, in: ctx)
        XCTAssertEqual(parsed.skippedRows.map(\.reason), [.unsupportedCurrency])
        XCTAssertEqual(parsed.candidates.map(\.externalTransactionID), [""])
        XCTAssertEqual(try commit(csv, in: ctx).importedCount, 1)
    }

    func testLegacyMerchantCorrectionPreservesOriginalSourceEvidence() throws {
        let ctx = try build33Ledger()
        let row = try XCTUnwrap(ctx.fetch(FetchDescriptor<FinanceTransaction>()).first)
        let categories = try ctx.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        var draft = TransactionDraft(transaction: row)
        draft.categoryID = try XCTUnwrap(categories.first { $0.kind == .expense && $0.parentID != nil && !$0.isHidden }).id
        draft.rawMerchantText = "商户乙"
        try TransactionLifecycleService.save(draft: draft, editing: row, accounts: [], categories: [], in: ctx)
        XCTAssertEqual(try plan(wacai(), in: ctx).duplicateCount, 1)
        XCTAssertEqual(try plan(wacai(merchant: "商户乙"), in: ctx).duplicateCount, 0)
    }

    func testGenericNonAccountingDirectionIsSkipped() throws {
        let ctx = try context()
        let csv = "type,amount,date_time,transaction_id\n支出,10.00,2026-10-15 12:00:00,a\n不计收支,10.00,2026-10-16 12:00:00,b"
        XCTAssertEqual(try plan(csv, in: ctx).skippedRows.first?.reason, .unsupportedDirection)
        XCTAssertEqual(try commit(csv, in: ctx).importedCount, 1)
        let rows = try ctx.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(rows.filter { $0.type == .expense }.count, 1)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.amountMinorUnits }, 1000)
    }

    func testExactTransactionIDTakesPrecedenceOverAccountID() throws {
        let ctx = try context()
        let header = "account_id,transaction_id,type,amount,date_time\n"
        try commit(header + "shared,txnA,expense,10.00,2026-10-15 12:00:00", in: ctx)
        let second = try plan(header + "shared,txnB,expense,20.00,2026-10-16 12:00:00", in: ctx)
        XCTAssertEqual(second.candidates.first?.externalTransactionID, "txnB")
        XCTAssertEqual(second.duplicateCount, 0)
    }
}
