import Foundation

enum SmartTransactionSuggestionService {
    static func suggest(
        note: String,
        merchant: String = "",
        type: TransactionType,
        categories: [SuggestionCategory],
        tags: [SuggestionTag],
        history: [SuggestionHistory],
        historyCutoff: Date? = nil
    ) -> SmartTransactionSuggestion {
        SmartClassificationEngine.suggest(
            note: note,
            merchant: merchant,
            type: type,
            categories: categories,
            tags: tags,
            history: history,
            historyCutoff: historyCutoff,
            profile: .empty
        )
    }

    static func suggest(
        note: String,
        merchant: String = "",
        type: TransactionType,
        categories: [SuggestionCategory],
        tags: [SuggestionTag],
        profile: ClassificationProfile
    ) -> SmartTransactionSuggestion {
        SmartClassificationEngine.suggest(
            note: note,
            merchant: merchant,
            type: type,
            categories: categories,
            tags: tags,
            history: [],
            historyCutoff: nil,
            profile: profile
        )
    }

    static func normalize(_ text: String) -> String {
        SmartClassificationEngine.normalize(text)
    }
}

private enum SmartClassificationEngine {
    private static let slowPathCharacters = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
    private static let quantityMarkers = [
        "个", "件", "包", "盒", "瓶", "杯", "斤", "公斤", "kg", "毫升", "ml", "升"
    ]

    private struct Candidate {
        let categoryID: UUID
        let evidenceType: SmartClassificationEvidenceType
        let score: Int
        let latestAt: Date
        let tagIDs: Set<UUID>
        let explanation: String
    }

    private struct HistoryAccumulator {
        let categoryID: UUID
        let evidenceType: SmartClassificationEvidenceType
        var items: [SuggestionHistory]
        var baseScore: Int
    }

