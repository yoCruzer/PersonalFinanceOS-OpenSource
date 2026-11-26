import Foundation
import Observation

@MainActor
@Observable
final class RecordedExpenseComparisonStore {
    private(set) var comparison: RecordedExpenseComparison?

    private var generation = UUID()

    @discardableResult
    func begin() -> UUID {
        generation = UUID()
        comparison = nil
        return generation
    }

    func clear() { begin() }

    func reload(request: UUID? = nil, query: () async throws -> RecordedExpenseComparison?,
                accepts: (RecordedExpenseComparison) -> Bool) async {
        let owner = request ?? begin()
        guard generation == owner else { return }
        do {
            guard let result = try await query() else { return }
            try Task.checkCancellation()
            try LedgerSaveRevision.shared.withProjectionBoundary {
                guard generation == owner, accepts(result) else { throw LedgerAnalysisError.staleSnapshot }
                comparison = result
            }
        } catch {
            if generation == owner, !Task.isCancelled { comparison = nil }
        }
    }
}
