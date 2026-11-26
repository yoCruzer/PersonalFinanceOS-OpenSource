import Foundation
import SwiftData

enum AppSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static let models: [any PersistentModel.Type] = AppSchemaV2.models + [SyncProjectionReceipt.self]

    /// Device-local infrastructure, deliberately excluded from ledger backups and CloudKit.
    /// Saved in the same transaction as an imported graph to make crash recovery unambiguous.
    @Model
    final class SyncProjectionReceipt {
        var projectionID: UUID?

        init(projectionID: UUID? = nil) {
            self.projectionID = projectionID
        }
    }
}

typealias SyncProjectionReceipt = AppSchemaV3.SyncProjectionReceipt

// V1/V2/V3 remain frozen. Add provenance without changing their financial model classes.
enum AppSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static let models: [any PersistentModel.Type] = AppSchemaV3.models + [ImportEntityOrigin.self]

    @Model
    final class ImportEntityOrigin {
        var entityKey: String = ""
        var semanticKey: String = ""

        init(entityKey: String, semanticKey: String) {
            self.entityKey = entityKey
            self.semanticKey = semanticKey
        }
    }
}

typealias ImportEntityOrigin = AppSchemaV4.ImportEntityOrigin
