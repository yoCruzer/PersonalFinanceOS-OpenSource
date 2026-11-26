import Foundation

/// Bridges actor-owned replica mutations and the synchronous SwiftData apply boundary.
/// Never hold this lock across an await. A checked apply either finishes before a remote
/// mutation, or rejects its old token after that mutation; there is no check/apply gap.
final class ReconcileRevision: @unchecked Sendable {
    enum Failure: Error { case stalePlan }
    private let lock = NSRecursiveLock()
    private var generation: UInt64 = 0

    var token: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func beginMutation() { lock.lock() }
    func endMutation(changed: Bool = true) {
        if changed { generation &+= 1 }
        lock.unlock()
    }

    /// UI metadata commits yield if a replica mutation is in progress.
    func withCurrentIfAvailable<T>(_ token: UInt64, _ body: () throws -> T) throws -> T {
        guard lock.try() else { throw Failure.stalePlan }
        defer { lock.unlock() }
        guard generation == token else { throw Failure.stalePlan }
        return try body()
    }

    func withCurrent<T>(_ token: UInt64, _ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard generation == token else { throw Failure.stalePlan }
        return try body()
    }
}
