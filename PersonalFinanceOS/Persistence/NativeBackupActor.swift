import Foundation
import SwiftData

struct NativeBackupPackage: Codable, Sendable {
    static let formatIdentifier = "com.personalfinanceos.native-backup"
    static let currentSchemaVersion = 1

    struct Manifest: Codable, Sendable {
        let formatIdentifier: String
        let schemaVersion: Int
        let exportedAt: Date
        let appVersion: String
        let baseCurrency: String
    }

    struct AccountPayload: Codable, Sendable {
        var id: UUID
        var name: String
        var type: AccountType
        var openingBalanceMinorUnits: Int64
        var currencyCode: String
        var isDefault: Bool
        var sortOrder: Int
        var archivedAt: Date?
        var createdAt: Date
        var updatedAt: Date
        var importSemanticOrigin: String? = nil
    }

    struct CategoryPayload: Codable, Sendable {
        var id: UUID
        var kind: CategoryKind
        var name: String
        var parentID: UUID?
        var defaultDefinitionKey: String
        var symbolName: String
        var colorToken: String
        var sortOrder: Int
        var isPinnedForQuickAdd: Bool
        var isSystemCategory: Bool
        var isHidden: Bool
        var archivedAt: Date?
        var createdAt: Date
        var updatedAt: Date
        var importSemanticOrigin: String? = nil
    }

    struct TagPayload: Codable, Sendable {
        var id: UUID
        var name: String
        var colorToken: String
        var sortOrder: Int
        var archivedAt: Date?
        var createdAt: Date
        var updatedAt: Date
        var importSemanticOrigin: String? = nil
    }

    struct MerchantPayload: Codable, Sendable {
        var id: UUID
        var canonicalName: String
        var normalizedSearchKey: String
        var archivedAt: Date?
        var createdAt: Date
        var updatedAt: Date
    }

    struct ImportBatchPayload: Codable, Sendable {
        var id: UUID
        var sourceType: ImportSourceType
        var sourceDisplayName: String
        var sourceFormatVersion: String
        var startedAt: Date
        var completedAt: Date?
        var status: ImportBatchStatus
        var totalRowCount: Int
        var importedRowCount: Int
        var skippedRowCount: Int
        var duplicateRowCount: Int?
        var errorRowCount: Int
        var incomeMinorUnits: Int64
        var expenseMinorUnits: Int64
        var rolledBackAt: Date?
        var createdAt: Date
        var updatedAt: Date
        var importSemanticOrigin: String? = nil
    }

    struct TransactionPayload: Codable, Sendable {
        var id: UUID
        var type: TransactionType
        var amountMinorUnits: Int64
        var currencyCode: String
        var occurredAt: Date
        var localDayKey: String
        var timeZoneIdentifier: String
        var accountID: UUID?
        var destinationAccountID: UUID?
        var categoryID: UUID?
        var merchantID: UUID?
        var rawMerchantText: String
        var note: String
        var categoryDecisionSource: CategoryDecisionSource
        var reviewStatus: ReviewStatus
        var reviewReasons: [ReviewReason]
        var relatedTransactionID: UUID?
        var importBatchID: UUID?
        var externalSource: ImportSourceType?
        var externalTransactionID: String
        var importFingerprint: String
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?
        var tagIDs: [UUID]
        var importSemanticOrigin: String? = nil
    }

    struct DailyReviewPayload: Codable, Sendable {
        var id: UUID
        var localDayKey: String
        var timeZoneIdentifier: String
        var reviewedAt: Date?
        var reviewedChangeToken: String
        var createdAt: Date
        var updatedAt: Date
    }

    struct AppMetadataPayload: Codable, Sendable {
        var id: UUID
        var defaultCategorySeedVersion: Int
        var deletedDefaultCategoryKeys: [String]
        var createdAt: Date
        var updatedAt: Date
    }

    let manifest: Manifest
    let accounts: [AccountPayload]
    let categories: [CategoryPayload]
    let tags: [TagPayload]
    let merchants: [MerchantPayload]
    let importBatches: [ImportBatchPayload]
    let transactions: [TransactionPayload]
    let dailyReviews: [DailyReviewPayload]
    let appMetadata: [AppMetadataPayload]
}

