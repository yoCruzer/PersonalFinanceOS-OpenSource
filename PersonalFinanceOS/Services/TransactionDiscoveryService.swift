import Foundation

enum TransactionSortOrder: String, CaseIterable, Sendable {
    case timeNewest
    case timeOldest
    case amountHigh
    case amountLow

    var title: String {
        switch self {
        case .timeNewest: "时间：最新优先"
        case .timeOldest: "时间：最早优先"
        case .amountHigh: "金额：从高到低"
        case .amountLow: "金额：从低到高"
        }
    }

    var isAmountOrder: Bool {
        self == .amountHigh || self == .amountLow
    }
}

struct TransactionDiscoveryCriteria {
    var month: Date
    var type: TransactionType?
    var categoryID: UUID?
    var accountID: UUID?
    var tagID: UUID?
    var searchText = ""
    var sortOrder: TransactionSortOrder = .timeNewest
}

enum TransactionDiscoveryService {
    /// Filters a persistence-bounded, database-sorted result. Time ordering is
    /// preserved rather than sorting the result again in Swift.
    static func filterBounded(
        _ transactions: [FinanceTransaction],
        criteria: TransactionDiscoveryCriteria,
        categoriesByID: [UUID: Category],
        accountsByID: [UUID: Account],
        calendar: Calendar = .current
    ) -> [FinanceTransaction] {
        let query = criteria.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hierarchy = CategoryHierarchy(categories: Array(categoriesByID.values))
        let categoryFilterIDs = criteria.categoryID.map(hierarchy.descendantIDs(of:))
        let filtered = transactions.filter { transaction in
            guard criteria.type.map({ transaction.type == $0 }) ?? true,
                  categoryFilterIDs.map({ ids in transaction.categoryID.map(ids.contains) ?? false }) ?? true,
                  criteria.accountID.map({ transaction.accountID == $0 }) ?? true,
                  criteria.tagID.map({ id in transaction.tags.contains { $0.id == id } }) ?? true else {
                return false
            }
            guard !query.isEmpty else { return true }
            let categoryName = transaction.categoryID
                .flatMap { categoriesByID[$0] }
                .map(hierarchy.displayPath(for:)) ?? "待分类 待选择分类"
            let accountName = transaction.accountID.flatMap { accountsByID[$0]?.name } ?? ""
            return ([transaction.note, transaction.rawMerchantText, categoryName, accountName]
                + transaction.tags.map(\.name))
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        switch criteria.sortOrder {
        case .timeNewest: return filtered
        case .timeOldest: return filtered.reversed()
        case .amountHigh:
            return filtered.sorted {
                $0.amountMinorUnits == $1.amountMinorUnits
                    ? newestFirst($0, $1)
                    : $0.amountMinorUnits > $1.amountMinorUnits
            }
        case .amountLow:
            return filtered.sorted {
                $0.amountMinorUnits == $1.amountMinorUnits
                    ? newestFirst($0, $1)
                    : $0.amountMinorUnits < $1.amountMinorUnits
            }
        }
    }

    static func filter(
        _ transactions: [FinanceTransaction],
        criteria: TransactionDiscoveryCriteria,
        categoriesByID: [UUID: Category],
        accountsByID: [UUID: Account],
        calendar: Calendar = .current
    ) -> [FinanceTransaction] {
        let monthPrefix = monthKey(for: criteria.month, calendar: calendar)
        let query = criteria.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hierarchy = CategoryHierarchy(categories: Array(categoriesByID.values))
        let categoryFilterIDs = criteria.categoryID.map(hierarchy.descendantIDs(of:))

        let filtered = TransactionLifecycleService.sortedActive(transactions).filter { transaction in
            guard transaction.localDayKey.hasPrefix(monthPrefix),
                  criteria.type.map({ transaction.type == $0 }) ?? true,
                  categoryFilterIDs.map({ ids in
                      transaction.categoryID.map(ids.contains) ?? false
                  }) ?? true,
                  criteria.accountID.map({ transaction.accountID == $0 }) ?? true,
                  criteria.tagID.map({ id in transaction.tags.contains { $0.id == id } }) ?? true else {
                return false
            }

            guard !query.isEmpty else {
                return true
            }
            let categoryName = transaction.categoryID
                .flatMap { categoriesByID[$0] }
                .map(hierarchy.displayPath(for:)) ?? "待分类 待选择分类"
            let accountName = transaction.accountID.flatMap { accountsByID[$0]?.name } ?? ""
            return (
                [transaction.note, transaction.rawMerchantText, categoryName, accountName]
                + transaction.tags.map(\.name)
            )
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return filtered.sorted { left, right in
            switch criteria.sortOrder {
            case .timeNewest:
                return newestFirst(left, right)
            case .timeOldest:
                return oldestFirst(left, right)
            case .amountHigh:
                if left.amountMinorUnits.magnitude != right.amountMinorUnits.magnitude {
                    return left.amountMinorUnits.magnitude > right.amountMinorUnits.magnitude
                }
                return newestFirst(left, right)
            case .amountLow:
                if left.amountMinorUnits.magnitude != right.amountMinorUnits.magnitude {
                    return left.amountMinorUnits.magnitude < right.amountMinorUnits.magnitude
                }
                return newestFirst(left, right)
            }
        }
    }

    static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private static func newestFirst(_ left: FinanceTransaction, _ right: FinanceTransaction) -> Bool {
        if left.occurredAt != right.occurredAt { return left.occurredAt > right.occurredAt }
        if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
        return left.id.uuidString > right.id.uuidString
    }

    private static func oldestFirst(_ left: FinanceTransaction, _ right: FinanceTransaction) -> Bool {
        if left.occurredAt != right.occurredAt { return left.occurredAt < right.occurredAt }
        if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
        return left.id.uuidString < right.id.uuidString
    }
}
