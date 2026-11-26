import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class NativeBackupTests: XCTestCase {
    func testNativeRestoreAfterFreshInstallBootstrapIsExactAndIdempotent() async throws {
        let source = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let sourceContext = ModelContext(source)
        try DefaultFinanceDataService.ensureDefaults(in: sourceContext)
        let fixture = try insertFixture(in: sourceContext)

        let exporter = NativeBackupActor(modelContainer: source)
        let exportedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try await exporter.exportData(exportedAt: exportedAt)
        let sourceSnapshot = try semanticSnapshot(data)
        let sourceFinanceSnapshot = try financeSnapshot(in: sourceContext)
        let preview = try NativeBackupService.preview(data: data)
        XCTAssertEqual(preview.transactionCount, 5)
        XCTAssertEqual(preview.activeTransactionCount, 4)
        XCTAssertEqual(preview.deletedTransactionCount, 1)

        let destination = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let bootstrapContext = ModelContext(destination)
        try DefaultFinanceDataService.ensureDefaults(in: bootstrapContext)
        let restorer = NativeBackupActor(modelContainer: destination)
        let result = try await restorer.restore(data: data, admission: offlineRestoreTicket(for: destination))
        XCTAssertEqual(result.insertedTransactionCount, 5)
        XCTAssertEqual(result.insertedDeletedTransactionCount, 1)

        let context = ModelContext(destination)
        let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
        let byID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        let expense = try XCTUnwrap(byID[fixture.expenseID])
        let income = try XCTUnwrap(byID[fixture.incomeID])
        let refund = try XCTUnwrap(byID[fixture.refundID])
        let transfer = try XCTUnwrap(byID[fixture.transferID])
        let deleted = try XCTUnwrap(byID[fixture.deletedID])

        XCTAssertEqual(expense.type, .expense)
        XCTAssertEqual(expense.amountMinorUnits, 1_021)
        XCTAssertEqual(expense.currencyCode, "CNY")
        XCTAssertEqual(expense.occurredAt, fixture.shanghai1021)
        XCTAssertEqual(expense.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(expense.localDayKey, "2026-08-18")
        XCTAssertEqual(localHourMinute(expense), [10, 21])
        XCTAssertEqual(expense.rawMerchantText, "早餐店原文")
        XCTAssertEqual(expense.note, "10:21 round trip")
        XCTAssertEqual(expense.categoryDecisionSource, .manualConfirmed)
        XCTAssertEqual(expense.reviewStatus, .needsReview)
        XCTAssertEqual(expense.reviewReasons, [.userMarked])
        XCTAssertEqual(Set(expense.tags.map(\.name)), ["工作", "报销"])
        XCTAssertEqual(expense.externalSource, .wacai)
        XCTAssertEqual(expense.externalTransactionID, "native-expense")
        XCTAssertEqual(expense.importFingerprint, "native-expense-fingerprint")
        XCTAssertEqual(expense.importBatchID, fixture.batchID)
        XCTAssertEqual(expense.createdAt, fixture.createdAt)
        XCTAssertEqual(expense.updatedAt, fixture.updatedAt)

        XCTAssertEqual(income.type, .income)
        XCTAssertEqual(income.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(income.localDayKey, "2026-07-31")
        XCTAssertEqual(localHourMinute(income), [23, 30])
        XCTAssertEqual(refund.type, .refund)
        XCTAssertEqual(refund.relatedTransactionID, expense.id)
        XCTAssertEqual(refund.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(refund.localDayKey, "2026-12-31")
        XCTAssertEqual(localHourMinute(refund), [23, 30])

        XCTAssertEqual(transfer.type, .transfer)
        XCTAssertEqual(transfer.currencyCode, "USD")
        XCTAssertEqual(transfer.accountID, fixture.usdSourceID)
        XCTAssertEqual(transfer.destinationAccountID, fixture.usdDestinationID)
        XCTAssertNil(transfer.categoryID)
        XCTAssertEqual(deleted.deletedAt, fixture.deletedAt)
        XCTAssertEqual(deleted.externalTransactionID, "native-deleted")

        let package = try NativeBackupService.decode(data)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Account>()).count, package.accounts.count)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).count,
            package.categories.count
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<Tag>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Merchant>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ImportBatch>()).map(\.id), [fixture.batchID])

        let accounts = try context.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accounts.filter(\.isDefault).map(\.id), [fixture.cnySourceID])
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let seededKeys = categories.map(\.defaultDefinitionKey).filter { !$0.isEmpty }
        XCTAssertEqual(Set(seededKeys).count, seededKeys.count)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AppMetadata>()).count, 1)
        XCTAssertTrue(transactions.compactMap(\.relatedTransactionID).allSatisfy {
            byID[$0] != nil
        })
        XCTAssertTrue(transactions.filter { $0.type == .transfer }.allSatisfy {
            $0.accountID.flatMap { id in accounts.first { $0.id == id } } != nil &&
            $0.destinationAccountID.flatMap { id in accounts.first { $0.id == id } } != nil
        })
        XCTAssertEqual(try financeSnapshot(in: context), sourceFinanceSnapshot)
        let restoredData = try await NativeBackupActor(modelContainer: destination).exportData(
            exportedAt: exportedAt
        )
        XCTAssertEqual(try semanticSnapshot(restoredData), sourceSnapshot)

        try DefaultFinanceDataService.ensureDefaults(in: context)
        let idempotentData = try await NativeBackupActor(modelContainer: destination).exportData(
            exportedAt: exportedAt
        )
        XCTAssertEqual(try semanticSnapshot(idempotentData), sourceSnapshot)
        XCTAssertEqual(try financeSnapshot(in: context), sourceFinanceSnapshot)
    }

    func testNativeRestoreRejectsNonEmptyUserLedgerWithoutMutation() async throws {
        let source = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let sourceContext = ModelContext(source)
        try DefaultFinanceDataService.ensureDefaults(in: sourceContext)
        _ = try insertFixture(in: sourceContext)
        let data = try await NativeBackupActor(modelContainer: source).exportData()

        let destination = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(destination)
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first)
        let category = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first {
            $0.kind == .expense && $0.parentID != nil
        })
        let userTag = Tag(name: "用户标签")
        context.insert(userTag)
        let existingOccurredAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-18T10:21:00+08:00")
        )
        context.insert(FinanceTransaction(
            type: .expense,
            amountMinorUnits: 1_021,
            currencyCode: "CNY",
            occurredAt: existingOccurredAt,
            localDayKey: "2026-08-18",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: account.id,
            categoryID: category.id,
            note: "existing user ledger",
            tags: [userTag]
        ))
        try context.save()

        let snapshotDate = Date(timeIntervalSince1970: 1_900_000_000)
        let beforeData = try await NativeBackupActor(modelContainer: destination).exportData(
            exportedAt: snapshotDate
        )
        let before = try semanticSnapshot(beforeData)
        let beforeFinance = try financeSnapshot(in: context)
        do {
            _ = try await NativeBackupActor(modelContainer: destination).restore(data: data, admission: offlineRestoreTicket(for: destination))
            XCTFail("Expected exact restore to reject an existing user ledger")
        } catch {
            XCTAssertEqual(error as? NativeBackupError, .destinationContainsUserLedger)
        }
        let afterData = try await NativeBackupActor(modelContainer: destination).exportData(
            exportedAt: snapshotDate
        )
        let after = try semanticSnapshot(afterData)
        XCTAssertEqual(after, before)
        XCTAssertEqual(try financeSnapshot(in: context), beforeFinance)
    }

    func testNativeExportRejectsDanglingReferenceWithoutLeavingShareableFile() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first)
        let category = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first {
            $0.kind == .expense && $0.parentID != nil
        })
        let occurredAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-18T10:21:00+08:00")
        )
        context.insert(FinanceTransaction(
            type: .refund,
            amountMinorUnits: 100,
            occurredAt: occurredAt,
            localDayKey: "2026-08-18",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: account.id,
            categoryID: category.id,
            relatedTransactionID: UUID()
        ))
        try context.save()

        let fileName = "invalid-native-backup-\(UUID().uuidString).json"
        let expectedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalFinanceOSExports", isDirectory: true)
            .appendingPathComponent(fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedURL.path))
        do {
            _ = try await NativeBackupActor(modelContainer: container).export(fileName: fileName)
            XCTFail("Expected dangling relation validation to fail")
        } catch {
            XCTAssertEqual(
                error as? NativeBackupError,
                .invalidReference("transaction.relatedTransactionID")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedURL.path))
    }

    func testNativeExportRejectsInvalidFinanceAndDateSemantics() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>()).first)
        let category = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first {
            $0.kind == .expense && $0.parentID != nil
        })
        let occurredAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-18T10:21:00+08:00")
        )
        context.insert(FinanceTransaction(
            type: .expense,
            amountMinorUnits: 0,
            occurredAt: occurredAt,
            localDayKey: "2099-01-01",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: account.id,
            categoryID: category.id
        ))
        try context.save()

        do {
            _ = try await NativeBackupActor(modelContainer: container).exportData()
            XCTFail("Expected invalid finance/date semantics to fail export")
        } catch {
            XCTAssertEqual(
                error as? NativeBackupError,
                .invalidReference("transaction finance/date semantics")
            )
        }
    }

    func testNativeBackupFileLoadReadsDecodesAndValidatesOffMainThread() async throws {
        let source = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(source)
        try DefaultFinanceDataService.ensureDefaults(in: context)
        _ = try insertFixture(in: context)
        let data = try await NativeBackupActor(modelContainer: source).exportData()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-load-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try await NativeBackupFileLoader.load(from: url) { url in
            guard !Thread.isMainThread else { throw NativeBackupIsolationError.mainThread }
            return try Data(contentsOf: url)
        }

        XCTAssertEqual(loaded.data, data)
        XCTAssertEqual(loaded.preview.transactionCount, 5)
    }

    private func semanticSnapshot(_ data: Data) throws -> Data {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        for key in [
            "accounts", "categories", "tags", "merchants", "importBatches",
            "transactions", "dailyReviews", "appMetadata"
        ] {
            guard var rows = root[key] as? [[String: Any]] else { continue }
            rows.sort {
                ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "")
            }
            root[key] = rows
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func financeSnapshot(in context: ModelContext) throws -> NativeFinanceSnapshot {
        let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
        let active = transactions.filter { $0.deletedAt == nil }
        return NativeFinanceSnapshot(
            transactionCount: transactions.count,
            activeTransactionCount: active.count,
            deletedTransactionCount: transactions.count - active.count,
            netExpenseMinorUnits: StatisticsFoundation.netExpenseMinorUnits(for: active)
        )
    }

    private func localHourMinute(_ transaction: FinanceTransaction) -> [Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: transaction.timeZoneIdentifier)!
        let components = calendar.dateComponents([.hour, .minute], from: transaction.occurredAt)
        return [components.hour!, components.minute!]
    }

    private func insertFixture(in context: ModelContext) throws -> Fixture {
        for account in try context.fetch(FetchDescriptor<Account>()) {
            account.isDefault = false
        }
        let createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let deletedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let shanghai1021 = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-18T10:21:00+08:00")
        )
        let losAngelesCrossMonth = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-31T23:30:00-07:00")
        )
        let newYorkCrossYear = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-12-31T23:30:00-05:00")
        )
        let cnySource = Account(
            id: UUID(), name: "现金", type: .cash, currencyCode: "CNY",
            isDefault: true, createdAt: createdAt, updatedAt: updatedAt
        )
        let cnyDestination = Account(
            id: UUID(), name: "银行卡", type: .bankCard, currencyCode: "CNY",
            createdAt: createdAt, updatedAt: updatedAt
        )
        let usdSource = Account(
            id: UUID(), name: "USD Cash", type: .cash, currencyCode: "USD",
            createdAt: createdAt, updatedAt: updatedAt
        )
        let usdDestination = Account(
            id: UUID(), name: "USD Bank", type: .bankCard, currencyCode: "USD",
            archivedAt: deletedAt, createdAt: createdAt, updatedAt: updatedAt
        )
        let expenseCategory = Category(
            id: UUID(), kind: .expense, name: "餐饮", symbolName: "fork.knife",
            colorToken: "orange", createdAt: createdAt, updatedAt: updatedAt
        )
        let incomeCategory = Category(
            id: UUID(), kind: .income, name: "工资", symbolName: "banknote",
            colorToken: "green", archivedAt: deletedAt,
            createdAt: createdAt, updatedAt: updatedAt
        )
        let work = Tag(name: "工作", createdAt: createdAt, updatedAt: updatedAt)
        let reimbursable = Tag(
            name: "报销", archivedAt: deletedAt, createdAt: createdAt, updatedAt: updatedAt
        )
        let merchant = Merchant(
            canonicalName: "早餐店", normalizedSearchKey: "breakfast",
            createdAt: createdAt, updatedAt: updatedAt
        )
        let batch = ImportBatch(
            sourceType: .wacai, sourceDisplayName: "native-fixture",
            sourceFormatVersion: "v1", startedAt: createdAt, completedAt: updatedAt,
            status: .completed, totalRowCount: 2, importedRowCount: 2,
            createdAt: createdAt, updatedAt: updatedAt
        )
        let expenseID = UUID()
        let incomeID = UUID()
        let refundID = UUID()
        let transferID = UUID()
        let deletedID = UUID()
        let expense = FinanceTransaction(
            id: expenseID, type: .expense, amountMinorUnits: 1_021,
            occurredAt: shanghai1021, localDayKey: "2026-08-18",
            timeZoneIdentifier: "Asia/Shanghai", accountID: cnySource.id,
            categoryID: expenseCategory.id, merchantID: merchant.id,
            rawMerchantText: "早餐店原文", note: "10:21 round trip",
            categoryDecisionSource: .manualConfirmed, reviewStatus: .needsReview,
            reviewReasons: [.userMarked], importBatchID: batch.id,
            externalSource: .wacai, externalTransactionID: "native-expense",
            importFingerprint: "native-expense-fingerprint",
            createdAt: createdAt, updatedAt: updatedAt, tags: [work, reimbursable]
        )
        let income = FinanceTransaction(
            id: incomeID, type: .income, amountMinorUnits: 500_000,
            occurredAt: losAngelesCrossMonth, localDayKey: "2026-07-31",
            timeZoneIdentifier: "America/Los_Angeles", accountID: cnyDestination.id,
            categoryID: incomeCategory.id, note: "DST UTC cross-month",
            createdAt: createdAt, updatedAt: updatedAt
        )
        let refund = FinanceTransaction(
            id: refundID, type: .refund, amountMinorUnits: 321,
            occurredAt: newYorkCrossYear, localDayKey: "2026-12-31",
            timeZoneIdentifier: "America/New_York", accountID: cnySource.id,
            categoryID: expenseCategory.id, note: "standard-time UTC cross-day",
            relatedTransactionID: expenseID, createdAt: createdAt, updatedAt: updatedAt
        )
        let transfer = FinanceTransaction(
            id: transferID, type: .transfer, amountMinorUnits: 12_345,
            currencyCode: "USD", occurredAt: shanghai1021, localDayKey: "2026-08-18",
            timeZoneIdentifier: "Asia/Shanghai", accountID: usdSource.id,
            destinationAccountID: usdDestination.id, note: "preserve transfer",
            createdAt: createdAt, updatedAt: updatedAt
        )
        let deleted = FinanceTransaction(
            id: deletedID, type: .expense, amountMinorUnits: 999,
            occurredAt: shanghai1021, localDayKey: "2026-08-18",
            timeZoneIdentifier: "Asia/Shanghai", accountID: cnySource.id,
            categoryID: expenseCategory.id, externalSource: .genericCSV,
            externalTransactionID: "native-deleted", importFingerprint: "native-deleted-fp",
            createdAt: createdAt, updatedAt: deletedAt, deletedAt: deletedAt
        )

        [cnySource, cnyDestination, usdSource, usdDestination].forEach(context.insert)
        [expenseCategory, incomeCategory].forEach(context.insert)
        [work, reimbursable].forEach(context.insert)
        context.insert(merchant)
        context.insert(batch)
        [expense, income, refund, transfer, deleted].forEach(context.insert)
        try context.save()
        return Fixture(
            expenseID: expenseID, incomeID: incomeID, refundID: refundID,
            transferID: transferID, deletedID: deletedID, batchID: batch.id,
            cnySourceID: cnySource.id, usdSourceID: usdSource.id,
            usdDestinationID: usdDestination.id, shanghai1021: shanghai1021,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt
        )
    }
}

private struct Fixture {
    let expenseID: UUID
    let incomeID: UUID
    let refundID: UUID
    let transferID: UUID
    let deletedID: UUID
    let batchID: UUID
    let cnySourceID: UUID
    let usdSourceID: UUID
    let usdDestinationID: UUID
    let shanghai1021: Date
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date
}

private struct NativeFinanceSnapshot: Equatable {
    let transactionCount: Int
    let activeTransactionCount: Int
    let deletedTransactionCount: Int
    let netExpenseMinorUnits: Int64
}

private enum NativeBackupIsolationError: Error {
    case mainThread
}
