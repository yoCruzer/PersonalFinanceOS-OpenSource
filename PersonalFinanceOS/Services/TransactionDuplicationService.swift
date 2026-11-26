import Foundation

protocol DateProvider {
    func now() -> Date
}

struct SystemDateProvider: DateProvider {
    func now() -> Date { Date() }
}

enum TransactionDuplicationService {
    static func makeDraft(
        from transaction: FinanceTransaction,
        dateProvider: any DateProvider = SystemDateProvider(),
        timeZone: TimeZone = .current
    ) -> TransactionDraft {
        var draft = TransactionDraft()
        draft.type = transaction.type
        draft.amountText = (try? Money(
            minorUnits: transaction.amountMinorUnits,
            currencyCode: transaction.currencyCode
        ).decimalString) ?? ""
        draft.currencyCode = transaction.currencyCode
        draft.accountID = transaction.accountID
        draft.destinationAccountID = transaction.destinationAccountID
        draft.categoryID = transaction.categoryID
        draft.merchantID = transaction.merchantID
        draft.rawMerchantText = transaction.rawMerchantText
        draft.note = transaction.note
        draft.tagIDs = Set(transaction.tags.map(\.id))
        draft.occurredAt = dateProvider.now()
        draft.timeZoneIdentifier = timeZone.identifier
        return draft
    }
}
