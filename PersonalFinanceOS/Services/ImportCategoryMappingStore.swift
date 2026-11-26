import Foundation

/// Local, derived review memory. Neither the old UUID-only cache nor this cache
/// grants permission to recreate a category or change the authoritative ledger.
enum ImportCategoryMappingStore {
    private struct Entry: Codable {
        let category: ImportCategorySnapshot
        let parent: ImportCategorySnapshot?
        let generation: UUID
    }
    private struct Cache: Codable {
        let version: Int
        var entries: [String: Entry]
    }
    private static let defaultsKey = "importCategoryMappings.v2"
    private static let generationKey = "importCategoryMappings.ledgerGeneration"
    private static let lock = NSLock()

    static func stableKey(source: ImportSourceType, rawCategory: String, kind: CategoryKind) -> String {
        "\(source.rawValue)|\(kind.rawValue)|\(ImportCategoryResolutionService.normalize(rawCategory))"
    }

    static func generation(defaults: UserDefaults = .standard) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return currentGeneration(defaults)
    }

    /// Invoked only after a successful restore inside the shared ledger boundary.
    static func invalidateForRestore(defaults: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(UUID().uuidString, forKey: generationKey)
    }

    static func mappings(categories: [ImportCategorySnapshot], defaults: UserDefaults = .standard) -> [String: UUID] {
        lock.lock()
        defer { lock.unlock() }
        guard let cache = load(defaults) else { return [:] }
        let generation = currentGeneration(defaults)
        let grouped = Dictionary(grouping: categories, by: \.id)
        let byID = grouped.compactMapValues { $0.count == 1 ? $0[0] : nil }
        return cache.entries.reduce(into: [:]) { result, pair in
            let entry = pair.value
            guard entry.generation == generation, let current = byID[entry.category.id],
                  eligible(current, byID: byID), sameIdentity(entry.category, current) else { return }
            let parent = current.parentID.flatMap { byID[$0] }
            if samePurpose(entry.category, current), sameParent(entry.parent, parent) {
                result[pair.key] = current.id
                return
            }
            // Only shipped, recognizable old/current purpose paths justify a
            // rename/move without asking again. Unknown custom edits are retained
            // in the cache but are not returned as automatic review choices.
            var baseline = [entry.category.id: entry.category]
            if let oldParent = entry.parent { baseline[oldParent.id] = oldParent }
            if let index = ImportCategoryAliasIndex.bundled,
               index.recognizesPurpose(entry.category, categoriesByID: baseline),
               index.recognizesPurpose(current, categoriesByID: byID) {
                result[pair.key] = current.id
            }
        }
    }

    @discardableResult
    static func remember(source: ImportSourceType, rawCategory: String, kind: CategoryKind, targetID: UUID,
                         categories: [ImportCategorySnapshot], expectedGeneration: UUID? = nil,
                         defaults: UserDefaults = .standard) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let generation = currentGeneration(defaults)
        guard expectedGeneration == nil || expectedGeneration == generation, var cache = load(defaults) else { return false }
        let grouped = Dictionary(grouping: categories, by: \.id)
        let byID = grouped.compactMapValues { $0.count == 1 ? $0[0] : nil }
        guard let category = byID[targetID], category.kind == kind, eligible(category, byID: byID) else { return false }
        cache.entries[stableKey(source: source, rawCategory: rawCategory, kind: kind)] = Entry(
            category: category, parent: category.parentID.flatMap { byID[$0] }, generation: generation)
        guard let data = try? JSONEncoder().encode(cache) else { return false }
        defaults.set(data, forKey: defaultsKey)
        return true
    }

    private static func load(_ defaults: UserDefaults) -> Cache? {
        guard defaults.object(forKey: defaultsKey) != nil else { return Cache(version: 2, entries: [:]) }
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        guard let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 2 else { return nil }
        return cache
    }

    private static func currentGeneration(_ defaults: UserDefaults) -> UUID {
        if let raw = defaults.string(forKey: generationKey), let value = UUID(uuidString: raw) { return value }
        let value = UUID()
        defaults.set(value.uuidString, forKey: generationKey)
        return value
    }

    private static func eligible(_ value: ImportCategorySnapshot, byID: [UUID: ImportCategorySnapshot]) -> Bool {
        guard value.isActiveForSelection else { return false }
        guard let parentID = value.parentID else { return true }
        guard let parent = byID[parentID] else { return false }
        return parent.parentID == nil && parent.kind == value.kind && parent.isActiveForSelection
    }

    private static func sameIdentity(_ first: ImportCategorySnapshot, _ second: ImportCategorySnapshot) -> Bool {
        first.id == second.id && first.createdAt == second.createdAt && first.kind == second.kind &&
            first.defaultDefinitionKey == second.defaultDefinitionKey
    }

    private static func samePurpose(_ first: ImportCategorySnapshot, _ second: ImportCategorySnapshot) -> Bool {
        first.parentID == second.parentID &&
            ImportCategoryResolutionService.normalize(first.name) == ImportCategoryResolutionService.normalize(second.name)
    }

    private static func sameParent(_ first: ImportCategorySnapshot?, _ second: ImportCategorySnapshot?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case let (.some(first), .some(second)): return sameIdentity(first, second) && samePurpose(first, second)
        default: return false
        }
    }
}
