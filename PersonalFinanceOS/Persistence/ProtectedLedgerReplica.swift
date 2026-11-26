import Foundation

/// A local, durable replica. CloudKit never owns or deletes this file or the ledger store.
/// Missing cloud records are deliberately not ledger deletions; only explicit tombstones are.
struct ProtectedLedgerReplica: Codable, Equatable, Sendable {
    struct Revision: Codable, Equatable, Comparable, Sendable {
        let counter: UInt64
        let author: UUID

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
            return lhs.author.uuidString < rhs.author.uuidString
        }
    }

    struct Record: Codable, Equatable, Sendable {
        let revision: Revision
        /// nil is an explicit deletion, never an absent or temporarily unavailable download.
        let payload: Data?
    }

    enum Failure: Error, Equatable {
        case unsupportedFormat
        case differentAccount
        case conflictingRevision
        case clockExhausted
        case malformedRecord
        case initialFetchRequired
    }

    static let currentFormat = 1
    private(set) var format = currentFormat
    let accountIdentifier: String
    private(set) var author: UUID
    private(set) var clock: UInt64 = 0
    private(set) var records: [String: Record] = [:]
    /// Last committed local projection. Kept separately from remote arrivals so an interrupted
    /// import cannot turn a not-yet-inserted remote row into a local deletion on the next launch.
    private(set) var localBaseline: [String: Data] = [:]

    init(accountIdentifier: String, author: UUID = UUID()) {
        self.accountIdentifier = accountIdentifier
        self.author = author
    }

    /// A restored device backup must not make two installations write as the same author.
    mutating func beginWritingSession() { author = UUID() }

    /// Capture saved local changes before merging any remote values. A single capture gets a
    /// single Lamport revision; wall-clock changes do not affect conflict ordering.
    mutating func captureLocal(_ snapshot: [String: Data]) throws {
        let changed = Set(snapshot.keys).union(localBaseline.keys).filter {
            snapshot[$0] != localBaseline[$0]
        }
        guard !changed.isEmpty else { return }
        guard clock < UInt64.max else { throw Failure.clockExhausted }
        clock += 1
        let revision = Revision(counter: clock, author: author)
        for key in changed {
            records[key] = Record(revision: revision, payload: snapshot[key])
        }
        localBaseline = snapshot
    }

    /// Merge only complete, decoded records for the confirmed private account. The operation
    /// is transactional in memory too: a malformed record cannot leave a half-merged replica.
    mutating func merge(_ remote: Self) throws {
        guard remote.format == Self.currentFormat else { throw Failure.unsupportedFormat }
        guard remote.accountIdentifier == accountIdentifier else { throw Failure.differentAccount }
        var next = self
        for (key, incoming) in remote.records {
            guard !key.isEmpty, incoming.revision.counter > 0,
                  incoming.revision.counter <= remote.clock else {
                throw Failure.malformedRecord
            }
            if let current = next.records[key] {
                if incoming.revision == current.revision, incoming.payload != current.payload {
                    throw Failure.conflictingRevision
                }
                guard current.revision < incoming.revision else { continue }
            }
            next.records[key] = incoming
        }
        next.clock = max(clock, remote.clock)
        self = next
    }

    mutating func mergeRecord(_ record: Record, key: String, accountIdentifier: String) throws {
        var remote = Self(accountIdentifier: accountIdentifier, author: record.revision.author)
        remote.clock = record.revision.counter
        remote.records[key] = record
        try merge(remote)
    }

    /// Call only after the corresponding ledger projection has committed successfully.
    mutating func acknowledgeLocalProjection(_ snapshot: [String: Data]) {
        localBaseline = snapshot
    }

    var livePayloads: [String: Data] {
        records.compactMapValues(\.payload)
    }
}
