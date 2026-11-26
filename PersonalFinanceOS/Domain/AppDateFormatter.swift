import Foundation

enum AppDateFormatter {
    static var interfaceLocale: Locale {
        interfaceLocale(
            preferredLanguages: Locale.preferredLanguages,
            systemLocale: .autoupdatingCurrent
        )
    }

    static func interfaceLocale(
        preferredLanguages: [String],
        systemLocale: Locale
    ) -> Locale {
        guard let preferredLanguage = preferredLanguages.first else { return systemLocale }
        let preferredLocale = Locale(identifier: preferredLanguage)
        if preferredLocale.language.languageCode == systemLocale.language.languageCode {
            return systemLocale
        }
        let region = systemLocale.region?.identifier
        let identifier = [preferredLanguage, region]
            .compactMap { $0 }
            .joined(separator: "_")
        return Locale(identifier: identifier)
    }

    static func monthYear(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        date.formatted(monthYearStyle(locale: locale, calendar: calendar, timeZone: timeZone))
    }

    static func monthAbbreviated(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        date.formatted(monthAbbreviatedStyle(
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        ))
    }

    static func dayNumber(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var localizedCalendar = calendar
        localizedCalendar.locale = locale
        localizedCalendar.timeZone = timeZone
        return String(localizedCalendar.component(.day, from: date))
    }

    static func fullDate(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        date.formatted(Date.FormatStyle(
            date: .complete,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        ))
    }

    static func dateTime(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        date.formatted(Date.FormatStyle(
            date: .complete,
            time: .shortened,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        ))
    }

    static func shortDateTime(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        date.formatted(Date.FormatStyle(
            date: .abbreviated,
            time: .shortened,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        ))
    }

    static func time(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        date.formatted(Date.FormatStyle(
            date: .omitted,
            time: .shortened,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        ))
    }

    static func monthDayWeekday(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        date.formatted(
            baseStyle(locale: locale, calendar: calendar, timeZone: timeZone)
                .month()
                .day()
                .weekday(.abbreviated)
        )
    }

    static func contextualDateTime(
        _ date: Date,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var localizedCalendar = calendar
        localizedCalendar.locale = locale
        localizedCalendar.timeZone = timeZone
        if localizedCalendar.isDate(date, inSameDayAs: now) {
            return "\(relativeDayName(today: true, locale: locale)) \(time(date, locale: locale, calendar: calendar, timeZone: timeZone))"
        }
        if let yesterday = localizedCalendar.date(byAdding: .day, value: -1, to: now),
           localizedCalendar.isDate(date, inSameDayAs: yesterday) {
            return "\(relativeDayName(today: false, locale: locale)) \(time(date, locale: locale, calendar: calendar, timeZone: timeZone))"
        }
        return shortDateTime(date, locale: locale, calendar: calendar, timeZone: timeZone)
    }

    static func weekdaySymbols(
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> [String] {
        var localizedCalendar = calendar
        localizedCalendar.locale = locale
        localizedCalendar.timeZone = timeZone
        let symbols = localizedCalendar.shortStandaloneWeekdaySymbols
        let start = max(0, localizedCalendar.firstWeekday - 1)
        return Array(symbols[start...] + symbols[..<start])
    }

    static func monthYearStyle(
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Date.FormatStyle {
        baseStyle(locale: locale, calendar: calendar, timeZone: timeZone)
            .year()
            .month(.wide)
    }

    static func monthAbbreviatedStyle(
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Date.FormatStyle {
        baseStyle(locale: locale, calendar: calendar, timeZone: timeZone)
            .month(.abbreviated)
    }

    private static func baseStyle(
        locale: Locale,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Date.FormatStyle {
        Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
    }

    private static func relativeDayName(today: Bool, locale: Locale) -> String {
        switch locale.language.languageCode?.identifier {
        case "zh": today ? "今天" : "昨天"
        default: today ? "Today" : "Yesterday"
        }
    }
}
