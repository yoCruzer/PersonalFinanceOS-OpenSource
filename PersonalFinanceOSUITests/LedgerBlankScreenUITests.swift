import XCTest

final class LedgerBlankScreenUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor private var cachedVisibleIDs: [String] = []

    @MainActor
    private func launch(extraArguments: [String] = []) -> XCUIApplication {
        cachedVisibleIDs = []
        let app = XCUIApplication()
        app.launchArguments = ["-build21SyntheticFixture", "YES", "-ledgerBlankFixture", "YES",
            "-icloudSyncEnabled", "NO", "-smartSuggestions.enabled", "NO",
            "-classificationFormTestOccurredAt", "1791288000", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchArguments += extraArguments
        app.launch()
        app.buttons["primary-tab-transactions"].tap()
        assertVisibleRows(app)
        return app
    }

    @MainActor
    private func rows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'transaction-row-'"))
    }

    @MainActor
    private func visibleRows(_ app: XCUIApplication) -> [XCUIElement] {
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = app.buttons["primary-tab-transactions"].frame.minY
        let cached = cachedVisibleIDs.map { app.descendants(matching: .any)[$0] }
        if !cached.isEmpty, cached.allSatisfy({ row in
            guard row.exists else { return false }
            let frame = row.frame
            return frame.height > 20 && frame.minY >= top && frame.maxY <= bottom && row.isHittable && row.isEnabled
        }) { return cached }
        let candidates = rows(app).allElementsBoundByIndex
        // Rows are in visual order. Locate the viewport in O(log n) AX reads;
        // enumerating every offscreen row makes a 300-row UI check unboundedly slow.
        var lower = 0, upper = candidates.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if candidates[middle].frame.minY < top { lower = middle + 1 }
            else { upper = middle }
        }
        var result: [XCUIElement] = []
        for row in candidates.dropFirst(lower).prefix(4) {
            let frame = row.frame
            if frame.height > 20 && frame.minY >= top && frame.maxY <= bottom && row.isHittable && row.isEnabled {
                result.append(row)
                if result.count == 2 { break }
            }
        }
        cachedVisibleIDs = result.map(\.identifier)
        return result
    }

    @MainActor
    private func assertVisibleRows(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(rows(app).firstMatch.waitForExistence(timeout: 10), file: file, line: line)
        let visible = visibleRows(app)
        if visible.isEmpty {
            let frames = rows(app).allElementsBoundByIndex.prefix(4).map { "\($0.frame), hit=\($0.isHittable)" }
            let detail = XCTAttachment(string: "nav=\(app.navigationBars.firstMatch.frame), bottom=\(app.buttons["primary-tab-transactions"].frame), rows=\(frames)")
            detail.name = "visible-row-failure-frames"; detail.lifetime = .keepAlways; add(detail)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        }
        XCTAssertFalse(visible.isEmpty,
            "流水主体必须在切 Tab 或滚动恢复前实际可见且可交互", file: file, line: line)
    }

    @MainActor
    private func submitSave(_ app: XCUIApplication) {
        app.buttons["quick-add"].tap()
        XCTAssertTrue(app.buttons["calculator-1"].waitForExistence(timeout: 5))
        app.buttons["calculator-1"].tap()
        app.buttons["category-午餐"].tap()
        app.buttons["transaction-save"].tap()
        XCTAssertTrue(app.navigationBars["记一笔"].waitForNonExistence(timeout: 8))
    }

    @MainActor
    private func save(_ app: XCUIApplication) {
        submitSave(app)
        assertVisibleRows(app)
    }

    @MainActor
    func testRealScrollingUpdatesInternalTransactionAnchor() {
        let app = XCUIApplication()
        app.launchArguments = ["-build21SyntheticFixture", "YES", "-ledgerBlankFixture", "YES",
            "-ledgerScrollProbe", "YES", "-icloudSyncEnabled", "NO"]
        app.launch(); app.buttons["primary-tab-transactions"].tap()
        assertVisibleRows(app)
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        let diagnostic = app.staticTexts["ledger-scroll-diagnostic"]
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5))
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "visible=true"), object: diagnostic)
        let settling = XCTWaiter.wait(for: [settled], timeout: 5)
        let first = diagnostic.label
        let proof = XCTAttachment(string: first + ";settling=\(settling)"); proof.name = "real-scroll-internal-anchor"; proof.lifetime = .keepAlways; add(proof)
        XCTAssertFalse(first.contains("height=0"), "Probe must measure the actual viewport")
        XCTAssertFalse(first.contains("frames=0"), "Probe must measure actual visible transaction frames")
        XCTAssertFalse(first.contains("anchor=nil"), "Real scrolling must update the App binding")
        let index = Int(first.components(separatedBy: ";")[0].replacingOccurrences(of: "anchor=", with: ""))!
        let boundRow = rows(app).matching(NSPredicate(format: "value == %@", "probe-index=\(index)")).firstMatch
        let axProof = XCTAttachment(string: "anchorOrdinal=\(index);AXframe=\(boundRow.frame);AXhittable=\(boundRow.isHittable);viewport=\(app.scrollViews.firstMatch.frame)")
        axProof.name = "bound-anchor-actual-AX-frame"; axProof.lifetime = .keepAlways; add(axProof)
        XCTAssertTrue(boundRow.isHittable, "The actual bound row must be interactable on screen")
        XCTAssertTrue(first.contains("visible=true"), "The bound transaction must intersect the measured viewport")
        attachLedgerState(app, name: "R1-first-bound-row")
        app.swipeUp(velocity: .fast)
        XCTAssertNotEqual(diagnostic.label.components(separatedBy: ";").first,
                          first.components(separatedBy: ";").first, "Moving the viewport must change the actual bound target")
        assertVisibleRows(app)
        XCTAssertTrue(diagnostic.label.contains("visible=true"))
        attachLedgerState(app, name: "R1-moved-bound-row")
    }

    @MainActor
    private func attachLedgerState(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let state = XCTAttachment(string: app.staticTexts["ledger-scroll-diagnostic"].label)
        state.name = name + "-state"; state.lifetime = .keepAlways; add(state)
    }

    @MainActor
    private func waitForGate(_ app: XCUIApplication, phase: String) {
        let predicate = NSPredicate(format: "label == %@", phase)
        let expectation = XCTNSPredicateExpectation(predicate: predicate,
            object: app.staticTexts["ledger-gate-phase"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    @MainActor
    private func waitForPublishedTotal(_ app: XCUIApplication, total: Int) {
        let predicate = NSPredicate { element, _ in
            guard let text = element as? XCUIElement else { return false }
            let value = text.label
            return value.contains("loading=false") && value.contains("stale=false") && value.contains("total=\(total)")
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate,
            object: app.staticTexts["ledger-scroll-diagnostic"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    @MainActor
    private func loadNextPage(in app: XCUIApplication, maxSwipes: Int = 40,
                              file: StaticString = #filePath, line: UInt = #line) {
        let next = app.buttons["global-search-next-page"]
        let tabTop = app.buttons["primary-tab-transactions"].frame.minY
        let gate = app.staticTexts["ledger-gate-phase"]
        let bottom = gate.exists ? min(tabTop, gate.frame.minY) : tabTop
        func isVisible() -> Bool {
            next.isHittable && next.frame.maxY <= bottom
        }

        for _ in 0..<maxSwipes {
            if isVisible() { break }
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(isVisible(), "The page button must be fully above the bottom controls", file: file, line: line)
        next.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["primary-tab-transactions"].isSelected, file: file, line: line)
        assertVisibleRows(app, file: file, line: line)
    }

    @MainActor
    private func prepareDeepGatedLedger() -> (XCUIApplication, String, CGFloat) {
        let app = launch(extraArguments: ["-ledgerScrollProbe", "YES", "-ledgerRefreshGate", "YES"])
        for _ in 0..<2 {
            loadNextPage(in: app)
        }
        let target = visibleRows(app).first!
        let id = target.identifier, y = target.frame.minY
        XCTAssertTrue(app.staticTexts["ledger-scroll-diagnostic"].label.contains("rows=300"))
        app.buttons["ledger-gate-arm"].tap()
        waitForGate(app, phase: "armed")
        return (app, id, y)
    }

    @MainActor
    private func assertRetainedViewport(_ app: XCUIApplication, id: String, y: CGFloat) {
        let target = app.descendants(matching: .any)[id]
        XCTAssertTrue(target.exists)
        XCTAssertGreaterThan(target.frame.height, 20)
        XCTAssertGreaterThanOrEqual(target.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThan(target.frame.maxY, app.buttons["primary-tab-transactions"].frame.minY)
        XCTAssertLessThan(abs(target.frame.minY - y), 160)
        XCTAssertTrue(app.staticTexts["ledger-scroll-diagnostic"].label.contains("rows=300"))
    }

    @MainActor
    func testDeepRefreshFaultsKeepViewportAndRetryWithoutCollapse() {
        executionTimeAllowance = 900
        for fault in ["cancel", "fail"] {
            let (app, id, y) = prepareDeepGatedLedger()
            submitSave(app)
            waitForGate(app, phase: "waiting")
            attachLedgerState(app, name: fault + "-waiting")
            assertRetainedViewport(app, id: id, y: y)
            XCTAssertTrue(app.staticTexts["ledger-scroll-diagnostic"].label.contains("total=328"))
            app.buttons["ledger-gate-" + fault].tap()
            let retry = app.buttons["ledger-retry"]
            XCTAssertTrue(retry.waitForExistence(timeout: 5)); XCTAssertTrue(retry.isHittable)
            assertRetainedViewport(app, id: id, y: y)
            XCTAssertFalse(app.descendants(matching: .any)[id].isEnabled)
            attachLedgerState(app, name: fault + "-retained-error")
            retry.tap()
            waitForPublishedTotal(app, total: 329)
            assertVisibleRows(app)
            attachLedgerState(app, name: fault + "-recovered")
            let retained = app.descendants(matching: .any)[id]
            XCTAssertTrue(retained.isEnabled && retained.isHittable)
            XCTAssertLessThan(abs(retained.frame.minY - y), 160)
            let state = app.staticTexts["ledger-scroll-diagnostic"].label
            XCTAssertTrue(state.contains("total=329"))
            XCTAssertTrue(state.contains("rows=300"))
            app.terminate()
        }
    }

    @MainActor
    func testUserScrollDuringSuspendedRefreshKeepsTheNewViewport() {
        executionTimeAllowance = 600
        let (app, oldID, _) = prepareDeepGatedLedger()
        submitSave(app)
        waitForGate(app, phase: "waiting")
        let before = app.staticTexts["ledger-scroll-diagnostic"].label.components(separatedBy: ";")[0]
        for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        let diagnostic = app.staticTexts["ledger-scroll-diagnostic"].label
        XCTAssertTrue(diagnostic.contains("visible=true"))
        XCTAssertTrue(diagnostic.contains("loading=true"))
        XCTAssertNotEqual(diagnostic.components(separatedBy: ";")[0], before)
        let ordinal = diagnostic.components(separatedBy: ";")[0].replacingOccurrences(of: "anchor=", with: "")
        let target = rows(app).matching(NSPredicate(format: "value == %@", "probe-index=" + ordinal)).firstMatch
        XCTAssertTrue(target.exists)
        let currentID = target.identifier, y = target.frame.minY
        XCTAssertNotEqual(currentID, oldID)
        attachLedgerState(app, name: "live-scroll-while-waiting")
        app.buttons["ledger-gate-release"].tap()
        waitForPublishedTotal(app, total: 329)
        assertVisibleRows(app)
        let retained = app.descendants(matching: .any)[currentID]
        XCTAssertTrue(retained.isHittable && retained.isEnabled)
        XCTAssertLessThan(abs(retained.frame.minY - y), 160)
        if app.descendants(matching: .any)[oldID].exists {
            XCTAssertFalse(app.descendants(matching: .any)[oldID].isHittable)
        }
        attachLedgerState(app, name: "live-scroll-after-publication")
    }

    @MainActor
    func testTabSwitchWhileDeepRefreshIsActuallySuspended() {
        executionTimeAllowance = 600
        let (app, id, y) = prepareDeepGatedLedger()
        submitSave(app)
        waitForGate(app, phase: "waiting")
        attachLedgerState(app, name: "tab-waiting")
        assertRetainedViewport(app, id: id, y: y)
        // Deliberately switch before the new snapshot has been read or published.
        app.buttons["primary-tab-overview"].tap()
        app.buttons["primary-tab-transactions"].tap()
        attachLedgerState(app, name: "tab-return-before-release")
        let target = app.descendants(matching: .any)[id]
        XCTAssertTrue(target.exists)
        XCTAssertLessThan(abs(target.frame.minY - y), 160)
        if app.staticTexts["ledger-gate-phase"].label == "waiting" {
            assertRetainedViewport(app, id: id, y: y)
            app.buttons["ledger-gate-release"].tap()
        } else if app.buttons["ledger-retry"].exists {
            XCTAssertTrue(app.buttons["ledger-retry"].isHittable)
            app.buttons["ledger-retry"].tap()
        }
        waitForPublishedTotal(app, total: 329)
        assertVisibleRows(app)
        XCTAssertTrue(target.isEnabled && target.isHittable)
        XCTAssertLessThan(abs(target.frame.minY - y), 160)
        XCTAssertTrue(app.staticTexts["ledger-scroll-diagnostic"].label.contains("total=329"))
    }

    @MainActor
    private func actualBoundRow(_ app: XCUIApplication) -> XCUIElement {
        let state = app.staticTexts["ledger-scroll-diagnostic"].label
        XCTAssertTrue(state.contains("visible=true"))
        let ordinal = state.components(separatedBy: ";")[0].replacingOccurrences(of: "anchor=", with: "")
        let row = rows(app).matching(NSPredicate(format: "value == %@", "probe-index=" + ordinal)).firstMatch
        XCTAssertTrue(row.isHittable)
        return row
    }

    @MainActor
    func testBoundTransactionSaveAndDeletePreserveVisibleNeighbour() {
        let app = launch(extraArguments: ["-ledgerScrollProbe", "YES"])
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        let bound = actualBoundRow(app)
        let id = bound.identifier, y = bound.frame.minY
        save(app)
        waitForPublishedTotal(app, total: 329)
        let retained = app.descendants(matching: .any)[id]
        XCTAssertTrue(retained.isHittable && retained.isEnabled)
        XCTAssertLessThan(abs(retained.frame.minY - y), 160)
        attachLedgerState(app, name: "R1-real-bound-save")
        let deleting = actualBoundRow(app)
        let deletedID = deleting.identifier
        let neighbour = visibleRows(app).first { $0.identifier != deletedID }!
        let neighbourID = neighbour.identifier
        deleting.tap()
        XCTAssertTrue(app.buttons["transaction-delete"].waitForExistence(timeout: 5))
        app.buttons["transaction-delete"].tap()
        app.buttons["transaction-delete-confirm"].tap()
        waitForPublishedTotal(app, total: 328)
        assertVisibleRows(app)
        XCTAssertFalse(app.descendants(matching: .any)[deletedID].exists)
        XCTAssertTrue(app.descendants(matching: .any)[neighbourID].isHittable)
        _ = actualBoundRow(app)
        attachLedgerState(app, name: "R1-real-bound-delete")
    }

    @MainActor
    func testAmountOrderingAndModeTransitionsHaveUsableCurrentContent() {
        let app = launch(extraArguments: ["-ledgerScrollProbe", "YES"])
        app.buttons["筛选"].tap()
        app.buttons["transaction-sort"].tap()
        app.buttons["金额：从高到低"].tap()
        let diagnostic = app.staticTexts["ledger-scroll-diagnostic"]
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "sort=amountHigh"), object: diagnostic)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
        assertVisibleRows(app)
        XCTAssertTrue(app.buttons["搜索"].isHittable)
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        _ = actualBoundRow(app)
        // The previous transition was already checked before navigating to controls.
        for _ in 0..<30 where !app.buttons["搜索"].isHittable { app.swipeDown(velocity: .fast) }
        app.buttons["transaction-sort"].tap()
        app.buttons["时间：最早优先"].tap()
        let oldest = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "sort=timeOldest"), object: diagnostic)
        XCTAssertEqual(XCTWaiter.wait(for: [oldest], timeout: 10), .completed)
        assertVisibleRows(app)
        XCTAssertTrue(app.buttons["搜索"].isHittable)
        app.buttons["列表"].tap(); app.buttons["日历"].tap()
        XCTAssertTrue(app.buttons["calendar-day-2026-10-04"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["calendar-day-2026-10-04"].isHittable)
        app.buttons["日历"].tap(); app.buttons["列表"].tap()
        assertVisibleRows(app)
        XCTAssertTrue(app.buttons["搜索"].isHittable)
        attachLedgerState(app, name: "R1-sort-mode-fallback")
    }

    @MainActor
    func testInitialVisibility() {
        let app = XCUIApplication()
        app.launchArguments = ["-build21SyntheticFixture", "YES", "-ledgerBlankFixture", "YES", "-icloudSyncEnabled", "NO"]
        app.launch(); app.buttons["primary-tab-transactions"].tap()
        let row = rows(app).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let detail = XCTAttachment(string: "type=\(row.elementType), row=\(row.frame), hit=\(row.isHittable), nav=\(app.navigationBars.firstMatch.frame), bottom=\(app.buttons["primary-tab-transactions"].frame), app=\(app.frame)")
        detail.name = "initial-frames"; detail.lifetime = .keepAlways; add(detail)
        XCTAssertTrue(row.isHittable)
    }

    @MainActor
    func testTwentySavesAtTopMiddleBottomAndAfterPaging() {
        executionTimeAllowance = 900
        let app = launch(extraArguments: ["-ledgerScrollProbe", "YES"])
        let initialState = app.staticTexts["ledger-scroll-diagnostic"].label
        let initialNet = Int(initialState.components(separatedBy: ";").first { $0.hasPrefix("net=") }!.dropFirst(4))!
        for iteration in 0..<20 {
            if iteration == 5 { for _ in 0..<3 { app.swipeUp(velocity: .fast) } }
            if iteration == 10 || iteration == 15 {
                loadNextPage(in: app, maxSwipes: 35)
            }
            let anchor = visibleRows(app).first!
            let id = anchor.identifier
            let previousY = anchor.frame.minY
            save(app)
            waitForPublishedTotal(app, total: 329 + iteration)
            XCTAssertTrue(app.staticTexts["ledger-scroll-diagnostic"].label.contains(";net=\(initialNet + (iteration + 1) * 100);"),
                "Every successful save must enter the current filtered aggregate")
            if iteration >= 5 {
                let retained = app.descendants(matching: .any)[id]
                XCTAssertTrue(retained.isHittable, "A valid deep anchor should stay on screen, iteration \(iteration)")
                XCTAssertLessThan(abs(retained.frame.minY - previousY), 160, "Unexpected jump at iteration \(iteration)")
            } else {
                XCTAssertTrue(app.buttons["搜索"].isHittable)
            }
            let proof = XCTAttachment(string: "save=\(iteration + 1), visibleRows=\(visibleRows(app).count), anchorYBefore=\(previousY), anchorYAfter=\(app.descendants(matching: .any)[id].frame.minY)")
            proof.name = "ledger-save-\(iteration + 1)"; proof.lifetime = .keepAlways; add(proof)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "save-\(iteration + 1)-visible"; shot.lifetime = .keepAlways; add(shot)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "ledger-after-20-saves"; screenshot.lifetime = .keepAlways; add(screenshot)
        visibleRows(app).first!.tap()
        XCTAssertTrue(app.buttons["transaction-edit"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSaveAtBottomOfCompletePagedLedger() {
        executionTimeAllowance = 600
        let app = launch()
        for _ in 0..<3 {
            loadNextPage(in: app)
        }
        let next = app.buttons["global-search-next-page"]
        XCTAssertFalse(next.exists, "The complete 328-row result must be loaded before testing its bottom")
        // Reach the actual final row without repairing or resetting the view after saving.
        for _ in 0..<14 { app.swipeUp(velocity: .fast) }
        assertVisibleRows(app)
        let anchor = visibleRows(app).first!
        let id = anchor.identifier, y = anchor.frame.minY
        save(app)
        let retained = app.descendants(matching: .any)[id]
        XCTAssertTrue(retained.isHittable && retained.isEnabled)
        XCTAssertLessThan(abs(retained.frame.minY - y), 160)
        XCTAssertFalse(next.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "complete-ledger-bottom-after-save"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testEditAndDeleteVisibleDeepAnchorReturnDirectlyToUsableRows() {
        let app = launch()
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        assertVisibleRows(app)
        let anchor = visibleRows(app).first!
        let id = anchor.identifier
        let y = anchor.frame.minY
        anchor.tap()
        XCTAssertTrue(app.buttons["transaction-edit"].waitForExistence(timeout: 5))
        app.buttons["transaction-edit"].tap()
        app.buttons["calculator-2"].tap()
        app.buttons["transaction-save"].tap()
        XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["流水"].tap()
        assertVisibleRows(app)
        let edited = app.descendants(matching: .any)[id]
        XCTAssertTrue(edited.isHittable)
        XCTAssertLessThan(abs(edited.frame.minY - y), 160)
        edited.tap()
        app.buttons["transaction-delete"].tap()
        app.buttons["transaction-delete-confirm"].tap()
        assertVisibleRows(app)
        XCTAssertFalse(app.descendants(matching: .any)[id].exists)
        XCTAssertFalse(app.buttons["搜索"].isHittable, "Deleting one deep row must not reset the whole ledger to its top")
        visibleRows(app).first!.tap()
        XCTAssertTrue(app.buttons["transaction-edit"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCancelledAndFailedQueryShowVisibleRetryAndRecover() {
        for fault in ["-ledgerQueryTestCancel", "-ledgerQueryTestFailure"] {
            let app = XCUIApplication()
            app.launchArguments = ["-build21SyntheticFixture", "YES", "-ledgerBlankFixture", "YES",
                "-icloudSyncEnabled", "NO", fault, "YES"]
            app.launch(); app.buttons["primary-tab-transactions"].tap()
            let retry = app.buttons["ledger-retry"]
            XCTAssertTrue(retry.waitForExistence(timeout: 10))
            XCTAssertTrue(retry.isHittable)
            XCTAssertTrue(retry.isEnabled)
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "重新加载")).count, 1)
            XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
            XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
            XCTAssertGreaterThan(retry.frame.minY, app.navigationBars.firstMatch.frame.minY)
            XCTAssertLessThan(retry.frame.maxY, app.buttons["primary-tab-transactions"].frame.minY)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = fault; shot.lifetime = .keepAlways; add(shot)
            retry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
            assertVisibleRows(app)
            XCTAssertFalse(retry.exists)
            app.terminate()
        }
    }

    @MainActor
    func testTransientConflictRecoversWithoutUserRetryOrBusinessNotification() {
        let app = XCUIApplication()
        app.launchArguments = ["-build21SyntheticFixture", "YES", "-productReviewFixture", "YES",
            "-icloudSyncEnabled", "NO", "-ledgerQueryTestStale", "YES"]
        app.launch()
        app.buttons["primary-tab-transactions"].tap()
        assertVisibleRows(app)
        XCTAssertFalse(app.buttons["ledger-retry"].exists)
        XCTAssertFalse(app.staticTexts["ledger-error-message"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "12k-transient-conflict-automatic-recovery"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testLargeLedgerInitialFailureHasOneEnabledRetry() {
        let app = XCUIApplication()
        app.launchArguments = ["-build21SyntheticFixture", "YES", "-productReviewFixture", "YES",
            "-icloudSyncEnabled", "NO", "-ledgerQueryTestFailure", "YES"]
        app.launch()
        app.buttons["primary-tab-transactions"].tap()
        let retry = app.buttons["ledger-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertTrue(retry.isEnabled)
        XCTAssertTrue(retry.isHittable)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "重新加载")).count, 1)
        XCTAssertEqual(app.staticTexts.matching(identifier: "ledger-error-message").count, 1)
        let failure = XCTAttachment(screenshot: app.screenshot())
        failure.name = "12k-single-error-enabled-retry"; failure.lifetime = .keepAlways; add(failure)
        retry.tap()
        assertVisibleRows(app)
        XCTAssertFalse(retry.exists)
        let recovered = XCTAttachment(screenshot: app.screenshot())
        recovered.name = "12k-recovered-ledger"; recovered.lifetime = .keepAlways; add(recovered)
    }

    @MainActor
    func testTwoSavesAtTopAndMiddleProbe() {
        let app = launch()
        save(app)
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        assertVisibleRows(app)
        let anchor = visibleRows(app).first!
        let id = anchor.identifier
        let beforeY = anchor.frame.minY
        save(app)
        let proof = XCTAttachment(string: "anchorYBefore=\(beforeY), anchorYAfter=\(app.descendants(matching: .any)[id].frame.minY), viewport=\(app.scrollViews.firstMatch.frame)")
        proof.name = "probe-scroll-position"; proof.lifetime = .keepAlways; add(proof)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "probe-after-save"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testFastTabSwitchAfterSaveAndSearchCalendarInsights() {
        let app = launch()
        save(app)
        app.buttons["primary-tab-overview"].tap()
        app.buttons["primary-tab-transactions"].tap()
        assertVisibleRows(app)
        app.buttons["搜索"].tap()
        let search = app.textFields["transaction-search-input"]
        search.tap(); search.typeText("合成流水-319\n")
        assertVisibleRows(app)
        XCTAssertTrue(visibleRows(app).allSatisfy { $0.label.contains("合成流水-319") })
        app.buttons["clear-transaction-search"].tap()
        app.buttons["收起"].tap()
        app.buttons["列表"].tap(); app.buttons["日历"].tap()
        XCTAssertTrue(app.buttons["calendar-day-2026-10-04"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["calendar-day-2026-10-04"].isHittable)
        app.buttons["primary-tab-insights"].tap()
        XCTAssertTrue(app.buttons["insights-range"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["insights-range"].isHittable)
    }
}
