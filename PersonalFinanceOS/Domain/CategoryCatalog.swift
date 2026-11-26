import Foundation

/// Shipped product intent, never an installation receipt or permission to change the ledger.
struct CategoryCatalog: Decodable, Sendable {
    struct Root: Decodable, Sendable {
        let semanticKey: String
        let kind: CategoryKind
        let displayName: String
        let storageDefaultKey: String
        let existingRootReuse: Bool
        let children: [Leaf]
    }

    struct Leaf: Decodable, Sendable {
        let semanticKey: String
        let displayName: String
        let storageDefaultKey: String
        let reuseExistingIdentity: Bool
        let parentSemanticKey: String
    }

    struct LegacyMapping: Decodable, Sendable {
        enum Action: String, Decodable, Sendable {
            case reuse = "preserve_id_key_review_display_structure"
            case retain = "preserve_legacy_no_auto_split"
            case retainAnchor = "preserve_legacy_anchor"
        }
        let oldKey: String
        let oldName: String
        let node: String
        let action: Action
        let targetSemanticKey: String?
        let targetDisplayPath: String?
    }

    struct Definition: Equatable, Sendable, Identifiable {
        var id: String { semanticKey }
        let semanticKey: String
        let storageDefaultKey: String
        let kind: CategoryKind
        let name: String
        let parentSemanticKey: String?
        let reusesExistingIdentity: Bool
    }

    enum Failure: Error {
        case missingResource
        case invalidResource
    }

    let proposedCategoryCatalogRevision: Int
    let retainedSwiftDataSchema: Int
    let catalog: [Root]
    let legacyMappings: [LegacyMapping]

    var definitions: [Definition] {
        catalog.flatMap { root in
            [Definition(
                semanticKey: root.semanticKey, storageDefaultKey: root.storageDefaultKey,
                kind: root.kind, name: root.displayName, parentSemanticKey: nil,
                reusesExistingIdentity: root.existingRootReuse
            )] + root.children.map { leaf in
                Definition(
                    semanticKey: leaf.semanticKey, storageDefaultKey: leaf.storageDefaultKey,
                    kind: root.kind, name: leaf.displayName, parentSemanticKey: leaf.parentSemanticKey,
                    reusesExistingIdentity: leaf.reuseExistingIdentity
                )
            }
        }
    }

    static func load(bundle: Bundle = .main) throws -> CategoryCatalog {
        guard let url = bundle.url(forResource: "taxonomy_v4_plan", withExtension: "json") else {
            throw Failure.missingResource
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> CategoryCatalog {
        let result = try JSONDecoder().decode(CategoryCatalog.self, from: data)
        let definitions = result.definitions
        let semantics = Set(definitions.map(\.semanticKey))
        let storageKeys = Set(definitions.map(\.storageDefaultKey))
        guard result.proposedCategoryCatalogRevision == 4, result.retainedSwiftDataSchema == 4,
              result.catalog.count == 26, definitions.count == 233,
              semantics.count == definitions.count, storageKeys.count == definitions.count,
              definitions.allSatisfy({ !$0.name.isEmpty && !$0.semanticKey.isEmpty && !$0.storageDefaultKey.isEmpty }),
              result.catalog.allSatisfy({ root in root.children.allSatisfy { $0.parentSemanticKey == root.semanticKey } }),
              result.legacyMappings.count == 77,
              Set(result.legacyMappings.map(\.oldKey)).count == 77,
              definitions.filter(\.reusesExistingIdentity).count == 43 else {
            throw Failure.invalidResource
        }
        let bySemantic = Dictionary(uniqueKeysWithValues: definitions.map { ($0.semanticKey, $0) })
        for mapping in result.legacyMappings {
            switch mapping.action {
            case .reuse:
                guard let target = mapping.targetSemanticKey.flatMap({ bySemantic[$0] }),
                      target.reusesExistingIdentity, target.storageDefaultKey == mapping.oldKey else {
                    throw Failure.invalidResource
                }
            case .retain, .retainAnchor:
                guard mapping.targetSemanticKey == nil, !storageKeys.contains(mapping.oldKey) else {
                    throw Failure.invalidResource
                }
            }
        }
        return result
    }
}
