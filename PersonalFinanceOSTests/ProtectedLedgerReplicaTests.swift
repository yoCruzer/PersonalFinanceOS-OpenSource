import XCTest
@testable import PersonalFinanceOS

final class ProtectedLedgerReplicaTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testCloudPurgeAndAccountExitCannotDeleteProtectedRows() throws {
        var local = ProtectedLedgerReplica(accountIdentifier: "account-A", author: a)
        try local.captureLocal(["transaction:1": Data("12345".utf8)])
        let before = local
        try local.merge(ProtectedLedgerReplica(accountIdentifier: "account-A", author: b))
        XCTAssertEqual(local, before)
        XCTAssertThrowsError(try local.merge(.init(accountIdentifier: "account-B"))) {
            XCTAssertEqual($0 as? ProtectedLedgerReplica.Failure, .differentAccount)
        }
        XCTAssertEqual(local, before)
    }

    func testExplicitDeletionPropagatesAndStaleReplicaCannotResurrectIt() throws {
        var first = ProtectedLedgerReplica(accountIdentifier: "account", author: a)
        try first.captureLocal(["transaction:1": Data([1])])
        let stale = first
        try first.captureLocal([:])
        try first.merge(stale)
        XCTAssertTrue(first.livePayloads.isEmpty)
        XCTAssertNotNil(first.records["transaction:1"])
        var second = ProtectedLedgerReplica(accountIdentifier: "account", author: b)
        try second.merge(stale)
        try second.merge(first)
        XCTAssertTrue(second.livePayloads.isEmpty)
    }

    func testConcurrentEditsConvergeRegardlessOfDeliveryOrder() throws {
        var first = ProtectedLedgerReplica(accountIdentifier: "account", author: a)
        var second = ProtectedLedgerReplica(accountIdentifier: "account", author: b)
        try first.captureLocal(["transaction:1": Data([1]), "account:1": Data([3])])
        try second.captureLocal(["transaction:1": Data([2]), "tag:1": Data([4])])
        let originalFirst = first
        try first.merge(second)
        try second.merge(originalFirst)
        XCTAssertEqual(first.records, second.records)
        XCTAssertEqual(first.livePayloads["transaction:1"], Data([2]))
        XCTAssertEqual(first.livePayloads.count, 3)
        first.acknowledgeLocalProjection(first.livePayloads)
        var edited = first.livePayloads
        edited["transaction:1"] = Data([5])
        try first.captureLocal(edited)
        try second.merge(first)
        XCTAssertEqual(second.livePayloads["transaction:1"], Data([5]))
    }

    func testRepeatedCaptureAndDuplicateDeliveryAreIdempotent() throws {
        var local = ProtectedLedgerReplica(accountIdentifier: "account", author: a)
        let snapshot = ["transaction:1": Data([1])]
        try local.captureLocal(snapshot)
        let before = local
        for _ in 0..<10 {
            try local.captureLocal(snapshot)
            try local.merge(before)
        }
        XCTAssertEqual(local, before)
    }

    func testUnappliedRemoteArrivalIsNotMistakenForLocalDeletion() throws {
        var local = ProtectedLedgerReplica(accountIdentifier: "account", author: a)
        var remote = ProtectedLedgerReplica(accountIdentifier: "account", author: b)
        try remote.captureLocal(["transaction:remote": Data([7])])
        try local.merge(remote)
        // The process exits before the remote transaction is materialized in SwiftData.
        var reopened = try JSONDecoder().decode(
            ProtectedLedgerReplica.self, from: JSONEncoder().encode(local)
        )
        try reopened.captureLocal([:])
        XCTAssertEqual(reopened.livePayloads["transaction:remote"], Data([7]))
    }

    func testSerializationRetainsDeletionHistory() throws {
        var replica = ProtectedLedgerReplica(accountIdentifier: "account", author: a)
        try replica.captureLocal(["transaction:1": Data([1])])
        try replica.captureLocal([:])
        let reopened = try JSONDecoder().decode(
            ProtectedLedgerReplica.self, from: JSONEncoder().encode(replica)
        )
        XCTAssertEqual(reopened, replica)
        XCTAssertNotNil(reopened.records["transaction:1"])
    }
}
