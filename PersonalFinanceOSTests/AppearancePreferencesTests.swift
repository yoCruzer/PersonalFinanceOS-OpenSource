import SwiftUI
import XCTest
@testable import PersonalFinanceOS

final class AppearancePreferencesTests: XCTestCase {
    func testDefaultsFollowSystemAndExplicitChoicesResolveImmediately() {
        XCTAssertEqual(AppAppearanceMode.defaultValue, .system)
        XCTAssertNil(AppAppearanceMode.system.colorScheme)
        XCTAssertEqual(AppAppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppAppearanceMode.dark.colorScheme, .dark)

        XCTAssertEqual(AppFontSizePreference.system.resolved(systemSize: .accessibility3), .accessibility3)
        XCTAssertEqual(AppFontSizePreference.standard.resolved(systemSize: .accessibility3), .large)
        XCTAssertEqual(AppFontSizePreference.large.resolved(systemSize: .large), .xLarge)
        XCTAssertEqual(AppFontSizePreference.extraLarge.resolved(systemSize: .large), .xxxLarge)
    }
}
