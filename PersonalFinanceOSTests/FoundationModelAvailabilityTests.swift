import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import PersonalFinanceOS

final class FoundationModelAvailabilityTests: XCTestCase {
    func testUnavailableCopyDoesNotDiagnoseHardware() {
        let states: [FoundationClassificationAvailability] = [
            .appleIntelligenceNotEnabled, .modelNotReady, .deviceNotEligible,
            .unsupportedLocale, .unsupportedSystem, .unknown
        ]
        for state in states {
            XCTAssertFalse(state.localizedDescription.contains("当前设备不支持"))
            XCTAssertFalse(state.recoveryDescription.isEmpty)
        }
        XCTAssertEqual(Set(states.map(\.localizedDescription)).count, states.count)
        XCTAssertEqual(FoundationClassificationAvailability.available.localizedDescription, "可用")
        XCTAssertTrue(FoundationClassificationAvailability.deviceNotEligible
            .recoveryDescription.contains("并不一定表示硬件不支持"))
        XCTAssertTrue(FoundationClassificationAvailability.unsupportedSystem
            .recoveryDescription.contains("iOS 26"))
    }

    func testLocaleOnlyOverridesAnAvailableModel() {
        XCTAssertEqual(FoundationClassificationAvailability.available
            .checkingLocale(isSupported: false), .unsupportedLocale)
        XCTAssertEqual(FoundationClassificationAvailability.available
            .checkingLocale(isSupported: true), .available)
        for state: FoundationClassificationAvailability in [
            .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady,
            .unsupportedSystem, .unknown
        ] {
            XCTAssertEqual(state.checkingLocale(isSupported: false), state)
        }
    }

#if canImport(FoundationModels)
    func testSDKAvailabilityMapping() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Foundation Models requires iOS 26") }
        XCTAssertEqual(AppleFoundationClassificationProvider.mapAvailability(.available), .available)
        XCTAssertEqual(AppleFoundationClassificationProvider.mapAvailability(
            .unavailable(.appleIntelligenceNotEnabled)), .appleIntelligenceNotEnabled)
        XCTAssertEqual(AppleFoundationClassificationProvider.mapAvailability(
            .unavailable(.modelNotReady)), .modelNotReady)
        XCTAssertEqual(AppleFoundationClassificationProvider.mapAvailability(
            .unavailable(.deviceNotEligible)), .deviceNotEligible)
    }
#endif
}