    static func suggest(
        note: String,
        merchant: String,
        type: TransactionType,
        categories: [SuggestionCategory],
        tags: [SuggestionTag],
        history: [SuggestionHistory],
        historyCutoff: Date?,
        profile: ClassificationProfile
    ) -> SmartTransactionSuggestion {
        guard type != .transfer else { return .none }
        let normalizedNote = normalize(note)
        let normalizedMerchant = normalize(merchant)
        guard !normalizedNote.isEmpty || !normalizedMerchant.isEmpty else {
            return .none
        }

        let requestedKind = kind(for: type)
        let activeCategories = SuggestionCategoryEligibility.active(categories).filter {
            $0.kind == requestedKind
        }
        let activeCategoriesByID = Dictionary(
            uniqueKeysWithValues: activeCategories.map { ($0.id, $0) }
        )
        let activeCategoryIDs = Set(activeCategoriesByID.keys)
        let activeTags = tags.filter(\.isActive)
        let activeTagIDs = Set(activeTags.map(\.id))
        let matchingTagIDs = Set(activeTags.compactMap { tag in
            tagMatches(tag.name, normalizedNote: normalizedNote) ? tag.id : nil
        })

        let semanticMatches = SemanticClassificationLexicon.bundled?.matches(
            note: normalizedNote.isEmpty ? normalizedMerchant : normalizedNote,
            kind: requestedKind, categories: activeCategories
        ) ?? []
        var needsChoice = SemanticClassificationLexicon.requiresUserChoice(
            note: note, type: type, matches: semanticMatches
        )
        let legacyCandidates = lexiconCandidates(
            normalizedNote: normalizedNote,
            kind: requestedKind,
            categories: activeCategories,
            categoriesByID: activeCategoriesByID
        )
        var candidates: [Candidate]
        if semanticMatches.isEmpty {
            candidates = legacyCandidates.filter {
                guard let category = activeCategoriesByID[$0.categoryID] else { return false }
                return category.defaultDefinitionKey.isEmpty ||
                    CategoryCatalogIndex.bundled?.legacyStorageKeys.contains(category.defaultDefinitionKey) == true
            }
        } else {
            candidates = semanticMatches.map {
                Candidate(categoryID: $0.categoryID, evidenceType: .builtInLexicon,
                    score: normalizedNote.isEmpty ? min(72, $0.score) : $0.score,
                    latestAt: .distantPast, tagIDs: [], explanation: $0.explanation)
            }
        }
        candidates.append(contentsOf: historyCandidates(
            normalizedNote: normalizedNote,
            normalizedMerchant: normalizedMerchant,
            type: type,
            history: history,
            historyCutoff: historyCutoff,
            activeCategoryIDs: activeCategoryIDs,
            activeCategoriesByID: activeCategoriesByID,
            activeTagIDs: activeTagIDs
        ))
        candidates.append(contentsOf: profile.candidates(
            note: note,
            merchant: merchant,
            type: type,
            activeCategoryIDs: activeCategoryIDs
        ).map {
            Candidate(
                categoryID: $0.categoryID,
                evidenceType: .personalMemory,
                score: $0.score,
                latestAt: $0.latestAt,
                tagIDs: $0.tagIDs,
                explanation: $0.explanation
            )
        })

        let ranked = rank(candidates)
        guard let winner = ranked.first else {
            if matchingTagIDs.isEmpty {
                return SmartTransactionSuggestion(categoryConfidence: .low, tagConfidence: .low,
                    categoryID: nil, tagIDs: [], explanation: "", requiresUserChoice: needsChoice)
            }
            return SmartTransactionSuggestion(
                categoryConfidence: .low,
                tagConfidence: .high,
                categoryID: nil,
                tagIDs: matchingTagIDs,
                evidenceType: nil,
                score: 0,
                explanation: "备注包含已有标签名称",
                requiresUserChoice: needsChoice
            )
        }

        let runnerUp = ranked.dropFirst().first { $0.categoryID != winner.categoryID }
        let margin = runnerUp.map { winner.score - $0.score } ?? Int.max
        if (winner.evidenceType == .personalMemory && winner.score >= 108) || winner.evidenceType == .exactConfirmedNote {
            needsChoice = SemanticClassificationLexicon.requiresUserChoice(
                note: note, type: type, matches: semanticMatches, hasStrongExactMemory: true
            )
        }
        let categoryConfidence: SuggestionConfidence
        if winner.score >= 90 && margin >= 6 && !needsChoice {
            categoryConfidence = .high
        } else if winner.score >= 60 {
            categoryConfidence = .medium
        } else {
            categoryConfidence = .low
        }
        let selectedCategoryID = categoryConfidence == .low ? nil : winner.categoryID
        let learnedTagIDs = winner.tagIDs.intersection(activeTagIDs)
        let combinedTagIDs = learnedTagIDs.union(matchingTagIDs)
        let tagConfidence: SuggestionConfidence
        if !matchingTagIDs.isEmpty {
            tagConfidence = .high
        } else if !learnedTagIDs.isEmpty {
            tagConfidence = winner.score >= 90 ? .high : .medium
        } else {
            tagConfidence = .low
        }
        let conflictSuffix = needsChoice ? "，请确认本次用途" : (margin < 6 ? "，存在相近冲突，已降低置信度" : "")

        return SmartTransactionSuggestion(
            categoryConfidence: categoryConfidence,
            tagConfidence: tagConfidence,
            categoryID: selectedCategoryID,
            tagIDs: combinedTagIDs,
            evidenceType: winner.evidenceType,
            score: winner.score,
            explanation: winner.explanation + conflictSuffix,
            alternatives: ranked.prefix(3).map {
                SmartClassificationAlternative(categoryID: $0.categoryID, score: $0.score, explanation: $0.explanation)
            },
            requiresUserChoice: needsChoice,
            diagnosticRuleIDs: semanticMatches.map(\.ruleID).sorted(),
            diagnosticMargin: runnerUp == nil ? nil : margin
        )
    }

    static func normalize(_ text: String) -> String {
        var result = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.rangeOfCharacter(from: slowPathCharacters) == nil,
           !quantityMarkers.contains(where: result.contains) {
            for prefix in ["购买了", "购买", "买了", "买"] where result.hasPrefix(prefix) {
                result.removeFirst(prefix.count)
                break
            }
            return result
        }
        result = result.replacingOccurrences(
            of: #"[×xX*]\s*\d+(?:\.\d+)?"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\d+(?:\.\d+)?\s*(?:个|件|包|盒|瓶|杯|斤|公斤|kg|g|毫升|ml|升|l)"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: #"[，。！？、；：,.!?;:'\"“”‘’（）()【】\[\]{}<>《》~～—_+=/\\|-]+"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["购买了", "购买", "买了", "买"] where result.hasPrefix(prefix) {
            result.removeFirst(prefix.count)
            break
        }
        return result.replacingOccurrences(of: " ", with: "")
    }

