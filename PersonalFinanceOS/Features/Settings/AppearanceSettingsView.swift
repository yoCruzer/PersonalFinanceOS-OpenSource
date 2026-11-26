import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(AppearancePreferences.modeKey) private var modeRaw =
        AppAppearanceMode.defaultValue.rawValue
    @AppStorage(AppearancePreferences.fontSizeKey) private var fontSizeRaw =
        AppFontSizePreference.defaultValue.rawValue

    var body: some View {
        Form {
            Section("显示模式") {
                Picker("显示模式", selection: $modeRaw) {
                    ForEach(AppAppearanceMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("appearance-mode-picker")
            }

            Section("字体大小") {
                Picker("字体大小", selection: $fontSizeRaw) {
                    ForEach(AppFontSizePreference.allCases, id: \.rawValue) { size in
                        Text(size.title).tag(size.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("font-size-picker")
            }

            Section {
                Text("金额与主要操作会优先保持完整；较大字体下页面可滚动。")
                    .font(.body)
            } header: {
                Text("预览")
            }
        }
        .navigationTitle("外观")
    }
}
