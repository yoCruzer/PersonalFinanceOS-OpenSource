#if DEBUG
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// XCUITest runs outside the app sandbox. Sample the actual export directory and
/// clipboard on a separate synthetic launch, independently of either button.
struct DiagnosticSideEffectsFixture: ViewModifier {
    @State private var snapshot: String?

    func body(content: Content) -> some View {
        let environment = ProcessInfo.processInfo.environment
        if Build21SyntheticFixture.isEnabled, let marker = environment["PFOS_DIAGNOSTIC_PROBE_MARKER"] {
            Text(snapshot ?? "Reading")
                .accessibilityIdentifier("diagnostic-side-effects-snapshot")
                .task {
                    if environment["PFOS_SEED_DIAGNOSTIC_CLIPBOARD"] == "1" {
                        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: marker]],
                                                      options: [.localOnly: true])
                    }
                    do {
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PFOSDiagnostics")
                        let names: [String]
                        do {
                            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                                .filter { $0.hasPrefix("PFOS-diagnostic-") && $0.hasSuffix(".json") }.sorted()
                        } catch CocoaError.fileReadNoSuchFile {
                            names = []
                        }
                        let result = Snapshot(files: names, markerMatches: UIPasteboard.general.string == marker,
                                              changeCount: UIPasteboard.general.changeCount)
                        snapshot = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
                    } catch {
                        snapshot = "Could not observe diagnostic files: \(error.localizedDescription)"
                    }
                }
        } else {
            content
        }
    }

    private struct Snapshot: Encodable {
        let files: [String]
        let markerMatches: Bool
        let changeCount: Int
    }
}
#endif
