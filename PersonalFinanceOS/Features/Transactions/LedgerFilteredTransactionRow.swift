import SwiftUI

struct LedgerFilteredTransactionRow: View {
    @Environment(\.locale) private var locale
    let row: LedgerFilteredRow
    let metadata: LedgerFilterMetadata
    var categoryPathOverride: String?
    var showsDate = true
    var searchQuery = ""

    private var presentation: TransactionTypePresentation { TransactionAccountingSemantics.presentation(for: row.type) }

    var body: some View {
        HStack(alignment: .center, spacing: PFSpacing.medium) {
            let category = row.categoryID.flatMap { metadata.categories[$0] }
            CategoryIconView(symbolName: row.type == .transfer ? "arrow.left.arrow.right" : category?.symbolName ?? CategoryIconLibrary.fallback,
                color: PFColor.category(category?.colorToken ?? "teal"), size: 34)
            VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
                Text(row.type == .transfer ? "转账" : (categoryPathOverride ?? metadata.path(row.categoryID)))
                    .font(.subheadline.weight(.semibold))
                if !row.note.isEmpty { Text(row.note).font(.subheadline).lineLimit(2) }
                if let explanation = LedgerRowPresentation.searchExplanation(query: searchQuery, row: row, metadata: metadata) {
                    Text(explanation).font(.caption).foregroundStyle(PFColor.accent).lineLimit(1)
                }
                Text(detail).font(.caption).foregroundStyle(PFColor.secondaryText)
            }
            Spacer()
            Text(presentation.amountPrefix + SignedAmountFormatting.text(row.amountMinorUnits, currencyCode: row.currencyCode, locale: locale))
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(presentation.color)
        }
        .foregroundStyle(PFColor.primaryText)
        .frame(minHeight: 52)
        .padding(.vertical, PFSpacing.small)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([presentation.title, row.type == .transfer ? "转账" : (categoryPathOverride ?? metadata.path(row.categoryID)), row.note, detail,
            LedgerRowPresentation.searchExplanation(query: searchQuery, row: row, metadata: metadata) ?? ""].filter { !$0.isEmpty }.joined(separator: "，"))
        .accessibilityValue(presentation.amountPrefix + SignedAmountFormatting.text(row.amountMinorUnits, currencyCode: row.currencyCode, locale: locale))
    }

    private var detail: String {
        var values: [String] = showsDate ? [row.localDayKey] : []
        values.append(LedgerRowPresentation.time(row, locale: locale))
        switch row.type {
        case .expense: break
        case .income: values.append("收入")
        case .refund: values.append("退款")
        case .transfer: values.append("转账")
        }
        if let id = row.accountID, let account = metadata.accounts[id] { values.append(account) }
        if row.type == .transfer, let id = row.destinationAccountID, let account = metadata.accounts[id] {
            values.append("→ " + account)
        }
        return values.joined(separator: " · ")
    }
}
