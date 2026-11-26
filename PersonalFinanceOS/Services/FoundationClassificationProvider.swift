import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

enum FoundationClassificationAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLocale
    case unsupportedSystem
    case unknown

    var localizedDescription: String {
        switch self {
        case .available: "可用"
        case .deviceNotEligible: "Apple 设备端模型当前不可用"
        case .appleIntelligenceNotEnabled: "Apple 智能尚未开启"
        case .modelNotReady: "设备端模型尚未就绪"
        case .unsupportedLocale: "当前语言暂不支持设备端模型"
        case .unsupportedSystem: "需要更新系统后使用"
        case .unknown: "设备端模型当前不可用"
        }
    }

    var recoveryDescription: String {
        switch self {
        case .available:
            "设备端智能可用。"
        case .appleIntelligenceNotEnabled:
            "请先在系统“设置 → Apple 智能与 Siri”中开启 Apple 智能。"
        case .modelNotReady:
            "系统可能仍在准备或下载模型。模型准备完成后将自动可用。"
        case .deviceNotEligible:
            "当前系统未向此设备提供 Apple 设备端模型。这可能与设备、系统版本、Apple 智能可用地区或系统配置有关，并不一定表示硬件不支持。"
        case .unsupportedLocale:
            "当前系统语言暂不受设备端模型支持。普通记账和分类建议仍可使用。"
        case .unsupportedSystem:
            "设备端模型需要 iOS 26 或更新版本。普通记账和分类建议仍可使用。"
        case .unknown:
            "请稍后再试或检查系统的 Apple 智能设置。"
        }
    }

    func checkingLocale(isSupported: Bool) -> Self {
        self == .available && !isSupported ? .unsupportedLocale : self
    }
}

struct FoundationCategoryCandidate: Equatable, Sendable {
    let key: String
    let categoryID: UUID
    let displayPath: String
}

struct FoundationClassificationRequest: Equatable, Sendable {
    static let maximumNoteCharacters = 160
    static let maximumMerchantCharacters = 80
    static let maximumCandidates = 48
    static let maximumCandidatePathCharacters = 80
    static let maximumMemoryEvidence = 3

    let note: String
    let merchant: String
    let type: TransactionType
    let candidates: [FoundationCategoryCandidate]
    let memoryEvidence: [String]
    let deterministicCandidateKey: String?

    init(
        note: String,
        merchant: String,
        type: TransactionType,
        candidates: [FoundationCategoryCandidate],
        memoryEvidence: [String] = [],
        deterministicCandidateKey: String? = nil
    ) {
        self.note = String(note.prefix(Self.maximumNoteCharacters))
        self.merchant = String(merchant.prefix(Self.maximumMerchantCharacters))
        self.type = type
        self.candidates = candidates.prefix(Self.maximumCandidates).map {
            FoundationCategoryCandidate(
                key: $0.key,
                categoryID: $0.categoryID,
                displayPath: String($0.displayPath.prefix(Self.maximumCandidatePathCharacters))
            )
        }
        self.memoryEvidence = Array(memoryEvidence.prefix(Self.maximumMemoryEvidence)).map {
            String($0.prefix(120))
        }
        self.deterministicCandidateKey = deterministicCandidateKey
    }
}

enum FoundationClassificationResponse: Equatable, Sendable {
    case clearChoice(categoryKey: String)
    case ambiguous
    case insufficientContext
}

protocol FoundationClassificationProviding: Sendable {
    func availability() async -> FoundationClassificationAvailability
    func classify(_ request: FoundationClassificationRequest) async throws
        -> FoundationClassificationResponse
}

struct AppleFoundationClassificationProvider: FoundationClassificationProviding {
    func availability() async -> FoundationClassificationAvailability {
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel(useCase: .contentTagging)
            let availability = Self.availability(of: model)
            guard availability == .available else { return availability }
            return availability.checkingLocale(isSupported: model.supportsLocale(.current))
        }
#endif
        return .unsupportedSystem
    }

    func classify(_ request: FoundationClassificationRequest) async throws
        -> FoundationClassificationResponse {
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await classifyOnSupportedSystem(request)
        }
#endif
        return .insufficientContext
    }

