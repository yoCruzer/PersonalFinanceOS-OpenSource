import CloudKit
import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class Build23ReviewRegressionTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func context() throws -> ModelContext { ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true)) }
    @discardableResult
    private func row(_ text: String, amount: Int64 = 2000, in c: ModelContext) -> FinanceTransaction {
        let value = FinanceTransaction(type: .expense, amountMinorUnits: amount, occurredAt: date(text), localDayKey: String(text.prefix(10)), timeZoneIdentifier: "GMT")
        c.insert(value); return value
    }

    func testR1ForegroundTransientActivationRecoversWithoutUserAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "icloudSyncConfirmedAccount.Development", saved = UserDefaults.standard.string(forKey: "icloudSyncConfirmedAccount.Development")
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("review-synthetic", forKey: key)
        let stopped = try PrivateCloudReplicaSession(stateURL: root.appendingPathComponent("old.json"), accountIdentifier: "review-synthetic", automaticallySync: false)
        let controller = ICloudSyncController(confirmedSession: stopped, identity: LedgerSyncIdentity(), identityURL: root.appendingPathComponent("identity.json"))
        let scheduled = expectation(description: "automatic activation backoff"), recovered = expectation(description: "second verification")
        var wake: CheckedContinuation<Void, Error>?, calls = 0
        controller.activationRetryWait = { delay in
            XCTAssertEqual(delay, 7)
            scheduled.fulfill()
            try await withCheckedThrowingContinuation { wake = $0 }
        }
        controller.activationVerification = {
            calls += 1
            if calls == 1 { throw CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 7.0]) }
            recovered.fulfill()
            return .init(environment: .development, account: "review-synthetic", root: root, automaticallySync: false)
        }
        controller.setForeground(true)
        await controller.activate()
        XCTAssertEqual(controller.status, .retrying)
        await fulfillment(of: [scheduled], timeout: 0.5)
        let retry = controller.activationRetryTask
        wake?.resume()
        await retry?.value
        if wake != nil { await fulfillment(of: [recovered], timeout: 1) }
        await controller.refreshStatus()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.displaySnapshot.engineAvailable)
        await controller.disable()
    }

    func testR2PublishedV4DiskReopenAllowsExactRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ModelConfiguration("ReviewV4", schema: AppSchema.schema, url: root.appendingPathComponent("ledger.store"), cloudKitDatabase: .none)
        try autoreleasepool {
            let c = ModelContext(try ModelContainerFactory.make(configuration: config))
            try seedPublishedV4(in: c)
        }
        let destination = try ModelContainerFactory.make(configuration: config), c = ModelContext(destination)
        try DefaultFinanceDataService.ensureDefaults(in: c)
        XCTAssertEqual(try c.fetchCount(FetchDescriptor<PersonalFinanceOS.Category>()), 233)
        XCTAssertEqual(try c.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining.fruit" }?.symbolName, "apple.logo")
        XCTAssertTrue(try pristine(c))
        let source = try context(); try seedFrozenV3Ledger(in: source)
        let tx = row("2026-10-02T10:00:00Z", in: source)
        tx.accountID = try source.fetch(FetchDescriptor<Account>()).first?.id
        tx.categoryID = try source.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.dining.lunch" }?.id
        try source.save()
        let backup = try await NativeBackupActor(modelContainer: source.container).exportData()
        let restored = try await NativeBackupActor(modelContainer: destination).restore(data: backup, admission: offlineRestoreTicket(for: destination))
        XCTAssertEqual(restored.insertedTransactionCount, 1)
        XCTAssertEqual(try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: ModelContext(destination))), try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: source)))
    }

    func testR3BothEvidencePeriodsExplicitDateSelectionMatchesIDsTotalsAndCSV() async throws {
        let c = try context(), asOf = date("2026-10-07T10:00:00Z")
        let timestamps = ["2025-08-01T10:00:00Z", "2026-09-02T10:00:00Z", "2026-09-07T11:00:00Z", "2026-10-02T10:00:00Z", "2026-10-07T11:00:00Z", "2026-10-20T10:00:00Z"]
        let rows = timestamps.enumerated().map { row($0.element, amount: Int64(($0.offset + 1) * 1000), in: c) }
        try c.save()
        let actor = LedgerAnalysisActor(modelContainer: c.container)
        let comparison = try await actor.recordedExpenseComparison(filter: .month(asOf, calendar: calendar), asOf: asOf, calendar: calendar)
        let periods = try XCTUnwrap(comparison).periods
        let ranges: [LocalDayRange?] = [LedgerFilter.month(asOf, calendar: calendar).dateRange, LocalDayRange(lowerBound: "2026-01-01", upperBound: "2027-01-01"), nil, LedgerRangeSelection.inclusiveRange(start: date("2026-09-07T00:00:00Z"), end: date("2026-10-20T00:00:00Z"), calendar: calendar)]
        for original in [periods.current, periods.previous] {
            for range in ranges {
                var edited = original; edited.revision = LedgerSaveRevision.shared.contentRevision
                edited.selectDateRange(range) // Same conversion called by every filter editor date action.
                XCTAssertNil(edited.occurredThrough)
                XCTAssertNil(edited.revision)
                XCTAssertEqual(edited.dateRange, range)
                var visibleRange = LedgerFilter(); visibleRange.dateRange = range
                XCTAssertEqual(edited.dateTitle(locale: Locale(identifier: "zh_CN")), visibleRange.dateTitle(locale: Locale(identifier: "zh_CN")))
                let expected = rows.filter { tx in range.map { r in tx.localDayKey >= r.lowerBound && tx.localDayKey < r.upperBound } ?? true }
                let snapshot = try await actor.snapshot(filter: edited)
                XCTAssertEqual(Set(snapshot.transactionIDs), Set(expected.map(\.id)))
                XCTAssertEqual(snapshot.totals.netExpenseMinorUnits, expected.reduce(0) { $0 + $1.amountMinorUnits })
                let csv = try await actor.exportData(snapshot: snapshot)
                XCTAssertEqual(csv.split(separator: 10).count, expected.count + 1)
                let text = String(decoding: csv, as: UTF8.self)
                for tx in rows { XCTAssertEqual(text.contains(tx.id.uuidString), expected.contains { $0.id == tx.id }) }
            }
        }
    }

    func testR4OldCancellationCannotClearNewComparison() async throws { try await ownershipRace(error: CancellationError(), roundTrip: false, revisionChange: false) }
    func testR4OldFailureCannotClearNewComparison() async throws { try await ownershipRace(error: CKError(.networkFailure), roundTrip: false, revisionChange: false) }
    func testR4SameRangeNewRevisionSurvivesOldFailure() async throws { try await ownershipRace(error: CKError(.networkFailure), roundTrip: false, revisionChange: true) }
    func testR4RangeRoundTripSurvivesOldFailure() async throws { try await ownershipRace(error: CKError(.networkFailure), roundTrip: true, revisionChange: false) }

    func testR4UncancelledStaleFailureCannotClearNewComparison() async throws { try await ownershipRace(error: CKError(.networkFailure), roundTrip: false, revisionChange: false, cancelOld: false) }
    func testR4UncancelledStaleSuccessCannotReplaceNewRevision() async throws { try await ownershipRace(error: nil, roundTrip: false, revisionChange: true, cancelOld: false) }

    private func ownershipRace(error: Error?, roundTrip: Bool, revisionChange: Bool, cancelOld: Bool = true) async throws {
        let c = try context(), asOf = date("2026-10-07T10:00:00Z")
        row("2026-09-02T10:00:00Z", in: c); row("2026-10-02T10:00:00Z", amount: 5000, in: c); try c.save()
        let actor = LedgerAnalysisActor(modelContainer: c.container), store = RecordedExpenseComparisonStore()
        let firstValue = try await actor.recordedExpenseComparison(filter: .month(asOf, calendar: calendar), asOf: asOf, calendar: calendar)
        let first = try XCTUnwrap(firstValue)
        let suspended = expectation(description: "A suspended")
        var finish: CheckedContinuation<RecordedExpenseComparison?, Error>?
        let a = Task { await store.reload(query: {
            try await withCheckedThrowingContinuation { finish = $0; suspended.fulfill() }
        }, accepts: { _ in true }) }
        await fulfillment(of: [suspended], timeout: 1)
        if cancelOld { a.cancel() }; store.clear()
        if roundTrip {
            let b = try await actor.recordedExpenseComparison(filter: .month(date("2026-09-02T10:00:00Z"), calendar: calendar), asOf: asOf, calendar: calendar)
            await store.reload(query: { b }, accepts: { _ in true })
            XCTAssertEqual(store.comparison?.periods.current.dateRange?.lowerBound, "2026-09-01")
            store.clear()
        }
        if revisionChange { row("2026-10-03T10:00:00Z", in: c); try c.save() }
        let latestValue = try await actor.recordedExpenseComparison(filter: .month(asOf, calendar: calendar), asOf: asOf, calendar: calendar)
        let latest = try XCTUnwrap(latestValue)
        if revisionChange { XCTAssertNotEqual(first.revision, latest.revision) }
        await store.reload(query: { latest }, accepts: { _ in true })
        XCTAssertEqual(store.comparison?.revision, latest.revision)
        if let error { finish?.resume(throwing: error) } else { finish?.resume(returning: first) }
        await a.value
        XCTAssertEqual(store.comparison?.facts.first?.delta, latest.facts.first?.delta)
        XCTAssertEqual(store.comparison?.revision, latest.revision)
        await store.reload(query: { throw CKError(.networkFailure) }, accepts: { _ in true })
        XCTAssertNil(store.comparison, "Current genuine failure hides its own result")
    }

    private func pristine(_ c: ModelContext) throws -> Bool {
        try DefaultFinanceDataService.isPristineBootstrap(accounts: c.fetch(FetchDescriptor<Account>()), categories: c.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), appMetadata: c.fetch(FetchDescriptor<AppMetadata>()))
    }
}

private struct PublishedV4Definition: Decodable {
    let key: String, parentKey: String?, kind: CategoryKind, name: String, symbol: String, color: String
    let sortOrder: Int, pinned: Bool
}

@MainActor
func seedPublishedV4(in c: ModelContext) throws {
    let url = try XCTUnwrap(Bundle(for: Build23ReviewRegressionTests.self).url(forResource: "published-v4-bootstrap-296f845", withExtension: "json"))
    let definitions = try JSONDecoder().decode([PublishedV4Definition].self, from: Data(contentsOf: url))
    XCTAssertEqual(definitions.count, 233)
    c.insert(Account(name: "日常账户", type: .other, isDefault: true))
    var ids: [String: UUID] = [:]
    for d in definitions {
        let category = PersonalFinanceOS.Category(kind: d.kind, name: d.name, parentID: d.parentKey.flatMap { ids[$0] }, defaultDefinitionKey: d.key, symbolName: d.symbol, colorToken: d.color, sortOrder: d.sortOrder, isPinnedForQuickAdd: d.pinned, isSystemCategory: true)
        c.insert(category); ids[d.key] = category.id
    }
    c.insert(AppMetadata(defaultCategorySeedVersion: 4)); try c.save()
}
