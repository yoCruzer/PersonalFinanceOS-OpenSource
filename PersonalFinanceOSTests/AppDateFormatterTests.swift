import XCTest
@testable import PersonalFinanceOS

final class AppDateFormatterTests: XCTestCase {
    func testCalendarDayNumberNeverAddsLocaleSuffix() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-04T12:00:00+08:00"))
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        XCTAssertEqual(AppDateFormatter.dayNumber(date, locale: Locale(identifier: "zh_CN"), timeZone: timeZone), "4")
        XCTAssertEqual(AppDateFormatter.dayNumber(date, locale: Locale(identifier: "en_US"), timeZone: timeZone), "4")
    }

    private let chinese = Locale(identifier: "zh_Hans_CN")
    private let english = Locale(identifier: "en_US")
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    func testChineseAndEnglishMonthAndWeekdayFollowRequestedLocale() throws {
        let date = try fixedDate()
        let chineseMonth = AppDateFormatter.monthYear(date, locale: chinese, timeZone: shanghai)
        let chineseWeekdays = AppDateFormatter.weekdaySymbols(locale: chinese, timeZone: shanghai)
        XCTAssertTrue(chineseMonth.contains("8月"))
        XCTAssertFalse(chineseMonth.localizedCaseInsensitiveContains("August"))
        XCTAssertFalse(chineseWeekdays.joined().localizedCaseInsensitiveContains("Sun"))

        let englishMonth = AppDateFormatter.monthYear(date, locale: english, timeZone: shanghai)
        let englishWeekdays = AppDateFormatter.weekdaySymbols(locale: english, timeZone: shanghai)
        XCTAssertTrue(englishMonth.localizedCaseInsensitiveContains("August"))
        XCTAssertTrue(englishWeekdays.contains { $0.localizedCaseInsensitiveContains("Sun") })
        XCTAssertFalse(englishMonth.contains("月"))
    }

    func testInterfaceLocaleUsesAppLanguageWithoutForcingChinese() {
        let chineseInterface = AppDateFormatter.interfaceLocale(
            preferredLanguages: ["zh-Hans"],
            systemLocale: Locale(identifier: "zh_Hans_CN@hours=h23")
        )
        let englishInterface = AppDateFormatter.interfaceLocale(
            preferredLanguages: ["en"],
            systemLocale: Locale(identifier: "en_US@hours=h12")
        )
        XCTAssertEqual(chineseInterface.language.languageCode?.identifier, "zh")
        XCTAssertEqual(englishInterface.language.languageCode?.identifier, "en")
        XCTAssertEqual(chineseInterface.hourCycle, .zeroToTwentyThree)
        XCTAssertEqual(englishInterface.hourCycle, .oneToTwelve)
    }

    func testDetailListAndCalendarUseConsistentLocalizedRules() throws {
        let date = try fixedDate()
        let detail = AppDateFormatter.dateTime(date, locale: chinese, timeZone: shanghai)
        let listTime = AppDateFormatter.time(date, locale: chinese, timeZone: shanghai)
        let calendarDate = AppDateFormatter.fullDate(date, locale: chinese, timeZone: shanghai)
        XCTAssertTrue(detail.contains(calendarDate))
        XCTAssertTrue(detail.contains(listTime))
        XCTAssertTrue(AppDateFormatter.monthDayWeekday(date, locale: chinese, timeZone: shanghai).contains("8月2日"))
    }

    func testStoredTimeZonePreventsNearMidnightDateDrift() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T02:45:00+08:00"))
        let shanghaiText = AppDateFormatter.fullDate(date, locale: chinese, timeZone: shanghai)
        let losAngelesText = AppDateFormatter.fullDate(date, locale: chinese, timeZone: losAngeles)
        XCTAssertTrue(shanghaiText.contains("8月2日"))
        XCTAssertTrue(losAngelesText.contains("8月1日"))
    }

    func testShortTimeRespectsLocaleHourCycle() throws {
        let date = try fixedDate()
        let twelveHour = AppDateFormatter.time(
            date,
            locale: Locale(identifier: "en_US@hours=h12"),
            timeZone: shanghai
        )
        let twentyFourHour = AppDateFormatter.time(
            date,
            locale: Locale(identifier: "en_US@hours=h23"),
            timeZone: shanghai
        )
        XCTAssertTrue(twelveHour.localizedCaseInsensitiveContains("AM"), twelveHour)
        XCTAssertFalse(twentyFourHour.localizedCaseInsensitiveContains("AM"), twentyFourHour)
        XCTAssertTrue(twentyFourHour.contains("02:45"), twentyFourHour)
    }

    func testFormatStyleIsRepeatableAcrossConcurrentCalls() async throws {
        let date = try fixedDate()
        let expected = AppDateFormatter.dateTime(date, locale: chinese, timeZone: shanghai)
        let locale = chinese
        let timeZone = shanghai
        let values = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<100 {
                group.addTask {
                    AppDateFormatter.dateTime(date, locale: locale, timeZone: timeZone)
                }
            }
            var results: [String] = []
            for await value in group { results.append(value) }
            return results
        }
        XCTAssertEqual(Set(values), [expected])
    }

    private func fixedDate() throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T02:45:00+08:00"))
    }
}