struct NativeBackupPreview: Equatable, Sendable {
    let exportedAt: Date
    let accountCount: Int
    let categoryCount: Int
    let tagCount: Int
    let transactionCount: Int
    let activeTransactionCount: Int
    let deletedTransactionCount: Int
}

struct NativeRestoreResult: Equatable, Sendable {
    let insertedAccountCount: Int
    let insertedCategoryCount: Int
    let insertedTagCount: Int
    let insertedMerchantCount: Int
    let insertedImportBatchCount: Int
    let insertedTransactionCount: Int
    let insertedDeletedTransactionCount: Int
    let insertedDailyReviewCount: Int
    var learningResetFailed = false
}

enum NativeBackupError: Error, Equatable {
    case invalidFormat
    case unsupportedSchemaVersion(Int)
    case duplicateIdentifier(String)
    case invalidReference(String)
    case destinationContainsUserLedger
}

extension NativeBackupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "不是可识别的PersonalFinanceOS备份。"
        case let .unsupportedSchemaVersion(version):
            "备份版本 \(version) 当前不支持。"
        case let .duplicateIdentifier(entity):
            "备份中的 \(entity) 包含重复 ID。"
        case let .invalidReference(reference):
            "备份包含无效关联：\(reference)。"
        case .destinationContainsUserLedger:
            "完整备份目前仅支持恢复到新安装/空账本，不支持与现有账本合并。"
        }
    }
}

enum NativeBackupService {
    static func decode(_ data: Data) throws -> NativeBackupPackage {
        let package = try JSONDecoder().decode(NativeBackupPackage.self, from: data)
        try validate(package)
        return package
    }

    static func preview(data: Data) throws -> NativeBackupPreview {
        let package = try decode(data)
        let activeCount = package.transactions.filter { $0.deletedAt == nil }.count
        return NativeBackupPreview(
            exportedAt: package.manifest.exportedAt,
            accountCount: package.accounts.count,
            categoryCount: package.categories.count,
            tagCount: package.tags.count,
            transactionCount: package.transactions.count,
            activeTransactionCount: activeCount,
            deletedTransactionCount: package.transactions.count - activeCount
        )
    }