    private static func lexiconCandidates(
        normalizedNote: String,
        kind: CategoryKind,
        categories: [SuggestionCategory],
        categoriesByID: [UUID: SuggestionCategory]
    ) -> [Candidate] {
        guard !normalizedNote.isEmpty else { return [] }
        return SmartClassificationLexicon.rules.compactMap { rule in
            let matchedKeywordLength = rule.keywords
                .map(normalize)
                .filter(normalizedNote.contains)
                .map(\.count)
                .max()
            guard rule.kind == kind,
                  let matchedKeywordLength,
                  !rule.exclusions.contains(where: {
                      normalizedNote.contains(normalize($0))
                  }),
                  let category = exactPathCategory(
                      rootName: rule.rootName,
                      childName: rule.childName,
                      categories: categories,
                      categoriesByID: categoriesByID
                  ) else {
                return nil
            }
            return Candidate(
                categoryID: category.id,
                evidenceType: .builtInLexicon,
                score: rule.score + min(max(0, matchedKeywordLength - 2), 4) * 3,
                latestAt: .distantPast,
                tagIDs: [],
                explanation: "匹配本地词典：\(rule.rootName) / \(rule.childName)"
            )
        }
    }

    private static func historyCandidates(
        normalizedNote: String,
        normalizedMerchant: String,
        type: TransactionType,
        history: [SuggestionHistory],
        historyCutoff: Date?,
        activeCategoryIDs: Set<UUID>,
        activeCategoriesByID: [UUID: SuggestionCategory],
        activeTagIDs: Set<UUID>
    ) -> [Candidate] {
        var accumulators: [String: HistoryAccumulator] = [:]
        for item in history {
            guard !item.isDeleted,
                  item.type == type,
                  historyCutoff.map({ item.occurredAt >= $0 }) ?? true,
                  let categoryID = item.categoryID,
                  activeCategoryIDs.contains(categoryID),
                  let category = activeCategoriesByID[categoryID] else {
                continue
            }

            let historicalNote = normalize(item.note)
            let historicalMerchant = normalize(item.merchant)
            let match: (SmartClassificationEvidenceType, Int)?
            if !normalizedNote.isEmpty && historicalNote == normalizedNote {
                switch item.decisionSource {
                case .manualConfirmed:
                    match = (.exactConfirmedNote, 112)
                case .automaticAccepted:
                    match = (.historicalAutomatic, 54)
                case .unchanged:
                    match = (.historicalAmbiguous, 60)
                case .timePrior:
                    match = nil
                }
            } else if !normalizedMerchant.isEmpty && historicalMerchant == normalizedMerchant {
                switch item.decisionSource {
                case .manualConfirmed:
                    match = (.exactConfirmedMerchant, 74)
                case .automaticAccepted:
                    match = (.historicalAutomatic, 50)
                case .unchanged:
                    match = (.historicalAmbiguous, 56)
                case .timePrior:
                    match = nil
                }
            } else if item.decisionSource == .manualConfirmed,
                      similar(normalizedNote, historicalNote) {
                match = (.confirmedTokenPattern, 66)
            } else {
                match = nil
            }
            guard let match else { continue }
            if isOther(category, categoriesByID: activeCategoriesByID),
               item.decisionSource != .manualConfirmed {
                continue
            }

            let key = "\(categoryID.uuidString)|\(match.0.rawValue)"
            if var existing = accumulators[key] {
                existing.items.append(item)
                existing.baseScore = max(existing.baseScore, match.1)
                accumulators[key] = existing
            } else {
                accumulators[key] = HistoryAccumulator(
                    categoryID: categoryID,
                    evidenceType: match.0,
                    items: [item],
                    baseScore: match.1
                )
            }
        }

        let conflictsByEvidence = Dictionary(grouping: accumulators.values, by: \.evidenceType)
        return accumulators.values.map { accumulator in
            let otherCount = (conflictsByEvidence[accumulator.evidenceType] ?? [])
                .filter { $0.categoryID != accumulator.categoryID }
                .reduce(0) { $0 + $1.items.count }
            let count = accumulator.items.count
            var score = accumulator.baseScore
            switch accumulator.evidenceType {
            case .personalMemory, .foundationModel:
                break
            case .exactConfirmedNote:
                score += min(max(0, count - 1), 4) * 5
                score -= otherCount * 20
            case .exactConfirmedMerchant:
                score = count >= 2 ? 100 + min(count - 2, 3) * 4 : 74
                score -= otherCount * 18
            case .confirmedTokenPattern:
                score += min(max(0, count - 1), 4) * 3
                score -= otherCount * 14
            case .historicalAutomatic:
                score += min(max(0, count - 1), 4) * 2
                score -= otherCount * 12
            case .historicalAmbiguous:
                score += min(max(0, count - 1), 4) * 5
                score -= otherCount * 14
            case .builtInLexicon:
                break
            }

            let tagCounts = accumulator.items
                .flatMap(\.tagIDs)
                .filter(activeTagIDs.contains)
                .reduce(into: [UUID: Int]()) { $0[$1, default: 0] += 1 }
            let tagIDs = Set(tagCounts.compactMap { id, tagCount in
                tagCount * 2 >= count ? id : nil
            })
            return Candidate(
                categoryID: accumulator.categoryID,
                evidenceType: accumulator.evidenceType,
                score: max(0, score),
                latestAt: accumulator.items.map(\.updatedAt).max() ?? .distantPast,
                tagIDs: tagIDs,
                explanation: explanation(for: accumulator.evidenceType, count: count)
            )
        }
    }

