import CryptoKit
import Foundation

/// Wire identities are separate from persisted UUIDs. Existing local IDs are never rewritten.
struct LedgerSyncIdentity: Codable, Equatable, Sendable {
    private(set) var localToWire: [String: UUID] = [:]
    // A later explicit re-import may create a new local row for a historical wire identity.
    // Prefer that current row, while retaining history for identities with no replacement.
    private var preferredLocalIDs: [String: UUID]?
    // Only needed when joining a pre-upgrade occurrence with a different fingerprint namespace.
    private var adoptedOccurrenceOrigins: [UUID: String]?
    static var bootstrapAccountID: UUID { stableID("bootstrap-account") }

    mutating func capture(_ package: NativeBackupPackage) throws -> [String: Data] {
        var activeKeys: [String] = []
        for value in package.accounts {
            let key = "accounts:\(value.id.uuidString)"
            activeKeys.append(key)
            if localToWire[key] == nil { localToWire[key] = value.importSemanticOrigin.map { Self.stableID("accounts:" + $0) } ?? value.id }
        }
        for value in package.categories {
            let key = "categories:\(value.id.uuidString)"
            activeKeys.append(key)
            if localToWire[key] == nil { localToWire[key] = value.defaultDefinitionKey.isEmpty ? (value.importSemanticOrigin.map { Self.stableID("categories:" + $0) } ?? value.id) : Self.stableID("category:" + value.defaultDefinitionKey) }
        }
        for value in package.tags {
            let key = "tags:\(value.id.uuidString)"
            activeKeys.append(key)
            if localToWire[key] == nil { localToWire[key] = value.importSemanticOrigin.map { Self.stableID("tags:" + $0) } ?? value.id }
        }
        for value in package.merchants {
            let key = "merchants:\(value.id.uuidString)"
            activeKeys.append(key)
            if localToWire[key] == nil { localToWire[key] = value.id }
        }
        for value in package.importBatches {
            let key = "importBatches:\(value.id.uuidString)"
            activeKeys.append(key)
            if localToWire[key] == nil { localToWire[key] = value.importSemanticOrigin.map { Self.stableID("importBatches:" + $0) } ?? value.id }
        }
        for value in package.transactions {
            let key = "transactions:\(value.id.uuidString)"
            activeKeys.append(key)
            // A legacy replica may already own a wire ID from before a type correction.
            // Explicit occurrences still supersede an ambiguous historical alias.
            let isExplicitInstance = value.importSemanticOrigin.map { !$0.hasPrefix("import-base-v1:") } ?? false
            let adopted = localToWire[key].flatMap { adoptedOccurrenceOrigins?[$0] }
            let usesAdoptedOccurrence = adopted != nil && value.importSemanticOrigin?.hasPrefix("occurrence-v1:") == true
            if (isExplicitInstance && !usesAdoptedOccurrence) || localToWire[key] == nil {
                localToWire[key] = Self.importIdentity(value) ?? value.id
            }
        }
        for value in package.dailyReviews {
            let key = "dailyReviews:\(value.id.uuidString)"
            activeKeys.append(key)
            if localToWire[key] == nil { localToWire[key] = Self.stableID("review:" + value.localDayKey + ":" + value.timeZoneIdentifier) }
        }
        for value in package.appMetadata {
            let key = "appMetadata:\(value.id.uuidString)"
            activeKeys.append(key)
            if localToWire[key] == nil { localToWire[key] = Self.stableID("appMetadata") }
        }
        var activeInverse: [String: UUID] = [:]
        for key in activeKeys {
            let parts = key.split(separator: ":", maxSplits: 1)
            let wireKey = "\(parts[0]):\(localToWire[key]!.uuidString)"
            let localID = UUID(uuidString: String(parts[1]))!
            guard activeInverse.updateValue(localID, forKey: wireKey) == nil else {
                throw NativeBackupError.duplicateIdentifier(wireKey)
            }
        }
        if preferredLocalIDs == nil { preferredLocalIDs = [:] }
        preferredLocalIDs?.merge(activeInverse) { _, current in current }
        // Keep historical aliases alongside tombstones: a concurrent winning edit can
        // resurrect a wire record and must recover its original on-device UUID.
        let wire = translated(package, wireOrigins: adoptedOccurrenceOrigins) { kind, id in
            localToWire["\(kind):\(id.uuidString)"] ?? id
        }
        var records = try LedgerSnapshotCodec.records(Self.preservingWireOrigins(wire))
        for key in package.appMetadata.flatMap(\.deletedDefaultCategoryKeys) {
            records["seedDeletion:" + key] = Data([1])
        }
        return records
    }

