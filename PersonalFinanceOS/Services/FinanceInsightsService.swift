import Foundation

struct FinanceMonthSummary: Equatable {
    let incomeMinorUnits: Int64
    let expenseMinorUnits: Int64
    let balanceMinorUnits: Int64
}

struct CategorySpending: Equatable {
    let categoryID: UUID?
    let amountMinorUnits: Int64
    let transactionCount: Int

    init(categoryID: UUID?, amountMinorUnits: Int64, transactionCount: Int = 0) {
        self.categoryID = categoryID
        self.amountMinorUnits = amountMinorUnits
        self.transactionCount = transactionCount
    }
}

struct MonthlyTrendPoint: Equatable {
    let monthKey: String
    let month: Date
    let incomeMinorUnits: Int64
    let expenseMinorUnits: Int64
}

struct ExpenseTrendSummary: Equatable {
    let averageMinorUnits: Int64
    let minimum: MonthlyTrendPoint?
    let maximum: MonthlyTrendPoint?
}

enum ExpenseTrendSummaryService {
    /// Only the observed coverage after the first record is known; empty months
    /// within that window still participate. The unfinished month is excluded.
    static func completeMonths(_ points: [MonthlyTrendPoint], earliestKnownDay: String?,
                               now: Date = Date(), calendar: Calendar = .current) -> [MonthlyTrendPoint] {
        guard let earliestKnownDay else { return [] }
        let currentKey = String(LocalDayKey.make(for: now, timeZone: calendar.timeZone).prefix(7))
        return points.filter { $0.monthKey > String(earliestKnownDay.prefix(7)) && $0.monthKey < currentKey }
    }

    static func summarize(_ points: [MonthlyTrendPoint]) -> ExpenseTrendSummary {
        guard !points.isEmpty else {
            return ExpenseTrendSummary(averageMinorUnits: 0, minimum: nil, maximum: nil)
        }
        let count = Int64(points.count)
        var quotientTotal: Int64 = 0
        var remainderTotal: Int64 = 0
        for point in points {
            let value = point.expenseMinorUnits
            quotientTotal += value / count
            remainderTotal += value % count
        }
        let average = quotientTotal + remainderTotal / count
        guard let maximum = points.max(by: { $0.expenseMinorUnits < $1.expenseMinorUnits }),
              points.contains(where: { $0.expenseMinorUnits != 0 }) else {
            return ExpenseTrendSummary(averageMinorUnits: average, minimum: nil, maximum: nil)
        }
        let minimum = points.min(by: { $0.expenseMinorUnits < $1.expenseMinorUnits })
        return ExpenseTrendSummary(
            averageMinorUnits: average,
            minimum: minimum?.expenseMinorUnits == maximum.expenseMinorUnits ? nil : minimum,
            maximum: maximum
        )
    }
}

struct FinanceMonthActivity: Equatable {
    let totalCount: Int
    let incomeCount: Int
    let expenseCount: Int
    let averageExpenseMinorUnits: Int64
    let averageIncomeMinorUnits: Int64
}

struct CategoryTrendPoint: Equatable {
    let monthKey: String
    let month: Date
    let amountMinorUnits: Int64
    let transactionCount: Int
}

enum MonthTrendSelectionService {
    static func nearestIndex(to selection: Date?, in months: [Date]) -> Int? {
        guard let selection, !months.isEmpty else { return nil }
        return months.indices.min { left, right in
            abs(months[left].timeIntervalSince(selection)) <
                abs(months[right].timeIntervalSince(selection))
        }
    }
}

struct FinanceInsightsSnapshot: Equatable {
    let selectedMonth: Date
    let summary: FinanceMonthSummary
    let categorySpending: [CategorySpending]
    let activity: FinanceMonthActivity
    let trend: [MonthlyTrendPoint]
    private let categoryTrendData: [String: [UUID?: CategoryTrendValue]]

    fileprivate init(
        selectedMonth: Date,
        summary: FinanceMonthSummary,
        categorySpending: [CategorySpending],
        activity: FinanceMonthActivity,
        trend: [MonthlyTrendPoint],
        categoryTrendData: [String: [UUID?: CategoryTrendValue]]
    ) {
        self.selectedMonth = selectedMonth
        self.summary = summary
        self.categorySpending = categorySpending
        self.activity = activity
        self.trend = trend
        self.categoryTrendData = categoryTrendData
    }