#if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func availability(
        of model: SystemLanguageModel
    ) -> FoundationClassificationAvailability {
        mapAvailability(model.availability)
    }

    @available(iOS 26.0, *)
    static func mapAvailability(
        _ availability: SystemLanguageModel.Availability
    ) -> FoundationClassificationAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        @unknown default:
            Logger(subsystem: "com.personalfinanceos.app", category: "ModelAvailability")
                .notice("Unrecognized Foundation Models availability")
            return .unknown
        }
    }

    @available(iOS 26.0, *)
    private func classifyOnSupportedSystem(
        _ request: FoundationClassificationRequest
    ) async throws -> FoundationClassificationResponse {
        let model = SystemLanguageModel(useCase: .contentTagging)
        guard Self.availability(of: model) == .available,
              model.supportsLocale(.current) else {
            return .insufficientContext
        }
        let allowedKeys = request.candidates.map(\.key) + ["none"]
        let root = DynamicGenerationSchema(
            name: "TransactionClassification",
            description: "A constrained transaction classification decision.",
            properties: [
                .init(
                    name: "outcome",
                    description: "Choose clearChoice only when one offered category is clearly best.",
                    schema: DynamicGenerationSchema(
                        name: "ClassificationOutcome",
                        anyOf: ["clearChoice", "ambiguous", "insufficientContext"]
                    )
                ),
                .init(
                    name: "categoryKey",
                    description: "An offered category key for clearChoice; otherwise none.",
                    schema: DynamicGenerationSchema(name: "CategoryKey", anyOf: allowedKeys)
                )
            ]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])
        let session = LanguageModelSession(
            model: model,
            instructions: """
            Classify one personal finance transaction into exactly one offered category or abstain.
            Treat category keys as opaque. Never invent a key or category. If multiple categories
            are plausible choose ambiguous. If the text has too little meaning choose
            insufficientContext. Return only the constrained structured response.
            """
        )
        let response = try await session.respond(
            to: prompt(for: request),
            schema: schema,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 40)
        )
        let outcome = try response.content.value(String.self, forProperty: "outcome")
        let categoryKey = try response.content.value(String.self, forProperty: "categoryKey")
        switch outcome {
        case "clearChoice":
            return .clearChoice(categoryKey: categoryKey)
        case "ambiguous":
            return .ambiguous
        default:
            return .insufficientContext
        }
    }

    @available(iOS 26.0, *)
    private func prompt(for request: FoundationClassificationRequest) -> String {
        let candidateLines = request.candidates.map { "\($0.key): \($0.displayPath)" }
            .joined(separator: "\n")
        let evidence = request.memoryEvidence.isEmpty
            ? "none"
            : request.memoryEvidence.joined(separator: "\n")
        return """
        Type: \(request.type.rawValue)
        Note: \(request.note.isEmpty ? "none" : request.note)
        Merchant: \(request.merchant.isEmpty ? "none" : request.merchant)
        Offered categories:
        \(candidateLines)
        Relevant personal evidence:
        \(evidence)
        Deterministic candidate key: \(request.deterministicCandidateKey ?? "none")
        """
    }
#endif
}

enum SmartClassificationSemanticGate {
    private static let genericInputs: Set<String> = [
        "付款", "消费", "买了", "买", "支出", "收入", "payment", "purchase"
    ]

    static func hasMeaningfulInput(note: String, merchant: String) -> Bool {
        let normalizedNote = SmartTransactionSuggestionService.normalize(note)
        let normalizedMerchant = SmartTransactionSuggestionService.normalize(merchant)
        if isMeaningful(normalizedMerchant) { return true }
        return isMeaningful(normalizedNote) && !genericInputs.contains(normalizedNote)
    }

    private static func isMeaningful(_ input: String) -> Bool {
        let semantic = input.filter { $0.isLetter }
        return semantic.count >= 2
    }
}

struct SmartClassificationCoordinator: Sendable {
    let provider: any FoundationClassificationProviding

