import SwiftData
import XCTest
@testable import PersonalFinanceOS

private typealias Account = AppSchemaV1.Account
private typealias Category = AppSchemaV1.Category
private typealias AppMetadata = AppSchemaV1.AppMetadata
private typealias Tag = AppSchemaV1.Tag
private typealias Merchant = AppSchemaV1.Merchant
private typealias ImportBatch = AppSchemaV1.ImportBatch
private typealias FinanceTransaction = AppSchemaV1.FinanceTransaction
private typealias DailyReview = AppSchemaV1.DailyReview

@MainActor
final class PersistenceMigrationTests: XCTestCase {
    func testBuild13UnversionedStoreOpensWithVersionedV1WithoutSemanticChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Build13LegacyStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Core Data may retain SQLite cleanup callbacks beyond the ModelContainer scope.
        // The process temporary directory owns cleanup so a live WAL/SHM file is never unlinked.
        let storeURL = directory.appendingPathComponent("PersonalFinanceOSV2.store")

        var legacyContainer: ModelContainer? = try makeBuild13Container(storeURL: storeURL)
        var legacyContext: ModelContext? = ModelContext(try XCTUnwrap(legacyContainer))
        try insertBuild13Fixture(in: try XCTUnwrap(legacyContext))
        let before = try StoreSnapshot(context: try XCTUnwrap(legacyContext))

        legacyContext = nil
        legacyContainer = nil

        let versionedConfiguration = ModelConfiguration(
            "PersonalFinanceOSV2",
            schema: Schema(versionedSchema: AppSchemaV1.self),
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let versionedContainer = try ModelContainer(
            for: Schema(versionedSchema: AppSchemaV1.self),
            configurations: [versionedConfiguration]
        )
        let versionedContext = ModelContext(versionedContainer)
        let after = try StoreSnapshot(context: versionedContext)

        XCTAssertEqual(after, before)
        XCTAssertEqual(after.financialSnapshot, before.financialSnapshot)
        XCTAssertEqual(after.transactions.count, 5)
        XCTAssertEqual(after.transactions.filter { $0.deletedAt == nil }.count, 4)
        XCTAssertEqual(after.transactions.filter { $0.deletedAt != nil }.count, 1)
    }