    static func empty(selectedMonth: Date, calendar: Calendar = .current) -> Self {
        let months = FinanceInsightsService.months(endingAt: selectedMonth, count: 6, calendar: calendar)
        return Self(
            selectedMonth: selectedMonth,
            summary: .init(incomeMinorUnits: 0, expenseMinorUnits: 0, balanceMinorUnits: 0),
            categorySpending: [],
            activity: .init(
                totalCount: 0,
                incomeCount: 0,
                expenseCount: 0,
                averageExpenseMinorUnits: 0,
                averageIncomeMinorUnits: 0
            ),
            trend: months.map {
                .init(monthKey: $0.key, month: $0.date, incomeMinorUnits: 0, expenseMinorUnits: 0)
            },
            categoryTrendData: [:]
        )
    }

    /// Presentation adapter for the checked, revision-coherent shared query.
    static func from(_ analysis: LedgerAnalysisSnapshot, selectedMonth: Date, calendar: Calendar = .current, wholeRange: Bool = false, trendAnalysis: LedgerAnalysisSnapshot? = nil) -> Self {
        let months = FinanceInsightsService.months(endingAt: selectedMonth, count: 6, calendar: calendar)
        let key = LocalDayKey.make(for: selectedMonth, timeZone: calendar.timeZone).prefix(7)
        let totals = wholeRange ? analysis.totals : analysis.monthTotals[String(key)] ?? LedgerTotals()
        var spending: [CategorySpending] = []
        let roots = wholeRange ? analysis.rootTotals : analysis.monthRootTotals[String(key), default: [:]]
        for (id, value) in roots where value.expenseCount + value.refundCount > 0 {
            spending.append(CategorySpending(categoryID: id, amountMinorUnits: value.netExpenseMinorUnits, transactionCount: value.expenseCount + value.refundCount))
        }
        spending.sort {
            if $0.amountMinorUnits != $1.amountMinorUnits { return $0.amountMinorUnits > $1.amountMinorUnits }
            return ($0.categoryID?.uuidString ?? "") < ($1.categoryID?.uuidString ?? "")
        }
        let trendSource = trendAnalysis ?? analysis
        let trend: [MonthlyTrendPoint] = months.map { month in
            let value = trendSource.monthTotals[month.key] ?? LedgerTotals()
            return MonthlyTrendPoint(monthKey: month.key, month: month.date, incomeMinorUnits: value.incomeMinorUnits,
                expenseMinorUnits: value.netExpenseMinorUnits)
        }
        let categoryTrendData: [String: [UUID?: CategoryTrendValue]] = trendSource.monthCategoryTotals.mapValues { categories in
            categories.mapValues { CategoryTrendValue(amountMinorUnits: $0.netExpenseMinorUnits, transactionCount: $0.expenseCount + $0.refundCount) }
        }
        return Self(selectedMonth: selectedMonth,
            summary: .init(incomeMinorUnits: totals.incomeMinorUnits, expenseMinorUnits: totals.netExpenseMinorUnits, balanceMinorUnits: totals.balanceMinorUnits),
            categorySpending: spending,
            activity: .init(totalCount: totals.totalCount, incomeCount: totals.incomeCount, expenseCount: totals.expenseCount,
                averageExpenseMinorUnits: totals.averageExpenseMinorUnits,
                averageIncomeMinorUnits: totals.incomeCount == 0 ? 0 : totals.incomeMinorUnits / Int64(totals.incomeCount)),
            trend: trend, categoryTrendData: categoryTrendData)
    }

    func categoryTrend(
        for categoryID: UUID?,
        categories: [Category]
    ) -> [CategoryTrendPoint] {
        let hierarchy = CategoryHierarchy(categories: categories)
        let includedIDs = categoryID.map(hierarchy.descendantIDs(of:))
        return trend.map { point in
            let values = categoryTrendData[point.monthKey, default: [:]]
            let matching = values.filter { id, _ in
                includedIDs.map { id.map($0.contains) ?? false } ?? true
            }.values
            return CategoryTrendPoint(
                monthKey: point.monthKey,
                month: point.month,
                amountMinorUnits: matching.reduce(0) {
                    FinanceInsightsService.safeAdd($0, $1.amountMinorUnits)
                },
                transactionCount: matching.reduce(0) { $0 + $1.transactionCount }
            )
        }
    }
}