    /// An older device and a newer one can independently import the same no-ID
    /// event before joining. Reuse a published base key only when its stored
    /// fingerprint, merchant and occurrence ordinal corroborate the version transition.
    mutating func adoptCompatibleImportKeys(in local: NativeBackupPackage, from replica: ProtectedLedgerReplica) throws {
        guard !replica.records.isEmpty else { return }
        let decoder = JSONDecoder()
        for row in local.transactions {
            let key = "transactions:" + row.id.uuidString
            guard localToWire[key] == nil, let ownID = Self.importIdentity(row),
                  replica.records["transactions:" + ownID.uuidString] == nil,
                  let alias = Self.alternateImportIdentity(row),
                  let bytes = replica.records["transactions:" + alias.id.uuidString]?.payload else { continue }
            let remote = try decoder.decode(NativeBackupPackage.TransactionPayload.self, from: bytes)
            guard remote.id == alias.id, remote.externalSource == row.externalSource, remote.externalTransactionID.isEmpty,
                  remote.rawMerchantText == row.rawMerchantText,
                  remote.importFingerprint == alias.fingerprint || remote.importFingerprint == row.importFingerprint,
                  remote.importSemanticOrigin == alias.origin || (remote.importSemanticOrigin == nil && alias.origin.hasPrefix("import-base-v1:"))
            else { continue }
            localToWire[key] = alias.id
            if alias.origin.hasPrefix("occurrence-v1:") {
                if adoptedOccurrenceOrigins == nil { adoptedOccurrenceOrigins = [:] }
                adoptedOccurrenceOrigins?[alias.id] = alias.origin
            }
        }
    }

    private static func alternateImportIdentity(_ row: NativeBackupPackage.TransactionPayload)
        -> (id: UUID, origin: String, fingerprint: String)? {
        guard let source = row.externalSource, source != .genericCSV, row.externalTransactionID.isEmpty,
              !row.importFingerprint.isEmpty else { return nil }
        let legacy = BillParserSupport.legacyFingerprint(row.importFingerprint)
        let modern = BillParserSupport.merchantFingerprint(source: source, legacy: legacy, merchant: row.rawMerchantText, externalID: "")
        guard row.importFingerprint == legacy || row.importFingerprint == modern else { return nil }
        let alternate = row.importFingerprint == legacy ? modern : legacy
        for type in TransactionType.allCases {
            guard let base = importIdentity(source: source, type: type, externalID: "", fingerprint: row.importFingerprint),
                  let other = importIdentity(source: source, type: type, externalID: "", fingerprint: alternate) else { continue }
            if let origin = row.importSemanticOrigin, origin.hasPrefix("occurrence-v1:" + base.uuidString + ":"),
               let ordinal = origin.split(separator: ":").last.flatMap({ Int($0) }), ordinal > 0 {
                let otherOrigin = "occurrence-v1:" + other.uuidString + ":" + String(ordinal)
                return (stableID("transactions:" + otherOrigin), otherOrigin, alternate)
            }
            if row.importSemanticOrigin == "import-base-v1:" + base.uuidString || (row.importSemanticOrigin == nil && type == row.type) {
                return (other, "import-base-v1:" + other.uuidString, alternate)
            }
        }
        return nil
    }

    /// A fresh, unused bootstrap account may adopt the cloud default while retaining its
    /// on-device UUID. Never call this for a ledger containing user transactions or metadata.
    mutating func adoptBootstrapAccount(localID: UUID, wireID: UUID) {
        localToWire["accounts:\(localID.uuidString)"] = wireID
    }

