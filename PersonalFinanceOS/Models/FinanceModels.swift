import Foundation
import SwiftData

enum TransactionType: String, CaseIterable, Codable, Sendable {
    case expense
    case income
    case refund
    case transfer
}

enum AccountType: String, CaseIterable, Codable, Sendable {
    case cash
    case bankCard
    case creditCard
    case wechat
    case alipay
    case other
}

enum CategoryKind: String, CaseIterable, Codable, Sendable {
    case expense
    case income
}

enum CategoryDecisionSource: String, Codable, Sendable {
    case unchanged
    case manualConfirmed
    case automaticAccepted
    case timePrior
}

enum ReviewStatus: String, CaseIterable, Codable, Sendable {
    case complete
    case needsReview
}

enum ReviewReason: String, CaseIterable, Codable, Sendable {
    case uncategorized
    case userMarked
    case importUncertain
    case missingAccount
    case ambiguousDescription
    case other
}

enum ImportSourceType: String, CaseIterable, Codable, Sendable {
    case wacai
    case wechat
    case alipay
    case jd
    case genericCSV
}

enum ImportBatchStatus: String, CaseIterable, Codable, Sendable {
    case preparing
    case readyForReview
    case importing
    case completed
    case failed
    case rolledBack
}

typealias Account = AppSchemaV2.Account
typealias Category = AppSchemaV2.Category
typealias AppMetadata = AppSchemaV2.AppMetadata
typealias Tag = AppSchemaV2.Tag
typealias Merchant = AppSchemaV2.Merchant
typealias ImportBatch = AppSchemaV2.ImportBatch
typealias FinanceTransaction = AppSchemaV2.FinanceTransaction
typealias DailyReview = AppSchemaV2.DailyReview

enum AppSchemaMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [AppSchemaV1.self, AppSchemaV2.self, AppSchemaV3.self, AppSchemaV4.self]
    static let stages: [MigrationStage] = [
        .lightweight(fromVersion: AppSchemaV1.self, toVersion: AppSchemaV2.self),
        .lightweight(fromVersion: AppSchemaV2.self, toVersion: AppSchemaV3.self),
        .lightweight(fromVersion: AppSchemaV3.self, toVersion: AppSchemaV4.self)
    ]
}

enum AppSchema {
    static let schema = Schema(versionedSchema: AppSchemaV4.self)

    /// Build 13 persisted this identical model graph without a migration plan.
    /// This is test-only migration-fixture infrastructure, not a production entry point.
    static let build13UnversionedSchema = Schema(AppSchemaV1.models)
}
