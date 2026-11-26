import Foundation

/// Shared, nonpersisted meaning of an analysis, its detail rows and its export.
struct LedgerFilter: Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case all, income, expense, refund, netExpense, transfer
        var title: String {
            switch self {
            case .all: "全部记录"
            case .income: "收入"
            case .expense: "只看支出记录"
            case .refund: "退款"
            case .netExpense: "支出（扣除退款）"
            case .transfer: "转账"
            }
        }
        var types: [String] {
            switch self {
            case .all: TransactionType.allCases.map(\.rawValue)
            case .income: [TransactionType.income.rawValue]
            case .expense: [TransactionType.expense.rawValue]
            case .refund: [TransactionType.refund.rawValue]
            case .netExpense: [TransactionType.expense.rawValue, TransactionType.refund.rawValue]
            case .transfer: [TransactionType.transfer.rawValue]
            }
        }
    }
    enum CategoryScope: Equatable, Sendable {
        case all
        case uncategorized
        case node(UUID)
        case direct(UUID)
    }
    enum Deletion: Sendable { case active, deleted, all }

    var dateRange: LocalDayRange?
    var mode: Mode = .all
    var category: CategoryScope = .all
    var accountID: UUID?
    /// All selected tags are required; a transaction contributes only once.
    var tagIDs: Set<UUID> = []
    var merchant = ""
    var query = ""
    var currencyCode = Money.cnyCode
    var deletion: Deletion = .active
    var sortOrder: TransactionSortOrder = .timeNewest
    /// Business-content revision; receipt-only persistence does not invalidate this filter.
    var revision: UInt64?
    /// Nonpersisted cutoff shared by factual comparisons, detail pages and exports.
    var occurredThrough: Date?

    mutating func selectDateRange(_ range: LocalDayRange?) {
        dateRange = range
        occurredThrough = nil
        revision = nil
    }

    var withoutRevision: Self { var value = self; value.revision = nil; return value }

    func dateTitle(locale: Locale = .current) -> String {
        guard let dateRange else { return "全部历史" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let start = formatter.date(from: dateRange.lowerBound),
              let exclusiveEnd = formatter.date(from: dateRange.upperBound),
              let end = calendar.date(byAdding: .day, value: -1, to: exclusiveEnd) else {
            return "自定义日期"
        }
        if calendar.dateInterval(of: .month, for: start)?.start == start,
           calendar.date(byAdding: .month, value: 1, to: start) == exclusiveEnd {
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("yyyyMMMM")
            return formatter.string(from: start)
        }
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMd")
        return formatter.string(from: start) + " 至 " + formatter.string(from: end)
    }

    static func month(_ date: Date, calendar: Calendar = .current) -> Self {
        let start = calendar.dateInterval(of: .month, for: date)!.start
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return Self(dateRange: LocalDayRange(lowerBound: LocalDayKey.make(for: start, timeZone: calendar.timeZone),
            upperBound: LocalDayKey.make(for: end, timeZone: calendar.timeZone)))
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> Self {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return Self(dateRange: LocalDayRange(lowerBound: LocalDayKey.make(for: start, timeZone: calendar.timeZone),
            upperBound: LocalDayKey.make(for: end, timeZone: calendar.timeZone)))
    }

    static func sixMonths(endingAt date: Date, calendar: Calendar = .current) -> Self {
        let first = calendar.date(byAdding: .month, value: -5, to: date)!
        return Self(dateRange: LocalDayRange(lowerBound: month(first, calendar: calendar).dateRange!.lowerBound,
            upperBound: month(date, calendar: calendar).dateRange!.upperBound))
    }

    func matches(_ row: LedgerFilteredRow, metadata: LedgerFilterMetadata) -> Bool {
        if let cutoff = occurredThrough, row.occurredAt > cutoff { return false }
        if let range = dateRange, !(row.localDayKey >= range.lowerBound && row.localDayKey < range.upperBound) { return false }
        guard mode.types.contains(row.type.rawValue), row.currencyCode == currencyCode else { return false }
        if deletion == .active && row.deletedAt != nil { return false }
        if deletion == .deleted && row.deletedAt == nil { return false }
        if let accountID, row.accountID != accountID && row.destinationAccountID != accountID { return false }
        guard tagIDs.isSubset(of: row.tagIDs) else { return false }
        if !merchant.isEmpty && !row.merchant.localizedCaseInsensitiveContains(merchant) { return false }
        switch category {
        case .all: break
        case .uncategorized:
            if let id = row.categoryID, metadata.categories[id] != nil { return false }
        case let .direct(id):
            if row.categoryID != id { return false }
        case let .node(id):
            guard let selected = row.categoryID,
                  selected == id || metadata.categories[selected]?.parentID == id else { return false }
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let texts = [row.note, row.merchant, metadata.path(row.categoryID),
            row.accountID.flatMap { metadata.accounts[$0] } ?? "",
            row.destinationAccountID.flatMap { metadata.accounts[$0] } ?? ""] +
            row.tagIDs.compactMap { metadata.tags[$0] }
        return texts.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct LedgerFilterMetadata: Sendable {
    struct CategoryValue: Sendable {
        let id: UUID
        let name: String
        let parentID: UUID?
        let symbolName: String
        let colorToken: String
        var createdAt: Date = .distantFuture
        var updatedAt: Date = .distantFuture
        var inactive = false
        var comparisonAllowed = false
    }
    let categories: [UUID: CategoryValue]
    let accounts: [UUID: String]
    let tags: [UUID: String]

    func path(_ id: UUID?) -> String {
        guard let id, let category = categories[id] else { return "待分类" }
        guard let parentID = category.parentID, let parent = categories[parentID] else { return category.name }
        return parent.name + " / " + category.name
    }

    func rootID(_ id: UUID?) -> UUID? {
        guard let id, let category = categories[id] else { return nil }
        if let parentID = category.parentID, categories[parentID] != nil { return parentID }
        return id
    }
}

struct LedgerFilteredRow: Sendable, Identifiable {
    let id: UUID
    let type: TransactionType
    let amountMinorUnits: Int64
    let currencyCode: String
    let occurredAt: Date
    let localDayKey: String
    let timeZoneIdentifier: String
    let accountID: UUID?
    let destinationAccountID: UUID?
    let categoryID: UUID?
    let tagIDs: Set<UUID>
    let merchant: String
    let note: String
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    init(_ value: FinanceTransaction) {
        id = value.id
        type = value.type
        amountMinorUnits = value.amountMinorUnits
        currencyCode = value.currencyCode
        occurredAt = value.occurredAt
        localDayKey = value.localDayKey
        timeZoneIdentifier = value.timeZoneIdentifier
        accountID = value.accountID
        destinationAccountID = value.destinationAccountID
        categoryID = value.categoryID
        tagIDs = Set(value.tags.map(\.id))
        merchant = value.rawMerchantText
        note = value.note
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        deletedAt = value.deletedAt
    }
}

enum LedgerAnalysisError: LocalizedError {
    case overflow, invalidAmount, staleSnapshot
    var errorDescription: String? {
        switch self {
        case .overflow: "合计金额超出支持范围，未显示不完整的统计结果。"
        case .invalidAmount: "账本中存在无效金额，无法完成统计。"
        case .staleSnapshot: "账本已更新，请刷新当前筛选。"
        }
    }
}

struct LedgerTotals: Equatable, Sendable {
    private(set) var incomeMinorUnits: Int64 = 0
    private(set) var grossExpenseMinorUnits: Int64 = 0
    private(set) var refundMinorUnits: Int64 = 0
    private(set) var netExpenseMinorUnits: Int64 = 0
    private(set) var balanceMinorUnits: Int64 = 0
    private(set) var totalCount = 0
    private(set) var incomeCount = 0
    private(set) var expenseCount = 0
    private(set) var refundCount = 0
    private(set) var transferCount = 0
    var averageExpenseMinorUnits: Int64 { expenseCount == 0 ? 0 : grossExpenseMinorUnits / Int64(expenseCount) }

    mutating func include(_ row: LedgerFilteredRow) throws {
        guard row.amountMinorUnits >= 0 else { throw LedgerAnalysisError.invalidAmount }
        switch row.type {
        case .income:
            incomeMinorUnits = try Self.add(incomeMinorUnits, row.amountMinorUnits)
            incomeCount += 1
        case .expense:
            grossExpenseMinorUnits = try Self.add(grossExpenseMinorUnits, row.amountMinorUnits)
            expenseCount += 1
        case .refund:
            refundMinorUnits = try Self.add(refundMinorUnits, row.amountMinorUnits)
            refundCount += 1
        case .transfer: transferCount += 1
        }
        totalCount += 1
    }

    func validated() throws -> Self {
        var result = self
        result.netExpenseMinorUnits = grossExpenseMinorUnits - refundMinorUnits
        let (balance, overflow) = incomeMinorUnits.subtractingReportingOverflow(result.netExpenseMinorUnits)
        guard !overflow else { throw LedgerAnalysisError.overflow }
        result.balanceMinorUnits = balance
        return result
    }

    func amount(for mode: LedgerFilter.Mode) -> Int64 {
        switch mode {
        case .all: balanceMinorUnits
        case .income: incomeMinorUnits
        case .expense: grossExpenseMinorUnits
        case .refund: refundMinorUnits
        case .netExpense: netExpenseMinorUnits
        case .transfer: 0
        }
    }

    private static func add(_ first: Int64, _ second: Int64) throws -> Int64 {
        let (value, overflow) = first.addingReportingOverflow(second)
        guard !overflow else { throw LedgerAnalysisError.overflow }
        return value
    }
}
