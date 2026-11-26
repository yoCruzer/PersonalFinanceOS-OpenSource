import Foundation
import SwiftData

/// Shared lossless ledger projection for semantic backups and the optional sync bridge.
enum LedgerSnapshotCodec {
    static func capture(in modelContext: ModelContext, exportedAt: Date = Date()) throws -> NativeBackupPackage {
        try LedgerSaveRevision.shared.withImportBoundary {
            try captureLocked(in: modelContext, exportedAt: exportedAt)
        }
    }

    /// Actor callers scan without holding the write boundary. A concurrent save
    /// invalidates the whole graph; bounded retries always use a fresh context.
    static func captureVersioned(
        in container: ModelContainer, exportedAt: Date = Date(),
        afterRead: (@Sendable () throws -> Void)? = nil,
        afterCategoriesRead: (@Sendable () throws -> Void)? = nil
    ) throws -> NativeBackupPackage {
        for _ in 0..<2 {
            try Task.checkCancellation()
            do {
                let revision = try LedgerSaveRevision.shared.readStamp()
                let package = try readPackage(in: ModelContext(container), exportedAt: exportedAt, afterCategoriesRead: afterCategoriesRead)
                try afterRead?()
                try Task.checkCancellation()
                guard try LedgerSaveRevision.shared.readStamp() == revision else {
                    throw ReconcileRevision.Failure.stalePlan
                }
                let additions = originAdditions(for: package)
                if additions.isEmpty { return package }
                try LedgerSaveRevision.shared.withProjectionBoundary {
                    guard LedgerSaveRevision.shared.revision == revision else {
                        throw ReconcileRevision.Failure.stalePlan
                    }
                    try persistOrigins(additions, in: ModelContext(container))
                }
                return applyingOrigins(additions, to: package)
            } catch ReconcileRevision.Failure.stalePlan { continue }
        }
        throw ReconcileRevision.Failure.stalePlan
    }

    private static func captureLocked(in context: ModelContext, exportedAt: Date) throws -> NativeBackupPackage {
        let package = try readPackage(in: context, exportedAt: exportedAt)
        let additions = originAdditions(for: package)
        if additions.isEmpty { return package }
        try persistOrigins(additions, in: context)
        return applyingOrigins(additions, to: package)
    }

