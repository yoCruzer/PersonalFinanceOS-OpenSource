import CloudKit
import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class LocalDiagnosticsTests: XCTestCase {
    func testAppBundleContainsExplicitGitBuildSetting() throws {
        let value = LocalDiagnostics.buildIdentity(bundle: .main).commit
        XCTAssertNotEqual(value, "unavailable")
        XCTAssertTrue(value.count == 40 && value.allSatisfy(\.isHexDigit))
        XCTAssertEqual(LocalDiagnostics().report().gitCommit, value)
    }

    func testJSONAllowlistExcludesRawInputNamesMoneyIDsAndUntrustedRuleIDs() throws {
        let store = LocalDiagnostics()
        let secret = "私密备注-商户-账户-123456789"
        let id = UUID()
        let suggestion = SmartTransactionSuggestion(categoryConfidence: .high, tagConfidence: .low,
            categoryID: id, tagIDs: [id], evidenceType: .builtInLexicon, score: 94, explanation: secret,
            alternatives: [.init(categoryID: id, score: 94, explanation: secret)],
            diagnosticRuleIDs: [secret], diagnosticMargin: 8)
        store.classification(noteLength: secret.count, merchantLength: secret.count, type: .expense,
            suggestion: suggestion, targetAvailable: true, manualLocked: false, modelEnabled: false, elapsed: .milliseconds(4))
        var filter = LedgerFilter(dateRange: nil)
        filter.query = secret
        filter.merchant = secret
        filter.accountID = id
        filter.category = .node(id)
        filter.tagIDs = [id]
        store.analysis(stage: .analysis, filter: filter, revision: 5, expectedCount: 2, actualCount: 2, elapsed: .milliseconds(3))
        let json = try store.json()
        for value in [secret, id.uuidString, "123456789", "normalizedNote", "normalizedMerchant", "inputFingerprint"] {
            XCTAssertFalse(json.contains(value), value)
        }
        XCTAssertTrue(json.contains("scoreMargin"))
        XCTAssertTrue(json.contains("countsMatch"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(LocalDiagnostics.Report.self, from: Data(json.utf8))
        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(report.entries[0].counts["noteLength"], secret.count)
        XCTAssertEqual(report.entries[0].counts["scoreMargin"], 8)
        XCTAssertEqual(report.entries[1].flags["countsMatch"], true)
        XCTAssertTrue(report.localOnly)
    }

    func testFingerprintIsStableWithinSessionIgnoresRevisionAndChangesAcrossSessions() {
        let first = LocalDiagnostics(), second = LocalDiagnostics()
        var filter = LedgerFilter(dateRange: nil)
        filter.query = "午餐"
        let tagA = UUID(), tagB = UUID()
        filter.tagIDs = [tagA, tagB]
        let fingerprint = first.fingerprint(filter)
        XCTAssertEqual(fingerprint.count, 64)
        filter.revision = 42
        filter.tagIDs = [tagB, tagA]
        XCTAssertEqual(first.fingerprint(filter), fingerprint)
        XCTAssertNotEqual(second.fingerprint(filter), fingerprint)
        filter.query = "晚餐"
        XCTAssertNotEqual(first.fingerprint(filter), fingerprint)
        filter.query = "午餐"
        filter.mode = .refund
        XCTAssertNotEqual(first.fingerprint(filter), fingerprint)
    }

    func testSessionRingIsBoundedAndReportsOnlyProvidedGitIdentity() throws {
        let store = LocalDiagnostics()
        for count in 0..<140 {
            store.analysis(stage: .analysis, filter: LedgerFilter(dateRange: nil), revision: UInt64(count),
                expectedCount: count, actualCount: count, elapsed: .zero)
        }
        let report = store.report()
        XCTAssertEqual(report.entries.count, 128)
        XCTAssertEqual(report.discardedEntryCount, 12)
        XCTAssertEqual(report.entries.first?.revision, 12)
        XCTAssertEqual(report.entries.last?.revision, 139)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-\(UUID()).bundle")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let commit = String(repeating: "a", count: 40)
        let info = ["CFBundleIdentifier": "test.diagnostic", "PFOSGitCommit": commit,
                    "CFBundleVersion": "10", "CFBundleShortVersionString": "2.0"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(path: directory.path))
        XCTAssertEqual(store.report(bundle: bundle).gitCommit, commit)
    }

    func testExportCreatesAtomicUTF8FileRetainsShareAndCleansOnlyExpiredDiagnostics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-export-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalDiagnostics()
        let secret = "private-\(UUID())-/secret/path-token-123456789"
        var filter = LedgerFilter(dateRange: nil)
        filter.query = secret
        filter.merchant = secret
        filter.accountID = UUID()
        filter.category = .node(UUID())
        store.analysis(stage: .analysis, filter: filter, revision: 1, expectedCount: 1, actualCount: 1, elapsed: .zero)
        let sync = ICloudSyncController.DisplaySnapshot(stage: .retrying, pendingChanges: 3, categoryDifferences: 0,
            lastUploadAt: nil, lastAppliedAt: nil, lastConfirmedAt: nil, errorCodes: [CKError.Code.networkUnavailable.rawValue])
        store.syncState(sync)
        let snapshot = store.report(sync: sync, catalogInstallation: .init(added: 4, installed: 5, skipped: 2, waiting: 0))
        let file = try DiagnosticFileStore.write(snapshot, root: root)
        let data = try Data(contentsOf: file)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for sentinel in [secret, filter.accountID!.uuidString, "123456789", "error.userInfo", "envelope"] {
            XCTAssertFalse(text.contains(sentinel), sentinel)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LocalDiagnostics.Report.self, from: data)
        XCTAssertEqual(decoded.sync, sync)
        XCTAssertEqual(decoded.catalogInstallation?.installed, 5)
        XCTAssertEqual(decoded.catalogVersion, 4)
        XCTAssertEqual(decoded.entries.count, 2)
        let failed = store.report(catalogInstallation: .init(added: 4, installed: 5, skipped: 2, waiting: 0), catalogCheckFailed: true)
        XCTAssertNil(failed.catalogInstallation, "A failed check cannot export stale installation success")
        XCTAssertTrue(failed.catalogCheckFailed)
        let second = try DiagnosticFileStore.write(snapshot, root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Sharing and a second export retain the first URL")
        let unrelated = root.appendingPathComponent("unrelated.json")
        try Data([1]).write(to: unrelated)
        let oldDate = Date().addingTimeInterval(-DiagnosticFileStore.retention - 100)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        _ = try DiagnosticFileStore.write(snapshot, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testActualAnalysisPagesAndExportShareFingerprintAndReconcileCounts() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        let secret = "诊断不得含完整输入-\(UUID())"
        let account = Account(name: "隐私账户-" + secret, type: .cash, currencyCode: "CNY")
        let category = Category(kind: .expense, name: "隐私分类-" + secret, symbolName: "folder", colorToken: "blue")
        context.insert(account)
        context.insert(category)
        try context.save()
        var draft = TransactionDraft()
        draft.type = .expense
        draft.amountText = "1234567.89"
        draft.accountID = account.id
        draft.categoryID = category.id
        draft.note = secret
        draft.rawMerchantText = "隐私商户-" + secret
        let transaction = try TransactionLifecycleService.save(draft: draft, accounts: [account], categories: [category], in: context)
        var filter = LedgerFilter(dateRange: nil)
        filter.query = secret
        let actor = LedgerAnalysisActor(modelContainer: context.container)
        let snapshot = try await actor.snapshot(filter: filter)
        _ = try await actor.page(snapshot: snapshot, offset: 0)
        _ = try await actor.exportData(snapshot: snapshot)
        let entries = Array(LocalDiagnostics.shared.report().entries.suffix(3))
        XCTAssertEqual(entries.map(\.stage), [.analysis, .page, .export])
        XCTAssertEqual(Set(entries.compactMap(\.filterFingerprint)).count, 1)
        XCTAssertTrue(entries.allSatisfy { $0.counts["actualRows"] == 1 && $0.flags["countsMatch"] == true })
        let json = try LocalDiagnostics.shared.json()
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains(transaction.id.uuidString))
        XCTAssertFalse(json.contains("123456789"))
        for prefix in ["隐私账户", "隐私分类", "隐私商户"] { XCTAssertFalse(json.contains(prefix)) }
    }

    func testConcurrentEventsRemainBoundedAndExportFailureIsReported() throws {
        let store = LocalDiagnostics()
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            store.analysis(stage: .analysis, filter: LedgerFilter(dateRange: nil), revision: UInt64(index),
                expectedCount: 1, actualCount: 1, elapsed: .zero)
            if index.isMultiple(of: 10) { _ = store.report() }
        }
        let report = store.report()
        XCTAssertEqual(report.entries.count, 128)
        XCTAssertEqual(report.discardedEntryCount, 872)
        XCTAssertEqual(Set(report.entries.map(\.operationID)).count, 128)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-invalid-root-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1]).write(to: file)
        XCTAssertThrowsError(try DiagnosticFileStore.write(report, root: file))
    }
}
