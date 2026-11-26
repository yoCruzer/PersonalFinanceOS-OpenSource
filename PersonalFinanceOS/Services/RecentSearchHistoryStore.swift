import Foundation
import Observation

@MainActor
@Observable
final class RecentSearchHistoryStore {
    static let storageKey = "transactionRecentSearches"
    static let maximumCount = 10

    private(set) var values: [String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = defaults.stringArray(forKey: Self.storageKey) ?? []
    }

    @discardableResult
    func submit(_ query: String) -> String? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        values.removeAll { $0.compare(normalized, options: .caseInsensitive) == .orderedSame }
        values.insert(normalized, at: 0)
        if values.count > Self.maximumCount {
            values.removeLast(values.count - Self.maximumCount)
        }
        persist()
        return normalized
    }

    func clear() {
        values = []
        persist()
    }

    private func persist() {
        defaults.set(values, forKey: Self.storageKey)
    }
}
