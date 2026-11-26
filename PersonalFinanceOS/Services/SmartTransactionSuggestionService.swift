import Foundation

enum SuggestionConfidence: Int, Comparable, Sendable {
    case low
    case medium
    case high

    static func < (lhs: SuggestionConfidence, rhs: SuggestionConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SuggestionCategory: Sendable, Equatable {
    let id: UUID
    let name: String
    let kind: CategoryKind
    let isActive: Bool
    let parentID: UUID?
    let defaultDefinitionKey: String

    init(
        id: UUID,
        name: String,
        kind: CategoryKind,
        isActive: Bool,
        parentID: UUID? = nil,
        defaultDefinitionKey: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isActive = isActive
        self.parentID = parentID
        self.defaultDefinitionKey = defaultDefinitionKey
    }
}

enum SuggestionCategoryEligibility {
    static func active(_ categories: [SuggestionCategory]) -> [SuggestionCategory] {
        let byID = Dictionary(grouping: categories, by: \.id)
        return categories.filter { value in
            guard value.isActive, byID[value.id]?.count == 1 else { return false }
            guard let parentID = value.parentID else { return true }
            guard let parents = byID[parentID], parents.count == 1, let parent = parents.first else { return false }
            return parent.isActive && parent.parentID == nil && parent.kind == value.kind && parent.id != value.id
        }
    }
}

enum QuickAddTimePriorService {
    static func categoryID(
        occurredAt: Date,
        timeZone: TimeZone,
        categories: [SuggestionCategory]
    ) -> UUID? {
        guard let definitionKey = definitionKey(for: occurredAt, timeZone: timeZone) else {
            return nil
        }
        return SuggestionCategoryEligibility.active(categories).first {
            $0.defaultDefinitionKey == definitionKey &&
            $0.kind == .expense &&
            $0.isActive
        }?.id
    }

    private static func definitionKey(for occurredAt: Date, timeZone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: occurredAt)
        switch hour {
        case 7..<10:
            return "expense.dining.breakfast"
        case 11..<15:
            return "expense.dining.lunch"
        case 17..<21:
            return "expense.dining.dinner"
        default:
            return nil
        }
    }
}

struct SuggestionTag: Sendable, Equatable {
    let id: UUID
    let name: String
    let isActive: Bool
}

struct SuggestionHistory: Sendable, Equatable {
    let id: UUID
    let type: TransactionType
    let note: String
    let merchant: String
    let categoryID: UUID?
    let tagIDs: Set<UUID>
    let occurredAt: Date
    let updatedAt: Date
    let isDeleted: Bool
    let isImported: Bool
    let decisionSource: CategoryDecisionSource

    init(
        id: UUID,
        type: TransactionType,
        note: String,
        merchant: String,
        categoryID: UUID?,
        tagIDs: Set<UUID>,
        occurredAt: Date? = nil,
        updatedAt: Date,
        isDeleted: Bool,
        isImported: Bool = false,
        decisionSource: CategoryDecisionSource = .unchanged
    ) {
        self.id = id
        self.type = type
        self.note = note
        self.merchant = merchant
        self.categoryID = categoryID
        self.tagIDs = tagIDs
        self.occurredAt = occurredAt ?? updatedAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
        self.isImported = isImported
        self.decisionSource = decisionSource
    }
}

enum SmartClassificationEvidenceType: String, Sendable {
    case builtInLexicon
    case personalMemory
    case foundationModel
    case exactConfirmedNote
    case exactConfirmedMerchant
    case confirmedTokenPattern
    case historicalAutomatic
    case historicalAmbiguous
}

struct SmartClassificationAlternative: Sendable, Equatable, Identifiable {
    var id: UUID { categoryID }
    let categoryID: UUID
    let score: Int
    let explanation: String
}

struct SmartTransactionSuggestion: Sendable, Equatable {
    let categoryConfidence: SuggestionConfidence
    let tagConfidence: SuggestionConfidence
    let categoryID: UUID?
    let tagIDs: Set<UUID>
    let evidenceType: SmartClassificationEvidenceType?
    let score: Int
    let explanation: String
    let alternatives: [SmartClassificationAlternative]
    let requiresUserChoice: Bool
    let diagnosticRuleIDs: [String]
    let diagnosticMargin: Int?

