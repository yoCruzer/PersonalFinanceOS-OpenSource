import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class LedgerChangeCenter {
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private var lastContentRevision: UInt64?
    @ObservationIgnored private var observer: LedgerChangeObservation?
    @ObservationIgnored private var observedContainer: ObjectIdentifier?
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingContentRevision: UInt64?

    init() { _ = LedgerSaveRevision.shared }

    func observeSaves(in container: ModelContainer) {
        guard observedContainer != ObjectIdentifier(container) else { return }
        observer = nil
        deliveryTask?.cancel()
        deliveryTask = nil
        pendingContentRevision = nil
        observedContainer = ObjectIdentifier(container)
        lastContentRevision = nil
        observer = LedgerChangeObservation(NotificationCenter.default.addObserver(forName: LedgerSaveRevision.contentDidChange, object: nil, queue: nil) { [weak self] note in
            if let sender = note.object as? ModelContainer, sender !== container { return }
            guard let revision = note.userInfo?[LedgerSaveRevision.contentRevisionKey] as? UInt64 else { return }
            Task { @MainActor [weak self] in self?.scheduleDelivery(contentRevision: revision) }
        })
    }

    private func scheduleDelivery(contentRevision: UInt64) {
        guard lastContentRevision.map({ contentRevision > $0 }) ?? true else { return }
        pendingContentRevision = max(pendingContentRevision ?? 0, contentRevision)
        guard deliveryTask == nil else { return }
        deliveryTask = Task { [weak self] in
            while !Task.isCancelled {
                // One coalesced background waiter, never the MainActor, waits for
                // the final write boundary before waking content consumers.
                let stable = await Task.detached(priority: .userInitiated) {
                    LedgerSaveRevision.shared.withImportBoundary { LedgerSaveRevision.shared.contentRevision }
                }.value
                guard !Task.isCancelled, let self else { return }
                self.recordMutation(contentRevision: stable)
                if (self.pendingContentRevision ?? 0) <= stable {
                    self.pendingContentRevision = nil
                    self.deliveryTask = nil
                    return
                }
            }
        }
    }

    /// Explicit UI acknowledgments and automatic save delivery converge on the
    /// same content marker. Metadata-only edits notify; receipt-only saves do not.
    func recordMutation(contentRevision: UInt64 = LedgerSaveRevision.shared.contentRevision) {
        guard lastContentRevision.map({ contentRevision > $0 }) ?? true else { return }
        lastContentRevision = contentRevision
        revision &+= 1
    }

}

private final class LedgerChangeObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
