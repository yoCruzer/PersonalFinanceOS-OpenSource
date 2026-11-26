import XCTest

final class SyncContinuationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCompletionBoundaryCopyInLightAndLargeDarkSettings() {
        for (style, size) in [("light", "system"), ("dark", "extraLarge")] {
            let app = XCUIApplication()
            app.launchArguments = ["-build21SyntheticFixture", "YES", "-icloudSyncEnabled", "NO",
                "-smartSuggestions.enabled", "NO", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                "-appearance.mode", style, "-appearance.fontSize", size]
            app.launch()
            let settings = app.buttons["primary-tab-settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            settings.tap()
            let disclosure = app.buttons["icloud-sync-disclosure"]
            for _ in 0..<7 where !disclosure.isHittable { app.swipeUp() }
            XCTAssertTrue(disclosure.isHittable)
            disclosure.tap()
            let explanation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "本机检查包括空拉取")).firstMatch
            for _ in 0..<3 where !explanation.isHittable { app.swipeUp() }
            XCTAssertTrue(explanation.isHittable)
            XCTAssertTrue(explanation.label.contains("本机检查包括空拉取"))
            XCTAssertTrue(explanation.label.contains("不表示另一设备有新增数据或已收到"))
            XCTAssertFalse(app.staticTexts["等待系统同步调度"].exists)
            XCTAssertFalse(app.buttons["icloud-sync-now"].exists, "The synthetic OFF fixture must never start real CloudKit")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "sync-settings-" + style + "-" + size
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }
}
