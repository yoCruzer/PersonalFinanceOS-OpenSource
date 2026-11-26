import XCTest

struct DiagnosticSideEffectsSnapshot: Decodable {
    let files: Set<String>
    let markerMatches: Bool
    let changeCount: Int

    @MainActor
    static func capture(marker: String, seedClipboard: Bool = false) throws -> Self {
        let probe = XCUIApplication()
        probe.launchArguments = ["-build21SyntheticFixture"]
        probe.launchEnvironment["PFOS_DIAGNOSTIC_PROBE_MARKER"] = marker
        if seedClipboard { probe.launchEnvironment["PFOS_SEED_DIAGNOSTIC_CLIPBOARD"] = "1" }
        probe.launch()
        defer { probe.terminate() }
        let value = probe.staticTexts["diagnostic-side-effects-snapshot"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label != 'Reading'"),
                                              object: value)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        return try JSONDecoder().decode(Self.self, from: Data(value.label.utf8))
    }
}
