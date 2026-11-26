import XCTest

final class Build28SettingsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAllFourFactsRemainVisibleAcrossTabsInLightAndDarkLargeText() {
        for (style, category) in [("light", "UICTContentSizeCategoryL"), ("dark", "UICTContentSizeCategoryAccessibilityXXXL")] {
            let app = XCUIApplication()
            app.launchArguments = ["-build21SyntheticFixture", "YES", "-icloudSyncEnabled", "NO",
                "-smartSuggestions.enabled", "NO", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                "-appearance.mode", style, "-appearance.fontSize", "system",
                "-UIPreferredContentSizeCategoryName", category]
            app.launch()
            XCTAssertTrue(app.buttons["primary-tab-settings"].waitForExistence(timeout: 10))
            app.buttons["primary-tab-settings"].tap()
            let date = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '2026-09-20'")).firstMatch
            XCTAssertTrue(date.waitForExistence(timeout: 10))
            for title in ["使用天数", "交易总笔数", "最早账单日", "有账天数"] {
                let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
                XCTAssertTrue(row.exists, title)
                XCTAssertGreaterThanOrEqual(row.frame.minX, 0)
                XCTAssertLessThanOrEqual(row.frame.maxX, app.frame.maxX)
            }
            XCTAssertTrue(date.label.contains("2026-09-20"))
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "build28-settings-\(style)-\(category)"; screenshot.lifetime = .keepAlways; add(screenshot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "build28-settings-\(style)-accessibility"; tree.lifetime = .keepAlways; add(tree)
            let last = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '有账天数'")).firstMatch
            let bottom = app.buttons["primary-tab-settings"].frame.minY
            for _ in 0..<3 where last.frame.maxY > bottom {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50)))
            }
            XCTAssertTrue(last.exists)
            XCTAssertTrue(last.isHittable)
            XCTAssertGreaterThan(last.frame.height, 0)
            XCTAssertGreaterThanOrEqual(last.frame.minY, app.navigationBars.firstMatch.frame.maxY)
            XCTAssertLessThanOrEqual(last.frame.maxY, bottom, "Last metric can scroll fully above navigation")
            if style == "dark" {
                let scrolled = XCTAttachment(screenshot: app.screenshot())
                scrolled.name = "build28-settings-dark-large-scrolled"; scrolled.lifetime = .keepAlways; add(scrolled)
            }
            app.buttons["primary-tab-transactions"].tap()
            app.buttons["primary-tab-settings"].tap()
            XCTAssertTrue(date.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["settings-usage-retry"].exists)
            app.terminate()
        }
    }
}