fileprivate struct CategoryTrendValue: Equatable {
    var amountMinorUnits: Int64 = 0
    var transactionCount = 0
}

enum FinanceInsightsService {
    /// Aggregates one bounded (normally six-month) query in a single pass.
    static func snapshot(
        for transactions: [FinanceTransaction],
        selectedMonth: Date,
        categories: [Category],
        currencyCode: String = Money.cnyCode,
        calendar: Calendar = .current
    ) -> FinanceInsightsSnapshot {
        let months = months(endingAt: selectedMonth, count: 6, calendar: calendar)
        guard !months.isEmpty else { return .empty(selectedMonth: selectedMonth, calendar: calendar) }

        let monthKeys = Set(months.map(\.key))
        let selectedKey = TransactionDiscoveryService.monthKey(for: selectedMonth, calendar: calendar)
        let hierarchy = CategoryHierarchy(categories: categories)
        var incomeByMonth = [String: Int64]()
        var expenseByMonth = [String: Int64]()
        var categoryByMonth = [String: [UUID?: CategoryTrendValue]]()
        var selectedCategoryTotals = [UUID?: Int64]()
        var selectedCategoryCounts = [UUID?: Int]()
        var totalCount = 0
        var incomeCount = 0
        var expenseCount = 0
        var incomeTotal: Int64 = 0
        var expenseTotal: Int64 = 0

        for transaction in transactions where transaction.deletedAt == nil && transaction.currencyCode == currencyCode {
            let monthKey = String(transaction.localDayKey.prefix(7))
            guard monthKeys.contains(monthKey) else { continue }
            let categoryID = transaction.categoryID
            switch transaction.type {
            case .income:
                incomeByMonth[monthKey] = safeAdd(incomeByMonth[monthKey, default: 0], transaction.amountMinorUnits)
                if monthKey == selectedKey {
                    totalCount += 1
                    incomeCount += 1
                    incomeTotal = safeAdd(incomeTotal, transaction.amountMinorUnits)
                }
            case .expense, .refund:
                let contribution = TransactionAccountingSemantics.netExpenseContribution(
                    for: transaction.type,
                    amount: transaction.amountMinorUnits
                )
                expenseByMonth[monthKey] = safeAdd(expenseByMonth[monthKey, default: 0], contribution)
                var byCategory = categoryByMonth[monthKey, default: [:]]
                var value = byCategory[categoryID, default: .init()]
                value.amountMinorUnits = safeAdd(value.amountMinorUnits, contribution)
                value.transactionCount += 1
                byCategory[categoryID] = value
                categoryByMonth[monthKey] = byCategory
                if monthKey == selectedKey {
                    totalCount += 1
                    if transaction.type == .expense {
                        expenseCount += 1
                        expenseTotal = safeAdd(expenseTotal, transaction.amountMinorUnits)
                    }
                    let aggregateID = hierarchy.aggregateRootID(for: categoryID)
                    selectedCategoryTotals[aggregateID] = safeAdd(
                        selectedCategoryTotals[aggregateID, default: 0],
                        contribution
                    )
                    selectedCategoryCounts[aggregateID, default: 0] += 1
                }
            case .transfer:
                if monthKey == selectedKey { totalCount += 1 }
            }
        }

        let trend = months.map { month in
            MonthlyTrendPoint(
                monthKey: month.key,
                month: month.date,
                incomeMinorUnits: max(0, incomeByMonth[month.key, default: 0]),
                expenseMinorUnits: expenseByMonth[month.key, default: 0]
            )
        }
        let income = incomeByMonth[selectedKey, default: 0]
        let expense = expenseByMonth[selectedKey, default: 0]
        var spending: [CategorySpending] = []
        for (categoryID, amount) in selectedCategoryTotals {
            spending.append(CategorySpending(
                categoryID: categoryID,
                amountMinorUnits: amount,
                transactionCount: selectedCategoryCounts[categoryID, default: 0]
            ))
        }
        spending.sort {
            if $0.amountMinorUnits != $1.amountMinorUnits {
                return $0.amountMinorUnits > $1.amountMinorUnits
            }
            return ($0.categoryID?.uuidString ?? "") < ($1.categoryID?.uuidString ?? "")
        }
        return FinanceInsightsSnapshot(
            selectedMonth: selectedMonth,
            summary: .init(
                incomeMinorUnits: income,
                expenseMinorUnits: expense,
                balanceMinorUnits: safeSubtract(income, expense)
            ),
            categorySpending: spending,
            activity: .init(
                totalCount: totalCount,
                incomeCount: incomeCount,
                expenseCount: expenseCount,
                averageExpenseMinorUnits: average(expenseTotal, count: expenseCount),
                averageIncomeMinorUnits: average(incomeTotal, count: incomeCount)
            ),
            trend: trend,
            categoryTrendData: categoryByMonth
        )
    }

