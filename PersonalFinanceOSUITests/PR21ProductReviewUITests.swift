import XCTest

@MainActor
final class PR21ProductReviewUITests: XCTestCase {
    private func start(empty: Bool = false, dark: Bool = false, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-build21SyntheticFixture", "YES", "-productReviewFixture", "YES", "-icloudSyncEnabled", "NO", "-smartSuggestions.enabled", "NO", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-appearance.mode", dark ? "dark" : "light", "-appearance.fontSize", "system"]
        if empty { app.launchArguments += ["-productReviewEmpty", "YES"] }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("REVIEW_SNAPSHOT_\(name)\n\(app.debugDescription)\nEND_REVIEW_SNAPSHOT")
    }
    func testBatchCorrection() {
        let app = start()
        app.buttons["primary-tab-transactions"].tap()
        app.submitLedgerSearch("生日礼物")
        app.buttons["收起"].tap()
        app.buttons["列表"].firstMatch.tap()
        app.buttons["toggle-batch-selection"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "batch-select-"))
        XCTAssertEqual(rows.count, 2)
        rows.element(boundBy: 0).tap()
        rows.element(boundBy: 1).tap()
        capture(app, "38-two-gifts-selected")
        // Dismissing the selector itself must not apply a target.
        app.buttons["batch-category-action"].tap()
        XCTAssertTrue(app.navigationBars["选择目标分类"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["create-category-inline"].exists)
        XCTAssertFalse(app.buttons["manage-categories-inline"].exists)
        capture(app, "43-batch-category-searchable")
        app.buttons["关闭"].tap()
        assertUnchangedGifts(app)
        chooseGiftTarget(app)
        XCTAssertTrue(app.buttons["confirm-batch-action-plan"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        assertUnchangedGifts(app)
        chooseGiftTarget(app)
        capture(app, "45-batch-preview")
        XCTAssertTrue(app.staticTexts["目标、人情公益 / 礼物"].exists)
        XCTAssertTrue(app.staticTexts["选择范围、2 笔"].exists)
        XCTAssertTrue(app.staticTexts["实际变更、2 笔"].exists)
        XCTAssertTrue(app.staticTexts["净支出、¥336.00"].exists)
        app.buttons["confirm-batch-action-plan"].tap()
        XCTAssertTrue(app.buttons["confirm-batch-action-plan"].waitForNonExistence(timeout: 10))
        capture(app, "46-batch-applied")
        XCTAssertTrue(app.staticTexts["2 笔"].exists)
        XCTAssertTrue(app.staticTexts["¥336.00"].exists)
        let corrected = app.buttons.matching(NSPredicate(format: "(identifier BEGINSWITH %@ OR identifier BEGINSWITH %@) AND label CONTAINS %@", "transaction-row-", "batch-select-", "人情公益 / 礼物"))
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: corrected)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(corrected.count, 2)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "(identifier BEGINSWITH %@ OR identifier BEGINSWITH %@) AND label CONTAINS %@", "transaction-row-", "batch-select-", "待分类")).count, 0)
    }

    private func assertUnchangedGifts(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["confirm-batch-action-plan"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["¥336.00"].exists)
        let unchanged = app.buttons.matching(NSPredicate(format: "(identifier BEGINSWITH %@ OR identifier BEGINSWITH %@) AND label CONTAINS %@", "transaction-row-", "batch-select-", "待分类"))
        XCTAssertEqual(unchanged.count, 2)
    }

    private func chooseGiftTarget(_ app: XCUIApplication) {
        app.buttons["batch-category-action"].tap()
        let search = app.searchFields["搜索分类或完整路径"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("礼物")
        let gift = app.buttons["all-category-人情公益 / 礼物"]
        XCTAssertTrue(gift.waitForExistence(timeout: 5)); XCTAssertTrue(gift.isHittable)
        capture(app, "44-batch-gift-search-result")
        gift.tap()
        XCTAssertTrue(app.buttons["confirm-batch-action-plan"].waitForExistence(timeout: 5))
    }

    func testAfterAmountAndScope() {
        var app = start(dark: true, large: true)
        XCTAssertTrue(app.staticTexts["¥11,906.40"].exists)
        capture(app, "after-01-large-dark-overview")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["¥9,600.00"].exists)
        capture(app, "after-16-large-dark-categories")
        app.buttons["primary-tab-transactions"].tap()
        capture(app, "after-02-large-dark-ledger")
        app.buttons["primary-tab-insights"].tap()
        capture(app, "after-03-large-dark-insights")
        app.terminate()
        app = start()
        capture(app, "after-04-normal-light-overview")
        app.buttons["primary-tab-transactions"].tap()
        app.searchAllTransactions(for: "生日礼物")
        XCTAssertTrue(app.staticTexts["965 笔"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["¥162,120.00"].exists)
        XCTAssertTrue(app.staticTexts["全部历史"].exists)
        XCTAssertFalse(app.buttons["上个月"].exists)
        XCTAssertFalse(app.buttons["下个月"].exists)
        capture(app, "after-05-global-search")
        app.buttons["列表"].firstMatch.tap()
        app.buttons["日历"].tap()
        XCTAssertTrue(app.buttons["上个月"].exists)
        app.buttons["上个月"].tap()
        XCTAssertTrue(app.staticTexts["2026年10月"].exists)
        capture(app, "after-06-global-calendar-october")
        app.buttons["日历"].firstMatch.tap()
        app.buttons["列表"].tap()
        XCTAssertTrue(app.staticTexts["全部历史"].exists)
        XCTAssertFalse(app.buttons["上个月"].exists)
        XCTAssertTrue(app.staticTexts["965 笔"].exists)
        capture(app, "after-07-back-to-global-list")
        app.buttons["搜索"].firstMatch.tap()
        app.buttons["本月"].tap()
        app.buttons["收起"].tap()
        XCTAssertTrue(app.staticTexts["2026年10月"].exists)
        XCTAssertTrue(app.buttons["上个月"].exists)
        capture(app, "after-08-month-scope-retained")
        app.terminate()
        app = start(dark: true)
        capture(app, "after-09-normal-dark-overview")
    }

    func testAfterLargeAmountFixture() {
        let app = XCUIApplication()
        app.launchArguments = ["-build21SyntheticFixture", "YES", "-build23LargeAmountFixture", "YES", "-icloudSyncEnabled", "NO", "-smartSuggestions.enabled", "NO", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-appearance.mode", "light", "-appearance.fontSize", "system", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        assertFullyVisibleAmount(app, "¥1,234,567,890,123,406.00")
        capture(app, "after-10-large-amount-fixture")
        assertFullyVisibleAmount(app, "-¥1,234,567,890,122,906.00")
        capture(app, "after-10-large-negative-balance")
        app.buttons["primary-tab-transactions"].tap()
        assertFullyVisibleAmount(app, "¥1,234,567,890,123,406.00")
        capture(app, "after-11-large-amount-ledger")
        assertFullyVisibleAmount(app, "-¥1,234,567,890,122,906.00")
        capture(app, "after-11-large-ledger-negative-balance")
    }
    private func assertFullyVisibleAmount(_ app: XCUIApplication, _ value: String) {
        let amount = app.staticTexts[value].firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        let bottom = app.buttons["primary-tab-transactions"].frame.minY
        for _ in 0..<8 where amount.frame.maxY > bottom {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.53)))
        }
        XCTAssertGreaterThanOrEqual(amount.frame.minX, 16)
        XCTAssertLessThanOrEqual(amount.frame.maxX, app.frame.maxX - 16)
        XCTAssertGreaterThanOrEqual(amount.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThanOrEqual(amount.frame.maxY, bottom)
        XCTAssertGreaterThanOrEqual(amount.frame.height, 20)
    }

}
