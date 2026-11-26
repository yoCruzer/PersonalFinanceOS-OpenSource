import XCTest

final class Build21UXUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launch(style: String = "light", fontSize: String = "system") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-build21SyntheticFixture", "YES", "-icloudSyncEnabled", "NO",
            "-smartSuggestions.enabled", "NO", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-appearance.mode", style, "-appearance.fontSize", fontSize]
        app.launch()
        XCTAssertTrue(app.buttons["primary-tab-transactions"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    @MainActor
    func testSyntheticDefaultPagesAndGeometry() throws {
        let marker = UUID().uuidString
        let before = try DiagnosticSideEffectsSnapshot.capture(marker: marker, seedClipboard: true)
        XCTAssertTrue(before.markerMatches)
        let app = launch()
        app.buttons["primary-tab-transactions"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transaction-row-"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        capture("build21-transactions", app: app)
        let bottom = app.buttons["primary-tab-transactions"].frame.minY
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        XCTAssertLessThanOrEqual(rows.firstMatch.frame.minY, navigationBottom + (bottom - navigationBottom) / 2)
        let completeRows = rows.allElementsBoundByIndex.filter { $0.frame.minY >= navigationBottom && $0.frame.maxY <= bottom }
        XCTAssertGreaterThanOrEqual(completeRows.count, 3)
        app.buttons["primary-tab-insights"].tap()
        let dining = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "合成餐饮")).firstMatch
        let shopping = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "合成购物")).firstMatch
        XCTAssertTrue(dining.waitForExistence(timeout: 10))
        XCTAssertTrue(shopping.isHittable)
        XCTAssertFalse(shopping.label.contains("占"))
        capture("build21-insights", app: app)
        dining.tap()
        XCTAssertTrue(app.navigationBars["合成餐饮"].waitForExistence(timeout: 5))
        capture("build21-category-drilldown", app: app)
        XCTAssertFalse(app.staticTexts["不含"].exists)
        app.buttons["primary-tab-settings"].tap()
        app.swipeUp()
        capture("build21-sync-settings", app: app)
        let disclosure = app.buttons["diagnostics-disclosure"]
        for _ in 0..<5 where !disclosure.isHittable { app.swipeUp() }
        if disclosure.value as? String != "已展开" { disclosure.tap() }
        let export = app.buttons["export-redacted-diagnostics"]
        for _ in 0..<5 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.isHittable)
        capture("build21-diagnostics", app: app)
        export.tap()
        let saveToFiles = app.cells["保存到“文件”"]
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 5))
        let close = app.buttons["header.closeButton"]
        XCTAssertTrue(close.isHittable)
        capture("build21-diagnostic-share", app: app)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        let status = app.staticTexts["diagnostic-export-status"]
        for _ in 0..<4 where !status.isHittable { app.swipeUp() }
        expectation(for: NSPredicate(format: "label == %@", "已取消分享，诊断文件仍保留。"), evaluatedWith: status)
        waitForExpectations(timeout: 5)
        export.tap()
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 5))
        saveToFiles.tap()
        let filename = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filename.waitForExistence(timeout: 10))
        XCTAssertTrue((filename.value as? String)?.hasPrefix("PFOS-diagnostic-") == true)
        let save = app.buttons.matching(NSPredicate(format: "label == '保存' OR label == '存储' OR label == 'Save'")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        capture("build21-diagnostic-save-to-files", app: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        expectation(for: NSPredicate(format: "label == %@", "诊断已分享。"), evaluatedWith: status)
        waitForExpectations(timeout: 10)

        let after = try DiagnosticSideEffectsSnapshot.capture(marker: marker)
        XCTAssertTrue(after.markerMatches)
        XCTAssertEqual(after.changeCount, before.changeCount)
        XCTAssertEqual(after.files.subtracting(before.files).count, 2, "Each export must create its own file")
    }

    @MainActor
    func testSyntheticSearchKeepsScopeAndCalendarKeepsFilters() {
        let app = launch()
        app.buttons["primary-tab-transactions"].tap()
        app.buttons["搜索"].tap()
        let input = app.textFields["transaction-search-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("合成九月正餐")
        input.typeText("\n")
        XCTAssertTrue(app.staticTexts["没有符合条件的交易"].waitForExistence(timeout: 5))
        app.buttons["全部记录"].tap()
        let historical = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-' AND label CONTAINS %@", "合成九月正餐")).firstMatch
        XCTAssertTrue(historical.waitForExistence(timeout: 8))
        let previousResult = historical.label
        app.buttons["收起"].tap()
        XCTAssertFalse(input.exists)
        XCTAssertFalse(app.segmentedControls["transaction-search-scope"].exists)
        XCTAssertTrue(app.buttons["搜索：合成九月正餐 ×"].exists)
        XCTAssertTrue(app.staticTexts["全部历史"].exists)
        XCTAssertEqual(historical.label, previousResult)
        app.buttons["搜索"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "合成九月正餐")
        XCTAssertTrue(app.buttons["全部记录"].isSelected)
        app.buttons["clear-filters"].tap()
        XCTAssertEqual(input.value as? String, "合成九月正餐")
        app.buttons["clear-transaction-search"].tap()
        XCTAssertTrue(app.buttons["recent-search-合成九月正餐"].waitForExistence(timeout: 5))
        app.buttons["clear-recent-searches"].tap()
        XCTAssertFalse(app.buttons["recent-search-合成九月正餐"].exists)
        app.buttons["收起"].tap()
        app.buttons["筛选"].tap()
        app.buttons["category-filter"].tap()
        app.buttons["合成餐饮"].tap()
        app.buttons["account-filter"].tap()
        app.buttons["合成现金"].tap()
        app.buttons["收起筛选"].tap()
        app.buttons["列表"].tap()
        app.buttons["日历"].tap()
        XCTAssertTrue(app.staticTexts["范围仍为全部历史；日历合计仅含当前月份"].waitForExistence(timeout: 8))
        capture("build21-filtered-calendar", app: app)
        app.buttons["日历"].tap()
        app.buttons["列表"].tap()
        XCTAssertTrue(historical.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["全部历史"].exists)
        capture("build21-preserved-list", app: app)
    }

    @MainActor
    func testCalendarCellsKeepAmountsAccessibilityAndDateSelection() {
        let app = launch()
        app.buttons["primary-tab-transactions"].tap()
        app.buttons["列表"].tap()
        app.buttons["日历"].tap()
        let negative = app.buttons["calendar-day-2026-10-02"]
        let positive = app.buttons["calendar-day-2026-10-03"]
        let income = app.buttons["calendar-day-2026-10-05"]
        let empty = app.buttons["calendar-day-2026-10-01"]
        XCTAssertTrue(negative.waitForExistence(timeout: 10))
        XCTAssertTrue(negative.label.hasSuffix("，2 笔，支出 -¥20.00"), negative.label)
        XCTAssertEqual(negative.value as? String, "无支出热力")
        XCTAssertTrue(positive.label.hasSuffix("，2 笔，支出 ¥60.00"), positive.label)
        XCTAssertTrue(income.label.hasSuffix("，2 笔，收入 ¥500.00"), income.label)
        XCTAssertTrue(empty.label.hasSuffix("，0 笔，没有记录"), empty.label)
        capture("build22-calendar-cells", app: app)

        positive.tap()
        app.swipeUp()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'calendar-transaction-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allElementsBoundByIndex.contains { $0.label.contains("合成十月正餐") })
        XCTAssertTrue(rows.allElementsBoundByIndex.contains { $0.label.contains("合成餐饮退款") })
        app.swipeDown()
        empty.tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["当天没有交易"].waitForExistence(timeout: 8))
        XCTAssertEqual(rows.count, 0)
        XCTAssertTrue(app.buttons["calendar-quick-add"].exists)
        app.swipeDown()

        let modes: [(String, String, String)] = [
            ("支出", "2026-10-03", "，1 笔，原始支出 ¥80.00"),
            ("退款", "2026-10-03", "，1 笔，退款 ¥20.00"),
            ("收入", "2026-10-05", "，1 笔，收入 ¥500.00"),
            ("转账", "2026-10-05", "，1 笔，转账 1 笔")
        ]
        for (mode, key, suffix) in modes {
            app.buttons["筛选"].tap()
            app.buttons.matching(identifier: "type-filter").firstMatch.tap()
            app.buttons[mode].tap()
            app.buttons["收起筛选"].tap()
            let cell = app.buttons["calendar-day-\(key)"]
            let expected = NSPredicate(format: "label ENDSWITH %@", suffix)
            expectation(for: expected, evaluatedWith: cell)
            waitForExpectations(timeout: 8)
        }
        capture("build22-calendar-transfer", app: app)
        income.tap()
        app.swipeUp()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.firstMatch.label.contains("合成账户转账"))
    }

    @MainActor
    func testSyntheticFocusedDarkLargeText() {
        let app = launch(style: "dark", fontSize: "extraLarge")
        app.buttons["primary-tab-transactions"].tap()
        let amount = app.staticTexts["-¥10.00"].firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 10))
        XCTAssertTrue(amount.isHittable)
        XCTAssertLessThanOrEqual(amount.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(app.buttons["搜索"].frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["筛选"].frame.height, 44)
        XCTAssertEqual(app.buttons["筛选"].value as? String, "收起")
        capture("build21-dark-large-transactions", app: app)
        app.buttons["primary-tab-insights"].tap()
        XCTAssertTrue(app.buttons["insights-range"].waitForExistence(timeout: 10))
        capture("build21-dark-large-insights", app: app)
    }

    @MainActor
    func testSyntheticRefundEditAndCopyUseFixedRefundType() {
        let app = launch()
        app.buttons["primary-tab-transactions"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-' AND label CONTAINS %@", "合成餐饮退款")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0..<3 where !row.isHittable || row.frame.maxY > app.buttons["primary-tab-transactions"].frame.minY { app.swipeUp() }
        XCTAssertLessThanOrEqual(row.frame.maxY, app.buttons["primary-tab-transactions"].frame.minY)
        row.tap()
        XCTAssertTrue(app.buttons["transaction-edit"].waitForExistence(timeout: 8))
        app.buttons["transaction-edit"].tap()
        XCTAssertTrue(app.staticTexts["退款记录"].waitForExistence(timeout: 5))
        let note = app.textFields["transaction-note"]
        note.tap()
        note.typeText("修改")
        let changedNote = note.value as! String
        XCTAssertTrue(changedNote.contains("修改"))
        app.buttons["transaction-save"].tap()
        XCTAssertTrue(app.navigationBars["编辑交易"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["退款"].exists)
        app.buttons["transaction-duplicate"].tap()
        XCTAssertTrue(app.staticTexts["退款记录"].waitForExistence(timeout: 5))
        app.buttons["transaction-save"].tap()
        XCTAssertTrue(app.buttons["transaction-duplicate"].waitForExistence(timeout: 8))
        app.navigationBars["交易详情"].buttons.firstMatch.tap()
        app.searchAllTransactions(for: changedNote)
        let copies = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-' AND label CONTAINS %@", changedNote))
        XCTAssertTrue(copies.firstMatch.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: copies)
        waitForExpectations(timeout: 8)
        XCTAssertEqual(Set(copies.allElementsBoundByIndex.map(\.identifier)).count, 2)
        for row in copies.allElementsBoundByIndex {
            XCTAssertEqual(row.label.components(separatedBy: "，").first, "退款", row.label)
        }
        capture("build21-refund-edit-copy", app: app)
    }

    @MainActor
    func testSyntheticMonthRangeAndRemovedCategoryUseActualTitles() {
        let app = launch()
        app.buttons["primary-tab-insights"].tap()
        app.buttons["insights-range"].tap()
        app.buttons["全部历史"].tap()
        XCTAssertTrue(app.staticTexts["¥90.00"].waitForExistence(timeout: 10))
        let dining = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "合成餐饮")).firstMatch
        XCTAssertTrue(dining.waitForExistence(timeout: 5))
        dining.tap()
        XCTAssertTrue(app.navigationBars["合成餐饮"].waitForExistence(timeout: 5))
        app.buttons["合成餐饮 ×"].tap()
        XCTAssertTrue(app.navigationBars["支出（扣除退款）"].waitForExistence(timeout: 8))
        capture("build21-removed-category-context", app: app)
        app.buttons["primary-tab-transactions"].tap()
        app.buttons["筛选"].tap()
        app.buttons["category-filter"].tap()
        app.buttons["合成餐饮"].tap()
        app.buttons["account-filter"].tap()
        app.buttons["合成现金"].tap()
        app.buttons["收起筛选"].tap()
        app.buttons["上个月"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-' AND label CONTAINS %@", "合成九月正餐")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-'"))
        XCTAssertEqual(rows.count, 1)
        capture("build21-month-preserved-filters", app: app)
    }
}