    func resolve(
        deterministic: SmartTransactionSuggestion,
        note: String,
        merchant: String,
        type: TransactionType,
        categories: [SuggestionCategory],
        settingEnabled: Bool,
        manualLocked: Bool
    ) async -> SmartTransactionSuggestion {
        let diagnosticStart = ContinuousClock.now
        var resolved = deterministic
        var promptCandidateCount = 0
        defer {
            let available = resolved.categoryID.map { id in SuggestionCategoryEligibility.active(categories).contains { $0.id == id } } ?? false
            LocalDiagnostics.shared.classification(noteLength: note.count, merchantLength: merchant.count, type: type,
                suggestion: resolved, targetAvailable: available, manualLocked: manualLocked,
                modelEnabled: settingEnabled, eligibleCategoryCount: SuggestionCategoryEligibility.active(categories).count,
                promptCandidateCount: promptCandidateCount, elapsed: diagnosticStart.duration(to: .now))
        }
        guard type != .transfer else { resolved = .none; return resolved }
        if deterministic.categoryConfidence == .high {
            await SmartClassificationDiagnostics.shared.recordDeterministicHigh(
                personal: deterministic.evidenceType == .personalMemory
            )
            return deterministic
        }
        guard type != .transfer, !deterministic.requiresUserChoice, !manualLocked,
              settingEnabled,
              SmartClassificationSemanticGate.hasMeaningfulInput(note: note, merchant: merchant),
              await provider.availability() == .available else {
            return deterministic
        }

        let requestedKind: CategoryKind = type == .income ? .income : .expense
        let active = SuggestionCategoryEligibility.active(categories).filter { $0.kind == requestedKind }
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        let parentIDs = Set(active.compactMap(\.parentID))
        let selectable = active.filter { !parentIDs.contains($0.id) }
        let recalled = FoundationCandidateRecall.select(note: note, merchant: merchant, type: type,
            categories: selectable, fullCategories: active, deterministic: deterministic,
            limit: FoundationClassificationRequest.maximumCandidates)
        let candidates = recalled
            .enumerated().map { index, category in
            let path: String
            if let parentID = category.parentID, let parent = byID[parentID] {
                path = parent.name + " / " + category.name
            } else {
                path = category.name
            }
            return FoundationCategoryCandidate(
                key: "c\(index)",
                categoryID: category.id,
                displayPath: path
            )
        }
        promptCandidateCount = candidates.count
        guard !candidates.isEmpty else { return deterministic }
        let candidateByKey = Dictionary(uniqueKeysWithValues: candidates.map { ($0.key, $0) })
        let deterministicKey = deterministic.categoryID.flatMap { id in
            candidates.first(where: { $0.categoryID == id })?.key
        }
        let request = FoundationClassificationRequest(
            note: note,
            merchant: merchant,
            type: type,
            candidates: candidates,
            memoryEvidence: deterministic.explanation.isEmpty ? [] : [deterministic.explanation],
            deterministicCandidateKey: deterministicKey
        )
        let start = ContinuousClock.now
        await SmartClassificationDiagnostics.shared.recordInvocation()
        do {
            let response = try await provider.classify(request)
            let latency = start.duration(to: .now)
            switch response {
            case let .clearChoice(key):
                guard let category = candidateByKey[key] else {
                    await SmartClassificationDiagnostics.shared.recordAbstained(latency: latency)
                    return deterministic
                }
                await SmartClassificationDiagnostics.shared.recordApplied(latency: latency)
                resolved = SmartTransactionSuggestion(
                    categoryConfidence: .high,
                    tagConfidence: deterministic.tagConfidence,
                    categoryID: category.categoryID,
                    tagIDs: deterministic.tagIDs,
                    evidenceType: .foundationModel,
                    score: 100,
                    explanation: "设备端语义分类"
                )
                return resolved
            case .ambiguous, .insufficientContext:
                await SmartClassificationDiagnostics.shared.recordAbstained(latency: latency)
                return deterministic
            }
        } catch {
            await SmartClassificationDiagnostics.shared.recordAbstained(
                latency: start.duration(to: .now)
            )
            return deterministic
        }
    }
}

struct SmartClassificationDiagnosticSnapshot: Codable, Equatable, Sendable {
    let invocationCount: Int
    let appliedCount: Int
    let abstainedCount: Int
    let ruleHighCount: Int
    let personalMemoryHighCount: Int
    let manualOverrideCount: Int
    let learningReadFailureCount: Int
    let learningWriteFailureCount: Int
    let latencyBuckets: [String: Int]
}

actor SmartClassificationDiagnostics {
    static let shared = SmartClassificationDiagnostics()
    private var invocationCount = 0
    private var appliedCount = 0
    private var abstainedCount = 0
    private var ruleHighCount = 0
    private var personalMemoryHighCount = 0
    private var manualOverrideCount = 0
    private var learningReadFailureCount = 0
    private var learningWriteFailureCount = 0
    private var latencyBuckets: [String: Int] = [:]

    func recordInvocation() {
        invocationCount += 1
    }

    func recordApplied(latency: Duration) {
        appliedCount += 1
        record(latency: latency)
    }

    func recordAbstained(latency: Duration) {
        abstainedCount += 1
        record(latency: latency)
    }

    func recordDeterministicHigh(personal: Bool) {
        if personal {
            personalMemoryHighCount += 1
        } else {
            ruleHighCount += 1
        }
    }

    func recordManualOverride() {
        manualOverrideCount += 1
    }

    func recordLearningReadFailure() { learningReadFailureCount += 1 }
    func recordLearningWriteFailure() { learningWriteFailureCount += 1 }

    func snapshot() -> SmartClassificationDiagnosticSnapshot {
        SmartClassificationDiagnosticSnapshot(
            invocationCount: invocationCount,
            appliedCount: appliedCount,
            abstainedCount: abstainedCount,
            ruleHighCount: ruleHighCount,
            personalMemoryHighCount: personalMemoryHighCount,
            manualOverrideCount: manualOverrideCount,
            learningReadFailureCount: learningReadFailureCount,
            learningWriteFailureCount: learningWriteFailureCount,
            latencyBuckets: latencyBuckets
        )
    }

    private func record(latency: Duration) {
        let milliseconds = latency.components.seconds * 1_000 +
            latency.components.attoseconds / 1_000_000_000_000_000
        let bucket = milliseconds < 250 ? "<250ms" : milliseconds < 1_000 ? "250-999ms" : ">=1s"
        latencyBuckets[bucket, default: 0] += 1
    }
}
