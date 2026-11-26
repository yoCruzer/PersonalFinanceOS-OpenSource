import SwiftData
import XCTest
@testable import PersonalFinanceOS

final class TransactionBatchOperationServiceTests: XCTestCase {
    func testSelectionOnlySelectsAndRetainsCurrentResults() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        var selection = TransactionBatchSelection()
        selection.selectAll(currentResultIDs: [first, second])
        XCTAssertEqual(selection.ids, [first, second])

        selection.toggle(second)
        selection.toggle(third)
        XCTAssertEqual(selection.ids, [first, third])

        selection.reconcile(currentResultIDs: [second, third])
        XCTAssertEqual(selection.ids, [third])
    }

    func testSummaryUsesNetExpenseSemanticsForRefunds() {
        let expense = FinanceTransaction(
            type: .expense,
            amountMinorUnits: 1_000,
            occurredAt: Date(),
            localDayKey: "2026-08-04",
            timeZoneIdentifier: "Asia/Shanghai"
        )
        let refund = FinanceTransaction(
            type: .refund,
            amountMinorUnits: 400,
            occurredAt: Date(),
            localDayKey: "2026-08-04",
            timeZoneIdentifier: "Asia/Shanghai"
        )

        let summary = TransactionBatchSummary.make(
            transactions: [expense, refund],
            selectedIDs: [expense.id, refund.id]
        )
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.expenseMinorUnits, 600)
    }

    @MainActor
    func testExportContainsOnlySelectedTransaction() throws {
        let fixture = try makeFixture()
        let data = try TransactionBatchOperationService.exportData(
            selectedIDs: [fixture.expense.id],
            transactions: [fixture.expense, fixture.income],
            categories: [fixture.expenseCategory, fixture.incomeCategory],
            accounts: [fixture.account, fixture.otherAccount]
        )
        let csv = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(csv.contains(fixture.expense.id.uuidString))
        XCTAssertFalse(csv.contains(fixture.income.id.uuidString))
    }

    @MainActor
    func testSoftDeleteIsAtomicWhenSaveFails() throws {
        let fixture = try makeFixture()
        enum Failure: Error { case save }

        XCTAssertThrowsError(try TransactionBatchOperationService.softDelete(
            selectedIDs: [fixture.expense.id, fixture.income.id],
            transactions: [fixture.expense, fixture.income],
            in: fixture.context,
            save: { throw Failure.save }
        ))
        XCTAssertNil(fixture.expense.deletedAt)
        XCTAssertNil(fixture.income.deletedAt)
    }

    @MainActor
    func testMutationsRefetchSelectionInsteadOfTrustingCallerSnapshot() throws {
        let fixture = try makeFixture()

        let result = try TransactionBatchOperationService.softDelete(
            selectedIDs: [fixture.expense.id],
            transactions: [],
            in: fixture.context
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertNotNil(fixture.expense.deletedAt)
    }

    @MainActor
    func testModelActorBatchMutationUsesIDsAndPersistsTags() async throws {
        let fixture = try makeFixture()
        let worker = LedgerBatchOperationActor(modelContainer: fixture.container)

        let result = try await worker.updateTags(
            selectedIDs: [fixture.expense.id, fixture.income.id],
            operation: .add(fixture.tag.id)
        )

        XCTAssertEqual(result.count, 2)
        let persisted = try fixture.context.fetch(FetchDescriptor<FinanceTransaction>())
        let selectedIDs = Set([fixture.expense.id, fixture.income.id])
        XCTAssertTrue(persisted
            .filter { selectedIDs.contains($0.id) }
            .allSatisfy { $0.tags.contains(where: { $0.id == fixture.tag.id }) }
        )
    }

    @MainActor
    func testAccountCategoryAndTagValidationProtectsMixedSelection() throws {
        let fixture = try makeFixture()
        let transfer = FinanceTransaction(
            type: .transfer,
            amountMinorUnits: 500,
            occurredAt: Date(),
            localDayKey: "2026-08-04",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: fixture.account.id,
            destinationAccountID: fixture.otherAccount.id
        )
        fixture.context.insert(transfer)
        try fixture.context.save()

        XCTAssertThrowsError(try TransactionBatchOperationService.migrateAccount(
            selectedIDs: [transfer.id],
            to: fixture.otherAccount,
            transactions: [transfer],
            in: fixture.context
        )) { error in
            XCTAssertEqual(error as? TransactionBatchOperationError, .transferConflict)
        }

        XCTAssertThrowsError(try TransactionBatchOperationService.migrateCategory(
            selectedIDs: [fixture.expense.id, fixture.income.id],
            to: fixture.expenseCategory,
            transactions: [fixture.expense, fixture.income],
            in: fixture.context
        )) { error in
            XCTAssertEqual(error as? TransactionBatchOperationError, .categoryKindMismatch)
        }

        _ = try TransactionBatchOperationService.updateTags(
            selectedIDs: [fixture.expense.id],
            operation: .add(fixture.tag.id),
            transactions: [fixture.expense],
            tags: [fixture.tag],
            in: fixture.context
        )
        _ = try TransactionBatchOperationService.updateTags(
            selectedIDs: [fixture.expense.id],
            operation: .add(fixture.tag.id),
            transactions: [fixture.expense],
            tags: [fixture.tag],
            in: fixture.context
        )
        XCTAssertEqual(fixture.expense.tags.map(\.id), [fixture.tag.id])
    }

    @MainActor
    func testAccountCategoryAndTagMutationsReportOnlyActualChanges() throws {
        let fixture = try makeFixture()
        let replacementCategory = PersonalFinanceOS.Category(
            kind: .expense,
            name: "水果",
            symbolName: "apple.logo",
            colorToken: "orange"
        )
        let replacementTag = Tag(name: "工作")
        fixture.context.insert(replacementCategory)
        fixture.context.insert(replacementTag)
        try fixture.context.save()

        var result = try TransactionBatchOperationService.migrateAccount(
            selectedIDs: [fixture.expense.id],
            to: fixture.otherAccount,
            transactions: [],
            in: fixture.context
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(fixture.expense.accountID, fixture.otherAccount.id)

        result = try TransactionBatchOperationService.migrateCategory(
            selectedIDs: [fixture.expense.id],
            to: replacementCategory,
            transactions: [],
            in: fixture.context
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(fixture.expense.categoryID, replacementCategory.id)

        result = try TransactionBatchOperationService.updateTags(
            selectedIDs: [fixture.expense.id],
            operation: .add(fixture.tag.id),
            transactions: [],
            tags: [],
            in: fixture.context
        )
        XCTAssertEqual(result.count, 1)
        result = try TransactionBatchOperationService.updateTags(
            selectedIDs: [fixture.expense.id],
            operation: .add(fixture.tag.id),
            transactions: [],
            tags: [],
            in: fixture.context
        )
        XCTAssertEqual(result.count, 0)

        result = try TransactionBatchOperationService.updateTags(
            selectedIDs: [fixture.expense.id],
            operation: .replace(sourceID: fixture.tag.id, targetID: replacementTag.id),
            transactions: [],
            tags: [],
            in: fixture.context
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(fixture.expense.tags.map(\.id), [replacementTag.id])
    }

    @MainActor
    func testCategoryMigrationResetsProvenanceAndRollbackRestoresIt() throws {
        let fixture = try makeFixture()
        let replacement = PersonalFinanceOS.Category(
            kind: .expense,
            name: "日用",
            symbolName: "basket",
            colorToken: "teal"
        )
        let automatic = transaction(
            type: .expense,
            account: fixture.account,
            category: fixture.expenseCategory
        )
        fixture.expense.categoryDecisionSource = .manualConfirmed
        automatic.categoryDecisionSource = .automaticAccepted
        fixture.context.insert(replacement)
        fixture.context.insert(automatic)
        try fixture.context.save()

        enum Failure: Error { case save }
        XCTAssertThrowsError(try TransactionBatchOperationService.migrateCategory(
            selectedIDs: [fixture.expense.id, automatic.id],
            to: replacement,
            transactions: [],
            in: fixture.context,
            save: { throw Failure.save }
        ))
        XCTAssertEqual(fixture.expense.categoryID, fixture.expenseCategory.id)
        XCTAssertEqual(automatic.categoryID, fixture.expenseCategory.id)
        XCTAssertEqual(fixture.expense.categoryDecisionSource, .manualConfirmed)
        XCTAssertEqual(automatic.categoryDecisionSource, .automaticAccepted)

        _ = try TransactionBatchOperationService.migrateCategory(
            selectedIDs: [fixture.expense.id, automatic.id],
            to: replacement,
            transactions: [],
            in: fixture.context
        )
        XCTAssertEqual(fixture.expense.categoryID, replacement.id)
        XCTAssertEqual(automatic.categoryID, replacement.id)
        XCTAssertEqual(fixture.expense.categoryDecisionSource, .unchanged)
        XCTAssertEqual(automatic.categoryDecisionSource, .unchanged)
    }

    @MainActor
    func testConfirmationPlansReportActualImpactWithoutMutatingData() throws {
        let fixture = try makeFixture()
        let replacementCategory = PersonalFinanceOS.Category(
            kind: .expense,
            name: "水果",
            symbolName: "apple.logo",
            colorToken: "orange"
        )
        fixture.context.insert(replacementCategory)
        try fixture.context.save()

        let accountPlan = try TransactionBatchOperationService.planAccountMigration(
            selectedIDs: [fixture.expense.id, fixture.income.id],
            to: fixture.otherAccount,
            in: fixture.context
        )
        XCTAssertEqual(accountPlan.count, 2)
        XCTAssertEqual(accountPlan.incomeMinorUnits, 2_000)
        XCTAssertEqual(accountPlan.expenseMinorUnits, 1_000)
        XCTAssertEqual(fixture.expense.accountID, fixture.account.id)
        XCTAssertEqual(fixture.income.accountID, fixture.account.id)

        let categoryPlan = try TransactionBatchOperationService.planCategoryMigration(
            selectedIDs: [fixture.expense.id],
            to: replacementCategory,
            in: fixture.context
        )
        XCTAssertEqual(categoryPlan.count, 1)
        XCTAssertEqual(categoryPlan.expenseMinorUnits, 1_000)
        XCTAssertEqual(fixture.expense.categoryID, fixture.expenseCategory.id)

        let tagPlan = try TransactionBatchOperationService.planTagUpdate(
            selectedIDs: [fixture.expense.id, fixture.income.id],
            operation: .add(fixture.tag.id),
            in: fixture.context
        )
        XCTAssertEqual(tagPlan.count, 2)
        XCTAssertEqual(tagPlan.incomeMinorUnits, 2_000)
        XCTAssertEqual(tagPlan.expenseMinorUnits, 1_000)
        XCTAssertTrue(fixture.expense.tags.isEmpty)
        XCTAssertTrue(fixture.income.tags.isEmpty)
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppSchema.schema, configurations: [configuration])
        let context = container.mainContext
        let account = Account(name: "现金", type: .cash, currencyCode: "CNY")
        let otherAccount = Account(name: "银行卡", type: .bankCard, currencyCode: "CNY")
        let expenseCategory = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let incomeCategory = Category(
            kind: .income,
            name: "工资",
            symbolName: "banknote",
            colorToken: "green"
        )
        let tag = Tag(name: "报销")
        let expense = transaction(type: .expense, account: account, category: expenseCategory)
        let income = transaction(type: .income, account: account, category: incomeCategory)
        context.insert(account)
        context.insert(otherAccount)
        context.insert(expenseCategory)
        context.insert(incomeCategory)
        context.insert(tag)
        context.insert(expense)
        context.insert(income)
        try context.save()
        return Fixture(
            container: container,
            context: context,
            account: account,
            otherAccount: otherAccount,
            expenseCategory: expenseCategory,
            incomeCategory: incomeCategory,
            tag: tag,
            expense: expense,
            income: income
        )
    }

    private func transaction(
        type: TransactionType,
        account: Account,
        category: PersonalFinanceOS.Category
    ) -> FinanceTransaction {
        FinanceTransaction(
            type: type,
            amountMinorUnits: type == .income ? 2_000 : 1_000,
            occurredAt: Date(),
            localDayKey: "2026-08-04",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: account.id,
            categoryID: category.id
        )
    }
}

private struct Fixture {
    let container: ModelContainer
    let context: ModelContext
    let account: Account
    let otherAccount: Account
    let expenseCategory: PersonalFinanceOS.Category
    let incomeCategory: PersonalFinanceOS.Category
    let tag: Tag
    let expense: FinanceTransaction
    let income: FinanceTransaction
}
