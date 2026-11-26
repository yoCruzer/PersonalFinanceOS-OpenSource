import XCTest
@testable import PersonalFinanceOS

final class TransactionValidatorTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    func testExpenseIncomeAndRefundConstraints() throws {
        let fixtures = makeFixtures()

        let expense = makeTransaction(
            type: .expense,
            accountID: fixtures.cnyAccount.id,
            categoryID: fixtures.expenseCategory.id
        )
        XCTAssertNoThrow(try TransactionValidator.validate(expense, context: fixtures.context))

        let income = makeTransaction(
            type: .income,
            accountID: fixtures.cnyAccount.id,
            categoryID: fixtures.incomeCategory.id
        )
        XCTAssertNoThrow(try TransactionValidator.validate(income, context: fixtures.context))

        let refund = makeTransaction(
            type: .refund,
            accountID: fixtures.cnyAccount.id,
            categoryID: fixtures.expenseCategory.id
        )
        XCTAssertNoThrow(try TransactionValidator.validate(refund, context: fixtures.context))

        let wrongCategory = makeTransaction(
            type: .expense,
            accountID: fixtures.cnyAccount.id,
            categoryID: fixtures.incomeCategory.id
        )
        XCTAssertThrowsError(
            try TransactionValidator.validate(wrongCategory, context: fixtures.context)
        ) { error in
            XCTAssertEqual(error as? TransactionValidationError, .categoryKindMismatch)
        }
    }

    func testTransferRequiresDifferentAccountsAndNoCategory() throws {
        let fixtures = makeFixtures()
        let transfer = makeTransaction(
            type: .transfer,
            accountID: fixtures.cnyAccount.id,
            destinationAccountID: fixtures.destinationAccount.id
        )
        XCTAssertNoThrow(try TransactionValidator.validate(transfer, context: fixtures.context))

        transfer.destinationAccountID = fixtures.cnyAccount.id
        XCTAssertThrowsError(
            try TransactionValidator.validate(transfer, context: fixtures.context)
        ) { error in
            XCTAssertEqual(error as? TransactionValidationError, .sameTransferAccounts)
        }

        transfer.destinationAccountID = nil
        XCTAssertThrowsError(
            try TransactionValidator.validate(transfer, context: fixtures.context)
        ) { error in
            XCTAssertEqual(error as? TransactionValidationError, .missingDestinationAccount)
        }

        transfer.destinationAccountID = fixtures.destinationAccount.id
        transfer.categoryID = fixtures.expenseCategory.id
        XCTAssertThrowsError(
            try TransactionValidator.validate(transfer, context: fixtures.context)
        ) { error in
            XCTAssertEqual(error as? TransactionValidationError, .unexpectedCategory)
        }
    }

    func testAccountAndAmountConstraints() {
        let fixtures = makeFixtures()
        let noAccount = makeTransaction(
            type: .expense,
            accountID: nil,
            categoryID: fixtures.expenseCategory.id
        )
        XCTAssertThrowsError(
            try TransactionValidator.validate(noAccount, context: fixtures.context)
        ) { error in
            XCTAssertEqual(error as? TransactionValidationError, .missingAccount)
        }

        let zero = makeTransaction(
            type: .expense,
            amountMinorUnits: 0,
            accountID: fixtures.cnyAccount.id,
            categoryID: fixtures.expenseCategory.id
        )
        XCTAssertThrowsError(
            try TransactionValidator.validate(zero, context: fixtures.context)
        ) { error in
            XCTAssertEqual(error as? TransactionValidationError, .amountMustBePositive)
        }
    }

    func testOnlyRefundMayCarryRelatedTransaction() throws {
        let fixtures = makeFixtures()
        let expense = makeTransaction(
            type: .expense,
            accountID: fixtures.cnyAccount.id,
            categoryID: fixtures.expenseCategory.id
        )
        expense.relatedTransactionID = UUID()
        XCTAssertThrowsError(
            try TransactionValidator.validate(expense, context: fixtures.context)
        ) { error in
            XCTAssertEqual(error as? TransactionValidationError, .unexpectedRelatedTransaction)
        }

        let refund = makeTransaction(
            type: .refund,
            accountID: fixtures.cnyAccount.id,
            categoryID: fixtures.expenseCategory.id
        )
        refund.relatedTransactionID = UUID()
        XCTAssertNoThrow(try TransactionValidator.validate(refund, context: fixtures.context))
    }

    func testSoftDeleteAndRestore() {
        let fixtures = makeFixtures()
        let transaction = makeTransaction(
            type: .expense,
            accountID: fixtures.cnyAccount.id,
            categoryID: fixtures.expenseCategory.id
        )
        let deletionDate = Date(timeIntervalSince1970: 1_800_000_000)

        transaction.softDelete(at: deletionDate)
        XCTAssertEqual(transaction.deletedAt, deletionDate)
        XCTAssertEqual(transaction.updatedAt, deletionDate)

        let restoreDate = deletionDate.addingTimeInterval(10)
        transaction.restore(at: restoreDate)
        XCTAssertNil(transaction.deletedAt)
        XCTAssertEqual(transaction.updatedAt, restoreDate)
    }

    private func makeFixtures() -> (
        cnyAccount: Account,
        destinationAccount: Account,
        expenseCategory: PersonalFinanceOS.Category,
        incomeCategory: PersonalFinanceOS.Category,
        context: TransactionValidationContext
    ) {
        let cnyAccount = Account(name: "Cash", type: .cash, isDefault: true)
        let destinationAccount = Account(name: "Bank", type: .bankCard)
        let expenseCategory = Category(
            kind: .expense,
            name: "Food",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let incomeCategory = Category(
            kind: .income,
            name: "Salary",
            symbolName: "banknote",
            colorToken: "green"
        )
        let context = TransactionValidationContext(
            accounts: [cnyAccount, destinationAccount],
            categories: [expenseCategory, incomeCategory]
        )
        return (
            cnyAccount,
            destinationAccount,
            expenseCategory,
            incomeCategory,
            context
        )
    }

    private func makeTransaction(
        type: TransactionType,
        amountMinorUnits: Int64 = 1_000,
        accountID: UUID?,
        destinationAccountID: UUID? = nil,
        categoryID: UUID? = nil
    ) -> FinanceTransaction {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        return FinanceTransaction(
            type: type,
            amountMinorUnits: amountMinorUnits,
            occurredAt: date,
            localDayKey: LocalDayKey.make(for: date, timeZone: timeZone),
            timeZoneIdentifier: timeZone.identifier,
            accountID: accountID,
            destinationAccountID: destinationAccountID,
            categoryID: categoryID
        )
    }
}
