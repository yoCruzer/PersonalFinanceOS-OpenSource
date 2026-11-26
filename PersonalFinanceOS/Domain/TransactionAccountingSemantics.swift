import SwiftUI

/// The single source of truth for how a transaction affects the user's ledger.
/// Amounts stored on `FinanceTransaction` are always positive magnitudes.
enum TransactionAccountingSemantics {
    static func incomeContribution(for type: TransactionType, amount: Int64) -> Int64 {
        type == .income ? amount : 0
    }

    static func netExpenseContribution(for type: TransactionType, amount: Int64) -> Int64 {
        switch type {
        case .expense: amount
        case .refund: -amount
        case .income, .transfer: 0
        }
    }

    static func presentation(for type: TransactionType) -> TransactionTypePresentation {
        switch type {
        case .expense:
            TransactionTypePresentation(title: "支出", amountPrefix: "", color: PFColor.primaryText)
        case .income:
            TransactionTypePresentation(title: "收入", amountPrefix: "+", color: PFColor.income)
        case .refund:
            TransactionTypePresentation(title: "退款", amountPrefix: "+", color: PFColor.accent)
        case .transfer:
            TransactionTypePresentation(title: "转账", amountPrefix: "", color: PFColor.secondaryText)
        }
    }
}

struct TransactionTypePresentation {
    let title: String
    let amountPrefix: String
    let color: Color
}
