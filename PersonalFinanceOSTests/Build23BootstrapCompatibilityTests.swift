import CloudKit
import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class Build23BootstrapCompatibilityTests: XCTestCase {
    private func context() throws -> ModelContext { ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true)) }
    private func pristine(_ c: ModelContext) throws -> Bool {
        try DefaultFinanceDataService.isPristineBootstrap(accounts: c.fetch(FetchDescriptor<Account>()), categories: c.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), appMetadata: c.fetch(FetchDescriptor<AppMetadata>()))
    }

    func testPublishedV4CustomizationFieldsAllRemainProtected() async throws {
        let source = try context(); try seedFrozenV3Ledger(in: source)
        let backup = try await NativeBackupActor(modelContainer: source.container).exportData()
        let mutations: [(ModelContext, PersonalFinanceOS.Category) throws -> Void] = [
            { _, v in v.name = "自定义" }, { _, v in v.symbolName = "star" }, { _, v in v.parentID = nil },
            { _, v in v.colorToken = "purple" }, { _, v in v.isHidden = true },
            { _, v in v.isPinnedForQuickAdd.toggle() }, { _, v in v.sortOrder += 1 },
            { _, v in v.isSystemCategory = false }, { _, v in v.archivedAt = Date() },
            { c, v in c.delete(v) },
            { c, _ in c.insert(PersonalFinanceOS.Category(kind: .expense, name: "新用途", symbolName: "star", colorToken: "blue")) },
            { c, _ in try c.fetch(FetchDescriptor<AppMetadata>()).first?.deletedDefaultCategoryKeys.insert("expense.dining.fruit") }
        ]
        for mutate in mutations {
            let c = try context(); try seedPublishedV4(in: c)
            let fruit = try XCTUnwrap(c.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining.fruit" })
            try mutate(c, fruit); try c.save()
            XCTAssertFalse(try pristine(c))
            do { _ = try await NativeBackupActor(modelContainer: c.container).restore(data: backup, admission: offlineRestoreTicket(for: c.container)); XCTFail("Customized defaults must remain protected") }
            catch { XCTAssertEqual(error as? NativeBackupError, .destinationContainsUserLedger) }
        }
    }

    func testPublishedV4BusinessDataStillBlocksRestoreAndBootstrapAdoption() async throws {
        let source = try context(); try seedFrozenV3Ledger(in: source)
        let backup = try await NativeBackupActor(modelContainer: source.container).exportData()
        for entity in 0..<5 {
            let c = try context(); try seedPublishedV4(in: c)
            switch entity {
            case 0:
                let value = FinanceTransaction(type: .expense, amountMinorUnits: 100, occurredAt: Date(), localDayKey: "2026-10-07", timeZoneIdentifier: "GMT")
                c.insert(value)
            case 1: c.insert(Tag(name: "自定义标签", colorToken: "blue"))
            case 2: c.insert(Merchant(canonicalName: "商户", normalizedSearchKey: "商户"))
            case 3: c.insert(DailyReview(localDayKey: "2026-10-07", timeZoneIdentifier: "GMT"))
            default: c.insert(ImportBatch(sourceType: .wacai, sourceDisplayName: "synthetic.csv"))
            }
            try c.save()
            do { _ = try await NativeBackupActor(modelContainer: c.container).restore(data: backup, admission: offlineRestoreTicket(for: c.container)); XCTFail("Business data must remain protected") }
            catch { XCTAssertEqual(error as? NativeBackupError, .destinationContainsUserLedger) }
        }
    }

    func testPublishedV4FirstSyncAdoptsRemotePersonalizationWithoutUploadingDefaults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try context(); try seedPublishedV4(in: local)
        let remote = try context(); try seedPublishedV4(in: remote)
        let fruit = try XCTUnwrap(remote.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining.fruit" })
        fruit.name = "云端水果"; fruit.symbolName = "star"; try remote.save()
        var mapping = LedgerSyncIdentity(), cloud = ProtectedLedgerReplica(accountIdentifier: "bootstrap-fixture")
        try cloud.captureLocal(mapping.capture(LedgerSnapshotCodec.capture(in: remote)))
        let session = try PrivateCloudReplicaSession(stateURL: root.appendingPathComponent("state.json"), accountIdentifier: "bootstrap-fixture", automaticallySync: false)
        try await session.start(verifiedAccountIdentifier: "bootstrap-fixture")
        let engineValue = await session.engine, engine = try XCTUnwrap(engineValue)
        let records = try cloud.records.map { key, value -> CKRecord in
            let record = CKRecord(recordType: PrivateCloudReplicaSession.recordType, recordID: .init(recordName: PrivateCloudReplicaSession.recordName(for: key), zoneID: PrivateCloudReplicaSession.zoneID))
            record["envelope"] = try JSONEncoder().encode(PrivateCloudReplicaSession.Envelope(format: 1, accountIdentifier: "bootstrap-fixture", key: key, record: value)) as CKRecordValue
            return record
        }
        try await session.receiveRemoteRecords(records, syncEngine: engine)
        try await session.recordFetchCompletion(succeeded: true, syncEngine: engine)
        let controller = ICloudSyncController(confirmedSession: session, identity: LedgerSyncIdentity(), identityURL: root.appendingPathComponent("identity.json"))
        await controller.reconcile(in: local, changes: LedgerChangeCenter())
        XCTAssertNil(controller.categoryReview)
        XCTAssertEqual(controller.status, .enabled)
        let actual = try ModelContext(local.container).fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertEqual(actual.count, 233)
        XCTAssertEqual(actual.first { $0.defaultDefinitionKey == "expense.dining.fruit" }?.name, "云端水果")
        XCTAssertEqual(actual.first { $0.defaultDefinitionKey == "expense.dining.fruit" }?.symbolName, "star")
        let evidence = await session.syncEvidence()
        XCTAssertEqual(evidence.pendingUploads, 0, "Unused local defaults must not overwrite cloud personalization")
        await controller.disable()
    }
}
