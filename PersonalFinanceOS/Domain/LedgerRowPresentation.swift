import Foundation

/// Uses the already loaded row/metadata; no extra model fetch per row.
enum LedgerRowPresentation {
    static func time(_ row: LedgerFilteredRow, locale: Locale) -> String {
        guard let zone = TimeZone(identifier: row.timeZoneIdentifier) else { return "时间待核实" }
        return AppDateFormatter.time(row.occurredAt, locale: locale, timeZone: zone)
    }

    static func searchExplanation(query: String, row: LedgerFilteredRow, metadata: LedgerFilterMetadata) -> String? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let visible = [row.note, metadata.path(row.categoryID), row.accountID.flatMap { metadata.accounts[$0] } ?? "",
            row.destinationAccountID.flatMap { metadata.accounts[$0] } ?? ""]
        guard !visible.contains(where: { $0.localizedCaseInsensitiveContains(query) }) else { return nil }
        if row.merchant.localizedCaseInsensitiveContains(query) { return "商户：" + row.merchant }
        let tags = row.tagIDs.compactMap { metadata.tags[$0] }.filter { $0.localizedCaseInsensitiveContains(query) }.sorted()
        return tags.isEmpty ? nil : "标签：" + tags.prefix(2).joined(separator: "、")
    }
}

enum SignedAmountFormatting {
    static func text(_ minorUnits: Int64, currencyCode: String = Money.cnyCode, locale: Locale = .current) -> String {
        (Decimal(minorUnits) / 100).formatted(.currency(code: currencyCode).locale(locale))
    }
}
