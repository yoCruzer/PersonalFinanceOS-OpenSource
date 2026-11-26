import XCTest
@testable import PersonalFinanceOS

final class DailyReminderServiceTests: XCTestCase {
    func testDefaultsAreDisabledAtNinePM() {
        XCTAssertFalse(DailyReminderPreferences.defaultEnabled)
        XCTAssertEqual(DailyReminderPreferences.defaultHour, 21)
        XCTAssertEqual(DailyReminderPreferences.defaultMinute, 0)
    }

    func testEnablingRequestsPermissionOnlyWhenNeededAndSchedulesOnePrivateReminder() async throws {
        let provider = ReminderProviderStub(status: .notDetermined, requestResult: .authorized)

        let result = try await DailyReminderService.enable(
            hour: 20,
            minute: 35,
            provider: provider
        )

        XCTAssertEqual(result, .authorized)
        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 1)
        let requests = await provider.scheduledRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].identifier, DailyReminderService.requestIdentifier)
        XCTAssertEqual(requests[0].hour, 20)
        XCTAssertEqual(requests[0].minute, 35)
        XCTAssertFalse(requests[0].title.contains("¥"))
        XCTAssertFalse(requests[0].body.contains("余额"))
    }

    func testDeniedPermissionDoesNotSchedule() async throws {
        let provider = ReminderProviderStub(status: .denied, requestResult: .denied)

        let result = try await DailyReminderService.enable(
            hour: 21,
            minute: 0,
            provider: provider
        )

        XCTAssertEqual(result, .denied)
        let requestCount = await provider.requestCount
        let scheduledRequests = await provider.scheduledRequests
        XCTAssertEqual(requestCount, 0)
        XCTAssertTrue(scheduledRequests.isEmpty)
    }

    func testChangingTimeReplacesTheSingleRequestAndDisablingCancelsIt() async throws {
        let provider = ReminderProviderStub(status: .authorized, requestResult: .authorized)
        _ = try await DailyReminderService.enable(hour: 21, minute: 0, provider: provider)
        _ = try await DailyReminderService.enable(hour: 22, minute: 10, provider: provider)

        var removeCount = await provider.removeCount
        var scheduledRequests = await provider.scheduledRequests
        XCTAssertEqual(removeCount, 2)
        XCTAssertEqual(scheduledRequests.count, 1)
        XCTAssertEqual(scheduledRequests[0].hour, 22)

        await DailyReminderService.disable(provider: provider)
        scheduledRequests = await provider.scheduledRequests
        removeCount = await provider.removeCount
        XCTAssertTrue(scheduledRequests.isEmpty)
        XCTAssertEqual(removeCount, 3)
    }
}

private actor ReminderProviderStub: DailyReminderNotificationProviding {
    var status: NotificationAuthorizationState
    let requestResult: NotificationAuthorizationState
    private(set) var requestCount = 0
    private(set) var removeCount = 0
    private(set) var scheduledRequests: [DailyReminderRequest] = []

    init(status: NotificationAuthorizationState, requestResult: NotificationAuthorizationState) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationState() async -> NotificationAuthorizationState { status }

    func requestAuthorization() async throws -> NotificationAuthorizationState {
        requestCount += 1
        status = requestResult
        return requestResult
    }

    func replaceDailyRequest(_ request: DailyReminderRequest) async throws {
        scheduledRequests = [request]
    }

    func removeDailyRequest(identifier: String) async {
        removeCount += 1
        scheduledRequests.removeAll { $0.identifier == identifier }
    }
}
