import Foundation

enum ImportCategoryResolutionConfidence: Int, Comparable, Sendable {
    case none
    case low
    case medium
    case high

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum ImportCategoryResolutionReason: String, Sendable {
    case rememberedMapping
    case exactPath
    case uniqueChildName
    case sourceAlias
    case inferredFromDescription
    case existingRoot
    case proposedChild
    case unresolved
}

struct ImportCategoryResolution: Equatable, Sendable {
    let resolvedCategoryID: UUID?
    let confidence: ImportCategoryResolutionConfidence
    let reason: ImportCategoryResolutionReason
    let proposedRootID: UUID?
    let proposedChildName: String?
    let requiresReview: Bool
}

enum ImportCategoryReviewList {
    static let summaryLimit = 8

    static func summaryRows(_ rows: [ImportCandidate]) -> [ImportCandidate] {
        Array(rows.prefix(summaryLimit))
    }

    static func filteredRows(
        _ rows: [ImportCandidate],
        query: String
    ) -> [ImportCandidate] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return rows }
        return rows.filter { row in
            [
                "\(row.rowNumber)",
                row.categoryName,
                row.persistedNote,
                row.merchantName,
                row.type == .income ? "收入" : "支出"
            ].contains { $0.localizedCaseInsensitiveContains(value) }
        }
    }
}

enum ImportCategoryResolutionService {
    static func resolve(
        source: ImportSourceType,
        rawCategory: String,
        note: String,
        merchant: String,
        type: TransactionType,
        kind: CategoryKind,
        categories: [Category],
        rememberedCategoryID: UUID? = nil
    ) -> ImportCategoryResolution {
        resolve(
            source: source,
            rawCategory: rawCategory,
            note: note,
            merchant: merchant,
            type: type,
            kind: kind,
            categories: categories.map {
                ImportCategorySnapshot(
                    id: $0.id,
                    kind: $0.kind,
                    name: $0.name,
                    parentID: $0.parentID,
                    symbolName: $0.symbolName,
                    colorToken: $0.colorToken,
                    sortOrder: $0.sortOrder,
                    isHidden: $0.isHidden,
                    archivedAt: $0.archivedAt,
                    createdAt: $0.createdAt,
                    defaultDefinitionKey: $0.defaultDefinitionKey
                )
            },
            rememberedCategoryID: rememberedCategoryID
        )
    }

