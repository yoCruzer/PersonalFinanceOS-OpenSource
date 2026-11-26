import XCTest

/// Captures production SwiftUI screens using the existing, explicit in-memory fixture.
/// No owner ledger, account, CloudKit zone, or persistent production data is accessed.
@MainActor
final class AppStoreScreenshotsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-build21SyntheticFixture", "YES", "-productReviewFixture", "YES",
            "-icloudSyncEnabled", "NO", "-smartSuggestions.enabled", "NO",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-appearance.mode", "light", "-appearance.fontSize", "system"]
        app.launch()
        XCTAssertTrue(app.buttons["primary-tab-transactions"].waitForExistence(timeout: 30))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        // Allow SwiftUI category-reordering and calendar-selection animations to finish.
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "appstore-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func test01QuickAdd() {
        let app = launch()
        app.buttons["quick-add"].tap()
        XCTAssertTrue(app.buttons["calculator-2"].waitForExistence(timeout: 5))
        app.buttons["calculator-2"].tap()
        app.buttons["calculator-8"].tap()
        app.buttons["category-午餐"].tap()
        XCTAssertTrue(app.buttons["transaction-save"].isEnabled)
        capture(app, "01-quick-add")
        app.buttons["transaction-cancel"].tap()
    }

    func test02Ledger() {
        let app = launch()
        app.buttons["primary-tab-transactions"].tap()
        XCTAssertTrue(app.staticTexts["¥11,906.40"].waitForExistence(timeout: 10))
        capture(app, "02-ledger")
    }

    func test03HistorySearch() {
        let app = launch()
        app.buttons["primary-tab-transactions"].tap()
        app.searchAllTransactions(for: "生日礼物")
        XCTAssertTrue(app.staticTexts["965 笔"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["¥162,120.00"].exists)
        capture(app, "03-search")
    }

    func test04Calendar() {
        let app = launch()
        app.buttons["primary-tab-transactions"].tap()
        app.buttons["列表"].firstMatch.tap()
        app.buttons["日历"].tap()
        XCTAssertTrue(app.buttons["上个月"].waitForExistence(timeout: 5))
        app.buttons["上个月"].tap()
        XCTAssertTrue(app.staticTexts["2026年10月"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["calendar-day-2026-10-15"].waitForExistence(timeout: 5))
        app.buttons["calendar-day-2026-10-15"].tap()
        capture(app, "04-calendar")
    }

    func test05InsightsAndDrilldown() {
        let app = launch()
        app.buttons["primary-tab-insights"].tap()
        XCTAssertTrue(app.staticTexts["¥11,906.40"].waitForExistence(timeout: 10))
        capture(app, "05-insights")
        app.buttons["primary-tab-overview"].tap()
        app.buttons["overview-net-expense-details"].tap()
        XCTAssertTrue(app.buttons["analysis-actions"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["¥11,906.40"].exists)
        capture(app, "05-drilldown-evidence")
    }

    func test06Categories() {
        let app = launch()
        app.buttons["primary-tab-settings"].tap()
        let categories = app.staticTexts["分类"].firstMatch
        XCTAssertTrue(categories.waitForExistence(timeout: 10))
        categories.tap()
        XCTAssertTrue(app.navigationBars["分类"].waitForExistence(timeout: 5))
        capture(app, "06-categories")
    }

    func test07DataOwnership() {
        let app = launch()
        app.buttons["primary-tab-settings"].tap()
        let data = app.staticTexts["导入与导出"].firstMatch
        XCTAssertTrue(data.waitForExistence(timeout: 10))
        for _ in 0..<5 where !data.isHittable { app.swipeUp() }
        data.tap()
        XCTAssertTrue(app.navigationBars["数据管理"].waitForExistence(timeout: 5))
        for title in ["导入账单", "导出账单", "完整备份与恢复", "导入历史"] {
            XCTAssertTrue(app.staticTexts[title].exists)
        }
        capture(app, "07-data")
    }
    func test08PrivacyAndLicenses() {
        let app = launch()
        app.buttons["primary-tab-settings"].tap()
        let policy = app.links["privacy-policy-link"]
        for _ in 0..<12 where !policy.isHittable { app.swipeUp() }
        XCTAssertTrue(policy.isHittable)
        XCTAssertTrue(app.links["support-link"].exists)
        let notices = app.buttons["open-source-notices"]
        // Keep the settings row above the custom bottom navigation hit region.
        for _ in 0..<5 where !notices.isHittable || notices.frame.maxY > app.frame.height - 140 {
            app.swipeUp()
        }
        XCTAssertTrue(notices.isHittable)
        notices.tap()
        XCTAssertTrue(app.navigationBars["开源许可"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "CoreXLSX 0.14.2")).firstMatch.exists)
        capture(app, "08-licenses-evidence")
    }

}