    init(
        categoryConfidence: SuggestionConfidence,
        tagConfidence: SuggestionConfidence,
        categoryID: UUID?,
        tagIDs: Set<UUID>,
        evidenceType: SmartClassificationEvidenceType? = nil,
        score: Int = 0,
        explanation: String,
        alternatives: [SmartClassificationAlternative] = [],
        requiresUserChoice: Bool = false,
        diagnosticRuleIDs: [String] = [],
        diagnosticMargin: Int? = nil
    ) {
        self.categoryConfidence = categoryConfidence
        self.tagConfidence = tagConfidence
        self.categoryID = categoryID
        self.tagIDs = tagIDs
        self.evidenceType = evidenceType
        self.score = score
        self.explanation = explanation
        self.alternatives = Array(alternatives.prefix(3))
        self.requiresUserChoice = requiresUserChoice
        self.diagnosticRuleIDs = Array(diagnosticRuleIDs.prefix(8))
        self.diagnosticMargin = diagnosticMargin
    }

    static let none = SmartTransactionSuggestion(
        categoryConfidence: .low,
        tagConfidence: .low,
        categoryID: nil,
        tagIDs: [],
        evidenceType: nil,
        score: 0,
        explanation: ""
    )

    var hasContent: Bool {
        categoryID != nil || !tagIDs.isEmpty
    }

    var confidence: SuggestionConfidence {
        max(categoryConfidence, tagConfidence)
    }
}

enum SmartSuggestionCategorySelectionState: Sendable {
    case `default`
    case automatic
    case manual
}

struct SmartSuggestionSession: Sendable {
    private(set) var selectionState: SmartSuggestionCategorySelectionState
    private(set) var categoryBeforeAutomaticSuggestion: UUID?
    private(set) var currentAutomaticCategoryID: UUID?
    private(set) var currentTimePriorCategoryID: UUID?
    private(set) var manualOverride: Bool
    private(set) var initialUserTagIDs: Set<UUID>
    private(set) var userControlledTagIDs: Set<UUID>
    private(set) var manuallyExcludedTagIDs: Set<UUID> = []
    private(set) var currentAutomaticTagIDs: Set<UUID> = []
    private(set) var allowsAutomaticRun: Bool
    private(set) var didExplicitlyConfirmCategory = false
    private(set) var rejectedAutomaticCategoryID: UUID?

    init(editingExisting: Bool, hasInitialCategory: Bool, initialTagIDs: Set<UUID>) {
        manualOverride = editingExisting || hasInitialCategory
        selectionState = manualOverride ? .manual : .default
        initialUserTagIDs = initialTagIDs
        userControlledTagIDs = initialTagIDs
        allowsAutomaticRun = !editingExisting && !hasInitialCategory && initialTagIDs.isEmpty
    }

    mutating func requestRefresh(currentCategoryID: UUID? = nil) {
        guard !didExplicitlyConfirmCategory else { return }
        allowsAutomaticRun = true
        manualOverride = false
        selectionState = .default
        categoryBeforeAutomaticSuggestion = currentCategoryID
        currentAutomaticCategoryID = nil
        didExplicitlyConfirmCategory = false
        rejectedAutomaticCategoryID = nil
    }

    mutating func markManualCategorySelection(selectedCategoryID: UUID? = nil) {
        if let automaticID = currentAutomaticCategoryID,
           automaticID != selectedCategoryID {
            rejectedAutomaticCategoryID = automaticID
        }
        manualOverride = true
        allowsAutomaticRun = false
        selectionState = .manual
        categoryBeforeAutomaticSuggestion = nil
        currentAutomaticCategoryID = nil
        currentTimePriorCategoryID = nil
        didExplicitlyConfirmCategory = true
    }

    mutating func applyTimePriorCategory(
        _ id: UUID?,
        currentCategoryID: UUID?
    ) -> UUID? {
        guard !manualOverride else { return currentCategoryID }
        let previousTimePriorID = currentTimePriorCategoryID
        currentTimePriorCategoryID = id
        if selectionState == .automatic,
           categoryBeforeAutomaticSuggestion == previousTimePriorID {
            categoryBeforeAutomaticSuggestion = id
        }
        guard selectionState != .automatic,
              currentCategoryID == nil || currentCategoryID == previousTimePriorID else {
            return currentCategoryID
        }
        return id
    }

    mutating func markAutomaticCategory(_ id: UUID) {
        _ = applyAutomaticCategory(id, currentCategoryID: currentAutomaticCategoryID)
    }

    mutating func applyAutomaticCategory(
        _ id: UUID,
        currentCategoryID: UUID?
    ) -> UUID? {
        guard !manualOverride else { return nil }
        if selectionState != .automatic {
            categoryBeforeAutomaticSuggestion = currentCategoryID
        }
        selectionState = .automatic
        currentAutomaticCategoryID = id
        didExplicitlyConfirmCategory = false
        return id
    }

