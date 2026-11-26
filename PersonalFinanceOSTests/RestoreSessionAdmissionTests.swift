import SwiftData
import XCTest
@testable import PersonalFinanceOS

func offlineRestoreTicket(for container: ModelContainer) throws -> LedgerRestoreAdmission.Ticket {
    let admission = LedgerRestoreAdmission()
    admission.markStopped()
    return try admission.ticket(for: container)
}

private final class RestoreAdmissionGate: @unchecked Sendable {
    let validated = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func waitForValidation() -> Bool { validated.wait(timeout: .now() + 10) == .success }
}

@MainActor
final class RestoreSessionAdmissionTests: XCTestCase {
    func testEnableInvalidatesPreviouslyConfirmedRestoreBeforeFinalCommit() async throws {
        let preferences = ICloudSyncPreferences()
        let previouslyEnabled = preferences.isEnabled
        preferences.isEnabled = false
        defer { preferences.isEnabled = previouslyEnabled }
        let controller = ICloudSyncController()
        let destination = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let ticket = try controller.makeRestoreAdmission(for: destination)
        let data = try await metadataBackup()
        try controller.prepareEnable()
        XCTAssertThrowsError(try controller.makeRestoreAdmission(for: destination))
        do {
            _ = try await NativeBackupActor(modelContainer: destination).restore(data: data, admission: ticket)
            XCTFail("A pre-enable confirmation must not authorize a later restore")
        } catch LedgerRestoreAdmission.Failure.staleConfirmation {}
        let context = ModelContext(destination)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppMetadata>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Account>()), 0)
        await controller.disable()
        _ = try await NativeBackupActor(modelContainer: destination).restore(
            data: data, admission: controller.makeRestoreAdmission(for: destination)
        )
        XCTAssertNoThrow(try NativeBackupService.validate(LedgerSnapshotCodec.capture(in: ModelContext(destination))))
    }

    func testRealRestoreExcludesEnableUntilFullCommitWithoutBlockingMainActor() async throws {
        let preferences = ICloudSyncPreferences()
        let previouslyEnabled = preferences.isEnabled
        preferences.isEnabled = false
        defer { preferences.isEnabled = previouslyEnabled }
        let controller = ICloudSyncController()
        let destination = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let ticket = try controller.makeRestoreAdmission(for: destination)
        let data = try await metadataBackup()
        let gate = RestoreAdmissionGate()
        let restoring = Task.detached {
            try await NativeBackupActor(modelContainer: destination).restore(
                data: data, admission: ticket, afterEligibilityValidation: {
                    gate.validated.signal()
                    guard gate.release.wait(timeout: .now() + 10) == .success else {
                        throw CocoaError(.userCancelled)
                    }
                }
            )
        }
        let reached = await Task.detached { gate.waitForValidation() }.value
        XCTAssertTrue(reached)
        // The actual enable entry must return before the restore is released.
        // No CKContainer query occurs because its local admission fails first.
        await controller.enable()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(preferences.isEnabled)
        gate.release.signal()
        let result = try await restoring.value
        XCTAssertEqual(result.insertedTransactionCount, 0)
        XCTAssertGreaterThan(result.insertedCategoryCount, 0)
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(destination))
        XCTAssertNoThrow(try NativeBackupService.validate(package))
        XCTAssertTrue(package.transactions.isEmpty)
        // A second use cannot replay the same confirmation, even for a pristine graph.
        do {
            _ = try await NativeBackupActor(modelContainer: destination).restore(data: data, admission: ticket)
            XCTFail("Restore confirmation is single use")
        } catch LedgerRestoreAdmission.Failure.staleConfirmation {}
    }

    private func metadataBackup() async throws -> Data {
        let source = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        try DefaultFinanceDataService.ensureDefaults(in: ModelContext(source))
        return try await NativeBackupActor(modelContainer: source).exportData()
    }
}
