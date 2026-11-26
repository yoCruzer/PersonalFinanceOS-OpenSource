import Foundation
@preconcurrency import UserNotifications

enum NotificationAuthorizationState: String, Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown

    var permitsScheduling: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }
}

struct DailyReminderRequest: Equatable, Sendable {
    let identifier: String
    let hour: Int
    let minute: Int
    let title: String
    let body: String
}

protocol DailyReminderNotificationProviding: Sendable {
    func authorizationState() async -> NotificationAuthorizationState
    func requestAuthorization() async throws -> NotificationAuthorizationState
    func replaceDailyRequest(_ request: DailyReminderRequest) async throws
    func removeDailyRequest(identifier: String) async
}

enum DailyReminderPreferences {
    static let enabledKey = "dailyReminder.enabled"
    static let hourKey = "dailyReminder.hour"
    static let minuteKey = "dailyReminder.minute"
    static let defaultEnabled = false
    static let defaultHour = 21
    static let defaultMinute = 0
}

enum DailyReminderService {
    static let requestIdentifier = "personalfinanceos.daily-review-reminder"

    static func enable(
        hour: Int,
        minute: Int,
        provider: any DailyReminderNotificationProviding = SystemNotificationProvider()
    ) async throws -> NotificationAuthorizationState {
        var state = await provider.authorizationState()
        if state == .notDetermined {
            state = try await provider.requestAuthorization()
        }
        guard state.permitsScheduling else { return state }

        await provider.removeDailyRequest(identifier: requestIdentifier)
        try await provider.replaceDailyRequest(DailyReminderRequest(
            identifier: requestIdentifier,
            hour: min(max(hour, 0), 23),
            minute: min(max(minute, 0), 59),
            title: "今天的账记完整了吗？",
            body: "花一分钟回顾今天的收入和支出。"
        ))
        return state
    }

    static func disable(
        provider: any DailyReminderNotificationProviding = SystemNotificationProvider()
    ) async {
        await provider.removeDailyRequest(identifier: requestIdentifier)
    }
}

struct SystemNotificationProvider: DailyReminderNotificationProviding {
    private let center = UNUserNotificationCenter.current()

    func authorizationState() async -> NotificationAuthorizationState {
        let settings = await center.notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    func requestAuthorization() async throws -> NotificationAuthorizationState {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return await authorizationState()
    }

    func replaceDailyRequest(_ request: DailyReminderRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: DateComponents(hour: request.hour, minute: request.minute),
            repeats: true
        )
        try await center.add(UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        ))
    }

    func removeDailyRequest(identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unknown
        }
    }
}
