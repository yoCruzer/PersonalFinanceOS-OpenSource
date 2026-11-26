import CryptoKit
import XCTest
@testable import PersonalFinanceOS

final class ClassificationFrozenEvaluationTests: XCTestCase {
    private struct Dataset: Decodable {
        struct Item: Decodable {
            let id: String
            let cohort: String
            let type: TransactionType
            let note: String
            let merchant: String
            let expectedSemanticKeys: [String]
            let mustNotAutoApply: Bool
        }
        let cases: [Item]
    }

    private struct Row: Codable {
        let id: String
        let cohort: String
        let expected: [String]
        let selected: String?
        let confidence: String
        let score: Int
        let automatic: Bool
        let correctAutomatic: Bool
        let targetAvailable: Bool
        let deterministicRecall: Bool
        let providerRecall: Bool
    }

    private struct Slice: Codable {
        var count = 0
        var automatic = 0
        var correctAutomatic = 0
    }

    private struct Report: Codable {
        let implementation: String
        let datasetSHA256: String
        let catalogNodeCount: Int
        let clearCount: Int
        let clearAutomatic: Int
        let clearCorrectAutomatic: Int
        let clearCorrectAutomaticCoverage: Double
        let allAutomatic: Int
        let allAutomaticPrecision: Double
        let ambiguityCount: Int
        let ambiguityAutomatic: Int
        let ambiguityAutomaticRate: Double
        let availableClearTargets: Int
        let clearDeterministicRecall: Int
        let clearProviderRecall: Int
        let rootSlices: [String: Slice]
        let rows: [Row]
    }

    func testFrozenSyntheticClassificationGate() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "classification-evaluation-v1", withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "classification-evaluation-v1", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "7b75660eae6f0d64908882e701ff59568e34b4366c20049e1973bee860a2a603")
        let dataset = try JSONDecoder().decode(Dataset.self, from: data)
        let definitions = try CategoryCatalog.load().definitions
        let ids = Dictionary(uniqueKeysWithValues: definitions.enumerated().map {
            ($0.element.semanticKey, UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0.offset + 1))!)
        })
        let semanticByID = Dictionary(uniqueKeysWithValues: ids.map { ($0.value, $0.key) })
        let categories = definitions.map {
            SuggestionCategory(id: ids[$0.semanticKey]!, name: $0.name, kind: $0.kind, isActive: true,
                parentID: $0.parentSemanticKey.flatMap { ids[$0] }, defaultDefinitionKey: $0.storageDefaultKey)
        }
        let rows = dataset.cases.map { item in
            let result = SmartTransactionSuggestionService.suggest(note: item.note, merchant: item.merchant,
                type: item.type, categories: categories, tags: [], history: [])
            let selected = result.categoryID.flatMap { semanticByID[$0] }
            let automatic = result.categoryConfidence == .high && selected != nil
            let recalled = FoundationCandidateRecall.select(note: item.note, merchant: item.merchant, type: item.type,
                categories: categories.filter { $0.parentID != nil }, fullCategories: categories,
                deterministic: result, limit: 48)
            return Row(id: item.id, cohort: item.cohort, expected: item.expectedSemanticKeys,
                selected: selected, confidence: result.categoryConfidence == .high ? "high" : (result.categoryConfidence == .medium ? "medium" : "low"),
                score: result.score, automatic: automatic,
                correctAutomatic: automatic && selected.map(item.expectedSemanticKeys.contains) == true && !item.mustNotAutoApply,
                targetAvailable: item.expectedSemanticKeys.contains { ids[$0] != nil },
                deterministicRecall: result.alternatives.contains { semanticByID[$0.categoryID].map(item.expectedSemanticKeys.contains) == true },
                providerRecall: recalled.contains { semanticByID[$0.id].map(item.expectedSemanticKeys.contains) == true })
        }
        let clear = rows.filter { $0.cohort == "clear" }
        let ambiguous = rows.filter { $0.cohort == "ambiguous" }
        let automatic = rows.filter(\.automatic)
        var slices: [String: Slice] = [:]
        for row in clear {
            let root = row.expected[0].split(separator: ".").prefix(2).joined(separator: ".")
            slices[root, default: Slice()].count += 1
            if row.automatic { slices[root, default: Slice()].automatic += 1 }
            if row.correctAutomatic { slices[root, default: Slice()].correctAutomatic += 1 }
        }
        let report = Report(implementation: "candidate-v4-local-rules-v1-no-model-empty-history", datasetSHA256: hash,
            catalogNodeCount: categories.count, clearCount: clear.count, clearAutomatic: clear.filter(\.automatic).count,
            clearCorrectAutomatic: clear.filter(\.correctAutomatic).count,
            clearCorrectAutomaticCoverage: Double(clear.filter(\.correctAutomatic).count) / Double(clear.count),
            allAutomatic: automatic.count,
            allAutomaticPrecision: automatic.isEmpty ? 0 : Double(automatic.filter(\.correctAutomatic).count) / Double(automatic.count),
            ambiguityCount: ambiguous.count, ambiguityAutomatic: ambiguous.filter(\.automatic).count,
            ambiguityAutomaticRate: Double(ambiguous.filter(\.automatic).count) / Double(ambiguous.count),
            availableClearTargets: clear.filter(\.targetAvailable).count,
            clearDeterministicRecall: clear.filter(\.deterministicRecall).count,
            clearProviderRecall: clear.filter(\.providerRecall).count, rootSlices: slices, rows: rows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print("PFOS_CLASSIFICATION_REPORT=" + (try encoder.encode(report)).base64EncodedString())
        XCTAssertEqual(rows.count, 249)
        XCTAssertGreaterThanOrEqual(report.clearCorrectAutomaticCoverage, 0.8)
        XCTAssertGreaterThanOrEqual(report.allAutomaticPrecision, 0.98)
        XCTAssertEqual(report.ambiguityAutomatic, 0)
    }
}
