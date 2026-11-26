import CloudKit
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class Build23ActivationRetryTests: XCTestCase {
    private func fixture() throws -> (ICloudSyncController, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = try PrivateCloudReplicaSession(stateURL: root.appendingPathComponent("old.json"), accountIdentifier: "retry-fixture", automaticallySync: false)
        return (ICloudSyncController(confirmedSession: session, identity: LedgerSyncIdentity(), identityURL: root.appendingPathComponent("identity.json")), root)
    }

    func testDuplicateRecoveryTriggersCoalesceAndOffDuringBackoffCannotRevive() async throws {
        let (controller, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0, sleeps = 0, wake: CheckedContinuation<Void, Error>?
        let scheduled = expectation(description: "backoff")
        controller.activationVerification = { attempts += 1; throw CKError(.networkUnavailable) }
        controller.activationRetryWait = { _ in sleeps += 1; scheduled.fulfill(); try await withCheckedThrowingContinuation { wake = $0 } }
        controller.setForeground(true); await controller.activate()
        await fulfillment(of: [scheduled], timeout: 1)
        for _ in 0..<5 { controller.setForeground(true); await controller.activate() }
        XCTAssertEqual(attempts, 1); XCTAssertEqual(sleeps, 1)
        let retry = controller.activationRetryTask
        await controller.disable(); wake?.resume(); await retry?.value
        XCTAssertEqual(attempts, 1); XCTAssertEqual(controller.status, .off)
        XCTAssertFalse(controller.displaySnapshot.engineAvailable)
    }

    func testReenableOwnsNewGenerationAndOldTimerCannotReplaceIt() async throws {
        let (controller, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let key = "icloudSyncConfirmedAccount.Development", saved = UserDefaults.standard.string(forKey: "icloudSyncConfirmedAccount.Development")
        defer { UserDefaults.standard.set(saved, forKey: key) }; UserDefaults.standard.set("retry-fixture", forKey: key)
        var attempts = 0, wake: CheckedContinuation<Void, Error>?
        let scheduled = expectation(description: "backoff")
        controller.activationVerification = {
            attempts += 1
            if attempts == 1 { throw CKError(.accountTemporarilyUnavailable) }
            return .init(environment: .development, account: "retry-fixture", root: root, automaticallySync: false)
        }
        controller.activationRetryWait = { _ in scheduled.fulfill(); try await withCheckedThrowingContinuation { wake = $0 } }
        controller.setForeground(true); await controller.activate(); await fulfillment(of: [scheduled], timeout: 1)
        let retry = controller.activationRetryTask
        await controller.disable(); await controller.enable(); wake?.resume(); await retry?.value
        await controller.refreshStatus()
        XCTAssertEqual(attempts, 2); XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.displaySnapshot.engineAvailable)
        await controller.activate(); XCTAssertEqual(attempts, 2, "A live engine is reused")
        await controller.disable()
    }

    func testBackgroundCancelsPendingRecoveryAndForegroundReschedules() async throws {
        let (controller, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0, sleeps = 0, wakes: [CheckedContinuation<Void, Error>] = []
        let firstScheduled = expectation(description: "first window"), secondScheduled = expectation(description: "second window")
        controller.activationVerification = { attempts += 1; throw CKError(.networkUnavailable) }
        controller.activationRetryWait = { _ in sleeps += 1; (sleeps == 1 ? firstScheduled : secondScheduled).fulfill(); try await withCheckedThrowingContinuation { wakes.append($0) } }
        controller.setForeground(true); await controller.activate()
        await fulfillment(of: [firstScheduled], timeout: 1)
        XCTAssertEqual(sleeps, 1)
        let firstRetry = controller.activationRetryTask
        controller.setForeground(false); wakes[0].resume(); await firstRetry?.value
        XCTAssertEqual(attempts, 1)
        controller.setForeground(true)
        await fulfillment(of: [secondScheduled], timeout: 1)
        XCTAssertEqual(sleeps, 2)
        let secondRetry = controller.activationRetryTask
        await controller.disable(); wakes[1].resume(); await secondRetry?.value
    }

    func testChangedAccountDuringAutomaticVerificationNeedsExplicitConfirmation() async throws {
        let (controller, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let key = "icloudSyncConfirmedAccount.Development", saved = UserDefaults.standard.string(forKey: "icloudSyncConfirmedAccount.Development")
        defer { UserDefaults.standard.set(saved, forKey: key) }; UserDefaults.standard.set("retry-fixture", forKey: key)
        var calls = 0
        let verified = expectation(description: "automatic verification")
        controller.activationVerification = {
            calls += 1
            if calls == 1 { throw CKError(.networkUnavailable) }
            verified.fulfill()
            return .init(environment: .development, account: "other-fixture", root: root, automaticallySync: false)
        }
        controller.activationRetryWait = { _ in }
        controller.setForeground(true); await controller.activate(); await controller.activationRetryTask?.value
        await fulfillment(of: [verified], timeout: 1)
        XCTAssertEqual(controller.status, .accountChanged)
        XCTAssertFalse(controller.displaySnapshot.engineAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudReplicaLocation(root: root, environment: .development, account: "other-fixture").stateURL.path))
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "retry-fixture")
        await controller.activate(); XCTAssertEqual(calls, 2)
        await controller.disable()
    }

    func testAutomaticBackoffIsFiniteAndPermanentFailureNeverSchedules() async throws {
        for code in [CKError.Code.networkUnavailable, .permissionFailure, .badContainer, .notAuthenticated] {
            let (controller, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            var attempts = 0, delays: [Double] = []
            controller.activationVerification = { attempts += 1; throw CKError(code) }
            controller.activationRetryWait = { delay in delays.append(delay) }
            controller.setForeground(true); await controller.activate()
            while let retry = controller.activationRetryTask { await retry.value }
            XCTAssertEqual(attempts, code == .networkUnavailable ? 4 : 1)
            XCTAssertEqual(delays, code == .networkUnavailable ? [2, 4, 8] : [])
            XCTAssertEqual(controller.status, .error)
            await controller.disable()
        }
    }

    func testBackgroundDuringSuspendedAutomaticVerificationDoesNotCreateSession() async throws {
        let (controller, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0, finish: CheckedContinuation<ICloudSyncController.VerifiedActivation, Error>?, wake: CheckedContinuation<Void, Error>?
        let scheduled = expectation(description: "backoff scheduled")
        let verifying = expectation(description: "verification suspended")
        controller.activationVerification = {
            attempts += 1
            if attempts == 1 { throw CKError(.networkUnavailable) }
            return try await withCheckedThrowingContinuation { finish = $0; verifying.fulfill() }
        }
        controller.activationRetryWait = { _ in
            scheduled.fulfill(); try await withCheckedThrowingContinuation { wake = $0 }
        }
        controller.setForeground(true); await controller.activate(); await fulfillment(of: [scheduled], timeout: 1)
        let retry = controller.activationRetryTask
        wake?.resume()
        await fulfillment(of: [verifying], timeout: 1)
        controller.setForeground(false)
        finish?.resume(returning: .init(environment: .development, account: "retry-fixture", root: root, automaticallySync: false))
        await retry?.value; await controller.refreshStatus()
        XCTAssertEqual(controller.status, .retrying)
        XCTAssertFalse(controller.displaySnapshot.engineAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudReplicaLocation(root: root, environment: .development, account: "retry-fixture").stateURL.path))
        await controller.disable()
    }
}