    static func validate(_ package: NativeBackupPackage) throws {
        guard package.manifest.formatIdentifier == NativeBackupPackage.formatIdentifier else {
            throw NativeBackupError.invalidFormat
        }
        guard package.manifest.schemaVersion == NativeBackupPackage.currentSchemaVersion else {
            throw NativeBackupError.unsupportedSchemaVersion(package.manifest.schemaVersion)
        }
        try requireUnique(package.accounts.map(\.id), entity: "accounts")
        try requireUnique(package.categories.map(\.id), entity: "categories")
        try requireUnique(package.tags.map(\.id), entity: "tags")
        try requireUnique(package.merchants.map(\.id), entity: "merchants")
        try requireUnique(package.importBatches.map(\.id), entity: "importBatches")
        try requireUnique(package.transactions.map(\.id), entity: "transactions")
        try requireUnique(package.dailyReviews.map(\.id), entity: "dailyReviews")
        try requireUnique(package.appMetadata.map(\.id), entity: "appMetadata")

        let accounts = Dictionary(uniqueKeysWithValues: package.accounts.map { ($0.id, $0) })
        let categories = Dictionary(uniqueKeysWithValues: package.categories.map { ($0.id, $0) })
        let tagIDs = Set(package.tags.map(\.id))
        let merchantIDs = Set(package.merchants.map(\.id))
        let batchIDs = Set(package.importBatches.map(\.id))
        let transactionIDs = Set(package.transactions.map(\.id))

        guard package.appMetadata.count == 1 else {
            throw NativeBackupError.invalidReference("AppMetadata singleton")
        }
        guard package.accounts.filter(\.isDefault).count == 1 else {
            throw NativeBackupError.invalidReference("default account uniqueness")
        }
        let defaultDefinitionKeys = package.categories
            .map(\.defaultDefinitionKey)
            .filter { !$0.isEmpty }
        guard Set(defaultDefinitionKeys).count == defaultDefinitionKeys.count else {
            throw NativeBackupError.invalidReference("category.defaultDefinitionKey uniqueness")
        }

        for category in package.categories {
            if let parentID = category.parentID,
               (categories[parentID]?.kind != category.kind || categories[parentID]?.parentID != nil || parentID == category.id) {
                throw NativeBackupError.invalidReference("category.parentID")
            }
        }
        for transaction in package.transactions {
            if let id = transaction.accountID, accounts[id]?.currencyCode != transaction.currencyCode {
                throw NativeBackupError.invalidReference("transaction.accountID")
            }
            if let id = transaction.destinationAccountID, accounts[id]?.currencyCode != transaction.currencyCode {
                throw NativeBackupError.invalidReference("transaction.destinationAccountID")
            }
            let expectedKind: CategoryKind = transaction.type == .income ? .income : .expense
            if let id = transaction.categoryID, categories[id]?.kind != expectedKind {
                throw NativeBackupError.invalidReference("transaction.categoryID")
            }
            if let id = transaction.merchantID, !merchantIDs.contains(id) {
                throw NativeBackupError.invalidReference("transaction.merchantID")
            }
            if let id = transaction.importBatchID, !batchIDs.contains(id) {
                throw NativeBackupError.invalidReference("transaction.importBatchID")
            }
            if let id = transaction.relatedTransactionID, !transactionIDs.contains(id) {
                throw NativeBackupError.invalidReference("transaction.relatedTransactionID")
            }
            if !Set(transaction.tagIDs).isSubset(of: tagIDs) {
                throw NativeBackupError.invalidReference("transaction.tagIDs")
            }
            guard transaction.amountMinorUnits > 0,
            (try? Money(
                minorUnits: transaction.amountMinorUnits,
                currencyCode: transaction.currencyCode
            )) != nil,
            let timeZone = TimeZone(identifier: transaction.timeZoneIdentifier),
            LocalDayKey.make(for: transaction.occurredAt, timeZone: timeZone) == transaction.localDayKey,
            LocalDayKey.isValid(transaction.localDayKey) else {
                throw NativeBackupError.invalidReference("transaction finance/date semantics")
            }
            guard transaction.accountID != nil else {
                throw NativeBackupError.invalidReference("transaction.accountID")
            }
            if transaction.type == .transfer {
                guard let sourceID = transaction.accountID,
                      let destinationID = transaction.destinationAccountID,
                      sourceID != destinationID,
                      transaction.categoryID == nil,
                      transaction.relatedTransactionID == nil else {
                    throw NativeBackupError.invalidReference("transaction transfer semantics")
                }
            } else {
                guard transaction.destinationAccountID == nil else {
                    throw NativeBackupError.invalidReference("transaction.destinationAccountID")
                }
                if transaction.type != .refund, transaction.relatedTransactionID != nil {
                    throw NativeBackupError.invalidReference("transaction.relatedTransactionID")
                }
            }
        }
    }

    private static func requireUnique(_ ids: [UUID], entity: String) throws {
        guard Set(ids).count == ids.count else {
            throw NativeBackupError.duplicateIdentifier(entity)
        }
    }
}

struct NativeBackupFileLoadResult: Sendable {
    let data: Data
    let preview: NativeBackupPreview
}

enum NativeBackupFileLoader {
    static func load(from url: URL) async throws -> NativeBackupFileLoadResult {
        try await load(from: url) { try Data(contentsOf: $0) }
    }

