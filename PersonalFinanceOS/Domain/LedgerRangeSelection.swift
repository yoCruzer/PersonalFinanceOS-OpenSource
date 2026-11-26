import Foundation

/// Range keys are authoritative; the month control and trend anchor derive from them.
enum LedgerRangeSelection {
    static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: key)
    }

    static func wholeMonth(_ filter: LedgerFilter, calendar: Calendar = .current) -> Date? {
        guard let range = filter.dateRange, let start = date(range.lowerBound, calendar: calendar),
              LedgerFilter.month(start, calendar: calendar).dateRange == range else { return nil }
        return start
    }

    static func trendAnchor(_ filter: LedgerFilter, asOf: Date, calendar: Calendar = .current) -> Date {
        if let month = wholeMonth(filter, calendar: calendar) { return month }
        guard let upper = filter.dateRange?.upperBound, let exclusiveEnd = date(upper, calendar: calendar),
              let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: exclusiveEnd) else { return asOf }
        return min(inclusiveEnd, asOf)
    }

    static func editorDates(_ filter: LedgerFilter, asOf: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        guard let range = filter.dateRange, let start = date(range.lowerBound, calendar: calendar),
              let exclusiveEnd = date(range.upperBound, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: -1, to: exclusiveEnd) else {
            let day = calendar.startOfDay(for: asOf)
            return (day, day)
        }
        return (start, end)
    }

    static func inclusiveRange(start: Date, end: Date, calendar: Calendar = .current) -> LocalDayRange? {
        let start = calendar.startOfDay(for: start)
        let end = calendar.startOfDay(for: end)
        guard start <= end, let upper = calendar.date(byAdding: .day, value: 1, to: end) else { return nil }
        return LocalDayRange(lowerBound: LocalDayKey.make(for: start, timeZone: calendar.timeZone),
            upperBound: LocalDayKey.make(for: upper, timeZone: calendar.timeZone))
    }
}
