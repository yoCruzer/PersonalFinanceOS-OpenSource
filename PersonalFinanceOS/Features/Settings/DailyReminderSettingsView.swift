import SwiftUI
import UIKit

struct DailyReminderSettingsView: View {
    @AppStorage(DailyReminderPreferences.enabledKey) private var isEnabled =
        DailyReminderPreferences.defaultEnabled
    @AppStorage(DailyReminderPreferences.hourKey) private var hour =
        DailyReminderPreferences.defaultHour
    @AppStorage(DailyReminderPreferences.minuteKey) private var minute =
        DailyReminderPreferences.defaultMinute
    @State private var authorizationState: NotificationAuthorizationState = .unknown
    @State private var errorMessage: String?
    @State private var isUpdating = false
    @State private var selectedTime = Date()
    @State private var didLoadStoredTime = false

    var body: some View {
        Form {
            Section {
                Toggle("每日记账提醒", isOn: $isEnabled)
                .disabled(isUpdating)
                .accessibilityIdentifier("daily-reminder-toggle")

                DatePicker(
                    "提醒时间",
                    selection: $selectedTime,
                    displayedComponents: .hourAndMinute
                )
                .disabled(!isEnabled || isUpdating)
                .accessibilityIdentifier("daily-reminder-time")
            } footer: {
                Text("提醒只会显示温和的记账回顾文案，不包含金额、账户或余额。")
            }

            Section("通知权限") {
                LabeledContent("状态", value: authorizationLabel)
                if authorizationState == .denied {
                    Button("打开系统设置") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .accessibilityIdentifier("open-notification-settings")
                }
            }
        }
        .navigationTitle("每日记账提醒")
        .task { await refreshAndRepairIfNeeded() }
        .onChange(of: isEnabled) { _, newValue in
            guard didLoadStoredTime else { return }
            Task { await applyEnabledChange(newValue) }
        }
        .onChange(of: selectedTime) { _, value in
            guard didLoadStoredTime else { return }
            let components = Calendar.current.dateComponents([.hour, .minute], from: value)
            hour = components.hour ?? DailyReminderPreferences.defaultHour
            minute = components.minute ?? DailyReminderPreferences.defaultMinute
            guard isEnabled else { return }
            Task { await scheduleCurrentTime() }
        }
        .alert("无法更新提醒", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var authorizationLabel: String {
        switch authorizationState {
        case .notDetermined: "尚未请求"
        case .denied: "已拒绝"
        case .authorized: "已允许"
        case .provisional: "临时允许"
        case .ephemeral: "本次允许"
        case .unknown: "正在读取"
        }
    }

    private func applyEnabledChange(_ newValue: Bool) async {
        isUpdating = true
        defer { isUpdating = false }
        if newValue {
            await scheduleCurrentTime()
            isEnabled = authorizationState.permitsScheduling
        } else {
            await DailyReminderService.disable()
            authorizationState = await SystemNotificationProvider().authorizationState()
        }
    }

    private func scheduleCurrentTime() async {
        do {
            authorizationState = try await DailyReminderService.enable(hour: hour, minute: minute)
            if !authorizationState.permitsScheduling {
                isEnabled = false
            }
        } catch {
            isEnabled = false
            errorMessage = error.localizedDescription
        }
    }

    private func refreshAndRepairIfNeeded() async {
        selectedTime = Calendar.current.date(
            from: DateComponents(hour: hour, minute: minute)
        ) ?? Date()
        authorizationState = await SystemNotificationProvider().authorizationState()
        if isEnabled {
            await scheduleCurrentTime()
        }
        didLoadStoredTime = true
    }
}
