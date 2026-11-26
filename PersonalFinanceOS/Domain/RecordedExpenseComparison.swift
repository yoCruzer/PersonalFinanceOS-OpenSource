import Foundation

/// Local, nonpersisted evidence. No claim about unrecorded spending or behavioral causes.
struct RecordedExpenseComparison: Sendable {
    enum Suppression: Sendable { case unsupportedRange, noRecordedHistory, noMaterialChange, unprovenCategory }
    struct Periods: Sendable {
        let current: LedgerFilter
        let previous: LedgerFilter
        let asOf: Date
        let isWholeMonth: Bool
        let commonDay: Int?
        let previousStart: Date
    }
    struct Fact: Sendable, Identifiable {
        let id: String
        let categoryID: UUID?
        let categoryName: String?
        let current: LedgerTotals
        let previous: LedgerTotals
        let delta: Int64
        let currentFilter: LedgerFilter
        let previousFilter: LedgerFilter
    }
    let periods: Periods
    let revision: UInt64
    let facts: [Fact]
    let suppressions: [Suppression]
    // A product noise rule (¥10), not statistical significance; never a percentage threshold.
    static let minimumChange: Int64 = 1_000

    static func periods(filter: LedgerFilter, asOf: Date, calendar: Calendar = .current) -> Periods? {
        guard filter.deletion == .active, [.all, .expense, .netExpense].contains(filter.mode),
              let month = LedgerRangeSelection.wholeMonth(filter, calendar: calendar),
              let thisMonth = calendar.dateInterval(of: .month, for: asOf)?.start,
              month <= thisMonth, let prior = calendar.date(byAdding: .month, value: -1, to: month) else { return nil }
        var current = filter.withoutRevision
        var previous = filter.withoutRevision
        current.mode = .netExpense
        previous.mode = .netExpense
        current.occurredThrough = asOf
        previous.occurredThrough = asOf
        let whole = month < thisMonth
        var commonDay: Int?
        if whole {
            current.dateRange = LedgerFilter.month(month, calendar: calendar).dateRange
            previous.dateRange = LedgerFilter.month(prior, calendar: calendar).dateRange
        } else {
            guard let previousDays = calendar.range(of: .day, in: .month, for: prior)?.count else { return nil }
            let today = calendar.component(.day, from: asOf)
            let day = min(today, previousDays)
            commonDay = day
            guard let currentLast = calendar.date(byAdding: .day, value: day - 1, to: month),
                  let previousLast = calendar.date(byAdding: .day, value: day - 1, to: prior),
                  let currentEnd = calendar.date(byAdding: .day, value: 1, to: currentLast),
                  let previousEnd = calendar.date(byAdding: .day, value: 1, to: previousLast) else { return nil }
            current.dateRange = LocalDayRange(lowerBound: LocalDayKey.make(for: month, timeZone: calendar.timeZone),
                upperBound: LocalDayKey.make(for: currentEnd, timeZone: calendar.timeZone))
            previous.dateRange = LocalDayRange(lowerBound: LocalDayKey.make(for: prior, timeZone: calendar.timeZone),
                upperBound: LocalDayKey.make(for: previousEnd, timeZone: calendar.timeZone))
            if today != day {
                current.occurredThrough = currentEnd
                previous.occurredThrough = previousEnd
            } else {
                let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: asOf)
                var components = calendar.dateComponents([.year, .month, .day], from: previousLast)
                components.hour = time.hour; components.minute = time.minute
                components.second = time.second; components.nanosecond = time.nanosecond
                guard let previousCutoff = calendar.date(from: components) else { return nil }
                previous.occurredThrough = previousCutoff
            }
        }
        return Periods(current: current, previous: previous, asOf: asOf, isWholeMonth: whole,
            commonDay: commonDay, previousStart: prior)
    }

    static func make(periods: Periods, current: LedgerAnalysisSnapshot, previous: LedgerAnalysisSnapshot) throws -> Self {
        guard current.revision == previous.revision,
              current.filter.withoutRevision == periods.current.withoutRevision,
              previous.filter.withoutRevision == periods.previous.withoutRevision else { throw LedgerAnalysisError.staleSnapshot }
        var facts: [Fact] = []
        var suppressions: [Suppression] = []
        func delta(_ now: Int64, _ old: Int64) throws -> Int64 {
            let (value, overflow) = now.subtractingReportingOverflow(old)
            guard !overflow else { throw LedgerAnalysisError.overflow }
            return value
        }
        func material(_ value: Int64) -> Bool { value >= minimumChange || value <= -minimumChange }
        if current.totals.expenseCount > 0 && previous.totals.expenseCount > 0 {
            let change = try delta(current.totals.netExpenseMinorUnits, previous.totals.netExpenseMinorUnits)
            if material(change) {
                facts.append(Fact(id: "net", categoryID: nil, categoryName: nil, current: current.totals,
                    previous: previous.totals, delta: change, currentFilter: current.filter, previousFilter: previous.filter))
            } else { suppressions.append(.noMaterialChange) }
        } else { suppressions.append(.noRecordedHistory) }
        var best: Fact?
        for (id, now) in current.directCategoryTotals {
            guard let id, let old = previous.directCategoryTotals[id], now.expenseCount > 0, old.expenseCount > 0,
                  let category = current.metadata.categories[id], comparable(category, metadata: current.metadata, since: periods.previousStart) else { continue }
            let change = try delta(now.netExpenseMinorUnits, old.netExpenseMinorUnits)
            guard change >= minimumChange else { continue }
            var nowFilter = current.filter, oldFilter = previous.filter
            nowFilter.category = .direct(id); oldFilter.category = .direct(id)
            let fact = Fact(id: id.uuidString, categoryID: id, categoryName: current.metadata.path(id), current: now,
                previous: old, delta: change, currentFilter: nowFilter, previousFilter: oldFilter)
            if best == nil || change > best!.delta || (change == best!.delta && fact.id < best!.id) { best = fact }
        }
        if let best { facts.append(best) } else { suppressions.append(.unprovenCategory) }
        return Self(periods: periods, revision: current.revision, facts: facts, suppressions: suppressions)
    }

    private static func comparable(_ category: LedgerFilterMetadata.CategoryValue, metadata: LedgerFilterMetadata, since: Date) -> Bool {
        guard category.comparisonAllowed, category.createdAt <= since, category.updatedAt <= since, !category.inactive,
              !["其他", "其它", "混合", "综合"].contains(where: category.name.contains) else { return false }
        // Direct postings to a parent/root can mix meanings; v1 only compares stable leaf identities.
        guard !metadata.categories.values.contains(where: { $0.parentID == category.id }) else { return false }
        if let parent = category.parentID {
            guard let root = metadata.categories[parent], root.createdAt <= since, root.updatedAt <= since, !root.inactive else { return false }
        }
        return true
    }
}
