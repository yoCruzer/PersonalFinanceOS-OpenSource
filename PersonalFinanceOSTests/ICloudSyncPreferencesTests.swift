import SwiftData
import XCTest
@testable import PersonalFinanceOS

final class ICloudSyncPreferencesTests: XCTestCase {
    func testAbsentPreferenceDefaultsOffAndBothChoicesPersist() throws {
        let suite = "ICloudPreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ICloudSyncPreferences(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: ICloudSyncPreferences.enabledKey))
        XCTAssertFalse(preferences.isEnabled)
        // Unrelated Build 20 device preferences must not opt an upgrading user in.
        defaults.set(true, forKey: "smartSuggestionsEnabled")
        XCTAssertFalse(ICloudSyncPreferences(defaults: defaults).isEnabled)
        preferences.isEnabled = true
        XCTAssertTrue(ICloudSyncPreferences(defaults: defaults).isEnabled)
        preferences.isEnabled = false
        XCTAssertFalse(ICloudSyncPreferences(defaults: defaults).isEnabled)
    }

    func testHistoricalAndCloudSchemaRelationshipOptionality() {
        let old = Schema(versionedSchema: Build20FixtureSchema.self).entities
            .flatMap(\.properties).compactMap { $0 as? Schema.Relationship }
        let current = AppSchema.schema.entities
            .flatMap(\.properties).compactMap { $0 as? Schema.Relationship }
        XCTAssertEqual(old.count, 2)
        XCTAssertTrue(old.contains { !$0.isOptional })
        XCTAssertEqual(current.count, 2)
        XCTAssertTrue(current.allSatisfy(\.isOptional))
        XCTAssertTrue(current.allSatisfy { $0.deleteRule == .nullify })
        XCTAssertEqual(Set(current.map(\.originalName)), ["tags", "transactions"])
    }

    func testAuthoritativeStoreKeepsBuild20URLAndNeverUsesManagedMirroring() {
        let baseline = ModelConfiguration(
            "PersonalFinanceOSV2", schema: AppSchema.schema, cloudKitDatabase: .none
        )
        let local = ModelContainerFactory.configuration()
        XCTAssertEqual(local.url, baseline.url)
        XCTAssertEqual(local, baseline)
        XCTAssertTrue(local.allowsSave)
    }
}