    private static func readPackage(in modelContext: ModelContext, exportedAt: Date,
                                    afterCategoriesRead: (@Sendable () throws -> Void)? = nil) throws -> NativeBackupPackage {
        var origins: [String: String] = [:]
        for origin in try checkedFetch(FetchDescriptor<ImportEntityOrigin>(), in: modelContext) {
            guard origins.updateValue(origin.semanticKey, forKey: origin.entityKey) == nil else {
                throw NativeBackupError.duplicateIdentifier("ImportEntityOrigin")
            }
        }
        let package = NativeBackupPackage(
            manifest: .init(
                formatIdentifier: NativeBackupPackage.formatIdentifier,
                schemaVersion: NativeBackupPackage.currentSchemaVersion,
                exportedAt: exportedAt,
                appVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "unknown",
                baseCurrency: Money.cnyCode
            ),
            accounts: try checkedFetch(FetchDescriptor<Account>(), in: modelContext).map { value in
                .init(
                    id: value.id,
                    name: value.name,
                    type: value.type,
                    openingBalanceMinorUnits: value.openingBalanceMinorUnits,
                    currencyCode: value.currencyCode,
                    isDefault: value.isDefault,
                    sortOrder: value.sortOrder,
                    archivedAt: value.archivedAt,
                    createdAt: value.createdAt,
                    updatedAt: value.updatedAt,
                    importSemanticOrigin: origins["accounts:\(value.id.uuidString)"]
                )
            },
            categories: try checkedFetch(FetchDescriptor<Category>(), in: modelContext, afterRead: afterCategoriesRead).map { value in
                .init(
                    id: value.id,
                    kind: value.kind,
                    name: value.name,
                    parentID: value.parentID,
                    defaultDefinitionKey: value.defaultDefinitionKey,
                    symbolName: value.symbolName,
                    colorToken: value.colorToken,
                    sortOrder: value.sortOrder,
                    isPinnedForQuickAdd: value.isPinnedForQuickAdd,
                    isSystemCategory: value.isSystemCategory,
                    isHidden: value.isHidden,
                    archivedAt: value.archivedAt,
                    createdAt: value.createdAt,
                    updatedAt: value.updatedAt,
                    importSemanticOrigin: origins["categories:\(value.id.uuidString)"]
                )
            },
            tags: try checkedFetch(FetchDescriptor<Tag>(), in: modelContext).map { value in
                .init(
                    id: value.id,
                    name: value.name,
                    colorToken: value.colorToken,
                    sortOrder: value.sortOrder,
                    archivedAt: value.archivedAt,
                    createdAt: value.createdAt,
                    updatedAt: value.updatedAt,
                    importSemanticOrigin: origins["tags:\(value.id.uuidString)"]
                )
            },
            merchants: try checkedFetch(FetchDescriptor<Merchant>(), in: modelContext).map { value in
                .init(
                    id: value.id,
                    canonicalName: value.canonicalName,
                    normalizedSearchKey: value.normalizedSearchKey,
                    archivedAt: value.archivedAt,
                    createdAt: value.createdAt,
                    updatedAt: value.updatedAt
                )
            },
            importBatches: try checkedFetch(FetchDescriptor<ImportBatch>(), in: modelContext).map { value in
                .init(
                    id: value.id,
                    sourceType: value.sourceType,
                    sourceDisplayName: value.sourceDisplayName,
                    sourceFormatVersion: value.sourceFormatVersion,
                    startedAt: value.startedAt,
                    completedAt: value.completedAt,
                    status: value.status,
                    totalRowCount: value.totalRowCount,
                    importedRowCount: value.importedRowCount,
                    skippedRowCount: value.skippedRowCount,
                    duplicateRowCount: value.duplicateRowCount,
                    errorRowCount: value.errorRowCount,
                    incomeMinorUnits: value.incomeMinorUnits,
                    expenseMinorUnits: value.expenseMinorUnits,
                    rolledBackAt: value.rolledBackAt,
                    createdAt: value.createdAt,
                    updatedAt: value.updatedAt,
                    importSemanticOrigin: origins["importBatches:\(value.id.uuidString)"]
                )
            },
            transactions: try checkedFetch(FetchDescriptor<FinanceTransaction>(), in: modelContext).map { value in
                .init(
                    id: value.id,
                    type: value.type,
                    amountMinorUnits: value.amountMinorUnits,
                    currencyCode: value.currencyCode,
                    occurredAt: value.occurredAt,
                    localDayKey: value.localDayKey,
                    timeZoneIdentifier: value.timeZoneIdentifier,
                    accountID: value.accountID,
                    destinationAccountID: value.destinationAccountID,
                    categoryID: value.categoryID,
                    merchantID: value.merchantID,
                    rawMerchantText: value.rawMerchantText,
                    note: value.note,
                    categoryDecisionSource: value.categoryDecisionSource,
                    reviewStatus: value.reviewStatus,
                    reviewReasons: value.reviewReasons.sorted { $0.rawValue < $1.rawValue },
                    relatedTransactionID: value.relatedTransactionID,
                    importBatchID: value.importBatchID,
                    externalSource: value.externalSource,
                    externalTransactionID: value.externalTransactionID,
                    importFingerprint: value.importFingerprint,
                    createdAt: value.createdAt,
                    updatedAt: value.updatedAt,
                    deletedAt: value.deletedAt,
                    tagIDs: value.tags.map(\.id).sorted { $0.uuidString < $1.uuidString },
                    importSemanticOrigin: origins["transactions:\(value.id.uuidString)"]
                )
            },
            dailyReviews: try checkedFetch(FetchDescriptor<DailyReview>(), in: modelContext).map { value in
                .init(
                    id: value.id,
                    localDayKey: value.localDayKey,
                    timeZoneIdentifier: value.timeZoneIdentifier,
                    reviewedAt: value.reviewedAt,
                    reviewedChangeToken: value.reviewedChangeToken,
                    createdAt: value.createdAt,
                    updatedAt: value.updatedAt
                )
            },
            appMetadata: try checkedFetch(FetchDescriptor<AppMetadata>(), in: modelContext).map { value in
                .init(
                    id: value.id,
                    defaultCategorySeedVersion: value.defaultCategorySeedVersion,
                    deletedDefaultCategoryKeys: value.deletedDefaultCategoryKeys.sorted(),
                    createdAt: value.createdAt,
                    updatedAt: value.updatedAt
                )
            }
        )
        return package
    }

