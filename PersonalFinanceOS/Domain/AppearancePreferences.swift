import SwiftUI

enum AppAppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    static let defaultValue = AppAppearanceMode.system

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppFontSizePreference: String, CaseIterable {
    case system
    case standard
    case large
    case extraLarge

    static let defaultValue = AppFontSizePreference.system

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .standard: "标准"
        case .large: "较大"
        case .extraLarge: "特大"
        }
    }

    func resolved(systemSize: DynamicTypeSize) -> DynamicTypeSize {
        switch self {
        case .system: systemSize
        case .standard: .large
        case .large: .xLarge
        case .extraLarge: .xxxLarge
        }
    }
}

enum AppearancePreferences {
    static let modeKey = "appearance.mode"
    static let fontSizeKey = "appearance.fontSize"
}

struct AppearanceRootView<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var systemDynamicTypeSize
    @AppStorage(AppearancePreferences.modeKey) private var modeRaw =
        AppAppearanceMode.defaultValue.rawValue
    @AppStorage(AppearancePreferences.fontSizeKey) private var fontSizeRaw =
        AppFontSizePreference.defaultValue.rawValue

    let content: Content

    var body: some View {
        content
            .preferredColorScheme(mode.colorScheme)
            .environment(\.dynamicTypeSize, fontSize.resolved(systemSize: systemDynamicTypeSize))
    }

    private var mode: AppAppearanceMode {
        AppAppearanceMode(rawValue: modeRaw) ?? .defaultValue
    }

    private var fontSize: AppFontSizePreference {
        AppFontSizePreference(rawValue: fontSizeRaw) ?? .defaultValue
    }
}
