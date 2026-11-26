import Foundation
import SwiftData

// Frozen Build 20 persisted graph (testflight-20 / f1c2ee8). Never edit persisted fields.
enum AppSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static let models: [any PersistentModel.Type] = [Account.self, Category.self, AppMetadata.self, Tag.self, Merchant.self, ImportBatch.self, FinanceTransaction.self, DailyReview.self]

    @Model
    final class Account {
        var id: UUID = UUID()
        var name: String = ""
        var typeRawValue: String = AccountType.other.rawValue
        var openingBalanceMinorUnits: Int64 = 0
        var currencyCode: String = Money.cnyCode
        var isDefault: Bool = false
        var sortOrder: Int = 0
        var archivedAt: Date?
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init(
            id: UUID = UUID(),
            name: String,
            type: AccountType,
            openingBalanceMinorUnits: Int64 = 0,
            currencyCode: String = Money.cnyCode,
            isDefault: Bool = false,
            sortOrder: Int = 0,
            archivedAt: Date? = nil,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.typeRawValue = type.rawValue
            self.openingBalanceMinorUnits = openingBalanceMinorUnits
            self.currencyCode = currencyCode
            self.isDefault = isDefault
            self.sortOrder = sortOrder
            self.archivedAt = archivedAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        var type: AccountType {
            get { AccountType(rawValue: typeRawValue) ?? .other }
            set { typeRawValue = newValue.rawValue }
        }
    }

    @Model
    final class Category {
        var id: UUID = UUID()
        var kindRawValue: String = CategoryKind.expense.rawValue
        var name: String = ""
        var parentID: UUID?
        var defaultDefinitionKey: String = ""
        var symbolName: String = "square.grid.2x2"
        var colorToken: String = "teal"
        var sortOrder: Int = 0
        var isPinnedForQuickAdd: Bool = false
        var isSystemCategory: Bool = false
        var isHidden: Bool = false
        var archivedAt: Date?
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init(
            id: UUID = UUID(),
            kind: CategoryKind,
            name: String,
            parentID: UUID? = nil,
            defaultDefinitionKey: String = "",
            symbolName: String,
            colorToken: String,
            sortOrder: Int = 0,
            isPinnedForQuickAdd: Bool = false,
            isSystemCategory: Bool = false,
            isHidden: Bool = false,
            archivedAt: Date? = nil,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.kindRawValue = kind.rawValue
            self.name = name
            self.parentID = parentID
            self.defaultDefinitionKey = defaultDefinitionKey
            self.symbolName = symbolName
            self.colorToken = colorToken
            self.sortOrder = sortOrder
            self.isPinnedForQuickAdd = isPinnedForQuickAdd
            self.isSystemCategory = isSystemCategory
            self.isHidden = isHidden
            self.archivedAt = archivedAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        var kind: CategoryKind {
            get { CategoryKind(rawValue: kindRawValue) ?? .expense }
            set { kindRawValue = newValue.rawValue }
        }
    }

    @Model
    final class AppMetadata {
        var id: UUID = UUID()
        var defaultCategorySeedVersion: Int = 0
        var deletedDefaultCategoryKeysStorage: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init(
            id: UUID = UUID(),
            defaultCategorySeedVersion: Int = 0,
            deletedDefaultCategoryKeys: Set<String> = [],
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.defaultCategorySeedVersion = defaultCategorySeedVersion
            deletedDefaultCategoryKeysStorage = Self.encode(deletedDefaultCategoryKeys)
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        var deletedDefaultCategoryKeys: Set<String> {
            get {
                Set(deletedDefaultCategoryKeysStorage.split(separator: "|").map(String.init))
            }
            set {
                deletedDefaultCategoryKeysStorage = Self.encode(newValue)
            }
        }

        private static func encode(_ keys: Set<String>) -> String {
            keys.sorted().joined(separator: "|")
        }
    }

    @Model
    final class Tag {
        var id: UUID = UUID()
        var name: String = ""
        var colorToken: String = "teal"
        var sortOrder: Int = 0
        var archivedAt: Date?
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        @Relationship(deleteRule: .nullify, inverse: \FinanceTransaction.tags)
        var transactions: [FinanceTransaction] = []

        init(
            id: UUID = UUID(),
            name: String,
            colorToken: String = "teal",
            sortOrder: Int = 0,
            archivedAt: Date? = nil,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.colorToken = colorToken
            self.sortOrder = sortOrder
            self.archivedAt = archivedAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

    }

    @Model
    final class Merchant {
        var id: UUID = UUID()
        var canonicalName: String = ""
        var normalizedSearchKey: String = ""
        var archivedAt: Date?
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init(
            id: UUID = UUID(),
            canonicalName: String,
            normalizedSearchKey: String,
            archivedAt: Date? = nil,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.canonicalName = canonicalName
            self.normalizedSearchKey = normalizedSearchKey
            self.archivedAt = archivedAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class ImportBatch {
        var id: UUID = UUID()
        var sourceTypeRawValue: String = ImportSourceType.genericCSV.rawValue
        var sourceDisplayName: String = ""
        var sourceFormatVersion: String = ""
        var startedAt: Date = Date()
        var completedAt: Date?
        var statusRawValue: String = ImportBatchStatus.preparing.rawValue
        var totalRowCount: Int = 0
        var importedRowCount: Int = 0
        var skippedRowCount: Int = 0
        var duplicateRowCount: Int?
        var errorRowCount: Int = 0
        var incomeMinorUnits: Int64 = 0
        var expenseMinorUnits: Int64 = 0
        var rolledBackAt: Date?
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init(
            id: UUID = UUID(),
            sourceType: ImportSourceType,
            sourceDisplayName: String,
            sourceFormatVersion: String = "",
            startedAt: Date = Date(),
            completedAt: Date? = nil,
            status: ImportBatchStatus = .preparing,
            totalRowCount: Int = 0,
            importedRowCount: Int = 0,
            skippedRowCount: Int = 0,
            duplicateRowCount: Int? = nil,
            errorRowCount: Int = 0,
            incomeMinorUnits: Int64 = 0,
            expenseMinorUnits: Int64 = 0,
            rolledBackAt: Date? = nil,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.sourceTypeRawValue = sourceType.rawValue
            self.sourceDisplayName = sourceDisplayName
            self.sourceFormatVersion = sourceFormatVersion
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.statusRawValue = status.rawValue
            self.totalRowCount = totalRowCount
            self.importedRowCount = importedRowCount
            self.skippedRowCount = skippedRowCount
            self.duplicateRowCount = duplicateRowCount
            self.errorRowCount = errorRowCount
            self.incomeMinorUnits = incomeMinorUnits
            self.expenseMinorUnits = expenseMinorUnits
            self.rolledBackAt = rolledBackAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        var sourceType: ImportSourceType {
            get { ImportSourceType(rawValue: sourceTypeRawValue) ?? .genericCSV }
            set { sourceTypeRawValue = newValue.rawValue }
        }

        var status: ImportBatchStatus {
            get { ImportBatchStatus(rawValue: statusRawValue) ?? .preparing }
            set { statusRawValue = newValue.rawValue }
        }
    }

    @Model
    final class FinanceTransaction {
        var id: UUID = UUID()
        var typeRawValue: String = TransactionType.expense.rawValue
        var amountMinorUnits: Int64 = 0
        var currencyCode: String = Money.cnyCode
        var occurredAt: Date = Date()
        var localDayKey: String = ""
        var timeZoneIdentifier: String = TimeZone.current.identifier
        var accountID: UUID?
        var destinationAccountID: UUID?
        var categoryID: UUID?
        var merchantID: UUID?
        var rawMerchantText: String = ""
        var note: String = ""
        var categoryDecisionSourceRawValue: String = CategoryDecisionSource.unchanged.rawValue
        var reviewStatusRawValue: String = ReviewStatus.complete.rawValue
        var reviewReasonsStorage: String = ""
        var relatedTransactionID: UUID?
        var importBatchID: UUID?
        var externalSourceRawValue: String = ""
        var externalTransactionID: String = ""
        var importFingerprint: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var deletedAt: Date?
        @Relationship(deleteRule: .nullify)
        var tags: [Tag] = []

        init(
            id: UUID = UUID(),
            type: TransactionType,
            amountMinorUnits: Int64,
            currencyCode: String = Money.cnyCode,
            occurredAt: Date,
            localDayKey: String,
            timeZoneIdentifier: String,
            accountID: UUID? = nil,
            destinationAccountID: UUID? = nil,
            categoryID: UUID? = nil,
            merchantID: UUID? = nil,
            rawMerchantText: String = "",
            note: String = "",
            categoryDecisionSource: CategoryDecisionSource = .unchanged,
            reviewStatus: ReviewStatus = .complete,
            reviewReasons: Set<ReviewReason> = [],
            relatedTransactionID: UUID? = nil,
            importBatchID: UUID? = nil,
            externalSource: ImportSourceType? = nil,
            externalTransactionID: String = "",
            importFingerprint: String = "",
            createdAt: Date = Date(),
            updatedAt: Date = Date(),
            deletedAt: Date? = nil,
            tags: [Tag] = []
        ) {
            self.id = id
            self.typeRawValue = type.rawValue
            self.amountMinorUnits = amountMinorUnits
            self.currencyCode = currencyCode
            self.occurredAt = occurredAt
            self.localDayKey = localDayKey
            self.timeZoneIdentifier = timeZoneIdentifier
            self.accountID = accountID
            self.destinationAccountID = destinationAccountID
            self.categoryID = categoryID
            self.merchantID = merchantID
            self.rawMerchantText = rawMerchantText
            self.note = note
            categoryDecisionSourceRawValue = categoryDecisionSource.rawValue
            self.reviewStatusRawValue = reviewStatus.rawValue
            self.reviewReasonsStorage = Self.encode(reviewReasons)
            self.relatedTransactionID = relatedTransactionID
            self.importBatchID = importBatchID
            self.externalSourceRawValue = externalSource?.rawValue ?? ""
            self.externalTransactionID = externalTransactionID
            self.importFingerprint = importFingerprint
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.deletedAt = deletedAt
            self.tags = tags
        }

        var type: TransactionType {
            get { TransactionType(rawValue: typeRawValue) ?? .expense }
            set { typeRawValue = newValue.rawValue }
        }

        var categoryDecisionSource: CategoryDecisionSource {
            get {
                CategoryDecisionSource(rawValue: categoryDecisionSourceRawValue) ?? .unchanged
            }
            set {
                categoryDecisionSourceRawValue = newValue.rawValue
            }
        }

        var reviewStatus: ReviewStatus {
            get { ReviewStatus(rawValue: reviewStatusRawValue) ?? .complete }
            set { reviewStatusRawValue = newValue.rawValue }
        }

        var reviewReasons: Set<ReviewReason> {
            get {
                Set(
                    reviewReasonsStorage
                        .split(separator: "|")
                        .compactMap { ReviewReason(rawValue: String($0)) }
                )
            }
            set {
                reviewReasonsStorage = Self.encode(newValue)
            }
        }

        var externalSource: ImportSourceType? {
            get { ImportSourceType(rawValue: externalSourceRawValue) }
            set { externalSourceRawValue = newValue?.rawValue ?? "" }
        }

        func softDelete(at date: Date = Date()) {
            deletedAt = date
            updatedAt = date
        }

        func restore(at date: Date = Date()) {
            deletedAt = nil
            updatedAt = date
        }

        private static func encode(_ reasons: Set<ReviewReason>) -> String {
            reasons.map(\.rawValue).sorted().joined(separator: "|")
        }
    }

    @Model
    final class DailyReview {
        var id: UUID = UUID()
        var localDayKey: String = ""
        var timeZoneIdentifier: String = TimeZone.current.identifier
        var reviewedAt: Date?
        var reviewedChangeToken: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init(
            id: UUID = UUID(),
            localDayKey: String,
            timeZoneIdentifier: String,
            reviewedAt: Date? = nil,
            reviewedChangeToken: String = "",
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.localDayKey = localDayKey
            self.timeZoneIdentifier = timeZoneIdentifier
            self.reviewedAt = reviewedAt
            self.reviewedChangeToken = reviewedChangeToken
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

}