    static func resolve(
        source: ImportSourceType,
        rawCategory: String,
        note: String,
        merchant: String,
        type: TransactionType,
        kind: CategoryKind,
        categories: [ImportCategorySnapshot],
        rememberedCategoryID: UUID? = nil
    ) -> ImportCategoryResolution {
        precondition((type == .income) == (kind == .income))
        let categoriesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let active = categories.filter { category in
            guard category.kind == kind, category.isActiveForSelection else { return false }
            guard let parentID = category.parentID else { return true }
            guard let parent = categoriesByID[parentID] else { return false }
            return parent.kind == kind && parent.parentID == nil && parent.isActiveForSelection
        }
        let activeByID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })

        if let rememberedCategoryID, activeByID[rememberedCategoryID] != nil {
            return resolved(rememberedCategoryID, confidence: .high, reason: .rememberedMapping)
        }

        let components = pathComponents(rawCategory)
        let aliasKeys = ImportCategoryAliasIndex.bundled?.storageKeys(source: rawCategory, kind: kind) ?? []
        if !aliasKeys.isEmpty {
            let targets = active.filter { value in
                if aliasKeys.contains(value.defaultDefinitionKey),
                   ImportCategoryAliasIndex.bundled?.recognizesPurpose(value, categoriesByID: activeByID) == true { return true }
                guard aliasKeys.contains(CategoryPurposeCompatibility.chargingKey) else { return false }
                let parent = value.parentID.flatMap { activeByID[$0] }
                return CategoryPurposeCompatibility.matches(semanticKey: CategoryPurposeCompatibility.chargingKey,
                    kind: value.kind, name: value.name, storageKey: value.defaultDefinitionKey,
                    parentKind: parent?.kind, parentName: parent?.name, parentKey: parent?.defaultDefinitionKey,
                    parentIsRoot: parent != nil && parent?.parentID == nil)
            }
            let exactMatches = active.filter {
                normalize(displayPath(for: $0, categories: active)) == normalize(rawCategory)
            }
            let possibleIDs = Set(targets.map(\.id)).union(exactMatches.map(\.id))
            if possibleIDs.count > 1 {
                return ImportCategoryResolution(resolvedCategoryID: nil, confidence: .none, reason: .unresolved,
                    proposedRootID: nil, proposedChildName: nil, requiresReview: true)
            }
            if possibleIDs.count == 1, let target = targets.first {
                return resolved(target.id, confidence: .high,
                    reason: exactMatches.contains(where: { $0.id == target.id }) ? .exactPath : .sourceAlias)
            }
            // Custom exact paths remain usable, but a recognized source alias
            // never claims a same-named custom object or proposes an old child.
            if targets.isEmpty, exactMatches.count == 1, let exact = exactMatches.first {
                return resolved(exact.id, confidence: .high, reason: .exactPath)
            }
        }
        if components.count >= 2 {
            let requested = components.prefix(2).map(normalize)
            let exactMatches = active.filter { category in
                pathComponents(displayPath(for: category, categories: active)).map(normalize) == requested
            }
            if aliasKeys.isEmpty, exactMatches.count == 1, let exact = exactMatches.first {
                return resolved(exact.id, confidence: .high, reason: .exactPath)
            }
            let roots = matchingRoots(named: components[0], in: active)
            if aliasKeys.isEmpty, roots.count > 1 {
                return ImportCategoryResolution(resolvedCategoryID: nil, confidence: .none, reason: .unresolved,
                    proposedRootID: nil, proposedChildName: nil, requiresReview: true)
            }
            if aliasKeys.isEmpty, let root = roots.first {
                let children = active.filter { $0.parentID == root.id && normalize($0.name) == normalize(components[1]) }
                if children.count == 1, let child = children.first {
                    return resolved(child.id, confidence: .high, reason: .sourceAlias)
                }
                if children.count > 1 {
                    return ImportCategoryResolution(resolvedCategoryID: nil, confidence: .none, reason: .unresolved,
                        proposedRootID: nil, proposedChildName: nil, requiresReview: true)
                }
                return ImportCategoryResolution(
                    resolvedCategoryID: nil,
                    confidence: .high,
                    reason: .proposedChild,
                    proposedRootID: root.id,
                    proposedChildName: components[1],
                    requiresReview: true
                )
            }
        }

        if components.count == 1, aliasKeys.isEmpty {
            let matches = active.filter {
                $0.parentID != nil && normalize($0.name) == normalize(components[0])
            }
            if matches.count == 1 {
                return resolved(matches[0].id, confidence: .high, reason: .uniqueChildName)
            }
        }

        let suggestion = SmartTransactionSuggestionService.suggest(
            note: [rawCategory, note].filter { !$0.isEmpty }.joined(separator: " "),
            merchant: merchant,
            type: type,
            categories: active.map {
                SuggestionCategory(
                    id: $0.id,
                    name: $0.name,
                    kind: $0.kind,
                    isActive: true,
                    parentID: $0.parentID,
                    defaultDefinitionKey: $0.defaultDefinitionKey
                )
            },
            tags: [],
            history: []
        )
        if suggestion.categoryConfidence == .high, let id = suggestion.categoryID {
            return resolved(id, confidence: .high, reason: .inferredFromDescription)
        }

        if aliasKeys.isEmpty, components.count == 1, let root = uniqueRoot(named: components[0], in: active) {
            return resolved(root.id, confidence: .high, reason: .existingRoot)
        }

        return ImportCategoryResolution(
            resolvedCategoryID: nil,
            confidence: .none,
            reason: .unresolved,
            proposedRootID: nil,
            proposedChildName: nil,
            requiresReview: true
        )
    }

    static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "＞", with: "/")
            .replacingOccurrences(of: ">", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pathComponents(_ value: String) -> [String] {
        normalize(value).split(separator: "/", maxSplits: 1).map(String.init)
    }

    private static func resolved(
        _ id: UUID,
        confidence: ImportCategoryResolutionConfidence,
        reason: ImportCategoryResolutionReason
    ) -> ImportCategoryResolution {
        ImportCategoryResolution(
            resolvedCategoryID: id,
            confidence: confidence,
            reason: reason,
            proposedRootID: nil,
            proposedChildName: nil,
            requiresReview: false
        )
    }

    private static func uniqueRoot(
        named name: String,
        in categories: [ImportCategorySnapshot]
    ) -> ImportCategorySnapshot? {
        let matches = matchingRoots(named: name, in: categories)
        return matches.count == 1 ? matches[0] : nil
    }

    private static func matchingRoots(
        named name: String,
        in categories: [ImportCategorySnapshot]
    ) -> [ImportCategorySnapshot] {
        let keys = ImportCategoryAliasIndex.bundled?.storageKeys(source: name, kind: categories.first?.kind ?? .expense) ?? []
        let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        return categories.filter {
            $0.parentID == nil && (normalize($0.name) == normalize(name) ||
                (keys.contains($0.defaultDefinitionKey) &&
                    ImportCategoryAliasIndex.bundled?.recognizesPurpose($0, categoriesByID: byID) == true))
        }
    }

    private static func displayPath(
        for category: ImportCategorySnapshot,
        categories: [ImportCategorySnapshot]
    ) -> String {
        guard let parentID = category.parentID,
              let parent = categories.first(where: { $0.id == parentID }) else {
            return category.name
        }
        return "\(parent.name) / \(category.name)"
    }
}
