import Foundation

enum QuickAddLayoutMetrics {
    static let calculatorKeyMinimumHeight = 44.0
    static let calculatorRowSpacing = 2.0
}

enum TransactionEntryInputMode: Equatable {
    case amount
    case note
    case merchant
    case categoryName
    case none

    var showsAmountPad: Bool { self == .amount }
    var usesSystemKeyboard: Bool {
        switch self {
        case .note, .merchant, .categoryName:
            true
        case .amount, .none:
            false
        }
    }
}

enum QuickAddCategoryLimit {
    static func intrinsicLimit(
        availableFormHeight: CGFloat,
        liveFormHeight: CGFloat,
        renderedCategoryGridHeight: CGFloat,
        fourRowCategoryGridHeight: CGFloat,
        inputMode: TransactionEntryInputMode,
        isAccessibilitySize: Bool
    ) -> Int {
        guard inputMode == .amount,
              !isAccessibilitySize,
              liveFormHeight > 0,
              renderedCategoryGridHeight > 0,
              fourRowCategoryGridHeight > 0 else {
            return 11
        }
        let fourRowFormHeight = liveFormHeight
            - renderedCategoryGridHeight
            + fourRowCategoryGridHeight
        return fourRowFormHeight <= availableFormHeight ? 15 : 11
    }
}


struct AmountInputSession: Equatable {
    private(set) var replacesPrefilledValue: Bool

    init(initialExpression: String = "") {
        replacesPrefilledValue = !initialExpression.isEmpty
    }

    mutating func applying(_ input: String, to expression: String) -> String {
        let result: String
        switch input {
        case "0"..."9":
            guard let digit = input.first else { return expression }
            result = AmountExpression.appendingDigit(
                digit,
                to: replacesPrefilledValue ? "" : expression
            )
        case ".":
            result = AmountExpression.appendingDecimalPoint(
                to: replacesPrefilledValue ? "" : expression
            )
        case "+", "÷", "×", "−":
            guard let operation = input.first else { return expression }
            result = AmountExpression.appendingOperator(operation, to: expression)
        case "C":
            result = ""
        case "⌫":
            result = AmountExpression.deletingLastCharacter(from: expression)
        default:
            return expression
        }
        replacesPrefilledValue = false
        return result
    }
}

enum CategoryQuickAccessService {
    static func visibleCategories(
        categories: [Category],
        transactions: [FinanceTransaction],
        kind: CategoryKind,
        selectedID: UUID?,
        suggestedID: UUID?,
        limit: Int
    ) -> [Category] {
        guard limit > 0 else { return [] }
        let hierarchy = CategoryHierarchy(categories: categories)
        var candidates = hierarchy.selectableCategories(kind: kind)
        if let index = CategoryCatalogIndex.bundled,
           categories.contains(where: { index.newStorageKeys.contains($0.defaultDefinitionKey) }) {
            candidates.removeAll {
                index.legacyStorageKeys.contains($0.defaultDefinitionKey) &&
                !$0.isPinnedForQuickAdd && $0.id != selectedID && $0.id != suggestedID
            }
        }
        if let selected = hierarchy.category(id: selectedID),
           selected.kind == kind,
           hierarchy.isEligibleForSelection(selected),
           !candidates.contains(where: { $0.id == selected.id }) {
            candidates.append(selected)
        }

        let activeIDs = Set(candidates.map(\.id))
        let relevantTransactions = transactions.filter {
            $0.deletedAt == nil &&
            $0.type.categoryKind == kind &&
            $0.categoryID.map(activeIDs.contains) == true
        }
        let frequency = relevantTransactions.reduce(into: [UUID: Int]()) { counts, transaction in
            if let categoryID = transaction.categoryID {
                counts[categoryID, default: 0] += 1
            }
        }
        let lastUsed = relevantTransactions.reduce(into: [UUID: Date]()) { values, transaction in
            guard let categoryID = transaction.categoryID else { return }
            values[categoryID] = max(values[categoryID] ?? .distantPast, transaction.updatedAt)
        }

        candidates.sort { left, right in
            compare(
                left,
                right,
                selectedID: selectedID,
                suggestedID: suggestedID,
                frequency: frequency,
                lastUsed: lastUsed,
                hierarchy: hierarchy
            )
        }
        var result = Array(candidates.prefix(limit))
        for forcedID in [suggestedID, selectedID].compactMap({ $0 }) {
            guard let forced = candidates.first(where: { $0.id == forcedID }),
                  !result.contains(where: { $0.id == forcedID }) else {
                continue
            }
            if result.count == limit {
                result.removeLast()
            }
            result.append(forced)
        }
        return result
    }

    private static func compare(
        _ left: Category,
        _ right: Category,
        selectedID: UUID?,
        suggestedID: UUID?,
        frequency: [UUID: Int],
        lastUsed: [UUID: Date],
        hierarchy: CategoryHierarchy
    ) -> Bool {
        let leftPinned = left.isPinnedForQuickAdd
        let rightPinned = right.isPinnedForQuickAdd
        if leftPinned != rightPinned { return leftPinned }

        let leftSelected = left.id == selectedID
        let rightSelected = right.id == selectedID
        if leftSelected != rightSelected { return leftSelected }

        let leftDate = lastUsed[left.id] ?? .distantPast
        let rightDate = lastUsed[right.id] ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }

        let leftFrequency = frequency[left.id, default: 0]
        let rightFrequency = frequency[right.id, default: 0]
        if leftFrequency != rightFrequency { return leftFrequency > rightFrequency }

        let leftSuggested = left.id == suggestedID
        let rightSuggested = right.id == suggestedID
        if leftSuggested != rightSuggested { return leftSuggested }

        let leftRoot = hierarchy.rootCategory(for: left)
        let rightRoot = hierarchy.rootCategory(for: right)
        if leftRoot.sortOrder != rightRoot.sortOrder {
            return leftRoot.sortOrder < rightRoot.sortOrder
        }
        if left.sortOrder != right.sortOrder {
            return left.sortOrder < right.sortOrder
        }
        return left.id.uuidString < right.id.uuidString
    }
}

private extension TransactionType {
    var categoryKind: CategoryKind {
        self == .income ? .income : .expense
    }
}
