import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class Build14ImportCorrectnessTests: XCTestCase {
    func testRefundDescriptionKeepsRefundTypeThroughPreviewRequestAndCommit() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let breakfast = try XCTUnwrap(categories.first { $0.defaultDefinitionKey == "expense.dining.breakfast" })
        let snapshot = FinanceCSVService.makeImportModelSnapshot(accounts: accounts, categories: categories, tags: [])
        let csv = """
        transaction_id,type,amount,currency,category,account,date_time,note
        refund-breakfast,refund,12.34,CNY,,现金,2026-08-18 10:21:00,早餐退款
        expense-breakfast,expense,12.34,CNY,,现金,2026-08-18 10:22:00,早餐退款
        """
        let document = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: "refund.csv")
        let plan = try FinanceCSVService.makePlan(
            document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "refund.csv",
            existingTransactions: [],
            parserMode: .generic
        )
        let row = try XCTUnwrap(plan.candidates.first { $0.type == .refund })
        let expense = try XCTUnwrap(plan.candidates.first { $0.type == .expense })
        XCTAssertEqual(row.type, .refund)
        let preview = try FinanceCSVService.makePreviewSnapshot(
            plan: plan, modelSnapshot: snapshot,
            includeSuspectedDuplicates: true, includeConfirmedDuplicates: false,
            rememberedCategoryMappings: [:], rowCategoryOverrides: [:]
        )
        XCTAssertEqual(preview.resolutionsByRowNumber[row.rowNumber]?.resolvedCategoryID, breakfast.id)
        XCTAssertNil(preview.resolutionsByRowNumber[expense.rowNumber]?.resolvedCategoryID)
        let request = try FinanceCSVService.makeBackgroundCommitRequest(
            plan: plan, modelSnapshot: snapshot, rememberedCategoryMappings: [:]
        )
        XCTAssertEqual(request.transactions.first { $0.type == .refund }?.categoryID, breakfast.id)
        XCTAssertNil(request.transactions.first { $0.type == .expense }?.categoryID)
        _ = try await ImportCommitActor(modelContainer: container).commit(request)
        let imported = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>())
            .first { $0.externalTransactionID == "refund-breakfast" })
        XCTAssertEqual(imported.type, .refund)
        XCTAssertEqual(imported.amountMinorUnits, 1_234)
        XCTAssertEqual(imported.externalTransactionID, "refund-breakfast")
        XCTAssertEqual(imported.categoryID, breakfast.id)

        // An upgraded ledger can retain archived legacy categories and transactions.
        let legacyCategory = PersonalFinanceOS.Category(
            kind: .expense, name: "旧账类别", symbolName: "archivebox", colorToken: "gray",
            archivedAt: Date()
        )
        let legacyTransaction = FinanceTransaction(
            type: .expense, amountMinorUnits: 500, occurredAt: Date(),
            localDayKey: "2026-08-18", timeZoneIdentifier: "Asia/Shanghai",
            accountID: try XCTUnwrap(accounts.first).id,
            categoryID: legacyCategory.id,
            note: "旧账记录"
        )
        context.insert(legacyCategory)
        context.insert(legacyTransaction)
        try context.save()
        let upgradedCSV = csv.replacingOccurrences(of: "refund-breakfast,refund", with: "refund-breakfast-upgraded,refund")
            .components(separatedBy: "\n")
            .prefix(2)
            .joined(separator: "\n")
        let upgradedDocument = try FinanceCSVService.readImportDocument(
            data: Data(upgradedCSV.utf8), fileName: "upgraded-refund.csv"
        )
        let upgradedPlan = try FinanceCSVService.makePlan(
            document: upgradedDocument,
            mapping: FinanceCSVService.autoMapping(headers: upgradedDocument.headers),
            fileName: "upgraded-refund.csv",
            existingTransactions: [], parserMode: .generic
        )
        let upgradedSnapshot = FinanceCSVService.makeImportModelSnapshot(
            accounts: accounts,
            categories: try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()),
            tags: []
        )
        let upgradedPreview = try FinanceCSVService.makePreviewSnapshot(
            plan: upgradedPlan, modelSnapshot: upgradedSnapshot,
            includeSuspectedDuplicates: true, includeConfirmedDuplicates: false,
            rememberedCategoryMappings: [:], rowCategoryOverrides: [:]
        )
        let upgradedRow = try XCTUnwrap(upgradedPlan.candidates.first)
        XCTAssertEqual(upgradedPreview.resolutionsByRowNumber[upgradedRow.rowNumber]?.resolvedCategoryID, breakfast.id)
        let upgradedRequest = try FinanceCSVService.makeBackgroundCommitRequest(
            plan: upgradedPlan, modelSnapshot: upgradedSnapshot, rememberedCategoryMappings: [:]
        )
        _ = try await ImportCommitActor(modelContainer: container).commit(upgradedRequest)
        let bothRefunds = try context.fetch(FetchDescriptor<FinanceTransaction>())
            .filter { $0.type == .refund }
        XCTAssertEqual(bothRefunds.count, 2)
        XCTAssertTrue(bothRefunds.allSatisfy { $0.categoryID == breakfast.id && $0.amountMinorUnits == 1_234 })
        XCTAssertEqual(legacyTransaction.categoryID, legacyCategory.id)
    }

    func testCSVExportRestoreThroughProductionActorKeeps1021LocalTime() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let occurredAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-18T10:21:00+08:00")
        )
        let source = try makeContainer()
        let sourceContext = ModelContext(source)
        let account = Account(name: "现金", type: .cash, isDefault: true)
        let category = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let transaction = FinanceTransaction(
            type: .expense,
            amountMinorUnits: 1_021,
            occurredAt: occurredAt,
            localDayKey: "2026-08-18",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: account.id,
            categoryID: category.id,
            note: "csv-10:21"
        )
        sourceContext.insert(account)
        sourceContext.insert(category)
        sourceContext.insert(transaction)
        try sourceContext.save()

        let data = FinanceCSVService.exportData(
            transactions: [transaction],
            categories: [category],
            accounts: [account]
        )
        let document = try FinanceCSVService.readImportDocument(
            data: data,
            fileName: "PersonalFinanceOS.csv"
        )
        let mapping = FinanceCSVService.autoMapping(headers: document.headers)
        let plan = try FinanceCSVService.makePlan(
            document: document,
            mapping: mapping,
            fileName: "PersonalFinanceOS.csv",
            existingRecords: [],
            parserMode: .generic,
            calendar: calendar
        )
        let candidate = try XCTUnwrap(plan.candidates.first)
        XCTAssertEqual(candidate.occurredAt, occurredAt)
        XCTAssertEqual(candidate.timeZoneIdentifier, "Asia/Shanghai")

        let destination = try makeContainer()
        let destinationContext = ModelContext(destination)
        let destinationAccount = Account(name: "现金", type: .cash, isDefault: true)
        let destinationCategory = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        destinationContext.insert(destinationAccount)
        destinationContext.insert(destinationCategory)
        try destinationContext.save()
        let snapshot = FinanceCSVService.makeImportModelSnapshot(
            accounts: [destinationAccount],
            categories: [destinationCategory],
            tags: []
        )
        let request = try FinanceCSVService.makeBackgroundCommitRequest(
            plan: plan,
            modelSnapshot: snapshot,
            rememberedCategoryMappings: [:]
        )
        let result = try await ImportCommitActor(modelContainer: destination).commit(request)
        XCTAssertEqual(result.importedCount, 1)

        let restored = try XCTUnwrap(
            destinationContext.fetch(FetchDescriptor<FinanceTransaction>()).first
        )
        XCTAssertEqual(restored.occurredAt, occurredAt)
        XCTAssertEqual(restored.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(restored.localDayKey, "2026-08-18")
        calendar.timeZone = TimeZone(identifier: restored.timeZoneIdentifier)!
        let components = calendar.dateComponents([.hour, .minute], from: restored.occurredAt)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 21)
    }

    func testLegacyCSVUTCDateUsesRestoreDeviceTimeZoneWithoutHardcodedOffset() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let csv = """
        transaction_id,type,amount,currency,category,category_icon,account,date_time,note,tags,created_at,updated_at
        legacy-1,expense,12.34,CNY,Food,fork.knife,Cash,2026-08-01T06:30:00Z,legacy,,2026-08-01T06:30:00Z,2026-08-01T06:30:00Z
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8),
            fileName: "PersonalFinanceOS_legacy.csv"
        )
        XCTAssertTrue(FinanceCSVService.isLegacyPersonalFinanceOSCSV(headers: document.headers))
        let plan = try FinanceCSVService.makePlan(
            document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "PersonalFinanceOS_legacy.csv",
            existingRecords: [],
            parserMode: .generic,
            calendar: calendar
        )
        let candidate = try XCTUnwrap(plan.candidates.first)
        XCTAssertEqual(candidate.timeZoneIdentifier, "America/Los_Angeles")
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: candidate.occurredAt)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 31)
        XCTAssertEqual(components.hour, 23)
        XCTAssertEqual(components.minute, 30)
    }

    func testGenericCSVWithPartialCommonFieldsPreservesExplicitTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let csv = """
        transaction_id,type,amount,currency,date_time,created_at,updated_at,third_party_field
        generic-1,expense,12.34,CNY,2026-08-01T06:30:00Z,2026-08-01T06:30:00Z,2026-08-01T06:30:00Z,vendor
        generic-2,expense,10.21,CNY,2026-08-18T10:21:00+08:00,2026-08-18T10:21:00+08:00,2026-08-18T10:21:00+08:00,vendor
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8),
            fileName: "third-party.csv"
        )
        XCTAssertFalse(FinanceCSVService.isLegacyPersonalFinanceOSCSV(headers: document.headers))
        let parsed = try FinanceCSVService.parsePlan(
            document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "third-party.csv",
            parserMode: .generic,
            calendar: calendar
        )
        XCTAssertEqual(parsed.candidates.count, 2)
        let utc = try XCTUnwrap(TimeZone(identifier: parsed.candidates[0].timeZoneIdentifier))
        XCTAssertEqual(utc.secondsFromGMT(for: parsed.candidates[0].occurredAt), 0)
        let plusEight = try XCTUnwrap(TimeZone(identifier: parsed.candidates[1].timeZoneIdentifier))
        XCTAssertEqual(plusEight.secondsFromGMT(for: parsed.candidates[1].occurredAt), 8 * 60 * 60)
        var plusEightCalendar = calendar
        plusEightCalendar.timeZone = plusEight
        let components = plusEightCalendar.dateComponents(
            [.hour, .minute],
            from: parsed.candidates[1].occurredAt
        )
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 21)
    }

    func testBuild14CSVHeaderDoesNotEnterLegacyMode() {
        XCTAssertFalse(FinanceCSVService.isLegacyPersonalFinanceOSCSV(
            headers: FinanceCSVService.exportHeaders
        ))
    }

    func testSoftDeletedCrossDateSourceIdentityStillBlocksReimport() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let container = try makeContainer()
        let context = ModelContext(container)
        let deleted = FinanceTransaction(
            type: .expense,
            amountMinorUnits: 1_000,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            localDayKey: "2027-01-14",
            timeZoneIdentifier: "UTC",
            externalSource: .genericCSV,
            externalTransactionID: "authoritative-A",
            importFingerprint: "deleted-A-fingerprint",
            deletedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        context.insert(deleted)
        try context.save()
        let csv = """
        transaction_id,type,amount,date_time,note
        authoritative-A,expense,10.00,2027-01-15 08:00:00,reimport
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8),
            fileName: "generic.csv"
        )
        let parsed = try FinanceCSVService.parsePlan(
            document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "generic.csv",
            parserMode: .generic,
            calendar: calendar
        )
        let duplicateRecords = try await ImportPlanningActor(
            modelContainer: container
        ).duplicateRecords(for: parsed)
        let plan = FinanceCSVService.assessDuplicates(parsed, existingRecords: duplicateRecords)

        XCTAssertEqual(plan.duplicateCount, 1)
        XCTAssertEqual(plan.candidates.first?.duplicateAssessment, .authoritativeExisting)
        XCTAssertTrue(plan.effectiveRowsToImport(
            includeSuspectedDuplicates: true,
            includeConfirmedDuplicates: false
        ).isEmpty)
    }

    func testActiveCrossDateSourceIdentityStillBlocksReimport() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(FinanceTransaction(
            type: .expense,
            amountMinorUnits: 1_000,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            localDayKey: "2023-11-14",
            timeZoneIdentifier: "UTC",
            externalSource: .genericCSV,
            externalTransactionID: "active-cross-date",
            importFingerprint: "old-fingerprint"
        ))
        try context.save()
        let csv = """
        transaction_id,type,amount,date_time,note
        active-cross-date,expense,10.00,2027-01-15 08:00:00,reimport
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8), fileName: "generic.csv"
        )
        let parsed = try FinanceCSVService.parsePlan(
            document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "generic.csv",
            parserMode: .generic,
            calendar: calendar
        )
        let records = try await ImportPlanningActor(modelContainer: container)
            .duplicateRecords(for: parsed)
        let plan = FinanceCSVService.assessDuplicates(parsed, existingRecords: records)

        XCTAssertEqual(plan.candidates.first?.duplicateAssessment, .authoritativeExisting)
        XCTAssertEqual(plan.duplicateCount, 1)
    }

    func testCrossDateFingerprintStillBlocksReimport() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let csv = """
        type,amount,date_time,note
        expense,10.00,2027-01-15 08:00:00,fingerprint
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8), fileName: "generic.csv"
        )
        let parsed = try FinanceCSVService.parsePlan(
            document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "generic.csv",
            parserMode: .generic,
            calendar: calendar
        )
        let candidate = try XCTUnwrap(parsed.candidates.first)
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(FinanceTransaction(
            type: .expense,
            amountMinorUnits: 999,
            occurredAt: Date(timeIntervalSince1970: 1_600_000_000),
            localDayKey: "2020-09-13",
            timeZoneIdentifier: "UTC",
            externalSource: .genericCSV,
            importFingerprint: candidate.fingerprint,
            deletedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try context.save()

        let records = try await ImportPlanningActor(modelContainer: container)
            .duplicateRecords(for: parsed)
        let plan = FinanceCSVService.assessDuplicates(parsed, existingRecords: records)

        XCTAssertEqual(plan.candidates.first?.duplicateAssessment, .exactFingerprintExisting)
        XCTAssertEqual(plan.duplicateCount, 1)
    }

    func testSuspectedDuplicateQueryRemainsBoundedAndDoesNotFetchUnrelatedHistory() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let csv = """
        type,amount,date_time,note
        expense,10.00,2027-01-15 08:00:00,suspected
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8), fileName: "generic.csv"
        )
        let parsed = try FinanceCSVService.parsePlan(
            document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "generic.csv",
            parserMode: .generic,
            calendar: calendar
        )
        let candidate = try XCTUnwrap(parsed.candidates.first)
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(FinanceTransaction(
            type: .expense,
            amountMinorUnits: candidate.amountMinorUnits,
            occurredAt: candidate.occurredAt,
            localDayKey: "2027-01-15",
            timeZoneIdentifier: "UTC",
            note: candidate.persistedNote
        ))
        for index in 0..<1_000 {
            context.insert(FinanceTransaction(
                type: .expense,
                amountMinorUnits: Int64(index + 1),
                occurredAt: Date(timeIntervalSince1970: TimeInterval(1_500_000_000 + index)),
                localDayKey: "2017-07-14",
                timeZoneIdentifier: "UTC",
                note: "unrelated-\(index)"
            ))
        }
        try context.save()

        let records = try await ImportPlanningActor(modelContainer: container)
            .duplicateRecords(for: parsed)
        let plan = FinanceCSVService.assessDuplicates(parsed, existingRecords: records)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(plan.candidates.first?.duplicateAssessment, .suspectedExisting)
        XCTAssertEqual(plan.suspectedDuplicateCount, 1)
        XCTAssertEqual(plan.duplicateCount, 0)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainerFactory.make(isStoredInMemoryOnly: true)
    }
}