    func localPackage(from replica: ProtectedLedgerReplica) throws -> NativeBackupPackage {
        let inverse = try localAliases()
        var package = try Self.wirePackage(from: replica.livePayloads)
        // Concurrent default-account selections converge to one selection without merging
        // distinct accounts or adding their opening balances together.
        let candidates = package.accounts.filter { $0.isDefault && $0.archivedAt == nil }
        let selected = candidates.max { lhs, rhs in
            let left = replica.records["accounts:\(lhs.id.uuidString)"]!.revision
            let right = replica.records["accounts:\(rhs.id.uuidString)"]!.revision
            if left != right { return left < right }
            return lhs.id.uuidString < rhs.id.uuidString
        }?.id ?? package.accounts.filter { $0.archivedAt == nil }
            .map(\.id).min { $0.uuidString < $1.uuidString }
        let accounts = package.accounts.map { value in
            var value = value
            value.isDefault = value.id == selected
            return value
        }
        package = NativeBackupPackage(
            manifest: package.manifest, accounts: accounts, categories: package.categories,
            tags: package.tags, merchants: package.merchants, importBatches: package.importBatches,
            transactions: package.transactions, dailyReviews: package.dailyReviews,
            appMetadata: package.appMetadata
        )
        return translated(package) { kind, id in inverse["\(kind):\(id.uuidString)"] ?? id }
    }

    func localPackage(fromWireRecords records: [String: Data]) throws -> NativeBackupPackage {
        let inverse = try localAliases()
        return translated(try Self.wirePackage(from: records)) { kind, id in
            inverse["\(kind):\(id.uuidString)"] ?? id
        }
    }

    private func localAliases() throws -> [String: UUID] {
        var inverse: [String: UUID] = [:]
        for (key, wireID) in localToWire {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let localID = UUID(uuidString: String(parts[1])) else {
                throw ProtectedLedgerReplica.Failure.malformedRecord
            }
            let wireKey = "\(parts[0]):\(wireID.uuidString)"
            if let preferred = preferredLocalIDs?[wireKey], preferred != localID { continue }
            // Two local rows for one semantic import/default identity need explicit repair;
            // silently deleting either would violate local data preservation.
            if let existing = inverse[wireKey], existing != localID {
                throw NativeBackupError.duplicateIdentifier(wireKey)
            }
            inverse[wireKey] = localID
        }
        return inverse
    }

    static func wirePackage(from records: [String: Data]) throws -> NativeBackupPackage {
        let package = try LedgerSnapshotCodec.package(from: records.filter { !$0.key.hasPrefix("seedDeletion:") })
        var deletedKeys: Set<String> = []
        for (key, value) in records where key.hasPrefix("seedDeletion:") {
            guard value == Data([1]) else { throw ProtectedLedgerReplica.Failure.malformedRecord }
            deletedKeys.insert(String(key.dropFirst("seedDeletion:".count)))
        }
        let metadata = package.appMetadata.map { value in
            var value = value
            value.deletedDefaultCategoryKeys = Array(Set(value.deletedDefaultCategoryKeys).union(deletedKeys)).sorted()
            return value
        }
        return NativeBackupPackage(
            manifest: package.manifest, accounts: package.accounts, categories: package.categories,
            tags: package.tags, merchants: package.merchants, importBatches: package.importBatches,
            transactions: preservingWireOrigins(package).transactions, dailyReviews: package.dailyReviews, appMetadata: metadata
        )
    }

    // Build 33 can transmit a corrected transaction under the wire key assigned before
    // the edit. Pin that key before translating it into a receiver's local UUID.
    private static func preservingWireOrigins(_ package: NativeBackupPackage) -> NativeBackupPackage {
        let transactions = package.transactions.map { transaction in
            var transaction = transaction
            if let inferred = importIdentity(transaction), inferred != transaction.id,
               transaction.importSemanticOrigin?.hasPrefix("import-base-v1:") != false {
                transaction.importSemanticOrigin = "import-base-v1:" + transaction.id.uuidString
            }
            return transaction
        }
        return NativeBackupPackage(manifest: package.manifest, accounts: package.accounts, categories: package.categories,
            tags: package.tags, merchants: package.merchants, importBatches: package.importBatches,
            transactions: transactions, dailyReviews: package.dailyReviews, appMetadata: package.appMetadata)
    }

