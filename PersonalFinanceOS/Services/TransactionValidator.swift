import Foundation

enum TransactionValidationError: Error, Equatable {
    case amountMustBePositive
    case invalidCurrencyCode
    case invalidLocalDayKey
    case invalidTimeZone
    case missingAccount
    case accountCurrencyMismatch
    case missingCategory
    case categoryKindMismatch
    case invalidCategoryHierarchy
    case unexpectedDestinationAccount
    case missingDestinationAccount
    case sameTransferAccounts
    case unexpectedCategory
    case unexpectedRelatedTransaction
}

struct TransactionValidationContext {
    let accountsByID: [UUID: Account]
    let categoriesByID: [UUID: Category]
    let categoryHierarchy: CategoryHierarchy

    init(accounts: [Account], categories: [Category]) {
        accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        categoriesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        categoryHierarchy = CategoryHierarchy(categories: categories)
    }
}

enum TransactionValidator {
    static func validate(
        _ transaction: FinanceTransaction,
        context: TransactionValidationContext
    ) throws {
        guard transaction.amountMinorUnits > 0 else {
            throw TransactionValidationError.amountMustBePositive
        }
        guard (try? Money(
            minorUnits: transaction.amountMinorUnits,
            currencyCode: transaction.currencyCode
        )) != nil else {
            throw TransactionValidationError.invalidCurrencyCode
        }
        guard LocalDayKey.isValid(transaction.localDayKey) else {
            throw TransactionValidationError.invalidLocalDayKey
        }
        guard TimeZone(identifier: transaction.timeZoneIdentifier) != nil else {
            throw TransactionValidationError.invalidTimeZone
        }
        guard let accountID = transaction.accountID,
              let account = context.accountsByID[accountID] else {
            throw TransactionValidationError.missingAccount
        }
        guard account.currencyCode == transaction.currencyCode else {
            throw TransactionValidationError.accountCurrencyMismatch
        }
        guard transaction.type == .refund || transaction.relatedTransactionID == nil else {
            throw TransactionValidationError.unexpectedRelatedTransaction
        }

        switch transaction.type {
        case .expense:
            try validateCategory(transaction, expectedKind: .expense, context: context)
            guard transaction.destinationAccountID == nil else {
                throw TransactionValidationError.unexpectedDestinationAccount
            }
        case .income:
            try validateCategory(transaction, expectedKind: .income, context: context)
            guard transaction.destinationAccountID == nil else {
                throw TransactionValidationError.unexpectedDestinationAccount
            }
        case .refund:
            try validateCategory(transaction, expectedKind: .expense, context: context)
            guard transaction.destinationAccountID == nil else {
                throw TransactionValidationError.unexpectedDestinationAccount
            }
        case .transfer:
            guard transaction.categoryID == nil else {
                throw TransactionValidationError.unexpectedCategory
            }
            guard let destinationAccountID = transaction.destinationAccountID,
                  let destinationAccount = context.accountsByID[destinationAccountID] else {
                throw TransactionValidationError.missingDestinationAccount
            }
            guard destinationAccountID != accountID else {
                throw TransactionValidationError.sameTransferAccounts
            }
            guard destinationAccount.currencyCode == transaction.currencyCode else {
                throw TransactionValidationError.accountCurrencyMismatch
            }
        }
    }

    private static func validateCategory(
        _ transaction: FinanceTransaction,
        expectedKind: CategoryKind,
        context: TransactionValidationContext
    ) throws {
        guard let categoryID = transaction.categoryID,
              let category = context.categoriesByID[categoryID] else {
            throw TransactionValidationError.missingCategory
        }
        guard category.kind == expectedKind else {
            throw TransactionValidationError.categoryKindMismatch
        }
        do {
            try context.categoryHierarchy.validate(
                kind: category.kind,
                parentID: category.parentID,
                categoryID: category.id
            )
        } catch {
            throw TransactionValidationError.invalidCategoryHierarchy
        }
    }
}
