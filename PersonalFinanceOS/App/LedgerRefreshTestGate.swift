#if DEBUG
import Foundation
import Observation

/// Explicit in-memory fixture only. No clock-based sleeps or filesystem side channel.
@MainActor @Observable
final class LedgerRefreshTestGate {
    enum Outcome { case success, cancelled, failure }
    private(set) var phase = "idle"
    private var armed = false
    private var request: UUID?
    private var continuation: CheckedContinuation<Void, Error>?

    var isEnabled: Bool {
        Build21SyntheticFixture.isEnabled && ProcessInfo.processInfo.arguments.contains("-ledgerRefreshGate")
    }

    func arm() {
        guard isEnabled, continuation == nil else { return }
        armed = true
        phase = "armed"
    }

    func checkpoint() async throws {
        guard isEnabled, armed else { return }
        armed = false
        try Task.checkCancellation()
        let token = UUID()
        request = token
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                phase = "waiting"
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor in self.release(.cancelled, matching: token) }
        }
    }

    func release(_ outcome: Outcome, matching token: UUID? = nil) {
        guard token == nil || token == request, let pending = continuation else { return }
        continuation = nil
        request = nil
        switch outcome {
        case .success: phase = "released"; pending.resume()
        case .cancelled: phase = "cancelled"; pending.resume(throwing: CancellationError())
        case .failure: phase = "failed"; pending.resume(throwing: CocoaError(.fileReadUnknown))
        }
    }
}
#endif
