import XCTest

@MainActor
final class R3PolishUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(dark: Bool = false, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-build21SyntheticFixture", "YES", "-productReviewFixture", "YES",
            "-icloudSyncEnabled", "NO", "-smartSuggestions.enabled", "NO",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-appearance.mode", dark ? "dark" : "light", "-appearance.fontSize", "system"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["primary-tab-transactions"].waitForExistence(timeout: 15))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    func testNormalLightWalkthrough() { walkthrough(dark: false, large: false) }
    func testNormalDarkWalkthrough() { walkthrough(dark: true, large: false) }
    func testLargeDarkWalkthrough() { walkthrough(dark: true, large: true) }

    func testLargeDarkBatchTargetAndCaptureSearch() {
        let app = launch(dark: true, large: true)
        app.buttons["overview-net-expense-details"].tap()
        XCTAssertTrue(app.buttons["analysis-actions"].waitForExistence(timeout: 10))
        app.buttons["analysis-actions"].tap()
        app.buttons["批量操作完整筛选结果"].tap()
        let category = app.buttons["batch-category-action"]
        for _ in 0..<8 where !category.isHittable { app.swipeUp() }
        let actions = app.scrollViews["batch-actions-scroll"]
        for _ in 0..<5 where !category.isHittable { actions.swipeLeft() }
        capture(app, "dark-large-batch-actions")
        XCTAssertTrue(category.isHittable); category.tap()
        let search = app.searchFields["搜索分类或完整路径"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("礼物")
        let gift = app.buttons["all-category-人情公益 / 礼物"]
        XCTAssertTrue(gift.waitForExistence(timeout: 5)); XCTAssertTrue(gift.isHittable)
        XCTAssertLessThanOrEqual(gift.frame.maxY, app.keyboards.firstMatch.frame.minY)
        capture(app, "dark-large-batch-search-keyboard")
        gift.tap()
        XCTAssertTrue(app.buttons["confirm-batch-action-plan"].waitForExistence(timeout: 5))
        capture(app, "dark-large-batch-preview")
        app.buttons["取消"].tap()
        app.buttons["完成"].tap()
        app.terminate()

        // The shared picker's ordinary capture mode retains its original tree and search.
        let captureApp = launch()
        captureApp.buttons["quick-add"].tap()
        captureApp.buttons["all-categories"].tap()
        XCTAssertTrue(captureApp.navigationBars["全部分类"].waitForExistence(timeout: 5))
        let captureSearch = captureApp.searchFields["搜索分类或完整路径"]
        captureSearch.tap(); captureSearch.typeText("礼物")
        captureApp.buttons["all-category-人情公益 / 礼物"].tap()
        XCTAssertTrue(captureApp.staticTexts["人情公益"].waitForExistence(timeout: 5))
        captureApp.buttons["transaction-cancel"].tap()
    }

    private func walkthrough(dark: Bool, large: Bool) {
        let app = launch(dark: dark, large: large)
        let name = (dark ? "dark" : "light") + (large ? "-large" : "-normal")
        app.buttons["primary-tab-transactions"].tap()
        XCTAssertTrue(app.staticTexts["¥11,906.40"].waitForExistence(timeout: 10))
        capture(app, name + "-ledger")
        app.buttons["primary-tab-insights"].tap()
        XCTAssertTrue(app.staticTexts["¥11,906.40"].waitForExistence(timeout: 10))
        capture(app, name + "-insights")
        app.buttons["quick-add"].tap()
        XCTAssertTrue(app.buttons["calculator-2"].waitForExistence(timeout: 5))
        app.buttons["calculator-2"].tap(); app.buttons["calculator-8"].tap()
        capture(app, name + "-quick-add")
        if !large {
            app.buttons["category-午餐"].tap()
            app.textFields["transaction-note"].tap()
            app.textFields["transaction-note"].typeText("合成布局检查")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let save = app.buttons["transaction-save"]
            XCTAssertTrue(save.isEnabled); XCTAssertTrue(save.isHittable)
            XCTAssertLessThanOrEqual(save.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
            capture(app, name + "-note-keyboard")
        }
        app.buttons["transaction-cancel"].tap()
        app.buttons["primary-tab-settings"].tap()
        let date = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '2021-05-15'")).firstMatch
        XCTAssertTrue(date.waitForExistence(timeout: 10))
        for title in ["使用天数", "交易总笔数", "最早账单日", "有账天数"] {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.exists)
        }
        capture(app, name + "-settings")
        if large {
            app.swipeUp()
            capture(app, name + "-settings-scrolled")
        }
    }
}