    mutating func categoryAfterSuggestion(
        _ suggestion: SmartTransactionSuggestion,
        currentCategoryID: UUID?
    ) -> UUID? {
        if suggestion.categoryConfidence == .high,
           !suggestion.requiresUserChoice,
           let categoryID = suggestion.categoryID {
            return applyAutomaticCategory(categoryID, currentCategoryID: currentCategoryID)
                ?? currentCategoryID
        }
        return categoryAfterAutomaticSuggestionUnavailable(currentCategoryID: currentCategoryID)
    }

    mutating func categoryAfterAutomaticSuggestionUnavailable(
        currentCategoryID: UUID?
    ) -> UUID? {
        guard selectionState == .automatic else { return currentCategoryID }
        let restored = currentCategoryID == currentAutomaticCategoryID
            ? categoryBeforeAutomaticSuggestion
            : currentCategoryID
        selectionState = .default
        categoryBeforeAutomaticSuggestion = nil
        currentAutomaticCategoryID = nil
        didExplicitlyConfirmCategory = false
        return restored
    }

    mutating func undoAutomaticSuggestion(currentCategoryID: UUID?) -> UUID? {
        let restored = currentCategoryID == currentAutomaticCategoryID
            ? categoryBeforeAutomaticSuggestion : currentCategoryID
        markManualCategorySelection(selectedCategoryID: restored)
        return restored
    }

    mutating func markManualTagChange(id: UUID, isSelected: Bool) {
        if isSelected {
            userControlledTagIDs.insert(id)
            currentAutomaticTagIDs.remove(id)
            manuallyExcludedTagIDs.remove(id)
        } else {
            userControlledTagIDs.remove(id)
            currentAutomaticTagIDs.remove(id)
            manuallyExcludedTagIDs.insert(id)
        }
    }

    mutating func reconcileAutomaticTags(
        _ suggestedIDs: Set<UUID>,
        currentTagIDs: Set<UUID>
    ) -> Set<UUID> {
        let eligible = eligibleAutomaticTags(suggestedIDs)
        var reconciled = currentTagIDs.subtracting(currentAutomaticTagIDs)
        reconciled.formUnion(eligible)
        currentAutomaticTagIDs = eligible.subtracting(userControlledTagIDs)
        return reconciled
    }

    mutating func clearAutomaticTags(currentTagIDs: Set<UUID>) -> Set<UUID> {
        reconcileAutomaticTags([], currentTagIDs: currentTagIDs)
    }

    mutating func adoptSuggestedTagsAsManual(_ ids: Set<UUID>) {
        for id in ids {
            userControlledTagIDs.insert(id)
            currentAutomaticTagIDs.remove(id)
            manuallyExcludedTagIDs.remove(id)
        }
    }

    func canAutoFillCategory(currentCategoryID: UUID?) -> Bool {
        !manualOverride && (
            selectionState != .automatic || currentCategoryID == currentAutomaticCategoryID
        )
    }

    func eligibleAutomaticTags(_ ids: Set<UUID>) -> Set<UUID> {
        ids.subtracting(manuallyExcludedTagIDs)
    }

    var categoryDecisionSource: CategoryDecisionSource {
        if didExplicitlyConfirmCategory { return .manualConfirmed }
        if selectionState == .automatic { return .automaticAccepted }
        if currentTimePriorCategoryID != nil { return .timePrior }
        return .unchanged
    }
}

struct SmartSuggestionRequestTracker: Sendable {
    private(set) var revision = 0
    private(set) var note = ""
    private(set) var merchant = ""
    private(set) var type: TransactionType = .expense

    mutating func begin(note: String, merchant: String, type: TransactionType) -> Int {
        revision += 1
        self.note = note
        self.merchant = merchant
        self.type = type
        return revision
    }

    mutating func invalidate() {
        revision += 1
    }

    func accepts(
        revision: Int,
        note: String,
        merchant: String,
        type: TransactionType
    ) -> Bool {
        self.revision == revision &&
        self.note == note &&
        self.merchant == merchant &&
        self.type == type
    }
}

enum SmartSuggestionPreferences {
    static let foundationModelEnabledKey = "smartSuggestions.enabled"
    static let enabledKey = foundationModelEnabledKey
    static let historyCutoffKey = "smartSuggestions.historyCutoff"
    static let defaultEnabled = true
}
