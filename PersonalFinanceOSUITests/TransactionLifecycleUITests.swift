import XCTest

final class TransactionLifecycleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func emptyReviewLedger(occurredAt: Date? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        let date = occurredAt ?? ISO8601DateFormatter().date(from: "2026-11-04T12:00:00Z")!
        app.launchArguments += ["-build21SyntheticFixture", "-productReviewFixture", "-productReviewEmpty",
                                "-classificationFormTestOccurredAt", String(date.timeIntervalSince1970)]
        return app
    }

    // The synthetic ledger opens in November. Place the saved row in December
    // regardless of the simulator clock, then exercise the actual scope switch.
    @MainActor
    private func nextMonthReviewLedger() throws -> XCUIApplication {
        let december = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-04T12:00:00Z"))
        return emptyReviewLedger(occurredAt: december)
    }

    @MainActor
    private func savedRowOutsideDisplayedMonth(note: String, in app: XCUIApplication) -> XCUIElement {
        app.submitLedgerSearch(note)
        let scope = app.segmentedControls["transaction-search-scope"]
        XCTAssertTrue(scope.buttons["本月"].isSelected)
        let rows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'transaction-row-' AND label CONTAINS %@", note
        ))
        XCTAssertTrue(app.staticTexts["没有符合条件的交易"].waitForExistence(timeout: 8))
        XCTAssertEqual(rows.count, 0)
        scope.buttons["全部记录"].tap()
        XCTAssertTrue(app.staticTexts["transactions-all-history-title"].waitForExistence(timeout: 5))
        app.buttons["收起"].tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(rows.count, 1)
        return rows.firstMatch
    }

    @MainActor
    func testAutomaticCategoryRequiresCurrentInputBeforeSave() {
        let app = XCUIApplication()
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 10
        components.minute = 30
        let occurredAt = try! XCTUnwrap(Calendar.current.date(from: components))
        app.launchArguments += ["-smartSuggestions.enabled", "NO",
                                "-classificationFormTestOccurredAt", String(occurredAt.timeIntervalSince1970)]
        app.launch()

        app.buttons["quick-add"].tap()
        app.buttons["calculator-1"].tap()
        let directNote = app.textFields["transaction-note"]
        XCTAssertTrue(directNote.waitForExistence(timeout: 5))
        directNote.tap()
        directNote.typeText("早餐退款")
        XCTAssertFalse(waitForValue("已选择", element: app.buttons["category-早餐"], timeout: 3))
        XCTAssertFalse(app.buttons["transaction-save"].isEnabled)
        app.buttons["transaction-cancel"].tap()

        app.buttons["quick-add"].tap()
        app.buttons["calculator-1"].tap()
        let stagedNote = app.textFields["transaction-note"]
        XCTAssertTrue(stagedNote.waitForExistence(timeout: 5))
        stagedNote.tap()
        stagedNote.typeText("早餐")
        let breakfast = app.buttons["category-早餐"]
        XCTAssertTrue(waitForValue("已选择", element: breakfast, timeout: 8))
        XCTAssertTrue(app.buttons["transaction-save"].isEnabled)
        stagedNote.typeText("退款")
        XCTAssertFalse(app.buttons["transaction-save"].isEnabled,
                       "A prior automatic choice must not be saved during the debounce window")
        app.buttons["transaction-save"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["记一笔"].exists)
        XCTAssertFalse(waitForValue("已选择", element: breakfast, timeout: 3),
                       "A choice required by the complete input must revoke the prior automatic category")
        XCTAssertEqual(stagedNote.value as? String, "早餐退款")
        breakfast.tap()
        XCTAssertTrue(app.buttons["transaction-save"].isEnabled)
        app.buttons["transaction-save"].tap()
        XCTAssertTrue(app.buttons["quick-add"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testPersonalHistoryConflictRevokesBaseAutomaticCategory() {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 10
        components.minute = 30
        let occurredAt = try! XCTUnwrap(Calendar.current.date(from: components))
        let app = emptyReviewLedger(occurredAt: occurredAt)
        app.launchArguments += ["-smartSuggestions.enabled", "NO",
                                "-classificationHistoryTestDelayMilliseconds", "15000"]
        app.launch()
        let baseNote = "早餐钚锆钯"

        for suffix in ["壹", "贰", "叁"] {
            app.buttons["quick-add"].tap()
            app.buttons["calculator-1"].tap()
            let note = app.textFields["transaction-note"]
            XCTAssertTrue(note.waitForExistence(timeout: 5))
            note.tap()
            note.typeText(baseNote + suffix)
            XCTAssertTrue(waitForValue("已选择", element: app.buttons["category-早餐"], timeout: 8))
            app.buttons["category-午餐"].tap()
            XCTAssertEqual(app.buttons["category-午餐"].value as? String, "已选择")
            app.buttons["transaction-save"].tap()
            XCTAssertTrue(app.buttons["quick-add"].waitForExistence(timeout: 8))
        }

        app.buttons["quick-add"].tap()
        app.buttons["calculator-1"].tap()
        let note = app.textFields["transaction-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText(baseNote)
        let breakfast = app.buttons["category-早餐"]
        XCTAssertTrue(waitForValue("已选择", element: breakfast, timeout: 8))
        let pending = app.staticTexts["基础规则可用，个人建议更新中"]
        XCTAssertTrue(pending.exists)
        XCTAssertTrue(pending.waitForNonExistence(timeout: 30))
        XCTAssertTrue(app.buttons["餐饮饮品 / 早餐"].waitForExistence(timeout: 8))
        XCTAssertNotEqual(breakfast.value as? String, "已选择")
        XCTAssertFalse(app.buttons["transaction-save"].isEnabled)
        app.buttons["transaction-cancel"].tap()
    }

    @MainActor
    func testBaseClassificationSurvivesDelayedHistoryAndFailedSave() {
        let app = XCUIApplication()
        app.launchArguments += ["-smartSuggestions.enabled", "NO",
                                "-classificationHistoryTestDelayMilliseconds", "30000",
                                "-classificationSaveTestFailure", "YES"]
        app.launch()
        let openedAt = Date()
        app.buttons["quick-add"].tap()
        let note = app.textFields["transaction-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("午餐")
        XCTAssertTrue(waitForValue("已选择", element: app.buttons["category-午餐"], timeout: 8))
        let firstSuggestionSeconds = Date().timeIntervalSince(openedAt)
        XCTAssertLessThan(firstSuggestionSeconds, 30, "Basic rule must respond before the held history read")
        let timing = XCTAttachment(string: "Cold form to first visible suggestion: \(firstSuggestionSeconds)s; history held 30s")
        timing.name = "PR14-Cold-First-Suggestion"
        timing.lifetime = .keepAlways
        add(timing)

        note.typeText("\n")
        app.buttons["calculator-1"].tap()
        app.buttons["transaction-save"].tap()
        XCTAssertTrue(app.alerts["无法完成操作"].waitForExistence(timeout: 5))
        app.alerts.buttons["好"].tap()
        XCTAssertEqual(note.value as? String, "午餐")

        note.tap()
        note.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "早餐")
        XCTAssertTrue(waitForValue("已选择", element: app.buttons["category-早餐"], timeout: 8))
        app.buttons["category-早餐"].tap()
        note.tap()
        note.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "午餐")
        XCTAssertTrue(app.staticTexts["基础规则可用，个人建议更新中"].waitForNonExistence(timeout: 40))
        XCTAssertEqual(app.buttons["category-早餐"].value as? String, "已选择")
        XCTAssertTrue(app.staticTexts["已手动选定"].exists)
        print("PR14 cold form to first visible suggestion: \(firstSuggestionSeconds)s; history held 30s")
        app.buttons["transaction-cancel"].tap()
    }

    @MainActor
    func testValidatedProfileReusedAcrossForms() throws {
        let app = try nextMonthReviewLedger()
        app.launchArguments += ["-smartSuggestions.enabled", "NO",
                                "-classificationHistoryTestDelayMilliseconds", "30000"]
        app.launch()
        app.buttons["primary-tab-transactions"].tap()
        let coldOpenedAt = Date()
        app.buttons["quick-add"].tap()
        let firstNote = app.textFields["transaction-note"]
        XCTAssertTrue(firstNote.waitForExistence(timeout: 5))
        firstNote.tap()
        firstNote.typeText("午餐")
        XCTAssertTrue(waitForValue("已选择", element: app.buttons["category-午餐"], timeout: 8))
        XCTAssertTrue(app.staticTexts["基础规则可用，个人建议更新中"].exists)
        XCTAssertTrue(app.staticTexts["基础规则可用，个人建议更新中"].waitForNonExistence(timeout: 40))
        let personalReadySeconds = Date().timeIntervalSince(coldOpenedAt)
        app.buttons["transaction-cancel"].tap()

        let warmOpenedAt = Date()
        app.buttons["quick-add"].tap()
        let secondNote = app.textFields["transaction-note"]
        XCTAssertTrue(secondNote.waitForExistence(timeout: 5))
        secondNote.tap()
        secondNote.typeText("早餐")
        XCTAssertTrue(waitForValue("已选择", element: app.buttons["category-早餐"], timeout: 8))
        XCTAssertFalse(app.staticTexts["基础规则可用，个人建议更新中"].exists)
        let warmSuggestionSeconds = Date().timeIntervalSince(warmOpenedAt)
        let timing = XCTAttachment(string: "Cold form to personal profile ready: \(personalReadySeconds)s; warm form to first visible suggestion: \(warmSuggestionSeconds)s")
        timing.name = "PR14-Profile-Ready-And-Warm-Suggestion"
        timing.lifetime = .keepAlways
        add(timing)
        secondNote.typeText("\n")
        app.buttons["calculator-1"].tap()
        app.buttons["transaction-save"].tap()
        XCTAssertTrue(secondNote.waitForNonExistence(timeout: 5))
        _ = savedRowOutsideDisplayedMonth(note: "早餐", in: app)
        XCTAssertTrue(app.staticTexts["已保存"].waitForNonExistence(timeout: 5))

        app.buttons["quick-add"].tap()
        let changedNote = app.textFields["transaction-note"]
        XCTAssertTrue(changedNote.waitForExistence(timeout: 5))
        changedNote.tap()
        changedNote.typeText("午餐")
        XCTAssertTrue(waitForValue("已选择", element: app.buttons["category-午餐"], timeout: 8))
        XCTAssertTrue(app.staticTexts["基础规则可用，个人建议更新中"].exists,
                      "A changed ledger revision must not reuse the previous personal profile")
        app.buttons["transaction-cancel"].tap()
    }

    @MainActor
    func testBaseClassificationSurvivesHistoryReadFailure() {
        let app = XCUIApplication()
        app.launchArguments += ["-smartSuggestions.enabled", "NO",
                                "-classificationHistoryTestFailure", "YES"]
        app.launch()
        app.buttons["quick-add"].tap()
        let note = app.textFields["transaction-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("午餐")
        XCTAssertTrue(waitForValue("已选择", element: app.buttons["category-午餐"], timeout: 8))
        XCTAssertTrue(app.staticTexts["个人建议暂不可用，基础规则仍可用"].waitForExistence(timeout: 5))
        app.buttons["transaction-cancel"].tap()
    }

    @MainActor
    func testFailedSaveRestartsCancelledProfileRefresh() {
        let app = XCUIApplication()
        app.launchArguments += ["-smartSuggestions.enabled", "NO",
                                "-classificationHistoryTestDelayMilliseconds", "60000",
                                "-classificationHistoryTestDelayOnce", "YES",
                                "-classificationSaveTestFailure", "YES"]
        app.launch()
        app.buttons["quick-add"].tap()
        let note = app.textFields["transaction-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("午餐")
        XCTAssertTrue(waitForValue("已选择", element: app.buttons["category-午餐"], timeout: 8))
        app.buttons["category-早餐"].tap()
        XCTAssertEqual(app.buttons["category-早餐"].value as? String, "已选择")
        note.typeText("\n")
        app.buttons["calculator-1"].tap()
        app.buttons["transaction-save"].tap()
        XCTAssertTrue(app.alerts["无法完成操作"].waitForExistence(timeout: 5))
        app.alerts.buttons["好"].tap()
        XCTAssertEqual(note.value as? String, "午餐")
        XCTAssertEqual(app.buttons["category-早餐"].value as? String, "已选择")
        app.buttons["refresh-smart-suggestion"].tap()
        XCTAssertTrue(app.buttons["餐饮饮品 / 午餐"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["category-早餐"].value as? String, "已选择")
        app.buttons["transaction-cancel"].tap()
    }

    @MainActor
    func testCancelledAndSavedFormsIgnoreLateHistory() {
        let app = XCUIApplication()
        app.launchArguments += ["-smartSuggestions.enabled", "NO",
                                "-classificationHistoryTestDelayMilliseconds", "30000"]
        app.launch()
        app.buttons["quick-add"].tap()
        let cancelledNote = app.textFields["transaction-note"]
        XCTAssertTrue(cancelledNote.waitForExistence(timeout: 5))
        cancelledNote.tap()
        cancelledNote.typeText("午餐")
        XCTAssertTrue(waitForValue("已选择", element: app.buttons["category-午餐"], timeout: 8))
        app.buttons["transaction-cancel"].tap()

        let savedNote = "早餐迟到结果\(UUID().uuidString.prefix(6))"
        app.buttons["quick-add"].tap()
        let note = app.textFields["transaction-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText(savedNote)
        XCTAssertTrue(waitForValue("已选择", element: app.buttons["category-早餐"], timeout: 8))
        note.typeText("\n")
        app.buttons["calculator-1"].tap()
        app.buttons["transaction-save"].tap()
        XCTAssertTrue(app.buttons["quick-add"].waitForExistence(timeout: 8))
        app.buttons["primary-tab-transactions"].tap()
        let row = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'transaction-row-' AND label CONTAINS %@", savedNote
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(row.label.contains("早餐"))
        sleep(35)
        XCTAssertTrue(row.exists)
        XCTAssertTrue(row.label.contains("早餐"), "A late refresh must not alter the saved transaction")
    }

    @MainActor
    func testRollbackUncertaintyDefaultsToPreserveAndRequiresExplicitChoice() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["primary-tab-settings"].tap()
        app.staticTexts["导入与导出"].tap()
        let history = app.staticTexts["导入历史"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        let fixture = app.staticTexts["合成回滚契约A.csv"].firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 5), "Run the explicitly armed synthetic fixture phase first")
        fixture.tap()
        let uncertain = app.switches["rollback-include-uncertain"]
        for _ in 0..<4 where !uncertain.isHittable { app.swipeUp() }
        XCTAssertTrue(uncertain.waitForExistence(timeout: 5))
        XCTAssertEqual(uncertain.value as? String, "0")
        let rollback = app.buttons["rollback-import-batch"]
        rollback.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "将软删除 0 笔")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["确认撤销"].tap()
        XCTAssertTrue(app.alerts["撤销完成"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "保留来源不确定 1 笔")).firstMatch.exists)
        app.alerts.buttons["好"].tap()
        XCTAssertTrue(uncertain.waitForExistence(timeout: 5))
        uncertain.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(uncertain.value as? String, "1")
        rollback.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已选择一并撤销，可能包含人工修改")).firstMatch.waitForExistence(timeout: 5))
        let confirmation = XCTAttachment(screenshot: app.screenshot())
        confirmation.name = "Rollback-A-explicit-uncertainty-confirmation"
        confirmation.lifetime = .keepAlways
        add(confirmation)
        app.buttons["确认撤销"].tap()
        XCTAssertTrue(app.alerts["撤销完成"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已软删除 1 笔")).firstMatch.exists)
    }

    @MainActor
    func testRemediationCatalogPreviewAndInsightsInLightAndDarkAppearance() {
        for style in ["Light", "Dark"] {
            let app = emptyReviewLedger()
            app.launchArguments += ["-deferAutomaticCatalogCheck", "-appearance.mode", style.lowercased(), "-appearance.fontSize", "system"]
            app.launch()
            app.buttons["primary-tab-settings"].tap()
            app.staticTexts["分类"].tap()
            let catalog = app.buttons["category-catalog-upgrade"]
            XCTAssertTrue(catalog.waitForExistence(timeout: 5))
            catalog.tap()
            XCTAssertTrue(app.navigationBars["分类补充状态"].waitForExistence(timeout: 5))
            let retry = app.buttons["检查并重试"]
            XCTAssertTrue(retry.waitForExistence(timeout: 5))
            let pending = app.staticTexts["正在检查缺少的分类"]
            XCTAssertTrue(pending.waitForExistence(timeout: 5))
            let completed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "分类已补充")).firstMatch
            XCTAssertFalse(completed.exists)
            retry.tap()
            XCTAssertTrue(completed.waitForExistence(timeout: 8))
            XCTAssertFalse(pending.exists)
            let preview = XCTAttachment(screenshot: app.screenshot())
            preview.name = "Remediation-Catalog-\(style)"
            preview.lifetime = .keepAlways
            add(preview)
            app.terminate()
            app.launch()
            app.buttons["primary-tab-insights"].tap()
            let insights = XCTAttachment(screenshot: app.screenshot())
            insights.name = "Remediation-Insights-\(style)"
            insights.lifetime = .keepAlways
            add(insights)
            XCTAssertTrue(app.buttons["primary-tab-insights"].isSelected)
            app.terminate()
        }
    }

    @MainActor
    func testSettingsCopiesSessionRedactedDiagnostics() throws {
        let marker = UUID().uuidString
        let before = try DiagnosticSideEffectsSnapshot.capture(marker: marker, seedClipboard: true)
        XCTAssertTrue(before.markerMatches)
        let app = emptyReviewLedger()
        app.launch()
        app.buttons["primary-tab-settings"].tap()
        let disclosure = app.buttons["diagnostics-disclosure"]
        for _ in 0..<7 where !disclosure.isHittable { app.swipeUp() }
        XCTAssertTrue(disclosure.isHittable)
        if disclosure.value as? String != "已展开" { disclosure.tap() }
        let copy = app.buttons["copy-redacted-diagnostics"]
        for _ in 0..<3 where !copy.isHittable { app.swipeUp() }
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        let status = app.staticTexts["diagnostic-export-status"]
        for _ in 0..<4 where !status.isHittable { app.swipeUp() }
        XCTAssertEqual(status.label, "已复制简短摘要。")
        XCTAssertFalse(app.buttons["header.closeButton"].exists)
        app.buttons["quick-add"].tap()
        let note = app.textFields["transaction-note"]
        note.tap()
        note.press(forDuration: 1)
        let paste = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["粘贴", "Paste"])).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "PersonalFinanceOS "), object: note)
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 5), .completed)
        let summary = note.value as? String ?? ""
        XCTAssertTrue(summary.hasPrefix("PersonalFinanceOS "))
        XCTAssertTrue(summary.contains(" · Git "))
        XCTAssertTrue(summary.contains(" · 本次会话 "))
        app.buttons["transaction-cancel"].tap()

        let after = try DiagnosticSideEffectsSnapshot.capture(marker: marker)
        XCTAssertFalse(after.markerMatches)
        XCTAssertGreaterThan(after.changeCount, before.changeCount)
        XCTAssertEqual(after.files, before.files, "Copy must not create or remove a diagnostic file")
    }

    @MainActor
    func testFilteredListSelectsCompleteResultAndConfirmsBatchCategoryCorrection() {
        let app = emptyReviewLedger()
        app.launchArguments += ["-smartSuggestions.enabled", "NO"]
        app.launch()
        let prefix = "完整批量-\(UUID().uuidString.prefix(6))"
        let outsideNote = "筛选外-\(UUID().uuidString.prefix(6))"
        createQuickAdd(note: outsideNote, amountKeys: ["3"], in: app)
        createQuickAdd(note: prefix + "甲", amountKeys: ["1", "1"], in: app)
        createQuickAdd(note: prefix + "乙", amountKeys: ["2", "2"], in: app)
        app.buttons["primary-tab-transactions"].tap()
        let outside = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'transaction-row-' AND label CONTAINS %@", outsideNote
        )).firstMatch
        XCTAssertTrue(outside.waitForExistence(timeout: 8))
        XCTAssertTrue(outside.label.contains("餐饮饮品 / 早餐"))
        let outsideID = outside.identifier
        app.buttons["搜索"].tap()
        let search = app.textFields["transaction-search-input"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(prefix)
        search.typeText("\n")
        app.buttons["列表"].tap()
        let select = app.buttons["toggle-batch-selection"]
        XCTAssertTrue(select.waitForExistence(timeout: 8))
        select.tap()
        app.buttons["select-all-current-results"].tap()
        let summary = app.staticTexts["batch-complete-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        XCTAssertTrue(summary.label.contains("已选 2 笔"))
        app.buttons["batch-category-action"].tap()
        let targetSearch = app.searchFields["搜索分类或完整路径"]
        targetSearch.tap()
        targetSearch.typeText("餐饮饮品 / 午餐")
        app.buttons["all-category-餐饮饮品 / 午餐"].tap()
        XCTAssertTrue(app.navigationBars["确认迁移分类"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.descendants(matching: .any)["batch-plan-selection-count"].value as? String, "2 笔")
        XCTAssertEqual(app.descendants(matching: .any)["batch-plan-impact-count"].value as? String, "2 笔")
        app.buttons["confirm-batch-action-plan"].tap()
        XCTAssertTrue(app.navigationBars["确认迁移分类"].waitForNonExistence(timeout: 8))
        XCTAssertEqual(search.value as? String, prefix)
        app.buttons["完成"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-' AND label CONTAINS %@", prefix))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.element(boundBy: 0).label.contains("午餐"))
        XCTAssertTrue(rows.element(boundBy: 1).label.contains("午餐"))
        XCTAssertFalse(outside.exists)
        app.buttons["clear-transaction-search"].tap()
        app.buttons["收起"].tap()
        XCTAssertTrue(outside.waitForExistence(timeout: 8))
        XCTAssertEqual(outside.identifier, outsideID)
        XCTAssertTrue(outside.label.contains("餐饮饮品 / 早餐"), outside.label)
    }

    @MainActor
    func testOverviewDrilldownKeepsFilterThroughEditingAndOffersCompleteExport() {
        let app = XCUIApplication()
        app.launchArguments += ["-smartSuggestions.enabled", "NO"]
        app.launch()
        let note = "下钻闭环-\(UUID().uuidString.prefix(6))"
        createQuickAdd(note: note, amountKeys: ["1", "3"], in: app)
        app.buttons["primary-tab-overview"].tap()
        let entry = app.buttons["overview-net-expense-details"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()
        XCTAssertTrue(app.navigationBars["支出（扣除退款）"].waitForExistence(timeout: 8))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(note)
        search.typeText("\n")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'filtered-transaction-' AND label CONTAINS %@", note)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 5))
        app.buttons["transaction-edit"].tap()
        let noteField = app.textFields["transaction-note"]
        XCTAssertTrue(noteField.waitForExistence(timeout: 5))
        noteField.tap()
        noteField.typeText("修订")
        noteField.typeText("\n")
        app.buttons["transaction-save"].tap()
        XCTAssertTrue(app.navigationBars["编辑交易"].waitForNonExistence(timeout: 5))
        app.navigationBars["交易详情"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["支出（扣除退款）"].waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, note)
        let changed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'filtered-transaction-' AND label CONTAINS %@", note + "修订")).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 8))
        app.buttons["analysis-filter"].tap()
        XCTAssertTrue(app.navigationBars["明细筛选"].waitForExistence(timeout: 5))
        app.buttons["全部历史"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["全部历史"].waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, note)
        app.buttons["analysis-actions"].tap()
        app.buttons["批量操作完整筛选结果"].tap()
        XCTAssertTrue(app.navigationBars["完整结果批量操作"].waitForExistence(timeout: 5))
        let batchSummary = app.staticTexts["batch-complete-summary"]
        XCTAssertTrue(batchSummary.waitForExistence(timeout: 8))
        XCTAssertTrue(batchSummary.label.contains("已选 1 笔"))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["完整结果批量操作"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, note)
        app.buttons["analysis-actions"].tap()
        app.buttons["导出完整筛选结果"].tap()
        let share = app.buttons["analysis-share-export"]
        for _ in 0..<3 where !share.exists { app.swipeUp() }
        XCTAssertTrue(share.waitForExistence(timeout: 8))
    }

    @MainActor
    func testSuggestionUndoAndExplicitRefreshKeepManualLock() {
        let app = XCUIApplication()
        app.launchArguments += ["-smartSuggestions.enabled", "NO"]
        app.launch()
        app.buttons["quick-add"].tap()
        let note = app.textFields["transaction-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("午餐吃火锅")
        let lunch = app.buttons["category-午餐"]
        XCTAssertTrue(waitForValue("已选择", element: lunch, timeout: 8))
        let undo = app.buttons["undo-smart-suggestion"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(app.staticTexts["已手动选定"].exists)
        let breakfast = app.buttons["category-早餐"]
        XCTAssertTrue(breakfast.isHittable)
        breakfast.tap()
        app.buttons["refresh-smart-suggestion"].tap()
        let candidate = app.buttons["餐饮饮品 / 午餐"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 8))
        XCTAssertEqual(breakfast.value as? String, "已选择")
        candidate.tap()
        XCTAssertEqual(lunch.value as? String, "已选择")
        XCTAssertTrue(app.staticTexts["已手动选定"].exists)
        note.tap()
        note.typeText("晚餐")
        XCTAssertFalse(undo.waitForExistence(timeout: 1))
        XCTAssertEqual(lunch.value as? String, "已选择")
        app.buttons["transaction-cancel"].tap()
    }

    @MainActor
    func testICloudDefaultsOffAndCancellingConsentDoesNotEnableIt() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["primary-tab-settings"].tap()
        let toggle = app.switches["icloud-sync-toggle"]
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap()
        let hasConsent = app.buttons["开启同步"].waitForExistence(timeout: 5)
        if !hasConsent {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(hasConsent)
        app.buttons["取消"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.terminate()
        app.launch()
        app.buttons["primary-tab-settings"].tap()
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "0")
    }

    @MainActor
    func testQuickAddRefreshesVisibleTransactionsAndInsightsSnapshots() {
        let app = emptyReviewLedger()
        app.launch()

        func hasAmount(_ amount: String, in summary: String) -> Bool {
            app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", summary, amount))
                .firstMatch.waitForExistence(timeout: 8)
        }
        app.buttons["primary-tab-transactions"].tap()
        XCTAssertTrue(hasAmount("¥0.00", in: "transactions-month-summary"))
        createQuickAdd(note: "流水即时刷新", amountKeys: ["7"], in: app)
        XCTAssertTrue(transactionRow(note: "流水即时刷新", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(hasAmount("¥7.00", in: "transactions-month-summary"))
        app.buttons["primary-tab-insights"].tap()
        XCTAssertTrue(hasAmount("¥7.00", in: "insights-summary"))
        createQuickAdd(note: "统计即时刷新", amountKeys: ["9"], in: app)
        XCTAssertTrue(hasAmount("¥16.00", in: "insights-summary"))
        XCTAssertTrue(app.buttons["primary-tab-insights"].isSelected)
    }

    @MainActor
    func testCreateEditPersistAndDeleteTransaction() {
        let app = XCUIApplication()
        let note = "UI-\(UUID().uuidString.prefix(8))"
        let editedNote = note + "-已编辑"
        app.launch()

        app.buttons["quick-add"].tap()

        XCTAssertTrue(app.staticTexts["transaction-amount"].waitForExistence(timeout: 5))
        for key in ["1", "+", "2"] {
            app.buttons["calculator-\(key)"].tap()
        }
        app.buttons["calculator-equals"].tap()

        let otherCategory = app.buttons["category-早餐"]
        XCTAssertTrue(otherCategory.waitForExistence(timeout: 5))
        otherCategory.tap()
        XCTAssertEqual(otherCategory.value as? String, "已选择")

        let noteField = app.textFields["transaction-note"]
        XCTAssertTrue(noteField.waitForExistence(timeout: 5))
        noteField.tap()
        noteField.typeText(note)
        noteField.typeText("\n")

        let saveButton = app.buttons["transaction-save"]
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()
        XCTAssertTrue(app.navigationBars["记一笔"].waitForNonExistence(timeout: 5))

        app.buttons["primary-tab-transactions"].tap()
        let createdRow = transactionRow(note: note, in: app)
        XCTAssertTrue(
            createdRow.waitForExistence(timeout: 10),
            "Expected saved transaction row for \(note): \(app.debugDescription)"
        )
        createdRow.tap()
        XCTAssertTrue(app.staticTexts["¥3.00"].waitForExistence(timeout: 5))

        app.buttons["transaction-edit"].tap()
        let editNoteField = app.textFields["transaction-note"]
        XCTAssertTrue(editNoteField.waitForExistence(timeout: 5))
        // A short unique note fits without horizontal scrolling; tap its trailing area.
        editNoteField.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        editNoteField.typeText("-已编辑")
        XCTAssertEqual(editNoteField.value as? String, editedNote)
        app.buttons["transaction-save"].tap()

        XCTAssertTrue(app.staticTexts[editedNote].waitForExistence(timeout: 5))

        app.buttons["primary-tab-insights"].tap()
        XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["支出构成"].waitForExistence(timeout: 5))
        app.buttons["primary-tab-overview"].tap()

        app.terminate()
        app.launch()

        app.buttons["primary-tab-transactions"].tap()
        let persistedRow = transactionRow(note: editedNote, in: app)
        XCTAssertTrue(
            persistedRow.waitForExistence(timeout: 5),
            "The edited transaction should remain after relaunch."
        )
        persistedRow.tap()
        XCTAssertTrue(app.staticTexts["¥3.00"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[editedNote].exists)
        app.buttons["transaction-delete"].tap()
        XCTAssertTrue(app.otherElements["transaction-delete-confirmation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["transaction-delete-confirm"].isHittable)
        XCTAssertTrue(app.buttons["transaction-delete-cancel"].isHittable)
        app.buttons.matching(identifier: "transaction-delete-confirm").firstMatch.tap()

        XCTAssertFalse(transactionRow(note: editedNote, in: app).waitForExistence(timeout: 2))

        app.terminate()
        app.launch()

        app.buttons["primary-tab-transactions"].tap()
        XCTAssertFalse(
            transactionRow(note: editedNote, in: app).waitForExistence(timeout: 2),
            "A deleted transaction must not return after relaunch."
        )
    }

    @MainActor
    func testQuickAddUsesThreeRowsOnIPhone16() throws {
        try assertQuickAddCategoryButtonCount(deviceName: "iPhone 16", expected: 12)
    }

    @MainActor
    func testQuickAddUsesFourRowsOnIPhone17ProMax() throws {
        try assertQuickAddCategoryButtonCount(deviceName: "iPhone 17 Pro Max", expected: 16)
    }

    @MainActor
    private func assertQuickAddCategoryButtonCount(
        deviceName: String,
        expected: Int
    ) throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == deviceName,
            "Device-specific Quick Add fixture requires \(deviceName)."
        )
        let app = XCUIApplication()
        app.launch()

        app.buttons["quick-add"].tap()
        let grid = app.otherElements["quick-category-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertEqual(hittableButtonCount(in: grid), expected)
        let keypad = app.otherElements["amount-keypad"]
        XCTAssertTrue(keypad.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(grid.frame.maxY, keypad.frame.minY)
        XCTAssertGreaterThanOrEqual(app.buttons["calculator-7"].frame.height, 44)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Build20-\(deviceName)-QuickAdd"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testAccessibilityQuickAddCategoriesRemainScrollable() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()

        app.buttons["quick-add"].tap()
        let grid = app.otherElements["quick-category-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        let allCategories = app.buttons["all-categories"]
        let form = app.scrollViews["transaction-form-scroll"]
        for _ in 0..<4 where !allCategories.isHittable {
            form.swipeUp()
        }
        XCTAssertTrue(allCategories.waitForExistence(timeout: 5))
        XCTAssertTrue(allCategories.isHittable)
    }

    @MainActor
    func testQuickAddKeepsThreeRowsAfterNoteEntry() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["quick-add"].tap()
        let grid = app.otherElements["quick-category-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(hittableButtonCount(in: grid), 12)

        for identifier in [
            "transaction-date",
            "transaction-account",
            "transaction-merchant-entry",
            "transaction-tags",
            "all-categories"
        ] {
            XCTAssertTrue(app.buttons[identifier].isHittable, "Expected \(identifier) without scrolling")
        }

        app.textFields["transaction-note"].tap()
        XCTAssertTrue(app.buttons["restore-amount-input"].waitForExistence(timeout: 5))
        XCTAssertEqual(hittableButtonCount(in: grid), 12)
        app.buttons["restore-amount-input"].tap()

        XCTAssertGreaterThanOrEqual(hittableButtonCount(in: grid), 12)
        XCTAssertTrue(app.otherElements["amount-keypad"].exists)
    }

    @MainActor
    func testCalendarQuickAddNoteFocusKeepsSystemKeyboard() {
        let app = XCUIApplication()
        let noteValue = "日历备注-\(UUID().uuidString.prefix(6))"
        app.launch()

        app.buttons["primary-tab-transactions"].tap()
        app.buttons["列表"].tap()
        app.buttons["日历"].tap()
        let quickAdd = app.buttons["calendar-quick-add"]
        XCTAssertTrue(quickAdd.waitForExistence(timeout: 5))
        let tabBarTop = app.buttons["primary-tab-transactions"].frame.minY
        if quickAdd.frame.maxY > tabBarTop {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertLessThanOrEqual(quickAdd.frame.maxY, tabBarTop)
        XCTAssertTrue(quickAdd.isHittable)
        quickAdd.tap()

        let note = app.textFields["transaction-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calculator-1"].isHittable)
        note.typeText(noteValue)
        XCTAssertEqual(note.value as? String, noteValue)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
    }

    @MainActor
    func testTagPickerCreatesAndRetainsSelectionAfterDuplicateNameError() throws {
        let app = try nextMonthReviewLedger()
        let name = "新标签-\(UUID().uuidString.prefix(6))"
        let note = "标签持久化-\(UUID().uuidString.prefix(6))"
        app.launch()
        app.buttons["primary-tab-transactions"].tap()

        app.buttons["quick-add"].tap()
        app.buttons["calculator-1"].tap()
        app.buttons["category-早餐"].tap()
        let noteField = app.textFields["transaction-note"]
        XCTAssertTrue(noteField.waitForExistence(timeout: 5))
        noteField.tap()
        noteField.typeText(note + "\n")
        XCTAssertEqual(noteField.value as? String, note)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["transaction-tags"].tap()
        XCTAssertTrue(app.navigationBars["选择标签"].waitForExistence(timeout: 5))
        let createTag = app.buttons["create-tag"]
        for _ in 0..<4 where !createTag.isHittable { app.swipeUp() }
        XCTAssertTrue(createTag.isHittable)
        createTag.tap()

        let nameField = app.textFields["new-tag-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        nameField.typeText(name)
        app.buttons["create-new-tag"].tap()

        let created = app.buttons["tag-\(name)"]
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        XCTAssertEqual(created.value as? String, "已选择")
        XCTAssertTrue(app.navigationBars["选择标签"].exists)

        for _ in 0..<4 where !createTag.isHittable { app.swipeUp() }
        XCTAssertTrue(createTag.isHittable)
        createTag.tap()
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        nameField.typeText(name)
        app.buttons["create-new-tag"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["new-tag-error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["新建标签"].exists)
        app.navigationBars["新建标签"].buttons["取消"].tap()
        for _ in 0..<4 where !created.isHittable { app.swipeDown() }

        XCTAssertEqual(created.value as? String, "已选择")
        app.buttons["tag-picker-done"].tap()

        app.buttons["transaction-save"].tap()
        XCTAssertTrue(noteField.waitForNonExistence(timeout: 5))
        let row = savedRowOutsideDisplayedMonth(note: note, in: app)
        row.tap()
        let edit = app.buttons["transaction-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        app.buttons["transaction-tags"].tap()
        XCTAssertTrue(app.navigationBars["选择标签"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["tag-\(name)"].value as? String, "已选择")
        app.buttons["tag-picker-done"].tap()
    }

    @MainActor
    private func hittableButtonCount(in element: XCUIElement) -> Int {
        element.buttons.allElementsBoundByIndex.filter { $0.isHittable }.count
    }

    @MainActor
    func testRound1CalendarStatisticsAndDataManagementEntrances() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["primary-tab-transactions"].tap()
        app.buttons["列表"].firstMatch.tap()
        let calendarSegment = app.buttons["日历"]
        XCTAssertTrue(calendarSegment.waitForExistence(timeout: 5))
        calendarSegment.tap()
        XCTAssertTrue(app.buttons["回到今天"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["calendar-quick-add"].waitForExistence(timeout: 5))

        app.buttons["primary-tab-insights"].tap()
        XCTAssertTrue(app.buttons["insights-range"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["支出构成"].waitForExistence(timeout: 5))

        app.buttons["primary-tab-settings"].tap()
        let tags = app.staticTexts["标签"]
        XCTAssertTrue(tags.waitForExistence(timeout: 5))
        tags.tap()
        XCTAssertTrue(app.navigationBars["标签"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        let dataManagement = app.staticTexts["导入与导出"]
        XCTAssertTrue(dataManagement.waitForExistence(timeout: 5))
        dataManagement.tap()
        XCTAssertTrue(app.staticTexts["导入账单"].waitForExistence(timeout: 5))
        app.staticTexts["导出账单"].tap()
        XCTAssertTrue(app.buttons["prepare-export"].waitForExistence(timeout: 5))
        app.buttons["prepare-export"].tap()
        XCTAssertTrue(app.buttons["share-export"].waitForExistence(timeout: 5))
        app.buttons["本月"].tap()
        XCTAssertTrue(app.buttons["share-export"].waitForNonExistence(timeout: 5))
        app.buttons["prepare-export"].tap()
        XCTAssertTrue(app.buttons["share-export"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testForeignCurrencyAndMidnightTimeArePreservedInEditor() {
        let app = XCUIApplication()
        app.launchArguments += ["-build21SyntheticFixture", "-foreignMidnightTransaction",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.buttons["primary-tab-settings"].tap()
        app.staticTexts["分类"].tap()
        let category = app.buttons["category-transactions-合成餐饮"]
        for _ in 0..<8 where !category.isHittable { app.swipeUp() }
        XCTAssertTrue(category.isHittable)
        category.tap()
        let row = transactionRow(note: "跨时区美元记录", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        app.buttons["transaction-edit"].tap()
        let amount = app.descendants(matching: .any)["transaction-amount"].firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertTrue(amount.label.contains("USD"), amount.label)
        let date = app.buttons["transaction-date"]
        date.tap()
        let time = app.descendants(matching: .any)["transaction-time-picker"].firstMatch
        XCTAssertTrue(time.waitForExistence(timeout: 5))
        let picker = time.debugDescription
        XCTAssertTrue(picker.contains("00:15") || picker.contains("12:15"), picker)
        app.buttons["完成"].tap()
        XCTAssertTrue(date.label.contains("10月6日"), date.label)
        XCTAssertTrue([" 0:15", " 00:15", " 12:15"].contains(where: date.label.hasSuffix), date.label)
    }

    @MainActor
    func testChineseTransactionDatePickerUsesLocalizedCalendarLabels() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        app.buttons["quick-add"].tap()
        let transactionDate = app.buttons["transaction-date"]
        XCTAssertTrue(transactionDate.waitForExistence(timeout: 5))
        transactionDate.tap()
        let monthLabel = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "月")
        ).firstMatch
        XCTAssertTrue(monthLabel.waitForExistence(timeout: 5))

        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains { $0.contains("月") })
        let englishCalendarWords = [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December",
            "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"
        ]
        let englishLabels = labels.filter { label in
            englishCalendarWords.contains { label.localizedCaseInsensitiveContains($0) }
        }
        XCTAssertTrue(englishLabels.isEmpty, "Unexpected English calendar labels: \(englishLabels)")
    }

    @MainActor
    func testDuplicateTransactionRequiresExplicitSaveAndCancelDoesNotCreate() {
        let app = emptyReviewLedger()
        let note = "复制-\(UUID().uuidString)"
        let duplicateNote = note + "-copy"
        app.launch()
        app.buttons["primary-tab-transactions"].tap()

        // A copy is dated today and may fall outside the source transaction's month.
        app.searchAllTransactions(for: note)
        app.buttons["quick-add"].tap()
        for key in ["4", "2"] {
            app.buttons["calculator-\(key)"].tap()
        }
        app.buttons["category-早餐"].tap()
        let noteField = app.textFields["transaction-note"]
        noteField.tap()
        noteField.typeText(note + "\n")
        XCTAssertEqual(noteField.value as? String, note)
        app.buttons["transaction-save"].tap()

        let row = transactionRow(note: note, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        app.buttons["transaction-duplicate"].tap()
        XCTAssertTrue(app.navigationBars["记一笔"].waitForExistence(timeout: 5))
        let duplicateAmount = app.descendants(matching: .any)
            .matching(identifier: "transaction-amount")
            .firstMatch
        XCTAssertEqual(duplicateAmount.value as? String, "42.00")
        app.buttons["calculator-6"].tap()
        XCTAssertEqual(duplicateAmount.value as? String, "6")
        let duplicateNoteField = app.textFields["transaction-note"]
        func editCopiedNote() {
            XCTAssertEqual(duplicateNoteField.value as? String, note)
            duplicateNoteField.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            duplicateNoteField.press(forDuration: 1)
            let selectAll = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label IN %@", ["全选", "Select All"])).firstMatch
            XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
            selectAll.tap()
            duplicateNoteField.typeText(duplicateNote + "\n")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertEqual(duplicateNoteField.value as? String, duplicateNote)
        }
        editCopiedNote()
        app.buttons["transaction-cancel"].tap()
        app.navigationBars["交易详情"].buttons.firstMatch.tap()
        let matchingRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "transaction-row-", note)
        )
        XCTAssertTrue(matchingRows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(matchingRows.count, 1)
        XCTAssertFalse(transactionRow(note: duplicateNote, in: app).exists)
        let originalID = matchingRows.firstMatch.identifier

        matchingRows.firstMatch.tap()
        app.buttons["transaction-duplicate"].tap()
        editCopiedNote()
        app.buttons["transaction-save"].tap()
        app.navigationBars["交易详情"].buttons.firstMatch.tap()
        XCTAssertTrue(transactionRow(note: duplicateNote, in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(matchingRows.count, 2)
        let identifiers = Set(matchingRows.allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(identifiers.count, 2)
        XCTAssertTrue(identifiers.contains(originalID))
    }

    @MainActor
    func testEditingPrefilledAmountReplacesOnDigitAndDirectlyEditsOnBackspace() {
        let app = XCUIApplication()
        let note = "编辑金额-\(UUID().uuidString)"
        app.launch()

        createQuickAdd(note: note, amountKeys: ["4", "2"], in: app)
        let row = transactionRow(note: note, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        app.buttons["transaction-edit"].tap()
        XCTAssertTrue(app.navigationBars["编辑交易"].waitForExistence(timeout: 5))
        let editAmount = app.descendants(matching: .any)
            .matching(identifier: "transaction-amount")
            .firstMatch
        XCTAssertEqual(editAmount.value as? String, "42.00")

        app.buttons["transaction-tags"].tap()
        XCTAssertTrue(app.navigationBars["选择标签"].waitForExistence(timeout: 5))
        app.buttons["tag-picker-done"].tap()
        app.buttons["calculator-6"].tap()
        XCTAssertEqual(editAmount.value as? String, "6")

        app.buttons["transaction-tags"].tap()
        XCTAssertTrue(app.navigationBars["选择标签"].waitForExistence(timeout: 5))
        app.buttons["tag-picker-done"].tap()
        app.buttons["calculator-8"].tap()
        XCTAssertEqual(editAmount.value as? String, "68")
        app.buttons["transaction-cancel"].tap()

        app.buttons["transaction-edit"].tap()
        XCTAssertTrue(app.navigationBars["编辑交易"].waitForExistence(timeout: 5))
        XCTAssertEqual(editAmount.value as? String, "42.00")
        app.buttons["calculator-⌫"].tap()
        XCTAssertEqual(editAmount.value as? String, "42.0")
        app.buttons["calculator-6"].tap()
        XCTAssertEqual(editAmount.value as? String, "42.06")
    }

    @MainActor
    func testCategoryManagementDrillsIntoAllCategoryTransactions() {
        let app = XCUIApplication()
        app.launchArguments += ["-build21SyntheticFixture"]
        app.launch()

        app.buttons["primary-tab-settings"].tap()
        app.staticTexts["分类"].tap()
        XCTAssertTrue(app.navigationBars["分类"].waitForExistence(timeout: 5))

        let drillDown = app.buttons["category-transactions-合成餐饮"]
        for _ in 0..<8 where !drillDown.isHittable { app.swipeUp() }
        XCTAssertTrue(drillDown.waitForExistence(timeout: 5))
        drillDown.tap()
        XCTAssertTrue(app.navigationBars["合成餐饮 · 全部交易"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["category-transactions-list"].exists)

        let categoryRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "category-transaction-row-"))
        let firstTransaction = categoryRows.matching(NSPredicate(format: "label CONTAINS %@", "合成九月正餐")).firstMatch
        XCTAssertTrue(categoryRows.matching(NSPredicate(format: "label CONTAINS %@", "合成父级直记")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(firstTransaction.waitForExistence(timeout: 5))
        firstTransaction.tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testBuild15TrendHeatmapAndIncomeExpenseVisualsAreReachable() {
        let app = XCUIApplication()
        app.launchArguments += ["-build21SyntheticFixture", "-productReviewFixture"]
        app.launch()

        let overviewTrend = app.descendants(matching: .any)["overview-expense-trend"]
        for _ in 0..<4 where !overviewTrend.exists { app.swipeUp() }
        XCTAssertTrue(overviewTrend.waitForExistence(timeout: 5))
        XCTAssertTrue((overviewTrend.value as? String)?.contains("平均净支出") == true)

        app.buttons["primary-tab-transactions"].tap()
        app.buttons["列表"].tap()
        app.buttons["日历"].tap()
        let heatedDay = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND value BEGINSWITH %@",
            "calendar-day-",
            "支出热力"
        )).firstMatch
        XCTAssertTrue(heatedDay.waitForExistence(timeout: 5))

        app.buttons["primary-tab-insights"].tap()
        let monthlyTrend = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "最近六个月收入与净支出趋势")).firstMatch
        for _ in 0..<4 where !monthlyTrend.exists { app.swipeUp() }
        XCTAssertTrue(monthlyTrend.waitForExistence(timeout: 5))
    }

    @MainActor
    func testAccountDeletionPopoverProvidesImmediatelyHittableConfirmAndCancel() {
        let app = XCUIApplication()
        let name = "待删账户-\(UUID().uuidString.prefix(6))"
        app.launch()

        app.buttons["primary-tab-settings"].tap()
        app.staticTexts["账户"].tap()
        app.buttons["新增账户"].tap()
        let nameField = app.textFields["账户名称"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        nameField.typeText(name)
        app.navigationBars["新增账户"].buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))

        app.buttons["account-actions-\(name)"].tap()
        app.buttons["永久删除"].tap()
        let deletePlan = app.buttons["confirm-account-deletion-plan"]
        XCTAssertTrue(deletePlan.waitForExistence(timeout: 5))
        deletePlan.tap()
        let confirm = app.buttons["confirm-permanent-deletion"]
        let cancel = app.buttons["cancel-permanent-deletion"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(deletePlan.isHittable)

        deletePlan.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
        XCTAssertFalse(app.staticTexts[name].waitForExistence(timeout: 2))
    }

    @MainActor
    func testCategoryDeletionPopoverProvidesImmediatelyHittableConfirmAndCancel() {
        let app = XCUIApplication()
        let name = "待删分类-\(UUID().uuidString.prefix(6))"
        app.launch()

        app.buttons["primary-tab-settings"].tap()
        app.staticTexts["分类"].tap()
        app.buttons["category-add-menu"].tap()
        app.buttons["新增大类"].tap()
        let nameField = app.textFields["new-category-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        nameField.typeText(name)
        let saveCategory = app.buttons["save-inline-category"]
        XCTAssertTrue(waitForEnabled(saveCategory, timeout: 5))
        XCTAssertTrue(saveCategory.isHittable)
        saveCategory.tap()
        XCTAssertTrue(app.navigationBars["新增分类"].waitForNonExistence(timeout: 5))
        app.navigationBars["分类"].buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["分类"].waitForExistence(timeout: 5))
        app.staticTexts["分类"].tap()
        XCTAssertTrue(app.navigationBars["分类"].waitForExistence(timeout: 5))
        let categoryActions = app.buttons
            .matching(identifier: "category-actions-\(name)")
            .matching(NSPredicate(format: "label == %@", "\(name)操作"))
            .firstMatch
        for _ in 0..<8 where !waitForHittable(categoryActions, timeout: 0.5) {
            app.swipeUp()
        }
        XCTAssertTrue(categoryActions.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(categoryActions, timeout: 2))
        categoryActions.tap()
        app.buttons["永久删除"].tap()
        let deletePlan = app.buttons["confirm-category-deletion-plan"]
        XCTAssertTrue(deletePlan.waitForExistence(timeout: 5))
        deletePlan.tap()
        let confirm = app.buttons["confirm-permanent-deletion"]
        let cancel = app.buttons["cancel-permanent-deletion"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(deletePlan.isHittable)

        deletePlan.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
        XCTAssertFalse(app.staticTexts[name].waitForExistence(timeout: 2))
    }

    @MainActor
    func testPermanentTagDeletionRequiresConfirmationAndCancelIsSafe() {
        let app = XCUIApplication()
        let name = "待删除-\(UUID().uuidString.prefix(8))"
        app.launch()
        app.buttons["primary-tab-settings"].tap()
        app.staticTexts["标签"].tap()

        app.buttons["新增标签"].tap()
        let nameField = app.textFields["标签名称"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText(name)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))

        app.buttons["tag-actions-\(name)"].tap()
        app.buttons["永久删除"].tap()
        XCTAssertTrue(app.navigationBars["删除标签"].waitForExistence(timeout: 5))
        app.navigationBars["删除标签"].buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts[name].exists)

        app.buttons["tag-actions-\(name)"].tap()
        app.buttons["永久删除"].tap()
        let deletePlan = app.buttons["confirm-tag-deletion-plan"]
        XCTAssertTrue(deletePlan.waitForExistence(timeout: 5))
        deletePlan.tap()
        let confirm = app.buttons["confirm-permanent-deletion"]
        let cancel = app.buttons["cancel-permanent-deletion"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(app.navigationBars["删除标签"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[name].exists)

        deletePlan.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
        XCTAssertFalse(app.staticTexts[name].waitForExistence(timeout: 2))
    }

    @MainActor
    func testQuickAddIsFixedBetweenTransactionsAndInsightsAndPreservesSelection() {
        let app = XCUIApplication()
        app.launch()
        let button = app.buttons["quick-add"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertEqual(button.frame.midX, app.frame.width / 2, accuracy: 3)

        app.buttons["primary-tab-insights"].tap()
        XCTAssertTrue(app.staticTexts["支出构成"].waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(app.navigationBars["记一笔"].waitForExistence(timeout: 5))
        app.buttons["transaction-cancel"].tap()
        XCTAssertTrue(app.staticTexts["支出构成"].exists)
        XCTAssertEqual(button.frame.midX, app.frame.width / 2, accuracy: 3)
    }

    @MainActor
    func testSmartSuggestionsAutoFillAndRespectManualCategoryOverride() {
        let app = emptyReviewLedger()
        let tagName = "小宝-\(UUID().uuidString.prefix(6))"
        app.launchArguments += ["-smartSuggestions.enabled", "YES"]
        app.launch()

        app.buttons["primary-tab-settings"].tap()
        app.staticTexts["标签"].tap()
        app.buttons["新增标签"].tap()
        let tagNameField = app.textFields["标签名称"]
        XCTAssertTrue(tagNameField.waitForExistence(timeout: 5))
        tagNameField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        tagNameField.typeText(tagName)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts[tagName].waitForExistence(timeout: 5))
        app.navigationBars["标签"].buttons.firstMatch.tap()
        app.buttons["primary-tab-overview"].tap()

        app.buttons["quick-add"].tap()
        let note = app.textFields["transaction-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("\(tagName)纸尿裤")

        let diapers = app.buttons["category-尿裤湿巾"]
        XCTAssertTrue(waitForValue("已选择", element: diapers, timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["smart-suggestion"].exists)
        note.typeText("\n")
        app.buttons["transaction-tags"].tap()
        XCTAssertTrue(app.navigationBars["选择标签"].waitForExistence(timeout: 5))
        let childTag = app.buttons["tag-\(tagName)"]
        XCTAssertTrue(childTag.waitForExistence(timeout: 5))
        XCTAssertTrue(childTag.isHittable)
        XCTAssertEqual(childTag.value as? String, "已选择")

        childTag.tap()
        // Deselection moves the row into the unselected section, potentially offscreen.
        for _ in 0..<12 where !childTag.isHittable { app.swipeUp() }
        XCTAssertEqual(childTag.value as? String, "未选择")

        app.buttons["tag-picker-done"].tap()
        note.tap()
        note.typeText("咖啡")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.buttons["transaction-tags"].tap()
        XCTAssertTrue(app.navigationBars["选择标签"].waitForExistence(timeout: 5))
        for _ in 0..<12 where !childTag.isHittable { app.swipeUp() }
        XCTAssertEqual(childTag.value as? String, "未选择")
        app.buttons["tag-picker-done"].tap()
        let dining = app.buttons["category-早餐"]
        XCTAssertTrue(dining.isHittable)
        dining.tap()
        XCTAssertEqual(dining.value as? String, "已选择")
        let form = app.scrollViews["transaction-form-scroll"]
        for _ in 0..<4 where !note.isHittable { form.swipeUp() }
        XCTAssertTrue(note.isHittable)
        note.tap()
        note.typeText("咖啡")
        sleep(1)
        XCTAssertEqual(dining.value as? String, "已选择", "Manual category must not be overwritten.")
        XCTAssertEqual(app.staticTexts["smart-suggestion"].label, "已手动选定")
        XCTAssertFalse(app.buttons["undo-smart-suggestion"].exists)
    }

    @MainActor
    func testFoundationSettingDoesNotDisableRulesAndCanClearDerivedData() {
        let app = XCUIApplication()
        app.launchArguments += ["-smartSuggestions.enabled", "NO"]
        app.launch()

        app.buttons["primary-tab-settings"].tap()
        let toggle = app.switches["smart-suggestions-toggle"]
        for _ in 0..<4 where !toggle.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.value as? String, "0")

        app.buttons["quick-add"].tap()
        let note = app.textFields["transaction-note"]
        note.tap()
        note.typeText("火龙果")
        sleep(1)
        XCTAssertEqual(app.buttons["category-水果"].value as? String, "已选择")
        XCTAssertTrue(app.descendants(matching: .any)["smart-suggestion"].exists)
        app.buttons["transaction-cancel"].tap()

        app.terminate()
        app.launchArguments = ["-smartSuggestions.enabled", "YES"]
        app.launch()
        app.buttons["primary-tab-settings"].tap()
        for _ in 0..<4 where !toggle.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(app.switches["smart-suggestions-toggle"].value as? String, "1")
        let clear = app.buttons["clear-smart-suggestion-data"]
        for _ in 0..<4 where !clear.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(clear.isHittable)
        clear.tap()
        app.buttons["确认清除"].tap()
        XCTAssertTrue(app.alerts["已清除"].waitForExistence(timeout: 5))
        app.alerts["已清除"].buttons["好"].tap()
    }

    @MainActor
    func testEntryInputModesCategorySheetAndInlineCreation() {
        let app = emptyReviewLedger()
        let noteValue = "层级体验-\(UUID().uuidString.prefix(6))"
        let newCategory = "临时小类-\(UUID().uuidString.prefix(6))"
        app.launch()

        app.buttons["quick-add"].tap()
        XCTAssertTrue(app.buttons["calculator-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["all-categories"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["transaction-amount"].exists)
        app.buttons["calculator-1"].tap()
        app.buttons["category-早餐"].tap()
        // The manual-selection row moves the note field below it.
        XCTAssertTrue(app.staticTexts["已手动选定"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("已选择", element: app.buttons["category-早餐"], timeout: 5))

        let note = app.textFields["transaction-note"]
        note.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calculator-1"].isHittable)
        XCTAssertTrue(app.staticTexts["早餐"].exists)
        XCTAssertTrue(app.buttons["all-categories"].exists)
        note.typeText(noteValue + "\n")
        XCTAssertTrue(app.buttons["calculator-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))

        app.buttons["transaction-merchant-entry"].tap()
        let merchant = app.textFields["transaction-merchant"]
        XCTAssertTrue(merchant.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calculator-1"].isHittable)
        merchant.typeText("测试商户")
        app.navigationBars["商户"].buttons["完成"].tap()

        app.buttons["all-categories"].tap()
        XCTAssertTrue(app.navigationBars["全部分类"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["category-root-餐饮饮品"].exists)
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("育儿照护 / 尿裤湿巾")
        let child = app.buttons["all-category-育儿照护 / 尿裤湿巾"]
        XCTAssertTrue(child.waitForExistence(timeout: 5))
        child.tap()
        XCTAssertEqual(app.textFields["transaction-note"].value as? String, noteValue)
        XCTAssertEqual(
            app.descendants(matching: .any)["transaction-amount"].firstMatch.value as? String,
            "1"
        )

        app.buttons["all-categories"].tap()
        XCTAssertTrue(app.navigationBars["全部分类"].waitForExistence(timeout: 5))
        let createCategory = app.buttons["create-category-inline"]
        search.tap()
        search.typeText(newCategory)
        XCTAssertTrue(app.staticTexts["没有匹配的大类、小类或完整路径"].waitForExistence(timeout: 5))
        search.typeText("\n")
        XCTAssertTrue(createCategory.isHittable)
        createCategory.tap()
        let name = app.textFields["new-category-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText(newCategory)
        app.buttons["save-inline-category"].tap()
        let created = app.buttons["category-\(newCategory)"]
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        XCTAssertEqual(created.value as? String, "已选择")
        XCTAssertEqual(app.textFields["transaction-note"].value as? String, noteValue)
        XCTAssertEqual(
            app.descendants(matching: .any)["transaction-amount"].firstMatch.value as? String,
            "1"
        )
        app.buttons["transaction-cancel"].tap()
    }

    @MainActor
    func testSettingsEntrancesAndAppearanceControls() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["primary-tab-settings"].tap()

        let appearance = app.staticTexts["显示与字体"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        XCTAssertTrue(app.navigationBars["外观"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["appearance-mode-picker"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["font-size-picker"].exists)
        app.navigationBars["外观"].buttons.firstMatch.tap()

        let reminder = app.staticTexts["每日记账提醒"]
        for _ in 0..<4 where !reminder.isHittable { app.swipeUp() }
        XCTAssertTrue(reminder.isHittable)
        reminder.tap()
        XCTAssertTrue(app.navigationBars["每日记账提醒"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["daily-reminder-toggle"].value as? String, "0")
        app.navigationBars["每日记账提醒"].buttons.firstMatch.tap()

    }

    @MainActor
    func testTransactionSearchScopeHistoryTapAndClear() {
        let app = XCUIApplication()
        app.launchArguments += ["-build21SyntheticFixture", "YES", "-icloudSyncEnabled", "NO"]
        let keyword = "Build14历史\(UUID().uuidString.prefix(6))"
        app.launch()
        app.buttons["primary-tab-transactions"].tap()

        app.buttons["搜索"].tap()
        let search = app.textFields["transaction-search-input"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        if app.buttons["clear-recent-searches"].exists {
            app.buttons["clear-recent-searches"].tap()
        }
        search.typeText(keyword)
        XCTAssertTrue(app.buttons["本月"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["全部记录"].exists)
        app.buttons["全部记录"].tap()
        search.typeText("\n")

        app.buttons["clear-filters"].tap()
        XCTAssertEqual(search.value as? String, keyword, "Clearing filters must preserve the search")
        app.buttons["clear-transaction-search"].tap()
        let historyChip = app.buttons["recent-search-\(keyword)"]
        XCTAssertTrue(historyChip.waitForExistence(timeout: 5))
        app.buttons["全部记录"].tap()
        historyChip.tap()
        XCTAssertEqual(search.value as? String, keyword)
        XCTAssertTrue(app.staticTexts["全部历史"].waitForExistence(timeout: 5))

        app.buttons["clear-filters"].tap()
        app.buttons["clear-transaction-search"].tap()
        XCTAssertTrue(app.buttons["clear-recent-searches"].waitForExistence(timeout: 5))
        app.buttons["clear-recent-searches"].tap()
        XCTAssertFalse(historyChip.exists)
    }

    @MainActor
    func testSettingsUsageSummaryLoadsAllFourMetrics() {
        let app = XCUIApplication()
        app.launchArguments = ["-build21SyntheticFixture", "YES", "-icloudSyncEnabled", "NO",
            "-smartSuggestions.enabled", "NO", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-appearance.fontSize", "system"]
        app.launch()
        XCTAssertTrue(app.buttons["primary-tab-settings"].waitForExistence(timeout: 10))
        app.buttons["primary-tab-settings"].tap()
        for (title, value) in [("使用天数", "1 天"), ("交易总笔数", "9 笔"),
                               ("最早账单日", "2026-09-20"), ("有账天数", "5 天")] {
            let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", title, value)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "\(title) must expose its exact synthetic value")
        }
    }

    @MainActor
    private func createQuickAdd(
        note: String,
        amountKeys: [String],
        in app: XCUIApplication
    ) {
        app.buttons["quick-add"].tap()
        XCTAssertTrue(app.staticTexts["transaction-amount"].waitForExistence(timeout: 5))
        for key in amountKeys { app.buttons["calculator-\(key)"].tap() }
        app.buttons["category-早餐"].tap()
        let noteField = app.textFields["transaction-note"]
        noteField.tap()
        noteField.typeText(note + "\n")
        app.buttons["transaction-save"].tap()
        XCTAssertTrue(app.navigationBars["记一笔"].waitForNonExistence(timeout: 5))
    }

    private func waitForValue(
        _ value: String,
        element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func transactionRow(note: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch
    }
}