    static func months(
        endingAt month: Date,
        count: Int,
        calendar: Calendar
    ) -> [(key: String, date: Date)] {
        guard count > 0 else { return [] }
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: -offset, to: month) else { return nil }
            return (TransactionDiscoveryService.monthKey(for: date, calendar: calendar), date)
        }
    }
    static func summary(
        for transactions: [FinanceTransaction],
        month: Date,
        currencyCode: String = Money.cnyCode,
        calendar: Calendar = .current
    ) -> FinanceMonthSummary {
        let relevant = transactionsForMonth(
            transactions,
            month: month,
            currencyCode: currencyCode,
            calendar: calendar
        )
        var income: Int64 = 0
        var expense: Int64 = 0

        for transaction in relevant {
            switch transaction.type {
            case .income:
                income = safeAdd(income, transaction.amountMinorUnits)
            case .expense:
                expense = safeAdd(expense, transaction.amountMinorUnits)
            case .refund:
                expense = safeSubtract(expense, transaction.amountMinorUnits)
            case .transfer:
                break
            }
        }

        return FinanceMonthSummary(
            incomeMinorUnits: income,
            expenseMinorUnits: expense,
            balanceMinorUnits: safeSubtract(income, expense)
        )
    }

    static func categorySpending(
        for transactions: [FinanceTransaction],
        month: Date,
        categories: [Category] = [],
        currencyCode: String = Money.cnyCode,
        calendar: Calendar = .current
    ) -> [CategorySpending] {
        let relevant = transactionsForMonth(
            transactions,
            month: month,
            currencyCode: currencyCode,
            calendar: calendar
        )
        let hierarchy = CategoryHierarchy(categories: categories)
        var totals: [UUID?: Int64] = [:]
        var counts: [UUID?: Int] = [:]

        for transaction in relevant {
            let aggregateID = categories.isEmpty
                ? transaction.categoryID
                : hierarchy.aggregateRootID(for: transaction.categoryID)
            switch transaction.type {
            case .expense:
                totals[aggregateID] = safeAdd(
                    totals[aggregateID, default: 0],
                    transaction.amountMinorUnits
                )
                counts[aggregateID, default: 0] += 1
            case .refund:
                counts[aggregateID, default: 0] += 1
                totals[aggregateID] = safeSubtract(
                    totals[aggregateID, default: 0],
                    transaction.amountMinorUnits
                )
            case .income, .transfer:
                break
            }
        }

        return totals
            .map {
                CategorySpending(
                    categoryID: $0.key,
                    amountMinorUnits: $0.value,
                    transactionCount: counts[$0.key, default: 0]
                )
            }
            .sorted {
                if $0.amountMinorUnits != $1.amountMinorUnits {
                    return $0.amountMinorUnits > $1.amountMinorUnits
                }
                return ($0.categoryID?.uuidString ?? "") < ($1.categoryID?.uuidString ?? "")
            }
    }

    static func activity(
        for transactions: [FinanceTransaction],
        month: Date,
        currencyCode: String = Money.cnyCode,
        calendar: Calendar = .current
    ) -> FinanceMonthActivity {
        let relevant = transactionsForMonth(
            transactions,
            month: month,
            currencyCode: currencyCode,
            calendar: calendar
        )
        let income = relevant.filter { $0.type == .income }
        let expense = relevant.filter { $0.type == .expense }
        let incomeTotal = income.reduce(0) { safeAdd($0, $1.amountMinorUnits) }
        let expenseTotal = expense.reduce(0) { safeAdd($0, $1.amountMinorUnits) }
        return FinanceMonthActivity(
            totalCount: relevant.count,
            incomeCount: income.count,
            expenseCount: expense.count,
            averageExpenseMinorUnits: average(expenseTotal, count: expense.count),
            averageIncomeMinorUnits: average(incomeTotal, count: income.count)
        )
    }

    static func categoryTrend(
        for transactions: [FinanceTransaction],
        categoryID: UUID?,
        endingAt month: Date,
        count: Int = 6,
        categories: [Category] = [],
        currencyCode: String = Money.cnyCode,
        calendar: Calendar = .current
    ) -> [CategoryTrendPoint] {
        guard count > 0 else { return [] }
        let hierarchy = CategoryHierarchy(categories: categories)
        let includedCategoryIDs = categoryID.map { id in
            categories.isEmpty ? Set([id]) : hierarchy.descendantIDs(of: id)
        }
        return (0..<count).reversed().compactMap { offset in
            guard let trendMonth = calendar.date(byAdding: .month, value: -offset, to: month) else {
                return nil
            }
            let relevant = transactionsForMonth(
                transactions,
                month: trendMonth,
                currencyCode: currencyCode,
                calendar: calendar
            ).filter { $0.type == .expense }
            let filtered = includedCategoryIDs == nil ? relevant : relevant.filter { transaction in
                transaction.categoryID.map { includedCategoryIDs?.contains($0) == true } ?? false
            }
            return CategoryTrendPoint(
                monthKey: TransactionDiscoveryService.monthKey(for: trendMonth, calendar: calendar),
                month: trendMonth,
                amountMinorUnits: filtered.reduce(0) { safeAdd($0, TransactionAccountingSemantics.netExpenseContribution(for: $1.type, amount: $1.amountMinorUnits)) },
                transactionCount: filtered.count
            )
        }
    }

    static func trend(
        for transactions: [FinanceTransaction],
        endingAt month: Date,
        count: Int = 6,
        currencyCode: String = Money.cnyCode,
        calendar: Calendar = .current
    ) -> [MonthlyTrendPoint] {
        guard count > 0 else {
            return []
        }

        return (0..<count).reversed().compactMap { offset in
            guard let trendMonth = calendar.date(byAdding: .month, value: -offset, to: month) else {
                return nil
            }
            let summary = summary(
                for: transactions,
                month: trendMonth,
                currencyCode: currencyCode,
                calendar: calendar
            )
            return MonthlyTrendPoint(
                monthKey: TransactionDiscoveryService.monthKey(
                    for: trendMonth,
                    calendar: calendar
                ),
                month: trendMonth,
                incomeMinorUnits: max(0, summary.incomeMinorUnits),
                expenseMinorUnits: summary.expenseMinorUnits
            )
        }
    }

    private static func transactionsForMonth(
        _ transactions: [FinanceTransaction],
        month: Date,
        currencyCode: String,
        calendar: Calendar
    ) -> [FinanceTransaction] {
        let monthKey = TransactionDiscoveryService.monthKey(for: month, calendar: calendar)
        return transactions.filter {
            $0.deletedAt == nil &&
            $0.currencyCode == currencyCode &&
            $0.localDayKey.hasPrefix(monthKey)
        }
    }

    fileprivate static func safeAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (result, overflow) = left.addingReportingOverflow(right)
        return overflow ? (right >= 0 ? .max : .min) : result
    }

    private static func safeSubtract(_ left: Int64, _ right: Int64) -> Int64 {
        let (result, overflow) = left.subtractingReportingOverflow(right)
        return overflow ? (right >= 0 ? .min : .max) : result
    }

    private static func average(_ value: Int64, count: Int) -> Int64 {
        guard count > 0 else { return 0 }
        return value / Int64(count)
    }
}
