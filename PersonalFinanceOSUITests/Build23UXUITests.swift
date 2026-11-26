import XCTest

final class Build23UXUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launch(style: String = "light", fontSize: String = "system", comparison: Bool = false, largeAmount: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-build21SyntheticFixture", "YES", "-icloudSyncEnabled", "NO",
            "-smartSuggestions.enabled", "NO", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-appearance.mode", style, "-appearance.fontSize", fontSize]
        if comparison { app.launchArguments += ["-build23ComparisonFixture", "YES"] }
        if largeAmount { app.launchArguments += ["-build23LargeAmountFixture", "YES"] }
        app.launch()
        XCTAssertTrue(app.buttons["primary-tab-transactions"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testMonthRangeSelectionKeepsSwitcherAndCurrentTrendAnchor() {
        let app = launch()
        app.buttons["primary-tab-insights"].tap()
        let previous = app.buttons["上个月"]
        XCTAssertTrue(previous.waitForExistence(timeout: 8))
        previous.tap()
        let range = app.buttons["insights-range"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        range.tap()
        app.buttons["本月"].tap()
        XCTAssertTrue(previous.waitForExistence(timeout: 5), "Selecting this month after a previous month must keep the unified month controls")
    }
    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }

    @MainActor
    func testDefaultDensityStoredTimesSignedNetAndCollapsedDiagnostics() {
        let app = launch()
        app.buttons["primary-tab-transactions"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let top = app.navigationBars.firstMatch.frame.maxY, bottom = app.buttons["primary-tab-transactions"].frame.minY
        let complete = rows.allElementsBoundByIndex.filter { $0.frame.minY >= top && $0.frame.maxY <= bottom }
        XCTAssertGreaterThanOrEqual(complete.count, 3)
        XCTAssertTrue(rows.firstMatch.label.contains("12:00"), rows.firstMatch.label)
        XCTAssertTrue(app.staticTexts["-¥10.00"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["笔数与平均每笔"].exists)
        capture("build23-iphone16-light-density", app: app)
        app.buttons["primary-tab-settings"].tap()
        let disclosure = app.buttons["diagnostics-disclosure"]
        for _ in 0..<6 where !disclosure.isHittable { app.swipeUp() }
        XCTAssertTrue(disclosure.exists)
        XCTAssertFalse(app.buttons["export-redacted-diagnostics"].exists)
        capture("build23-collapsed-diagnostics", app: app)
        disclosure.tap()
        XCTAssertEqual(disclosure.value as? String, "已展开")
        capture("build23-expanded-diagnostics", app: app)
        let export = app.buttons["export-redacted-diagnostics"]
        for _ in 0..<4 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.exists)
    }

    @MainActor
    func testRangeEditorPrefillsCancelAndAllHistoryAnchor() {
        let app = launch()
        app.buttons["primary-tab-insights"].tap()
        let range = app.buttons["insights-range"]
        XCTAssertTrue(range.waitForExistence(timeout: 10))
        let original = range.label
        range.tap()
        XCTAssertTrue(app.datePickers["range-start"].waitForExistence(timeout: 5))
        capture("build23-custom-range-prefill", app: app)
        app.buttons["取消"].tap()
        XCTAssertEqual(range.label, original)
        range.tap(); app.buttons["全部历史"].tap()
        XCTAssertTrue(app.buttons["insights-range"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["insights-range"].label.contains("全部历史"))
        XCTAssertFalse(app.buttons["上个月"].exists)
        capture("build23-all-history-anchor", app: app)
    }

    @MainActor
    func testRecordedFactsOpenBothCompletePeriods() {
        let app = launch(comparison: true)
        app.buttons["primary-tab-insights"].tap()
        let fact = app.buttons["recorded-expense-fact-net"]
        XCTAssertTrue(fact.waitForExistence(timeout: 12))
        XCTAssertFalse(fact.label.contains("%"))
        capture("build23-recorded-facts", app: app)
        fact.tap()
        XCTAssertTrue(app.navigationBars["比较依据"].waitForExistence(timeout: 5))
        let links = app.buttons.matching(NSPredicate(format: "label CONTAINS '查看全部'"))
        XCTAssertEqual(links.count, 2)
        capture("build23-two-period-evidence", app: app)
        links.firstMatch.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'filtered-transaction-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(rows.firstMatch.label.contains("12:00"))
        capture("build23-comparison-drilldown", app: app)
    }

    @MainActor
    func testBothComparisonPeriodsConvertToVisibleOrdinaryDateAnalysis() {
        for period in 0..<2 {
            let app = launch(comparison: true)
            app.buttons["primary-tab-insights"].tap()
            let fact = app.buttons["recorded-expense-fact-net"]
            XCTAssertTrue(fact.waitForExistence(timeout: 12)); fact.tap()
            let links = app.buttons.matching(NSPredicate(format: "label CONTAINS '查看全部'"))
            XCTAssertTrue(links.firstMatch.waitForExistence(timeout: 5))
            links.element(boundBy: period).tap()
            XCTAssertTrue(app.staticTexts["analysis-evidence-cutoff"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.staticTexts["analysis-evidence-cutoff"].isHittable)
            capture("build23-review-period-\(period)-fixed-cutoff", app: app)
            app.buttons["analysis-filter"].tap()
            XCTAssertTrue(app.staticTexts["选择日期范围将转为普通分析，不再作为原比较依据。"].waitForExistence(timeout: 5))
            app.buttons["本月"].tap(); app.buttons["完成"].tap()
            XCTAssertTrue(app.staticTexts["analysis-ordinary-context"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.staticTexts["analysis-ordinary-context"].isHittable)
            XCTAssertFalse(app.staticTexts["analysis-evidence-cutoff"].exists)
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'filtered-transaction-'"))
            let ordinary = rows.matching(NSPredicate(format: "label CONTAINS %@", "本月普通分析对照"))
            XCTAssertTrue(ordinary.firstMatch.waitForExistence(timeout: 8))
            XCTAssertEqual(ordinary.count, 1)
            XCTAssertEqual(ordinary.firstMatch.value as? String, "¥1.23")
            XCTAssertEqual(rows.matching(NSPredicate(format: "label CONTAINS %@", "上月普通分析对照")).count, 0)
            capture("build23-review-period-\(period)-ordinary-range", app: app)
            app.terminate()
        }
    }

    @MainActor
    func testDarkLargeTextPreservesFullLargeSignedAmount() {
        let app = launch(style: "dark", fontSize: "extraLarge", largeAmount: true)
        app.buttons["primary-tab-transactions"].tap()
        let amount = app.staticTexts["¥1,234,567,890,123,406.00"].firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 10))
        XCTAssertTrue(amount.isHittable)
        XCTAssertLessThanOrEqual(amount.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(app.buttons["搜索"].frame.height, 44)
        capture("build23-dark-large-amount", app: app)
        app.buttons["primary-tab-insights"].tap()
        XCTAssertTrue(app.buttons["insights-range"].waitForExistence(timeout: 8))
        capture("build23-dark-large-insights", app: app)
    }

}
