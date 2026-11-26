import Foundation

/// Rank the full eligible catalog before applying the provider's bounded prompt budget.
enum FoundationCandidateRecall {
    static func select(note: String, merchant: String, type: TransactionType,
                       categories: [SuggestionCategory], fullCategories: [SuggestionCategory],
                       deterministic: SmartTransactionSuggestion, limit: Int) -> [SuggestionCategory] {
        guard limit > 0, type != .transfer else { return [] }
        let input = SmartTransactionSuggestionService.normalize(note + " " + merchant)
        let kind: CategoryKind = type == .income ? .income : .expense
        let eligibleIDs = Set(SuggestionCategoryEligibility.active(fullCategories).filter { $0.kind == kind }.map(\.id))
        let categories = categories.filter { eligibleIDs.contains($0.id) }
        let matches = SemanticClassificationLexicon.bundled?.matches(note: input, kind: kind, categories: fullCategories) ?? []
        var scores = matches.reduce(into: [UUID: Int]()) { result, match in
            result[match.categoryID] = max(result[match.categoryID, default: 0], match.score * 10)
        }
        for (offset, candidate) in deterministic.alternatives.enumerated() {
            scores[candidate.categoryID] = max(scores[candidate.categoryID, default: 0], 9_000 - offset * 100)
        }
        if let id = deterministic.categoryID { scores[id] = 10_000 }
        for category in categories {
            let name = SmartTransactionSuggestionService.normalize(category.name)
            if !name.isEmpty, input.contains(name) {
                scores[category.id, default: 0] += name.count * 20
            } else {
                let characters = Array(name)
                for offset in 0..<max(0, characters.count - 1) {
                    if input.contains(String(characters[offset...offset + 1])) { scores[category.id, default: 0] += 5 }
                }
            }
        }
        return Array(categories.sorted {
            let left = scores[$0.id, default: 0], right = scores[$1.id, default: 0]
            if left != right { return left > right }
            if $0.defaultDefinitionKey != $1.defaultDefinitionKey { return $0.defaultDefinitionKey < $1.defaultDefinitionKey }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(limit))
    }
}