    private static func rank(_ candidates: [Candidate]) -> [Candidate] {
        let grouped = Dictionary(grouping: candidates, by: \.categoryID)
        return grouped.compactMap { _, values in
            values.sorted(by: candidateOrder).first
        }.sorted(by: candidateOrder)
    }

    private static func candidateOrder(_ left: Candidate, _ right: Candidate) -> Bool {
        if left.score != right.score { return left.score > right.score }
        let leftPriority = evidencePriority(left.evidenceType)
        let rightPriority = evidencePriority(right.evidenceType)
        if leftPriority != rightPriority { return leftPriority > rightPriority }
        if left.latestAt != right.latestAt { return left.latestAt > right.latestAt }
        return left.categoryID.uuidString < right.categoryID.uuidString
    }

    private static func evidencePriority(_ type: SmartClassificationEvidenceType) -> Int {
        switch type {
        case .personalMemory: 7
        case .foundationModel: 0
        case .exactConfirmedNote: 6
        case .exactConfirmedMerchant: 5
        case .builtInLexicon: 4
        case .confirmedTokenPattern: 3
        case .historicalAutomatic: 2
        case .historicalAmbiguous: 1
        }
    }

    private static func explanation(
        for type: SmartClassificationEvidenceType,
        count: Int
    ) -> String {
        switch type {
        case .personalMemory:
            "参考个人分类记忆"
        case .foundationModel:
            "设备端语义分类"
        case .exactConfirmedNote:
            "参考 \(count) 次相同备注的人工确认"
        case .exactConfirmedMerchant:
            "参考 \(count) 次相同商户的人工确认"
        case .confirmedTokenPattern:
            "参考相似备注的人工确认"
        case .historicalAutomatic:
            "参考较弱的历史自动结果"
        case .historicalAmbiguous:
            "参考来源未确认的历史结果"
        case .builtInLexicon:
            "匹配本地词典"
        }
    }

    private static func exactPathCategory(
        rootName: String,
        childName: String,
        categories: [SuggestionCategory],
        categoriesByID: [UUID: SuggestionCategory]
    ) -> SuggestionCategory? {
        let matches = categories.filter { child in
            guard normalize(child.name) == normalize(childName),
                  let parentID = child.parentID,
                  let parent = categoriesByID[parentID] else {
                return false
            }
            return parent.parentID == nil && normalize(parent.name) == normalize(rootName)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func isOther(
        _ category: SuggestionCategory,
        categoriesByID: [UUID: SuggestionCategory]
    ) -> Bool {
        if category.name.hasPrefix("其他") { return true }
        guard let parentID = category.parentID,
              let parent = categoriesByID[parentID] else {
            return false
        }
        return parent.name == "其他支出" || (
            parent.name == "其他收入" && category.name == "其他"
        )
    }

    private static func similar(_ left: String, _ right: String) -> Bool {
        let shorterCount = min(left.count, right.count)
        return shorterCount >= 3 && (left.contains(right) || right.contains(left))
    }

    private static func tagMatches(_ name: String, normalizedNote: String) -> Bool {
        let normalizedName = normalize(name)
        guard normalizedName.count >= 2 else { return false }
        if normalizedName.allSatisfy(\.isASCII) && normalizedName.count < 3 {
            return false
        }
        return normalizedNote.contains(normalizedName)
    }

    private static func kind(for type: TransactionType) -> CategoryKind {
        type == .income ? .income : .expense
    }
}
