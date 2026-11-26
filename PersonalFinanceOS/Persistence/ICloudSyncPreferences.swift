import Foundation

/// Device configuration; deliberately absent from the ledger and semantic backups.
struct ICloudSyncPreferences {
    static let enabledKey = "icloudSyncEnabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
}