    static func baseOrigin(source: ImportSourceType?, type: TransactionType, externalID: String, fingerprint: String) -> String? {
        importIdentity(source: source, type: type, externalID: externalID, fingerprint: fingerprint)
            .map { "import-base-v1:" + $0.uuidString }
    }

    static func importIdentity(_ value: NativeBackupPackage.TransactionPayload) -> UUID? {
        if let origin = value.importSemanticOrigin {
            if origin.hasPrefix("import-base-v1:"), let id = UUID(uuidString: String(origin.dropFirst("import-base-v1:".count))) { return id }
            return stableID("transactions:" + origin)
        }
        return importIdentity(source: value.externalSource, type: value.type,
                              externalID: value.externalTransactionID, fingerprint: value.importFingerprint)
    }

    static func importIdentity(source: ImportSourceType?, type: TransactionType, externalID: String, fingerprint: String) -> UUID? {
        guard let source else { return nil }
        // For legacy rows with a provider ID the immutable digest can prove the
        // original direction even if a Build 33 edit predates the provenance marker.
        var sourceType = type
        if !externalID.isEmpty, !fingerprint.isEmpty,
           BillParserSupport.eventFingerprint(source: source, type: type, eventID: externalID) != fingerprint,
           let original = TransactionType.allCases.first(where: {
               BillParserSupport.eventFingerprint(source: source, type: $0, eventID: externalID) == fingerprint
           }) {
            sourceType = original
        }
        let identifier: String
        if source == .jd, sourceType == .refund, !fingerprint.isEmpty {
            // JD order IDs can own multiple refund events; the parser fingerprints each event.
            identifier = "fingerprint:" + fingerprint
        } else if !externalID.isEmpty {
            identifier = "id:" + externalID
        } else if !fingerprint.isEmpty {
            identifier = "fingerprint:" + fingerprint
        } else { return nil }
        return stableID("import:\(source.rawValue):\(sourceType.rawValue):\(identifier)")
    }

    private static func stableID(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(("PersonalFinanceOS.sync.v1:" + key).utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func translated(
        _ package: NativeBackupPackage,
        wireOrigins: [UUID: String]? = nil,
        id: (String, UUID) -> UUID
    ) -> NativeBackupPackage {
        let accounts = package.accounts.map { value in
            var value = value
            value.id = id("accounts", value.id)
            return value
        }
        let categories = package.categories.map { value in
            var value = value
            value.id = id("categories", value.id)
            value.parentID = value.parentID.map { id("categories", $0) }
            return value
        }
        let tags = package.tags.map { value in
            var value = value
            value.id = id("tags", value.id)
            return value
        }
        let merchants = package.merchants.map { value in
            var value = value
            value.id = id("merchants", value.id)
            return value
        }
        let importBatches = package.importBatches.map { value in
            var value = value
            value.id = id("importBatches", value.id)
            return value
        }
        let transactions = package.transactions.map { value in
            var value = value
            value.id = id("transactions", value.id)
            if let origin = wireOrigins?[value.id] { value.importSemanticOrigin = origin }
            value.accountID = value.accountID.map { id("accounts", $0) }
            value.destinationAccountID = value.destinationAccountID.map { id("accounts", $0) }
            value.categoryID = value.categoryID.map { id("categories", $0) }
            value.merchantID = value.merchantID.map { id("merchants", $0) }
            value.relatedTransactionID = value.relatedTransactionID.map { id("transactions", $0) }
            value.importBatchID = value.importBatchID.map { id("importBatches", $0) }
            value.tagIDs = value.tagIDs.map { id("tags", $0) }.sorted { $0.uuidString < $1.uuidString }
            return value
        }
        let dailyReviews = package.dailyReviews.map { value in
            var value = value
            value.id = id("dailyReviews", value.id)
            return value
        }
        let appMetadata = package.appMetadata.map { value in
            var value = value
            value.id = id("appMetadata", value.id)
            return value
        }
        return NativeBackupPackage(
            manifest: package.manifest,
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
}
