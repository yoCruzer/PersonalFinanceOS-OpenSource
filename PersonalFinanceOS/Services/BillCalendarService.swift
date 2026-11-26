import Foundation

struct BillCalendarAmountPresentation: Equatable {
    let text: String
    let isApproximate: Bool
}

enum BillCalendarAmountFormatter {
    static func presentation(for minorUnits: Int64) -> BillCalendarAmountPresentation {
        let sign = minorUnits < 0 ? "−" : ""
        let absolute = minorUnits == .min ? Int64.max : abs(minorUnits)
        let yuan = Decimal(absolute) / 100
        let compact = "¥\(yuan.formatted(.number.notation(.compactName)))"
        let isApproximate = !isLosslesslyRepresented(absolute)
        return BillCalendarAmountPresentation(
            text: "\(sign)\(isApproximate ? "≈" : "")\(compact)",
            isApproximate: isApproximate
        )
    }

    private static func isLosslesslyRepresented(_ minorUnits: Int64) -> Bool {
        switch minorUnits {
        case 0..<100_000:
            minorUnits.isMultiple(of: 100)
        case 100_000..<100_000_000:
            minorUnits.isMultiple(of: 10_000)
        default:
            minorUnits.isMultiple(of: 10_000_000)
        }
    }
}

struct BillCalendarDay: Identifiable, Equatable {
    let date: Date
    let localDayKey: String
    let incomeMinorUnits: Int64
    let expenseMinorUnits: Int64
    let incomeCount: Int
    let expenseCount: Int
    var refundCount = 0
    var transferCount = 0
    var grossExpenseMinorUnits: Int64 = 0
    var refundMinorUnits: Int64 = 0

    var id: String { localDayKey }
    var transactionCount: Int { incomeCount + expenseCount + refundCount + transferCount }
    var balanceMinorUnits: Int64 { incomeMinorUnits - expenseMinorUnits }

    func displayedAmount(for mode: LedgerFilter.Mode) -> Int64? {
        guard transactionCount > 0 else { return nil }
        switch mode {
        case .income: return incomeMinorUnits
        case .refund: return refundMinorUnits
        case .expense: return grossExpenseMinorUnits
        case .transfer: return nil
        case .netExpense: return expenseMinorUnits
        case .all: return expenseCount + refundCount > 0 ? expenseMinorUnits : incomeCount > 0 ? incomeMinorUnits : nil
        }
    }

    func displayedAmountTitle(for mode: LedgerFilter.Mode) -> String {
        switch mode {
        case .income: return "收入"
        case .refund: return "退款"
        case .expense: return "原始支出"
        case .transfer: return "转账"
        case .netExpense: return "支出"
        case .all: return expenseCount + refundCount > 0 ? "支出" : incomeCount > 0 ? "收入" : "转账"
        }
    }
}

enum ExpenseHeatLevel: Int, Equatable {
    case none = 0
    case low = 1
    case mediumLow = 2
    case mediumHigh = 3
    case high = 4
}

enum BillCalendarHeatmap {
    static func levels(for expenses: [Int64]) -> [ExpenseHeatLevel] {
        let positiveValues = Array(Set(expenses.filter { $0 > 0 })).sorted()
        guard !positiveValues.isEmpty else { return expenses.map { _ in .none } }

        return expenses.map { expense in
            guard expense > 0,
                  let rank = positiveValues.firstIndex(of: expense) else { return .none }
            switch positiveValues.count {
            case 1:
                return .mediumLow
            case 2:
                return rank == 0 ? .mediumLow : .high
            default:
                let rawLevel = 1 + rank * 3 / (positiveValues.count - 1)
                return ExpenseHeatLevel(rawValue: rawLevel) ?? .high
            }
        }
    }
}

enum BillCalendarService {
    /// Calendar cells and day details use the same checked, stored-local-day totals.
    static func days(in month: Date, totalsByDay: [String: LedgerTotals],
                     calendar: Calendar = .current) -> [BillCalendarDay?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let dayRange = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var result = Array<BillCalendarDay?>(repeating: nil, count: leading)
        for day in dayRange {
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: interval.start) else { continue }
            let key = LocalDayKey.make(for: date, timeZone: calendar.timeZone)
            let totals = totalsByDay[key, default: LedgerTotals()]
            result.append(BillCalendarDay(date: date, localDayKey: key,
                incomeMinorUnits: totals.incomeMinorUnits, expenseMinorUnits: totals.netExpenseMinorUnits,
                incomeCount: totals.incomeCount, expenseCount: totals.expenseCount,
                refundCount: totals.refundCount, transferCount: totals.transferCount,
                grossExpenseMinorUnits: totals.grossExpenseMinorUnits, refundMinorUnits: totals.refundMinorUnits))
        }
        return result
    }

    static func days(
        in month: Date,
        transactions: [FinanceTransaction],
        calendar: Calendar = .current
    ) -> [BillCalendarDay?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let dayRange = calendar.range(of: .day, in: .month, for: month) else {
            return []
        }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var totalsByDay: [String: BillCalendarTotals] = [:]
        for transaction in transactions where transaction.deletedAt == nil {
            var totals = totalsByDay[transaction.localDayKey, default: .init()]
            switch transaction.type {
            case .income:
                totals.incomeMinorUnits = safeAdd(totals.incomeMinorUnits, transaction.amountMinorUnits)
                totals.incomeCount += 1
            case .expense:
                totals.expenseMinorUnits = safeAdd(totals.expenseMinorUnits, transaction.amountMinorUnits)
                totals.expenseCount += 1
            case .refund:
                totals.expenseMinorUnits = safeSubtract(totals.expenseMinorUnits, transaction.amountMinorUnits)
                totals.expenseCount += 1
            case .transfer:
                break
            }
            totalsByDay[transaction.localDayKey] = totals
        }
        var result = Array<BillCalendarDay?>(repeating: nil, count: leading)

        for day in dayRange {
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: interval.start) else {
                continue
            }
            let key = LocalDayKey.make(for: date, timeZone: calendar.timeZone)
            let totals = totalsByDay[key, default: .init()]
            result.append(BillCalendarDay(
                date: date,
                localDayKey: key,
                incomeMinorUnits: totals.incomeMinorUnits,
                expenseMinorUnits: totals.expenseMinorUnits,
                incomeCount: totals.incomeCount,
                expenseCount: totals.expenseCount
            ))
        }
        return result
    }

    static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        AppDateFormatter.weekdaySymbols(
            locale: calendar.locale ?? .autoupdatingCurrent,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
    }

    private static func safeAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? .max : value
    }

    private static func safeSubtract(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.subtractingReportingOverflow(right)
        return overflow ? .min : value
    }
}

private struct BillCalendarTotals {
    var incomeMinorUnits: Int64 = 0
    var expenseMinorUnits: Int64 = 0
    var incomeCount = 0
    var expenseCount = 0
}