    private func makeBuild13Container(storeURL: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "PersonalFinanceOSV2",
            schema: AppSchema.build13UnversionedSchema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: AppSchema.build13UnversionedSchema,
            configurations: [configuration]
        )
    }

    private func insertBuild13Fixture(in context: ModelContext) throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let deletedAt = Date(timeIntervalSince1970: 1_720_000_000)
        let expenseID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let incomeID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let refundID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let transferID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!

        let cash = Account(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            name: "现金",
            type: .cash,
            openingBalanceMinorUnits: 12_345,
            currencyCode: "CNY",
            isDefault: true,
            sortOrder: 1,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let bank = Account(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            name: "银行卡",
            type: .bankCard,
            openingBalanceMinorUnits: 98_765,
            currencyCode: "CNY",
            sortOrder: 2,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let archived = Account(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
            name: "已归档账户",
            type: .other,
            archivedAt: deletedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        let parent = Category(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            kind: .expense,
            name: "餐饮",
            defaultDefinitionKey: "expense.food",
            symbolName: "fork.knife",
            colorToken: "orange",
            sortOrder: 1,
            isPinnedForQuickAdd: true,
            isSystemCategory: true,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let child = Category(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            kind: .expense,
            name: "早餐",
            parentID: parent.id,
            symbolName: "cup.and.saucer",
            colorToken: "yellow",
            sortOrder: 2,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let salary = Category(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            kind: .income,
            name: "工资",
            symbolName: "banknote",
            colorToken: "green",
            sortOrder: 3,
            archivedAt: deletedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        let work = Tag(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            name: "工作",
            colorToken: "blue",
            sortOrder: 1,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let archivedTag = Tag(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            name: "已归档标签",
            colorToken: "gray",
            sortOrder: 2,
            archivedAt: deletedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let merchant = Merchant(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            canonicalName: "示例商户",
            normalizedSearchKey: "sample merchant",
            archivedAt: deletedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let batch = ImportBatch(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!,
            sourceType: .wacai,
            sourceDisplayName: "挖财旧账本",
            sourceFormatVersion: "build13-fixture",
            startedAt: createdAt,
            completedAt: updatedAt,
            status: .completed,
            totalRowCount: 2,
            importedRowCount: 2,
            skippedRowCount: 0,
            duplicateRowCount: 1,
            errorRowCount: 0,
            incomeMinorUnits: 20_000,
            expenseMinorUnits: 1_234,
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        let expense = FinanceTransaction(
            id: expenseID,
            type: .expense,
            amountMinorUnits: 1_234,
            currencyCode: "CNY",
            occurredAt: Date(timeIntervalSince1970: 1_718_689_260),
            localDayKey: "2024-06-18",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: cash.id,
            categoryID: child.id,
            merchantID: merchant.id,
            rawMerchantText: "商户原文",
            note: "早餐备注",
            categoryDecisionSource: .manualConfirmed,
            reviewStatus: .needsReview,
            reviewReasons: [.userMarked, .other],
            importBatchID: batch.id,
            externalSource: .wacai,
            externalTransactionID: "legacy-expense-1",
            importFingerprint: "legacy-fingerprint-expense",
            createdAt: createdAt,
            updatedAt: updatedAt,
            tags: [work, archivedTag]
        )
        let income = FinanceTransaction(
            id: incomeID,
            type: .income,
            amountMinorUnits: 20_000,
            currencyCode: "CNY",
            occurredAt: Date(timeIntervalSince1970: 1_718_775_600),
            localDayKey: "2024-06-19",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: bank.id,
            categoryID: salary.id,
            rawMerchantText: "工资",
            note: "六月工资",
            importBatchID: batch.id,
            externalSource: .wacai,
            externalTransactionID: "legacy-income-1",
            importFingerprint: "legacy-fingerprint-income",
            createdAt: createdAt,
            updatedAt: updatedAt,
            tags: [work]
        )
        let refund = FinanceTransaction(
            id: refundID,
            type: .refund,
            amountMinorUnits: 234,
            currencyCode: "CNY",
            occurredAt: Date(timeIntervalSince1970: 1_718_862_000),
            localDayKey: "2024-06-20",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: cash.id,
            categoryID: child.id,
            rawMerchantText: "商户退款",
            note: "原路退回",
            relatedTransactionID: expense.id,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let transfer = FinanceTransaction(
            id: transferID,
            type: .transfer,
            amountMinorUnits: 5_000,
            currencyCode: "CNY",
            occurredAt: Date(timeIntervalSince1970: 1_718_948_400),
            localDayKey: "2024-06-21",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: cash.id,
            destinationAccountID: bank.id,
            rawMerchantText: "账户转账",
            note: "资金转移",
            createdAt: createdAt,
            updatedAt: updatedAt,
            tags: [archivedTag]
        )
        let softDeleted = FinanceTransaction(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
            type: .expense,
            amountMinorUnits: 999,
            currencyCode: "CNY",
            occurredAt: Date(timeIntervalSince1970: 1_719_034_800),
            localDayKey: "2024-06-22",
            timeZoneIdentifier: "America/Los_Angeles",
            accountID: archived.id,
            categoryID: parent.id,
            rawMerchantText: "用户已删除",
            note: "不应复活",
            externalSource: .genericCSV,
            externalTransactionID: "deleted-source-id",
            importFingerprint: "deleted-fingerprint",
            createdAt: createdAt,
            updatedAt: deletedAt,
            deletedAt: deletedAt
        )
        let metadata = AppMetadata(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
            defaultCategorySeedVersion: 7,
            deletedDefaultCategoryKeys: ["expense.old", "income.old"],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let review = DailyReview(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000001")!,
            localDayKey: "2024-06-18",
            timeZoneIdentifier: "Asia/Shanghai",
            reviewedAt: updatedAt,
            reviewedChangeToken: "legacy-token",
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        [cash, bank, archived].forEach(context.insert)
        [parent, child, salary].forEach(context.insert)
        [work, archivedTag].forEach(context.insert)
        context.insert(merchant)
        context.insert(batch)
        [expense, income, refund, transfer, softDeleted].forEach(context.insert)
        context.insert(metadata)
        context.insert(review)
        try context.save()
    }
}

private struct StoreSnapshot: Equatable {
    let accounts: [AccountValue]
    let categories: [CategoryValue]
    let metadata: [MetadataValue]
    let tags: [TagValue]
    let merchants: [MerchantValue]
    let batches: [BatchValue]
    let transactions: [TransactionValue]
    let dailyReviews: [DailyReviewValue]
    let financialSnapshot: FinancialSnapshot

    @MainActor
    init(context: ModelContext) throws {
        accounts = try context.fetch(FetchDescriptor<Account>()).map(AccountValue.init).sorted()
        categories = try context.fetch(FetchDescriptor<Category>())
            .map(CategoryValue.init)
            .sorted()
        metadata = try context.fetch(FetchDescriptor<AppMetadata>()).map(MetadataValue.init).sorted()
        tags = try context.fetch(FetchDescriptor<Tag>()).map(TagValue.init).sorted()
        merchants = try context.fetch(FetchDescriptor<Merchant>()).map(MerchantValue.init).sorted()
        batches = try context.fetch(FetchDescriptor<ImportBatch>()).map(BatchValue.init).sorted()
        transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
            .map(TransactionValue.init)
            .sorted()
        dailyReviews = try context.fetch(FetchDescriptor<DailyReview>()).map(DailyReviewValue.init).sorted()
        financialSnapshot = FinancialSnapshot(transactions: transactions)
    }
}

private protocol IdentifiedSnapshot: Comparable {
    var id: UUID { get }
}

private extension IdentifiedSnapshot {
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.id.uuidString < rhs.id.uuidString }
}

private struct AccountValue: Equatable, IdentifiedSnapshot {
    let id: UUID
    let name: String
    let typeRawValue: String
    let openingBalanceMinorUnits: Int64
    let currencyCode: String
    let isDefault: Bool
    let sortOrder: Int
    let archivedAt: Date?
    let createdAt: Date
    let updatedAt: Date

    init(_ value: Account) {
        id = value.id
        name = value.name
        typeRawValue = value.typeRawValue
        openingBalanceMinorUnits = value.openingBalanceMinorUnits
        currencyCode = value.currencyCode
        isDefault = value.isDefault
        sortOrder = value.sortOrder
        archivedAt = value.archivedAt
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }
}

private struct CategoryValue: Equatable, IdentifiedSnapshot {
    let id: UUID
    let kindRawValue: String
    let name: String
    let parentID: UUID?
    let defaultDefinitionKey: String
    let symbolName: String
    let colorToken: String
    let sortOrder: Int
    let isPinnedForQuickAdd: Bool
    let isSystemCategory: Bool
    let isHidden: Bool
    let archivedAt: Date?
    let createdAt: Date
    let updatedAt: Date

    init(_ value: Category) {
        id = value.id
        kindRawValue = value.kindRawValue
        name = value.name
        parentID = value.parentID
        defaultDefinitionKey = value.defaultDefinitionKey
        symbolName = value.symbolName
        colorToken = value.colorToken
        sortOrder = value.sortOrder
        isPinnedForQuickAdd = value.isPinnedForQuickAdd
        isSystemCategory = value.isSystemCategory
        isHidden = value.isHidden
        archivedAt = value.archivedAt
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }
}

private struct MetadataValue: Equatable, IdentifiedSnapshot {
    let id: UUID
    let defaultCategorySeedVersion: Int
    let deletedDefaultCategoryKeysStorage: String
    let createdAt: Date
    let updatedAt: Date

    init(_ value: AppMetadata) {
        id = value.id
        defaultCategorySeedVersion = value.defaultCategorySeedVersion
        deletedDefaultCategoryKeysStorage = value.deletedDefaultCategoryKeysStorage
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }
}

private struct TagValue: Equatable, IdentifiedSnapshot {
    let id: UUID
    let name: String
    let colorToken: String
    let sortOrder: Int
    let archivedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let transactionIDs: [UUID]

    init(_ value: Tag) {
        id = value.id
        name = value.name
        colorToken = value.colorToken
        sortOrder = value.sortOrder
        archivedAt = value.archivedAt
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        transactionIDs = value.transactions.map(\.id).sorted { $0.uuidString < $1.uuidString }
    }
}

private struct MerchantValue: Equatable, IdentifiedSnapshot {
    let id: UUID
    let canonicalName: String
    let normalizedSearchKey: String
    let archivedAt: Date?
    let createdAt: Date
    let updatedAt: Date

    init(_ value: Merchant) {
        id = value.id
        canonicalName = value.canonicalName
        normalizedSearchKey = value.normalizedSearchKey
        archivedAt = value.archivedAt
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }
}

private struct BatchValue: Equatable, IdentifiedSnapshot {
    let id: UUID
    let sourceTypeRawValue: String
    let sourceDisplayName: String
    let sourceFormatVersion: String
    let startedAt: Date
    let completedAt: Date?
    let statusRawValue: String
    let totalRowCount: Int
    let importedRowCount: Int
    let skippedRowCount: Int
    let duplicateRowCount: Int?
    let errorRowCount: Int
    let incomeMinorUnits: Int64
    let expenseMinorUnits: Int64
    let rolledBackAt: Date?
    let createdAt: Date
    let updatedAt: Date

    init(_ value: ImportBatch) {
        id = value.id
        sourceTypeRawValue = value.sourceTypeRawValue
        sourceDisplayName = value.sourceDisplayName
        sourceFormatVersion = value.sourceFormatVersion
        startedAt = value.startedAt
        completedAt = value.completedAt
        statusRawValue = value.statusRawValue
        totalRowCount = value.totalRowCount
        importedRowCount = value.importedRowCount
        skippedRowCount = value.skippedRowCount
        duplicateRowCount = value.duplicateRowCount
        errorRowCount = value.errorRowCount
        incomeMinorUnits = value.incomeMinorUnits
        expenseMinorUnits = value.expenseMinorUnits
        rolledBackAt = value.rolledBackAt
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }
}

private struct TransactionValue: Equatable, IdentifiedSnapshot {
    let id: UUID
    let typeRawValue: String
    let amountMinorUnits: Int64
    let currencyCode: String
    let occurredAt: Date
    let localDayKey: String
    let timeZoneIdentifier: String
    let accountID: UUID?
    let destinationAccountID: UUID?
    let categoryID: UUID?
    let merchantID: UUID?
    let rawMerchantText: String
    let note: String
    let categoryDecisionSourceRawValue: String
    let reviewStatusRawValue: String
    let reviewReasonsStorage: String
    let relatedTransactionID: UUID?
    let importBatchID: UUID?
    let externalSourceRawValue: String
    let externalTransactionID: String
    let importFingerprint: String
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let tagIDs: [UUID]

    init(_ value: FinanceTransaction) {
        id = value.id
        typeRawValue = value.typeRawValue
        amountMinorUnits = value.amountMinorUnits
        currencyCode = value.currencyCode
        occurredAt = value.occurredAt
        localDayKey = value.localDayKey
        timeZoneIdentifier = value.timeZoneIdentifier
        accountID = value.accountID
        destinationAccountID = value.destinationAccountID
        categoryID = value.categoryID
        merchantID = value.merchantID
        rawMerchantText = value.rawMerchantText
        note = value.note
        categoryDecisionSourceRawValue = value.categoryDecisionSourceRawValue
        reviewStatusRawValue = value.reviewStatusRawValue
        reviewReasonsStorage = value.reviewReasonsStorage
        relatedTransactionID = value.relatedTransactionID
        importBatchID = value.importBatchID
        externalSourceRawValue = value.externalSourceRawValue
        externalTransactionID = value.externalTransactionID
        importFingerprint = value.importFingerprint
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        deletedAt = value.deletedAt
        tagIDs = value.tags.map(\.id).sorted { $0.uuidString < $1.uuidString }
    }
}

private struct DailyReviewValue: Equatable, IdentifiedSnapshot {
    let id: UUID
    let localDayKey: String
    let timeZoneIdentifier: String
    let reviewedAt: Date?
    let reviewedChangeToken: String
    let createdAt: Date
    let updatedAt: Date

    init(_ value: DailyReview) {
        id = value.id
        localDayKey = value.localDayKey
        timeZoneIdentifier = value.timeZoneIdentifier
        reviewedAt = value.reviewedAt
        reviewedChangeToken = value.reviewedChangeToken
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }
}

private struct FinancialSnapshot: Equatable {
    let transactionCount: Int
    let activeCount: Int
    let deletedCount: Int
    let expenseMinorUnits: Int64
    let incomeMinorUnits: Int64
    let refundMinorUnits: Int64
    let transferMinorUnits: Int64
    let netExpenseMinorUnits: Int64

    init(transactions: [TransactionValue]) {
        transactionCount = transactions.count
        let active = transactions.filter { $0.deletedAt == nil }
        activeCount = active.count
        deletedCount = transactions.count - active.count
        expenseMinorUnits = active.filter { $0.typeRawValue == TransactionType.expense.rawValue }
            .reduce(0) { $0 + $1.amountMinorUnits }
        incomeMinorUnits = active.filter { $0.typeRawValue == TransactionType.income.rawValue }
            .reduce(0) { $0 + $1.amountMinorUnits }
        refundMinorUnits = active.filter { $0.typeRawValue == TransactionType.refund.rawValue }
            .reduce(0) { $0 + $1.amountMinorUnits }
        transferMinorUnits = active.filter { $0.typeRawValue == TransactionType.transfer.rawValue }
            .reduce(0) { $0 + $1.amountMinorUnits }
        netExpenseMinorUnits = expenseMinorUnits - refundMinorUnits
    }
}
