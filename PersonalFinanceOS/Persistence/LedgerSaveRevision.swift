import Foundation
import SwiftData

/// A synchronous save marker across ModelActor contexts. It carries no ledger contents and
/// lets background snapshot preparation detect intervening saves before applying a projection.
final class LedgerSaveRevision: @unchecked Sendable {
    static let shared = LedgerSaveRevision()
    static let editingDidEnd = Notification.Name("PFOSLedgerEditingDidEnd")
    static let contentDidChange = Notification.Name("PFOSLedgerContentDidChange")
    static let contentRevisionKey = "contentRevision"
    private let lock = NSLock()
    private let importLock = NSRecursiveLock()
    private var value: UInt64 = 0
    private var contentValue: UInt64 = 0
    private var restoreEpoch = UUID()
    private var observer: NSObjectProtocol?
    private var beforeObserver: NSObjectProtocol?
    private struct ContextSave {
        weak var context: AnyObject?
        var pending = true
    }
    private var contextSaves: [ObjectIdentifier: ContextSave] = [:]

    private init() {
        beforeObserver = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: nil, queue: nil) { [weak self] in
            self?.willSave($0)
        }
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] in
            self?.didSave($0)
        }
    }

    private func willSave(_ notification: Notification) {
        guard let context = notification.object as? ModelContext else { return }
        lock.lock()
        contextSaves[ObjectIdentifier(context)] = ContextSave(context: context)
        if contextSaves.count > 64 { contextSaves = contextSaves.filter { $0.value.context != nil } }
        lock.unlock()
    }

    private func didSave(_ notification: Notification) {
        lock.lock()
        if let context = notification.object as? ModelContext,
           var state = contextSaves[ObjectIdentifier(context)], state.context === context {
            // A second didSave without another willSave is a duplicate delivery,
            // not evidence that the same rows were edited again.
            guard state.pending else { lock.unlock(); return }
            state.pending = false
            contextSaves[ObjectIdentifier(context)] = state
        }
        value &+= 1
        let changed = Self.changesContent(notification)
        if changed { contentValue &+= 1 }
        let contentRevision = contentValue
        lock.unlock()
        if changed {
            NotificationCenter.default.post(name: Self.contentDidChange, object: (notification.object as? ModelContext)?.container,
                userInfo: [Self.contentRevisionKey: contentRevision])
        }
    }

    private static func changesContent(_ notification: Notification) -> Bool {
        guard let info = notification.userInfo else { return true }
        if info[ModelContext.NotificationKey.invalidatedAllIdentifiers] != nil ||
            info[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] != nil { return true }
        var hasKnownPayload = false
        for key in [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers] {
            guard let value = info[key] ?? info[key.rawValue] else { continue }
            hasKnownPayload = true
            let identifiers: [PersistentIdentifier]
            if let array = value as? [PersistentIdentifier] { identifiers = array }
            else if let set = value as? Set<PersistentIdentifier> { identifiers = Array(set) }
            else { return true }
            if identifiers.contains(where: { $0.entityName != "SyncProjectionReceipt" }) { return true }
        }
        // Missing/new SDK payloads conservatively invalidate. Only a positively
        // identified no-op or receipt-only save can avoid a content refresh.
        return !hasKnownPayload
    }

    var revision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var contentRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return contentValue
    }

    /// Business readers ignore receipt-only persistence while retaining the same
    /// short admission boundary against an in-flight business writer.
    func readContentStamp() throws -> UInt64 {
        try withProjectionBoundary { contentRevision }
    }

    var restoreGeneration: UUID {
        lock.lock()
        defer { lock.unlock() }
        return restoreEpoch
    }

    /// Called only after a successful native restore, inside its final boundary.
    func didRestore() {
        lock.lock()
        defer { lock.unlock() }
        restoreEpoch = UUID()
    }

    /// Short, nonblocking stamp for a versioned read. A writer still inside its
    /// commit boundary cannot be mistaken for a stable multi-entity snapshot.
    func readStamp() throws -> UInt64 {
        try withProjectionBoundary { revision }
    }

    /// Serialize import/restore/projection and metadata deletion/migration writes, never network or detached work.
    func withImportBoundary<T>(onContention: (@Sendable () -> Void)? = nil, _ body: () throws -> T) rethrows -> T {
        if !importLock.try() {
            onContention?()
            importLock.lock()
        }
        defer { importLock.unlock() }
        return try body()
    }

    /// Main-actor sync application yields to a running import instead of blocking the UI.
    func withProjectionBoundary<T>(_ body: () throws -> T) throws -> T {
        guard importLock.try() else { throw ReconcileRevision.Failure.stalePlan }
        defer { importLock.unlock() }
        return try body()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let beforeObserver { NotificationCenter.default.removeObserver(beforeObserver) }
    }
}

// SwiftData has no public rollback notification. Preserve its exact rollback behavior,
// then wake synchronization that may be waiting for this context's unsaved edits.
extension ModelContext {
    func rollbackNotifyingSync() {
        rollback()
        NotificationCenter.default.post(name: LedgerSaveRevision.editingDidEnd, object: container)
    }
}
