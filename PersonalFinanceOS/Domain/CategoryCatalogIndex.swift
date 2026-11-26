import Foundation

/// Read-only shipped names and compatibility groups; never an installation receipt.
struct CategoryCatalogIndex: Sendable {
    static let bundled = (try? CategoryCatalog.load()).map(CategoryCatalogIndex.init)

    let bySemanticKey: [String: CategoryCatalog.Definition]
    let byStorageKey: [String: CategoryCatalog.Definition]
    let legacyStorageKeys: Set<String>
    let newStorageKeys: Set<String>
    private let searchTermsByStorageKey: [String: [String]]

    init(catalog: CategoryCatalog) {
        let definitions = catalog.definitions
        let semanticDefinitions = Dictionary(uniqueKeysWithValues: definitions.map { ($0.semanticKey, $0) })
        bySemanticKey = semanticDefinitions
        byStorageKey = Dictionary(uniqueKeysWithValues: definitions.map { ($0.storageDefaultKey, $0) })
        legacyStorageKeys = Set(catalog.legacyMappings.filter { $0.action != .reuse }.map(\.oldKey))
        newStorageKeys = Set(definitions.filter { !$0.reusesExistingIdentity }.map(\.storageDefaultKey))
        var terms: [String: [String]] = [:]
        for definition in definitions {
            terms[definition.storageDefaultKey, default: []].append(definition.name)
            if let parent = definition.parentSemanticKey.flatMap({ semanticDefinitions[$0] }) {
                terms[definition.storageDefaultKey, default: []].append(parent.name + "/" + definition.name)
            }
        }
        for mapping in catalog.legacyMappings {
            terms[mapping.oldKey, default: []].append(mapping.oldName)
        }
        searchTermsByStorageKey = terms.mapValues { Array(Set($0.map(Self.normalizedSearch))) }
    }

    func matches(storageKey: String, query: String) -> Bool {
        let query = Self.normalizedSearch(query)
        guard !query.isEmpty, !storageKey.isEmpty else { return false }
        return searchTermsByStorageKey[storageKey, default: []].contains { $0.contains(query) }
    }

    private static func normalizedSearch(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && $0 != "/" && $0 != "／" }
    }
}
