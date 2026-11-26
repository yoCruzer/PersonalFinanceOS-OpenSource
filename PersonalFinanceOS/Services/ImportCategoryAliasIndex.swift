import Foundation

/// Shipped source vocabulary. A recognized obsolete path must not create a new
/// child under its old root when its real category has moved or is unavailable.
struct ImportCategoryAliasIndex: Sendable {
    private struct Resource: Decodable {
        struct Alias: Decodable { let sources: [String]; let storageKey: String }
        let version: Int
        let aliases: [Alias]
    }

    static let bundled: Self? = {
        guard let url = Bundle.main.url(forResource: "import_category_aliases_v1", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? CategoryCatalog.load() else { return nil }
        return try? Self(data: data, catalog: catalog)
    }()

    private let keysBySource: [String: Set<String>]
    private let definitions: [String: CategoryCatalog.Definition]
    private let frozen: [String: DefaultFinanceDataService.FrozenDefinition]

    init(data: Data, catalog: CategoryCatalog) throws {
        let resource = try JSONDecoder().decode(Resource.self, from: data)
        let definitions = Dictionary(uniqueKeysWithValues: catalog.definitions.map { ($0.storageDefaultKey, $0) })
        let frozen = Dictionary(uniqueKeysWithValues: DefaultFinanceDataService.frozenDefinitions.map { ($0.key, $0) })
        guard resource.version == 1, resource.aliases.allSatisfy({ frozen[$0.storageKey] != nil || definitions[$0.storageKey] != nil }) else {
            throw CategoryCatalog.Failure.invalidResource
        }
        var keys: [String: Set<String>] = [:]
        for alias in resource.aliases {
            for source in alias.sources { keys[Self.normalize(source), default: []].insert(alias.storageKey) }
        }
        let bySemantic = Dictionary(uniqueKeysWithValues: catalog.definitions.map { ($0.semanticKey, $0) })
        for definition in catalog.definitions {
            let path = definition.parentSemanticKey.flatMap { bySemantic[$0]?.name }.map { $0 + "/" } ?? ""
            keys[Self.normalize(path + definition.name), default: []].insert(definition.storageDefaultKey)
        }
        for legacy in catalog.legacyMappings {
            keys[Self.normalize(legacy.oldName), default: []].insert(legacy.oldKey)
        }
        keysBySource = keys
        self.definitions = definitions
        self.frozen = frozen
    }

    func storageKeys(source: String, kind: CategoryKind) -> Set<String> {
        Set(keysBySource[Self.normalize(source), default: []].filter {
            (definitions[$0]?.kind ?? frozen[$0]?.kind) == kind
        })
    }

    func recognizesPurpose(_ category: ImportCategorySnapshot, categoriesByID: [UUID: ImportCategorySnapshot]) -> Bool {
        let key = category.defaultDefinitionKey
        guard !key.isEmpty else { return false }
        let old = frozen[key], current = definitions[key]
        let names = [old?.name, current?.name].compactMap { $0 }.map(Self.normalize)
        guard names.contains(Self.normalize(category.name)) else { return false }
        let currentParent = current?.parentSemanticKey.flatMap { semantic in definitions.values.first { $0.semanticKey == semantic } }
        let oldParent = old?.parentKey.flatMap { frozen[$0] }
        if oldParent == nil && currentParent == nil { return category.parentID == nil }
        guard let parent = category.parentID.flatMap({ categoriesByID[$0] }), parent.parentID == nil,
              parent.kind == category.kind, parent.isActiveForSelection else { return false }
        let allowedKeys = [oldParent?.key, currentParent?.storageDefaultKey].compactMap { $0 }
        let allowedNames = [oldParent?.name, currentParent?.name].compactMap { $0 }.map(Self.normalize)
        return allowedKeys.contains(parent.defaultDefinitionKey) && allowedNames.contains(Self.normalize(parent.name))
    }

    private static func normalize(_ value: String) -> String { ImportCategoryResolutionService.normalize(value) }
}
