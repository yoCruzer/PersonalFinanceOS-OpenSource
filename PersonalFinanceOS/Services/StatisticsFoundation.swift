import Foundation

enum StatisticsFoundation {
    static func netExpenseMinorUnits(
        for transactions: [FinanceTransaction],
        currencyCode: String = Money.cnyCode,
        localDayKey: String? = nil,
        categoryID: UUID? = nil,
        categories: [Category] = []
    ) -> Int64 {
        let hierarchy = CategoryHierarchy(categories: categories)
        let includedCategoryIDs = categoryID.map { id in
            categories.isEmpty ? Set([id]) : hierarchy.descendantIDs(of: id)
        }
        return transactions.reduce(into: Int64.zero) { result, transaction in
            guard transaction.deletedAt == nil,
                  transaction.currencyCode == currencyCode,
                  localDayKey.map({ $0 == transaction.localDayKey }) ?? true,
                  includedCategoryIDs.map({ ids in
                      transaction.categoryID.map(ids.contains) ?? false
                  }) ?? true else {
                return
            }

            result += TransactionAccountingSemantics.netExpenseContribution(
                for: transaction.type,
                amount: transaction.amountMinorUnits
            )
        }
    }
}