    private static func checkedFetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, in context: ModelContext,
                                                        afterRead: (@Sendable () throws -> Void)? = nil) throws -> [T] {
        try Task.checkCancellation()
        let values = try context.fetch(descriptor)
        try afterRead?()
        try Task.checkCancellation()
        return values
    }

    private static func originAdditions(for package: NativeBackupPackage) -> [UUID: String] {
        // Build 20 had no duplicate-instance provenance. Preserve every row and UUID,
        // reserving one deterministic base identity and assigning stable instances to others.
        // The existing V4 local metadata model persists these choices, including in backups.
        let unmarked = package.transactions.filter { $0.importSemanticOrigin == nil }
        let grouped = Dictionary(grouping: unmarked.compactMap { row in
            LedgerSyncIdentity.importIdentity(row).map { ($0, row.id) }
        }, by: { $0.0 })
        var additions: [UUID: String] = [:]
        let reserved = Set(package.transactions.compactMap { row -> UUID? in
            guard row.importSemanticOrigin?.hasPrefix("import-base-v1:") == true else { return nil }
            return LedgerSyncIdentity.importIdentity(row)
        })
        for (base, rows) in grouped where rows.count > 1 || reserved.contains(base) {
            let ids = rows.map { $0.1 }.sorted { $0.uuidString < $1.uuidString }
            for id in ids {
                additions[id] = id == ids.first && !reserved.contains(base) ? "import-base-v1:" + base.uuidString : "duplicate-v1:" + id.uuidString
            }
        }
        return additions
    }

    private static func persistOrigins(_ additions: [UUID: String], in context: ModelContext) throws {
        guard !context.hasChanges else { throw ProjectionError.unsavedLocalChanges }
        do {
            for (id, origin) in additions {
                context.insert(ImportEntityOrigin(entityKey: "transactions:\(id.uuidString)", semanticKey: origin))
            }
            try context.save()
        } catch { context.rollbackNotifyingSync(); throw error }
    }

    private static func applyingOrigins(_ additions: [UUID: String], to package: NativeBackupPackage) -> NativeBackupPackage {
        NativeBackupPackage(manifest: package.manifest, accounts: package.accounts,
            categories: package.categories, tags: package.tags, merchants: package.merchants,
            importBatches: package.importBatches, transactions: package.transactions.map { value in
                var value = value
                if let origin = additions[value.id] { value.importSemanticOrigin = origin }
                return value
            }, dailyReviews: package.dailyReviews, appMetadata: package.appMetadata)
    }

    static func records(_ package: NativeBackupPackage) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for value in package.accounts {
            let key = "accounts:\(value.id.uuidString)"
            guard result[key] == nil else { throw NativeBackupError.duplicateIdentifier("accounts") }
            result[key] = try encoder.encode(value)
        }
        for value in package.categories {
            let key = "categories:\(value.id.uuidString)"
            guard result[key] == nil else { throw NativeBackupError.duplicateIdentifier("categories") }
            result[key] = try encoder.encode(value)
        }
        for value in package.tags {
            let key = "tags:\(value.id.uuidString)"
            guard result[key] == nil else { throw NativeBackupError.duplicateIdentifier("tags") }
            result[key] = try encoder.encode(value)
        }
        for value in package.merchants {
            let key = "merchants:\(value.id.uuidString)"
            guard result[key] == nil else { throw NativeBackupError.duplicateIdentifier("merchants") }
            result[key] = try encoder.encode(value)
        }
        for value in package.importBatches {
            let key = "importBatches:\(value.id.uuidString)"
            guard result[key] == nil else { throw NativeBackupError.duplicateIdentifier("importBatches") }
            result[key] = try encoder.encode(value)
        }
        for value in package.transactions {
            let key = "transactions:\(value.id.uuidString)"
            guard result[key] == nil else { throw NativeBackupError.duplicateIdentifier("transactions") }
            result[key] = try encoder.encode(value)
        }
        for value in package.dailyReviews {
            let key = "dailyReviews:\(value.id.uuidString)"
            guard result[key] == nil else { throw NativeBackupError.duplicateIdentifier("dailyReviews") }
            result[key] = try encoder.encode(value)
        }
        for value in package.appMetadata {
            let key = "appMetadata:\(value.id.uuidString)"
            guard result[key] == nil else { throw NativeBackupError.duplicateIdentifier("appMetadata") }
            result[key] = try encoder.encode(value)
        }
        return result
    }

    static func package(from records: [String: Data]) throws -> NativeBackupPackage {
        let decoder = JSONDecoder()
        var accounts: [NativeBackupPackage.AccountPayload] = []
        var categories: [NativeBackupPackage.CategoryPayload] = []
        var tags: [NativeBackupPackage.TagPayload] = []
        var merchants: [NativeBackupPackage.MerchantPayload] = []
        var importBatches: [NativeBackupPackage.ImportBatchPayload] = []
        var transactions: [NativeBackupPackage.TransactionPayload] = []
        var dailyReviews: [NativeBackupPackage.DailyReviewPayload] = []
        var appMetadata: [NativeBackupPackage.AppMetadataPayload] = []
        for (key, data) in records.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { throw ProtectedLedgerReplica.Failure.malformedRecord }
            switch parts[0] {
            case "accounts":
                let value = try decoder.decode(NativeBackupPackage.AccountPayload.self, from: data)
                guard value.id.uuidString == parts[1] else { throw ProtectedLedgerReplica.Failure.malformedRecord }
                accounts.append(value)
            case "categories":
                let value = try decoder.decode(NativeBackupPackage.CategoryPayload.self, from: data)
                guard value.id.uuidString == parts[1] else { throw ProtectedLedgerReplica.Failure.malformedRecord }
                categories.append(value)
            case "tags":
                let value = try decoder.decode(NativeBackupPackage.TagPayload.self, from: data)
                guard value.id.uuidString == parts[1] else { throw ProtectedLedgerReplica.Failure.malformedRecord }
                tags.append(value)
            case "merchants":
                let value = try decoder.decode(NativeBackupPackage.MerchantPayload.self, from: data)
                guard value.id.uuidString == parts[1] else { throw ProtectedLedgerReplica.Failure.malformedRecord }
                merchants.append(value)
            case "importBatches":
                let value = try decoder.decode(NativeBackupPackage.ImportBatchPayload.self, from: data)
                guard value.id.uuidString == parts[1] else { throw ProtectedLedgerReplica.Failure.malformedRecord }
                importBatches.append(value)
            case "transactions":
                let value = try decoder.decode(NativeBackupPackage.TransactionPayload.self, from: data)
                guard value.id.uuidString == parts[1] else { throw ProtectedLedgerReplica.Failure.malformedRecord }
                transactions.append(value)
            case "dailyReviews":
                let value = try decoder.decode(NativeBackupPackage.DailyReviewPayload.self, from: data)
                guard value.id.uuidString == parts[1] else { throw ProtectedLedgerReplica.Failure.malformedRecord }
                dailyReviews.append(value)
            case "appMetadata":
                let value = try decoder.decode(NativeBackupPackage.AppMetadataPayload.self, from: data)
                guard value.id.uuidString == parts[1] else { throw ProtectedLedgerReplica.Failure.malformedRecord }
                appMetadata.append(value)
            default: throw ProtectedLedgerReplica.Failure.unsupportedFormat
            }
        }
        return NativeBackupPackage(
            manifest: .init(
                formatIdentifier: NativeBackupPackage.formatIdentifier,
                schemaVersion: NativeBackupPackage.currentSchemaVersion,
                exportedAt: Date(timeIntervalSince1970: 0),
                appVersion: "sync", baseCurrency: Money.cnyCode
            ),
            accounts: accounts,
            categories: categories,
            tags: tags,
            merchants: merchants,
            importBatches: importBatches,
            transactions: transactions,
            dailyReviews: dailyReviews,
            appMetadata: appMetadata
        )
    }

    /// Upserts existing objects instead of replacing the store or changing their UUIDs.
    /// The entire candidate graph is validated before any local object is touched.
    static func apply(
        _ package: NativeBackupPackage, in context: ModelContext, changedKeys: Set<String>? = nil,
        projectionID: UUID? = nil
    ) throws {
        try apply(
            ValidatedLedgerSnapshot(package), in: context,
            changedKeys: changedKeys, projectionID: projectionID
        )
    }

    static func apply(
        _ projection: ValidatedLedgerSnapshot, in context: ModelContext,
        changedKeys: Set<String>? = nil, projectionID: UUID? = nil, expectedRevision: UInt64? = nil
    ) throws {
        try LedgerSaveRevision.shared.withProjectionBoundary {
            if let expectedRevision, expectedRevision != LedgerSaveRevision.shared.revision {
                throw ReconcileRevision.Failure.stalePlan
            }
            try applyLocked(projection, in: context, changedKeys: changedKeys, projectionID: projectionID)
        }
    }

    private static func applyLocked(
        _ projection: ValidatedLedgerSnapshot, in context: ModelContext,
        changedKeys: Set<String>?, projectionID: UUID?
    ) throws {
        guard !context.hasChanges else { throw ProjectionError.unsavedLocalChanges }
        let package = projection.package
        let accountsIDs = changedKeys?.compactMap { key -> UUID? in
            guard key.hasPrefix("accounts:") else { return nil }
            return UUID(uuidString: String(key.dropFirst("accounts:".count)))
        }
        let existingAccount: [Account]
        if let ids = accountsIDs {
            var fetched: [Account] = []
            for offset in stride(from: 0, to: ids.count, by: 256) {
                let batch = Array(ids[offset..<min(offset + 256, ids.count)])
                fetched += try context.fetch(FetchDescriptor<Account>(predicate: #Predicate { batch.contains($0.id) }))
            }
            existingAccount = fetched
        } else {
            existingAccount = try context.fetch(FetchDescriptor<Account>())
        }
        var accountsByID: [UUID: Account] = [:]
        for value in existingAccount {
            guard accountsByID[value.id] == nil else { throw NativeBackupError.duplicateIdentifier("accounts") }
            accountsByID[value.id] = value
        }
        let categoriesIDs = changedKeys?.compactMap { key -> UUID? in
            guard key.hasPrefix("categories:") else { return nil }
            return UUID(uuidString: String(key.dropFirst("categories:".count)))
        }
        let existingCategory: [Category]
        if let ids = categoriesIDs {
            var fetched: [Category] = []
            for offset in stride(from: 0, to: ids.count, by: 256) {
                let batch = Array(ids[offset..<min(offset + 256, ids.count)])
                fetched += try context.fetch(FetchDescriptor<Category>(predicate: #Predicate { batch.contains($0.id) }))
            }
            existingCategory = fetched
        } else {
            existingCategory = try context.fetch(FetchDescriptor<Category>())
        }
        var categoriesByID: [UUID: Category] = [:]
        for value in existingCategory {
            guard categoriesByID[value.id] == nil else { throw NativeBackupError.duplicateIdentifier("categories") }
            categoriesByID[value.id] = value
        }
        let tagsIDs = changedKeys?.compactMap { key -> UUID? in
            guard key.hasPrefix("tags:") else { return nil }
            return UUID(uuidString: String(key.dropFirst("tags:".count)))
        }
        let existingTag: [Tag]
        if let ids = tagsIDs {
            var fetched: [Tag] = []
            for offset in stride(from: 0, to: ids.count, by: 256) {
                let batch = Array(ids[offset..<min(offset + 256, ids.count)])
                fetched += try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { batch.contains($0.id) }))
            }
            existingTag = fetched
        } else {
            existingTag = try context.fetch(FetchDescriptor<Tag>())
        }
        var tagsByID: [UUID: Tag] = [:]
        for value in existingTag {
            guard tagsByID[value.id] == nil else { throw NativeBackupError.duplicateIdentifier("tags") }
            tagsByID[value.id] = value
        }
        let merchantsIDs = changedKeys?.compactMap { key -> UUID? in
            guard key.hasPrefix("merchants:") else { return nil }
            return UUID(uuidString: String(key.dropFirst("merchants:".count)))
        }
        let existingMerchant: [Merchant]
        if let ids = merchantsIDs {
            var fetched: [Merchant] = []
            for offset in stride(from: 0, to: ids.count, by: 256) {
                let batch = Array(ids[offset..<min(offset + 256, ids.count)])
                fetched += try context.fetch(FetchDescriptor<Merchant>(predicate: #Predicate { batch.contains($0.id) }))
            }
            existingMerchant = fetched
        } else {
            existingMerchant = try context.fetch(FetchDescriptor<Merchant>())
        }
        var merchantsByID: [UUID: Merchant] = [:]
        for value in existingMerchant {
            guard merchantsByID[value.id] == nil else { throw NativeBackupError.duplicateIdentifier("merchants") }
            merchantsByID[value.id] = value
        }
        let importBatchesIDs = changedKeys?.compactMap { key -> UUID? in
            guard key.hasPrefix("importBatches:") else { return nil }
            return UUID(uuidString: String(key.dropFirst("importBatches:".count)))
        }
        let existingImportBatch: [ImportBatch]
        if let ids = importBatchesIDs {
            var fetched: [ImportBatch] = []
            for offset in stride(from: 0, to: ids.count, by: 256) {
                let batch = Array(ids[offset..<min(offset + 256, ids.count)])
                fetched += try context.fetch(FetchDescriptor<ImportBatch>(predicate: #Predicate { batch.contains($0.id) }))
            }
            existingImportBatch = fetched
        } else {
            existingImportBatch = try context.fetch(FetchDescriptor<ImportBatch>())
        }
        var importBatchesByID: [UUID: ImportBatch] = [:]
        for value in existingImportBatch {
            guard importBatchesByID[value.id] == nil else { throw NativeBackupError.duplicateIdentifier("importBatches") }
            importBatchesByID[value.id] = value
        }
        let transactionsIDs = changedKeys?.compactMap { key -> UUID? in
            guard key.hasPrefix("transactions:") else { return nil }
            return UUID(uuidString: String(key.dropFirst("transactions:".count)))
        }
        let existingFinanceTransaction: [FinanceTransaction]
        if let ids = transactionsIDs {
            var fetched: [FinanceTransaction] = []
            for offset in stride(from: 0, to: ids.count, by: 256) {
                let batch = Array(ids[offset..<min(offset + 256, ids.count)])
                fetched += try context.fetch(FetchDescriptor<FinanceTransaction>(predicate: #Predicate { batch.contains($0.id) }))
            }
            existingFinanceTransaction = fetched
        } else {
            existingFinanceTransaction = try context.fetch(FetchDescriptor<FinanceTransaction>())
        }
        var transactionsByID: [UUID: FinanceTransaction] = [:]
        for value in existingFinanceTransaction {
            guard transactionsByID[value.id] == nil else { throw NativeBackupError.duplicateIdentifier("transactions") }
            transactionsByID[value.id] = value
        }
        let dailyReviewsIDs = changedKeys?.compactMap { key -> UUID? in
            guard key.hasPrefix("dailyReviews:") else { return nil }
            return UUID(uuidString: String(key.dropFirst("dailyReviews:".count)))
        }
        let existingDailyReview: [DailyReview]
        if let ids = dailyReviewsIDs {
            var fetched: [DailyReview] = []
            for offset in stride(from: 0, to: ids.count, by: 256) {
                let batch = Array(ids[offset..<min(offset + 256, ids.count)])
                fetched += try context.fetch(FetchDescriptor<DailyReview>(predicate: #Predicate { batch.contains($0.id) }))
            }
            existingDailyReview = fetched
        } else {
            existingDailyReview = try context.fetch(FetchDescriptor<DailyReview>())
        }
        var dailyReviewsByID: [UUID: DailyReview] = [:]
        for value in existingDailyReview {
            guard dailyReviewsByID[value.id] == nil else { throw NativeBackupError.duplicateIdentifier("dailyReviews") }
            dailyReviewsByID[value.id] = value
        }
        let appMetadataIDs = changedKeys?.compactMap { key -> UUID? in
            guard key.hasPrefix("appMetadata:") else { return nil }
            return UUID(uuidString: String(key.dropFirst("appMetadata:".count)))
        }
        let existingAppMetadata: [AppMetadata]
        if let ids = appMetadataIDs {
            var fetched: [AppMetadata] = []
            for offset in stride(from: 0, to: ids.count, by: 256) {
                let batch = Array(ids[offset..<min(offset + 256, ids.count)])
                fetched += try context.fetch(FetchDescriptor<AppMetadata>(predicate: #Predicate { batch.contains($0.id) }))
            }
            existingAppMetadata = fetched
        } else {
            existingAppMetadata = try context.fetch(FetchDescriptor<AppMetadata>())
        }
        var appMetadataByID: [UUID: AppMetadata] = [:]
        for value in existingAppMetadata {
            guard appMetadataByID[value.id] == nil else { throw NativeBackupError.duplicateIdentifier("appMetadata") }
            appMetadataByID[value.id] = value
        }
        if changedKeys != nil {
            let referencedTagIDs = Set(package.transactions.filter {
                changedKeys!.contains("transactions:\($0.id.uuidString)")
            }.flatMap(\.tagIDs))
            let missingIDs = Array(referencedTagIDs.subtracting(tagsByID.keys))
            for offset in stride(from: 0, to: missingIDs.count, by: 256) {
                let batch = Array(missingIDs[offset..<min(offset + 256, missingIDs.count)])
                for tag in try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { batch.contains($0.id) })) {
                    tagsByID[tag.id] = tag
                }
            }
        }
        do {
            for payload in package.accounts where changedKeys == nil ||
                changedKeys!.contains("accounts:\(payload.id.uuidString)") {
                if let value = accountsByID[payload.id] {
                    value.name = payload.name
                    value.type = payload.type
                    value.openingBalanceMinorUnits = payload.openingBalanceMinorUnits
                    value.currencyCode = payload.currencyCode
                    value.isDefault = payload.isDefault
                    value.sortOrder = payload.sortOrder
                    value.archivedAt = payload.archivedAt
                    value.createdAt = payload.createdAt
                    value.updatedAt = payload.updatedAt
                } else {
                    let value = Account(
                        id: payload.id,
                        name: payload.name,
                        type: payload.type,
                        openingBalanceMinorUnits: payload.openingBalanceMinorUnits,
                        currencyCode: payload.currencyCode,
                        isDefault: payload.isDefault,
                        sortOrder: payload.sortOrder,
                        archivedAt: payload.archivedAt,
                        createdAt: payload.createdAt,
                        updatedAt: payload.updatedAt
                    )
                    context.insert(value)
                    accountsByID[payload.id] = value
                }
            }
            for payload in package.categories where changedKeys == nil ||
                changedKeys!.contains("categories:\(payload.id.uuidString)") {
                if let value = categoriesByID[payload.id] {
                    value.kind = payload.kind
                    value.name = payload.name
                    value.parentID = payload.parentID
                    value.defaultDefinitionKey = payload.defaultDefinitionKey
                    value.symbolName = payload.symbolName
                    value.colorToken = payload.colorToken
                    value.sortOrder = payload.sortOrder
                    value.isPinnedForQuickAdd = payload.isPinnedForQuickAdd
                    value.isSystemCategory = payload.isSystemCategory
                    value.isHidden = payload.isHidden
                    value.archivedAt = payload.archivedAt
                    value.createdAt = payload.createdAt
                    value.updatedAt = payload.updatedAt
                } else {
                    let value = Category(
                        id: payload.id,
                        kind: payload.kind,
                        name: payload.name,
                        parentID: payload.parentID,
                        defaultDefinitionKey: payload.defaultDefinitionKey,
                        symbolName: payload.symbolName,
                        colorToken: payload.colorToken,
                        sortOrder: payload.sortOrder,
                        isPinnedForQuickAdd: payload.isPinnedForQuickAdd,
                        isSystemCategory: payload.isSystemCategory,
                        isHidden: payload.isHidden,
                        archivedAt: payload.archivedAt,
                        createdAt: payload.createdAt,
                        updatedAt: payload.updatedAt
                    )
                    context.insert(value)
                    categoriesByID[payload.id] = value
                }
            }
            for payload in package.tags where changedKeys == nil ||
                changedKeys!.contains("tags:\(payload.id.uuidString)") {
                if let value = tagsByID[payload.id] {
                    value.name = payload.name
                    value.colorToken = payload.colorToken
                    value.sortOrder = payload.sortOrder
                    value.archivedAt = payload.archivedAt
                    value.createdAt = payload.createdAt
                    value.updatedAt = payload.updatedAt
                } else {
                    let value = Tag(
                        id: payload.id,
                        name: payload.name,
                        colorToken: payload.colorToken,
                        sortOrder: payload.sortOrder,
                        archivedAt: payload.archivedAt,
                        createdAt: payload.createdAt,
                        updatedAt: payload.updatedAt
                    )
                    context.insert(value)
                    tagsByID[payload.id] = value
                }
            }
            for payload in package.merchants where changedKeys == nil ||
                changedKeys!.contains("merchants:\(payload.id.uuidString)") {
                if let value = merchantsByID[payload.id] {
                    value.canonicalName = payload.canonicalName
                    value.normalizedSearchKey = payload.normalizedSearchKey
                    value.archivedAt = payload.archivedAt
                    value.createdAt = payload.createdAt
                    value.updatedAt = payload.updatedAt
                } else {
                    let value = Merchant(
                        id: payload.id,
                        canonicalName: payload.canonicalName,
                        normalizedSearchKey: payload.normalizedSearchKey,
                        archivedAt: payload.archivedAt,
                        createdAt: payload.createdAt,
                        updatedAt: payload.updatedAt
                    )
                    context.insert(value)
                    merchantsByID[payload.id] = value
                }
            }
            for payload in package.importBatches where changedKeys == nil ||
                changedKeys!.contains("importBatches:\(payload.id.uuidString)") {
                if let value = importBatchesByID[payload.id] {
                    value.sourceType = payload.sourceType
                    value.sourceDisplayName = payload.sourceDisplayName
                    value.sourceFormatVersion = payload.sourceFormatVersion
                    value.startedAt = payload.startedAt
                    value.completedAt = payload.completedAt
                    value.status = payload.status
                    value.totalRowCount = payload.totalRowCount
                    value.importedRowCount = payload.importedRowCount
                    value.skippedRowCount = payload.skippedRowCount
                    value.duplicateRowCount = payload.duplicateRowCount
                    value.errorRowCount = payload.errorRowCount
                    value.incomeMinorUnits = payload.incomeMinorUnits
                    value.expenseMinorUnits = payload.expenseMinorUnits
                    value.rolledBackAt = payload.rolledBackAt
                    value.createdAt = payload.createdAt
                    value.updatedAt = payload.updatedAt
                } else {
                    let value = ImportBatch(
                        id: payload.id,
                        sourceType: payload.sourceType,
                        sourceDisplayName: payload.sourceDisplayName,
                        sourceFormatVersion: payload.sourceFormatVersion,
                        startedAt: payload.startedAt,
                        completedAt: payload.completedAt,
                        status: payload.status,
                        totalRowCount: payload.totalRowCount,
                        importedRowCount: payload.importedRowCount,
                        skippedRowCount: payload.skippedRowCount,
                        duplicateRowCount: payload.duplicateRowCount,
                        errorRowCount: payload.errorRowCount,
                        incomeMinorUnits: payload.incomeMinorUnits,
                        expenseMinorUnits: payload.expenseMinorUnits,
                        rolledBackAt: payload.rolledBackAt,
                        createdAt: payload.createdAt,
                        updatedAt: payload.updatedAt
                    )
                    context.insert(value)
                    importBatchesByID[payload.id] = value
                }
            }
            for payload in package.transactions where changedKeys == nil ||
                changedKeys!.contains("transactions:\(payload.id.uuidString)") {
                guard payload.tagIDs.allSatisfy({ tagsByID[$0] != nil }) else {
                    throw NativeBackupError.invalidReference("transaction.tags during projection")
                }
                if let value = transactionsByID[payload.id] {
                    value.type = payload.type
                    value.amountMinorUnits = payload.amountMinorUnits
                    value.currencyCode = payload.currencyCode
                    value.occurredAt = payload.occurredAt
                    value.localDayKey = payload.localDayKey
                    value.timeZoneIdentifier = payload.timeZoneIdentifier
                    value.accountID = payload.accountID
                    value.destinationAccountID = payload.destinationAccountID
                    value.categoryID = payload.categoryID
                    value.merchantID = payload.merchantID
                    value.rawMerchantText = payload.rawMerchantText
                    value.note = payload.note
                    value.categoryDecisionSource = payload.categoryDecisionSource
                    value.reviewStatus = payload.reviewStatus
                    value.reviewReasons = Set(payload.reviewReasons)
                    value.relatedTransactionID = payload.relatedTransactionID
                    value.importBatchID = payload.importBatchID
                    value.externalSource = payload.externalSource
                    value.externalTransactionID = payload.externalTransactionID
                    value.importFingerprint = payload.importFingerprint
                    value.createdAt = payload.createdAt
                    value.updatedAt = payload.updatedAt
                    value.deletedAt = payload.deletedAt
                    value.tags = payload.tagIDs.compactMap { tagsByID[$0] }
                } else {
                    let value = FinanceTransaction(
                        id: payload.id,
                        type: payload.type,
                        amountMinorUnits: payload.amountMinorUnits,
                        currencyCode: payload.currencyCode,
                        occurredAt: payload.occurredAt,
                        localDayKey: payload.localDayKey,
                        timeZoneIdentifier: payload.timeZoneIdentifier,
                        accountID: payload.accountID,
                        destinationAccountID: payload.destinationAccountID,
                        categoryID: payload.categoryID,
                        merchantID: payload.merchantID,
                        rawMerchantText: payload.rawMerchantText,
                        note: payload.note,
                        categoryDecisionSource: payload.categoryDecisionSource,
                        reviewStatus: payload.reviewStatus,
                        reviewReasons: Set(payload.reviewReasons),
                        relatedTransactionID: payload.relatedTransactionID,
                        importBatchID: payload.importBatchID,
                        externalSource: payload.externalSource,
                        externalTransactionID: payload.externalTransactionID,
                        importFingerprint: payload.importFingerprint,
                        createdAt: payload.createdAt,
                        updatedAt: payload.updatedAt,
                        deletedAt: payload.deletedAt,
                        tags: payload.tagIDs.compactMap { tagsByID[$0] }
                    )
                    context.insert(value)
                    transactionsByID[payload.id] = value
                }
            }
            for payload in package.dailyReviews where changedKeys == nil ||
                changedKeys!.contains("dailyReviews:\(payload.id.uuidString)") {
                if let value = dailyReviewsByID[payload.id] {
                    value.localDayKey = payload.localDayKey
                    value.timeZoneIdentifier = payload.timeZoneIdentifier
                    value.reviewedAt = payload.reviewedAt
                    value.reviewedChangeToken = payload.reviewedChangeToken
                    value.createdAt = payload.createdAt
                    value.updatedAt = payload.updatedAt
                } else {
                    let value = DailyReview(
                        id: payload.id,
                        localDayKey: payload.localDayKey,
                        timeZoneIdentifier: payload.timeZoneIdentifier,
                        reviewedAt: payload.reviewedAt,
                        reviewedChangeToken: payload.reviewedChangeToken,
                        createdAt: payload.createdAt,
                        updatedAt: payload.updatedAt
                    )
                    context.insert(value)
                    dailyReviewsByID[payload.id] = value
                }
            }
            for payload in package.appMetadata where changedKeys == nil ||
                changedKeys!.contains("appMetadata:\(payload.id.uuidString)") {
                if let value = appMetadataByID[payload.id] {
                    value.defaultCategorySeedVersion = payload.defaultCategorySeedVersion
                    value.deletedDefaultCategoryKeys = Set(payload.deletedDefaultCategoryKeys)
                    value.createdAt = payload.createdAt
                    value.updatedAt = payload.updatedAt
                } else {
                    let value = AppMetadata(
                        id: payload.id,
                        defaultCategorySeedVersion: payload.defaultCategorySeedVersion,
                        deletedDefaultCategoryKeys: Set(payload.deletedDefaultCategoryKeys),
                        createdAt: payload.createdAt,
                        updatedAt: payload.updatedAt
                    )
                    context.insert(value)
                    appMetadataByID[payload.id] = value
                }
            }
            let retainedFinanceTransactionIDs = Set(package.transactions.map(\.id))
            for value in existingFinanceTransaction where !retainedFinanceTransactionIDs.contains(value.id) {
                context.delete(value)
            }
            let retainedAccountIDs = Set(package.accounts.map(\.id))
            for value in existingAccount where !retainedAccountIDs.contains(value.id) {
                context.delete(value)
            }
            let retainedCategoryIDs = Set(package.categories.map(\.id))
            for value in existingCategory where !retainedCategoryIDs.contains(value.id) {
                context.delete(value)
            }
            let retainedTagIDs = Set(package.tags.map(\.id))
            for value in existingTag where !retainedTagIDs.contains(value.id) {
                context.delete(value)
            }
            let retainedMerchantIDs = Set(package.merchants.map(\.id))
            for value in existingMerchant where !retainedMerchantIDs.contains(value.id) {
                context.delete(value)
            }
            let retainedImportBatchIDs = Set(package.importBatches.map(\.id))
            for value in existingImportBatch where !retainedImportBatchIDs.contains(value.id) {
                context.delete(value)
            }
            let retainedDailyReviewIDs = Set(package.dailyReviews.map(\.id))
            for value in existingDailyReview where !retainedDailyReviewIDs.contains(value.id) {
                context.delete(value)
            }
            let retainedAppMetadataIDs = Set(package.appMetadata.map(\.id))
            for value in existingAppMetadata where !retainedAppMetadataIDs.contains(value.id) {
                context.delete(value)
            }
            // Provenance travels inside the entity payload and commits with that entity.
            let importedOrigins = package.accounts.map { ("accounts:\($0.id.uuidString)", $0.importSemanticOrigin) }
                + package.categories.map { ("categories:\($0.id.uuidString)", $0.importSemanticOrigin) }
                + package.tags.map { ("tags:\($0.id.uuidString)", $0.importSemanticOrigin) }
                + package.importBatches.map { ("importBatches:\($0.id.uuidString)", $0.importSemanticOrigin) }
                + package.transactions.map { ("transactions:\($0.id.uuidString)", $0.importSemanticOrigin) }
            let desired = Dictionary(uniqueKeysWithValues: importedOrigins.compactMap { key, origin in
                origin.map { (key, $0) }
            })
            var retainedOrigins: Set<String> = []
            for value in try context.fetch(FetchDescriptor<ImportEntityOrigin>()) {
                guard let origin = desired[value.entityKey] else { context.delete(value); continue }
                guard retainedOrigins.insert(value.entityKey).inserted else {
                    throw NativeBackupError.duplicateIdentifier("ImportEntityOrigin")
                }
                if value.semanticKey != origin { value.semanticKey = origin }
            }
            for (key, origin) in desired where !retainedOrigins.contains(key) {
                context.insert(ImportEntityOrigin(entityKey: key, semanticKey: origin))
            }
            if let projectionID {
                let receipts = try context.fetch(FetchDescriptor<SyncProjectionReceipt>())
                guard receipts.count <= 1 else {
                    throw NativeBackupError.duplicateIdentifier("SyncProjectionReceipt")
                }
                if let receipt = receipts.first {
                    receipt.projectionID = projectionID
                } else {
                    context.insert(SyncProjectionReceipt(projectionID: projectionID))
                }
            }
            try context.save()
        } catch {
            context.rollbackNotifyingSync()
            throw error
        }
    }

    enum ProjectionError: Error {
        case unsavedLocalChanges
    }

    static func committedProjectionID(in context: ModelContext) throws -> UUID? {
        let receipts = try context.fetch(FetchDescriptor<SyncProjectionReceipt>())
        guard receipts.count <= 1 else { throw NativeBackupError.duplicateIdentifier("SyncProjectionReceipt") }
        return receipts.first?.projectionID
    }
}

struct ValidatedLedgerSnapshot: Sendable {
    let package: NativeBackupPackage

    init(_ package: NativeBackupPackage) throws {
        try NativeBackupService.validate(package)
        self.package = package
    }
}

actor LedgerSnapshotReader {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) { self.modelContainer = modelContainer }

    func capture(afterRead: (@Sendable () throws -> Void)? = nil,
                 afterCategoriesRead: (@Sendable () throws -> Void)? = nil) throws -> NativeBackupPackage {
        try LedgerSnapshotCodec.captureVersioned(in: modelContainer, afterRead: afterRead, afterCategoriesRead: afterCategoriesRead)
    }
}
