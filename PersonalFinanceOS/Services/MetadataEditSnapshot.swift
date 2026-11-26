import Foundation

/// Immutable scalar metadata for rejecting stale UI objects before a mutation.
/// Tag transaction relationships are read by deletion/migration writers, not these scalar editors.
enum MetadataEditSnapshot {
    struct AccountValue: Equatable, Sendable {
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

    struct CategoryValue: Equatable, Sendable {
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

    struct TagValue: Equatable, Sendable {
        let id: UUID
        let name: String
        let colorToken: String
        let sortOrder: Int
        let archivedAt: Date?
        let createdAt: Date
        let updatedAt: Date

        init(_ value: Tag) {
            id = value.id
            name = value.name
            colorToken = value.colorToken
            sortOrder = value.sortOrder
            archivedAt = value.archivedAt
            createdAt = value.createdAt
            updatedAt = value.updatedAt
        }
    }
}
