import XCTest
@testable import PersonalFinanceOS

final class TransactionEntryPresentationTests: XCTestCase {
    func testAmountCalculatorUsesUniversalFortyFourPointMinimumHeight() {
        XCTAssertEqual(QuickAddLayoutMetrics.calculatorKeyMinimumHeight, 44)
        XCTAssertEqual(QuickAddLayoutMetrics.calculatorRowSpacing, 2)
    }

    func testEmptySessionBuildsAmountWithoutReplacement() {
        var session = AmountInputSession(initialExpression: "")
        XCTAssertFalse(session.replacesPrefilledValue)

        var expression = session.applying("6", to: "")
        XCTAssertEqual(expression, "6")
        expression = session.applying("8", to: expression)
        XCTAssertEqual(expression, "68")
        expression = session.applying(".", to: expression)
        XCTAssertEqual(expression, "68.")
    }

    func testPrefilledSessionPreservesAmountUntilUserInputs() {
        let expression = "123.45"
        let session = AmountInputSession(initialExpression: expression)

        XCTAssertTrue(session.replacesPrefilledValue)
        XCTAssertEqual(expression, "123.45")
    }

    func testFirstDigitReplacesPrefilledAmountAndReplacementIsConsumedOnce() {
        var session = AmountInputSession(initialExpression: "123.45")

        var expression = session.applying("6", to: "123.45")
        XCTAssertEqual(expression, "6")
        XCTAssertFalse(session.replacesPrefilledValue)
        expression = session.applying("8", to: expression)
        XCTAssertEqual(expression, "68")
    }

    func testFirstDecimalPointReplacesPrefilledAmount() {
        var session = AmountInputSession(initialExpression: "123.45")

        XCTAssertEqual(session.applying(".", to: "123.45"), "0.")
        XCTAssertFalse(session.replacesPrefilledValue)
    }

    func testFirstBackspaceDirectlyEditsPrefilledAmountAndEndsReplacement() {
        var deletion = AmountInputSession(initialExpression: "123.45")
        XCTAssertEqual(deletion.applying("⌫", to: "123.45"), "123.4")
        XCTAssertFalse(deletion.replacesPrefilledValue)
        XCTAssertEqual(deletion.applying("6", to: "123.4"), "123.46")
    }

    func testFirstClearEmptiesPrefilledAmountAndEndsReplacement() {
        var clearing = AmountInputSession(initialExpression: "123.45")
        XCTAssertEqual(clearing.applying("C", to: "123.45"), "")
        XCTAssertFalse(clearing.replacesPrefilledValue)
        XCTAssertEqual(clearing.applying("6", to: ""), "6")
    }

    func testFirstOperatorExtendsPrefilledAmountAndEndsReplacement() {
        var operation = AmountInputSession(initialExpression: "123.45")
        XCTAssertEqual(operation.applying("+", to: "123.45"), "123.45+")
        XCTAssertFalse(operation.replacesPrefilledValue)
        XCTAssertEqual(operation.applying("6", to: "123.45+"), "123.45+6")
    }

    func testUnknownInputDoesNotConsumePrefilledReplacement() {
        var session = AmountInputSession(initialExpression: "123.45")

        XCTAssertEqual(session.applying("unexpected", to: "123.45"), "123.45")
        XCTAssertTrue(session.replacesPrefilledValue)
        XCTAssertEqual(session.applying("6", to: "123.45"), "6")
    }

    func testOnlyAmountModeShowsCustomPadAndOnlyTextModesUseSystemKeyboard() {
        XCTAssertTrue(TransactionEntryInputMode.amount.showsAmountPad)
        XCTAssertFalse(TransactionEntryInputMode.note.showsAmountPad)
        XCTAssertFalse(TransactionEntryInputMode.merchant.showsAmountPad)
        XCTAssertFalse(TransactionEntryInputMode.categoryName.showsAmountPad)
        XCTAssertFalse(TransactionEntryInputMode.none.showsAmountPad)

        XCTAssertFalse(TransactionEntryInputMode.amount.usesSystemKeyboard)
        XCTAssertTrue(TransactionEntryInputMode.note.usesSystemKeyboard)
        XCTAssertTrue(TransactionEntryInputMode.merchant.usesSystemKeyboard)
        XCTAssertTrue(TransactionEntryInputMode.categoryName.usesSystemKeyboard)
        XCTAssertFalse(TransactionEntryInputMode.none.usesSystemKeyboard)
    }

