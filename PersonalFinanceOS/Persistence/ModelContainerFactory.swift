import Foundation
import SwiftData

enum ModelContainerFactory {
    static let cloudContainerIdentifier = "iCloud.org.example.PersonalFinanceOS"

    /// The authoritative Build 20 store is always local, including while optional sync is ON.
    /// CKSyncEngine owns the separate replica; account changes cannot purge this store.
    static func configuration(isStoredInMemoryOnly: Bool = false) -> ModelConfiguration {
        ModelConfiguration(
            "PersonalFinanceOSV2",
            schema: AppSchema.schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            allowsSave: true,
            cloudKitDatabase: .none
        )
    }

    @MainActor
    static func make(isStoredInMemoryOnly: Bool = false) throws -> ModelContainer {
        try make(configuration: configuration(isStoredInMemoryOnly: isStoredInMemoryOnly))
    }

    @MainActor
    static func make(configuration: ModelConfiguration) throws -> ModelContainer {
        return try ModelContainer(
            for: AppSchema.schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
