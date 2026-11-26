import XCTest
@testable import PersonalFinanceOS

@MainActor
final class RecentSearchHistoryStoreTests: XCTestCase {
    func testTypingDoesNotPersistUntilSubmitAndEmptySubmitIsIgnored() {
        let defaults = cleanDefaults()
        let store = RecentSearchHistoryStore(defaults: defaults)

        XCTAssertTrue(store.values.isEmpty)
        XCTAssertNil(defaults.stringArray(forKey: RecentSearchHistoryStore.storageKey))
        XCTAssertNil(store.submit("   \n"))
        XCTAssertTrue(store.values.isEmpty)

        XCTAssertEqual(store.submit("  星巴克  "), "星巴克")
        XCTAssertEqual(store.values, ["星巴克"])
        XCTAssertEqual(
            defaults.stringArray(forKey: RecentSearchHistoryStore.storageKey),
            ["星巴克"]
        )
    }

    func testDedupeMovesToFrontCapsAtTenAndClearRemovesAll() {
        let defaults = cleanDefaults()
        let store = RecentSearchHistoryStore(defaults: defaults)
        for index in 0..<12 {
            store.submit("关键词\(index)")
        }
        XCTAssertEqual(store.values.count, 10)
        XCTAssertEqual(store.values.first, "关键词11")
        XCTAssertEqual(store.values.last, "关键词2")

        store.submit("关键词5")
        XCTAssertEqual(store.values.first, "关键词5")
        XCTAssertEqual(store.values.count, 10)

        store.clear()
        XCTAssertTrue(store.values.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: RecentSearchHistoryStore.storageKey), [])
    }

    private func cleanDefaults() -> UserDefaults {
        let name = "RecentSearchHistoryStoreTests"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