    func testQuickAddCategoryLimitUsesMeasuredIntrinsicFitAtDeviceBoundaries() {
        XCTAssertEqual(
            QuickAddCategoryLimit.intrinsicLimit(
                availableFormHeight: 445,
                liveFormHeight: 449,
                renderedCategoryGridHeight: 194,
                fourRowCategoryGridHeight: 252,
                inputMode: .amount,
                isAccessibilitySize: false
            ),
            11
        )
        XCTAssertEqual(
            QuickAddCategoryLimit.intrinsicLimit(
                availableFormHeight: 542,
                liveFormHeight: 449,
                renderedCategoryGridHeight: 194,
                fourRowCategoryGridHeight: 252,
                inputMode: .amount,
                isAccessibilitySize: false
            ),
            15
        )
        XCTAssertEqual(
            QuickAddCategoryLimit.intrinsicLimit(
                availableFormHeight: 507,
                liveFormHeight: 449,
                renderedCategoryGridHeight: 194,
                fourRowCategoryGridHeight: 252,
                inputMode: .amount,
                isAccessibilitySize: false
            ),
            15
        )
        XCTAssertEqual(
            QuickAddCategoryLimit.intrinsicLimit(
                availableFormHeight: 506.9,
                liveFormHeight: 449,
                renderedCategoryGridHeight: 194,
                fourRowCategoryGridHeight: 252,
                inputMode: .amount,
                isAccessibilitySize: false
            ),
            11
        )
        XCTAssertEqual(
            QuickAddCategoryLimit.intrinsicLimit(
                availableFormHeight: 542,
                liveFormHeight: 0,
                renderedCategoryGridHeight: 0,
                fourRowCategoryGridHeight: 0,
                inputMode: .amount,
                isAccessibilitySize: false
            ),
            11
        )
        XCTAssertEqual(
            QuickAddCategoryLimit.intrinsicLimit(
                availableFormHeight: 542,
                liveFormHeight: 449,
                renderedCategoryGridHeight: 194,
                fourRowCategoryGridHeight: 252,
                inputMode: .note,
                isAccessibilitySize: false
            ),
            11
        )
        XCTAssertEqual(
            QuickAddCategoryLimit.intrinsicLimit(
                availableFormHeight: 542,
                liveFormHeight: 449,
                renderedCategoryGridHeight: 194,
                fourRowCategoryGridHeight: 252,
                inputMode: .amount,
                isAccessibilitySize: true
            ),
            11
        )
    }

    func testQuickAccessHonorsPriorityAndForcesHiddenSelectionIntoLimit() {
        let root = category("餐饮", order: 0)
        let breakfast = category("早餐", parentID: root.id, order: 0, pinned: true)
        let lunch = category("午餐", parentID: root.id, order: 1, pinned: true)
        let dinner = category("晚餐", parentID: root.id, order: 2)
        let fruit = category("水果", parentID: root.id, order: 3)
        let categories = [root, breakfast, lunch, dinner, fruit]
        let recentDinner = transaction(categoryID: dinner.id, updatedAt: Date())

        let visible = CategoryQuickAccessService.visibleCategories(
            categories: categories,
            transactions: [recentDinner],
            kind: .expense,
            selectedID: fruit.id,
            suggestedID: dinner.id,
            limit: 3
        )

        XCTAssertEqual(visible.map(\.id), [breakfast.id, lunch.id, fruit.id])
        XCTAssertTrue(visible.contains { $0.id == fruit.id })
    }

    func testQuickAccessUsesRecencyThenFrequencyBeforeDefaultOrder() {
        let root = category("交通", order: 0)
        let bus = category("公交", parentID: root.id, order: 0)
        let metro = category("地铁", parentID: root.id, order: 1)
        let now = Date()
        let history = [
            transaction(categoryID: bus.id, updatedAt: now.addingTimeInterval(-10)),
            transaction(categoryID: bus.id, updatedAt: now.addingTimeInterval(-20)),
            transaction(categoryID: metro.id, updatedAt: now)
        ]

        let visible = CategoryQuickAccessService.visibleCategories(
            categories: [root, bus, metro],
            transactions: history,
            kind: .expense,
            selectedID: nil,
            suggestedID: nil,
            limit: 2
        )
        XCTAssertEqual(visible.map(\.id), [metro.id, bus.id])
    }

    private func category(
        _ name: String,
        parentID: UUID? = nil,
        order: Int,
        pinned: Bool = false
    ) -> PersonalFinanceOS.Category {
        PersonalFinanceOS.Category(
            kind: .expense,
            name: name,
            parentID: parentID,
            symbolName: "square.grid.2x2",
            colorToken: "teal",
            sortOrder: order,
            isPinnedForQuickAdd: pinned
        )
    }

    private func transaction(categoryID: UUID, updatedAt: Date) -> FinanceTransaction {
        FinanceTransaction(
            type: .expense,
            amountMinorUnits: 100,
            occurredAt: updatedAt,
            localDayKey: "2026-08-02",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: UUID(),
            categoryID: categoryID,
            updatedAt: updatedAt
        )
    }
}