    static func load(
        from url: URL,
        read: @escaping @Sendable (URL) throws -> Data
    ) async throws -> NativeBackupFileLoadResult {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try read(url)
            try Task.checkCancellation()
            let preview = try NativeBackupService.preview(data: data)
            try Task.checkCancellation()
            return NativeBackupFileLoadResult(data: data, preview: preview)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

actor NativeBackupActor {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) { self.modelContainer = modelContainer }

    func exportData(exportedAt: Date = Date()) throws -> Data {
        let package = try LedgerSnapshotCodec.captureVersioned(in: modelContainer, exportedAt: exportedAt)
        try NativeBackupService.validate(package)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(package)
    }

    func export(fileName: String, exportedAt: Date = Date()) throws -> URL {
        try FinanceCSVService.writeTemporaryExport(
            data: exportData(exportedAt: exportedAt),
            fileName: fileName
        )
    }

    func restore(
        data: Data, admission: LedgerRestoreAdmission.Ticket,
        onBoundaryContention: (@Sendable () -> Void)? = nil,
        afterEligibilityValidation: (@Sendable () throws -> Void)? = nil,
        learningStore: ClassificationProfileStore = .shared
    ) async throws -> NativeRestoreResult {
        let package = try NativeBackupService.decode(data)
        let (committed, generation) = try LedgerSaveRevision.shared.withImportBoundary(onContention: onBoundaryContention) {
            try admission.consume(for: modelContainer)
            let context = ModelContext(modelContainer)
            do {
                let result = try NativeRestoreWriter(modelContext: context).restore(
                    package: package, afterEligibilityValidation: afterEligibilityValidation
                )
                LedgerSaveRevision.shared.didRestore()
                ImportCategoryMappingStore.invalidateForRestore()
                return (result, learningStore.beginClear())
            }
            catch { context.rollbackNotifyingSync(); throw error }
        }
        var result = committed
        do { try await learningStore.reset(generation: generation) }
        catch {
            result.learningResetFailed = true
            await SmartClassificationDiagnostics.shared.recordLearningWriteFailure()
        }
        return result
    }
}

private struct NativeRestoreWriter {
    let modelContext: ModelContext

    func restore(
        package: NativeBackupPackage, afterEligibilityValidation: (@Sendable () throws -> Void)?
    ) throws -> NativeRestoreResult {
        let existingAccounts = try modelContext.fetch(FetchDescriptor<Account>())
        let existingCategories = try modelContext.fetch(FetchDescriptor<Category>())
        let existingMetadata = try modelContext.fetch(FetchDescriptor<AppMetadata>())
        let existingTagCount = try modelContext.fetchCount(FetchDescriptor<Tag>())
        let existingMerchantCount = try modelContext.fetchCount(FetchDescriptor<Merchant>())
        let existingBatchCount = try modelContext.fetchCount(FetchDescriptor<ImportBatch>())
        let existingTransactionCount = try modelContext.fetchCount(
            FetchDescriptor<FinanceTransaction>()
        )
        let existingReviewCount = try modelContext.fetchCount(FetchDescriptor<DailyReview>())

        let isEmpty = existingAccounts.isEmpty &&
            existingCategories.isEmpty &&
            existingTagCount == 0 &&
            existingMerchantCount == 0 &&
            existingBatchCount == 0 &&
            existingTransactionCount == 0 &&
            existingReviewCount == 0 &&
            existingMetadata.isEmpty
        let isPristineBootstrap = existingTagCount == 0 &&
            existingMerchantCount == 0 &&
            existingBatchCount == 0 &&
            existingTransactionCount == 0 &&
            existingReviewCount == 0 &&
            DefaultFinanceDataService.isPristineBootstrap(
                accounts: existingAccounts,
                categories: existingCategories,
                appMetadata: existingMetadata
            )
        guard isEmpty || isPristineBootstrap else {
            throw NativeBackupError.destinationContainsUserLedger
        }

        try afterEligibilityValidation?()
        try LedgerSnapshotCodec.apply(package, in: modelContext)
        let insertedDeletedTransactions = package.transactions.filter { $0.deletedAt != nil }.count
        return NativeRestoreResult(
            insertedAccountCount: package.accounts.count,
            insertedCategoryCount: package.categories.count,
            insertedTagCount: package.tags.count,
            insertedMerchantCount: package.merchants.count,
            insertedImportBatchCount: package.importBatches.count,
            insertedTransactionCount: package.transactions.count,
            insertedDeletedTransactionCount: insertedDeletedTransactions,
            insertedDailyReviewCount: package.dailyReviews.count
        )
    }
}
