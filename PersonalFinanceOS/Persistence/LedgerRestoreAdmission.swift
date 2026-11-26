import Foundation
import SwiftData

/// Process-local confirmation tied to the controller's fully stopped transport.
/// The shared ledger write boundary serializes consume() with enabling sync.
final class LedgerRestoreAdmission: @unchecked Sendable {
    enum Failure: LocalizedError {
        case syncNotStopped, staleConfirmation

        var errorDescription: String? {
            switch self {
            case .syncNotStopped: "恢复前请先关闭 iCloud，并等待同步完全停止。"
            case .staleConfirmation: "同步状态或恢复请求已变化，请重新确认恢复。"
            }
        }
    }

    struct Ticket: Sendable {
        fileprivate let owner: LedgerRestoreAdmission
        fileprivate let generation: UUID
        fileprivate let containerID: ObjectIdentifier

        func consume(for container: ModelContainer) throws {
            guard containerID == ObjectIdentifier(container) else { throw Failure.staleConfirmation }
            try owner.consume(generation)
        }
    }

    private let lock = NSLock()
    private var generation = UUID()
    private var stopped = false

    func markStopped() {
        lock.lock()
        defer { lock.unlock() }
        generation = UUID()
        stopped = true
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        generation = UUID()
        stopped = false
    }

    func ticket(for container: ModelContainer) throws -> Ticket {
        lock.lock()
        defer { lock.unlock() }
        guard stopped else { throw Failure.syncNotStopped }
        return Ticket(owner: self, generation: generation, containerID: ObjectIdentifier(container))
    }

    private func consume(_ expected: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard stopped, generation == expected else { throw Failure.staleConfirmation }
        // Single use, including failed eligibility checks. A retry must confirm again.
        generation = UUID()
    }
}
