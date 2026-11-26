import CryptoKit
import Foundation

enum ClassificationLearningSource: String, Codable, Sendable {
    case explicitCorrection
    case manualChoice
    case automaticAccepted
    case historicalBootstrap
    case importedBootstrap

    var strength: Double {
        switch self {
        case .explicitCorrection: 4
        case .manualChoice: 2.5
        case .automaticAccepted: 0.5
        case .historicalBootstrap: 0.3
        case .importedBootstrap: 0.15
        }
    }

    var isStrong: Bool {
        self == .explicitCorrection || self == .manualChoice
    }
}

struct ClassificationLearningEvent: Codable, Equatable, Sendable {
    private static let maximumNoteCharacters = 96
    private static let maximumMerchantCharacters = 96

    let transactionID: UUID
    let recordedAt: Date
    let type: TransactionType
    let normalizedNote: String
    let normalizedMerchant: String
    let categoryID: UUID
    let rejectedCategoryID: UUID?
    let source: ClassificationLearningSource
    /// Local-only verification of the complete normalized input; never diagnostic output.
    let inputFingerprint: String?

    init(
        transactionID: UUID,
        recordedAt: Date,
        type: TransactionType,
        note: String,
        merchant: String,
        categoryID: UUID,
        rejectedCategoryID: UUID?,
        source: ClassificationLearningSource
    ) {
        self.transactionID = transactionID
        self.recordedAt = recordedAt
        self.type = type
        normalizedNote = String(
            SmartTransactionSuggestionService.normalize(note).prefix(Self.maximumNoteCharacters)
        )
        normalizedMerchant = String(
            SmartTransactionSuggestionService.normalize(merchant).prefix(Self.maximumMerchantCharacters)
        )
        self.categoryID = categoryID
        self.rejectedCategoryID = rejectedCategoryID
        self.source = source
        inputFingerprint = Self.fingerprint(note: note, merchant: merchant)
    }

    static func fingerprint(note: String, merchant: String) -> String {
        let note = SmartTransactionSuggestionService.normalize(note)
        let merchant = SmartTransactionSuggestionService.normalize(merchant)
        let data = Data("\(note.utf8.count):\(note)\(merchant.utf8.count):\(merchant)".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func matchesInput(note: String, merchant: String) -> Bool {
        if let inputFingerprint {
            return inputFingerprint == Self.fingerprint(note: note, merchant: merchant)
        }
        // V1 events at the truncation boundary cannot prove their original full input.
        guard normalizedNote.count < Self.maximumNoteCharacters,
              normalizedMerchant.count < Self.maximumMerchantCharacters else { return false }
        return normalizedNote == SmartTransactionSuggestionService.normalize(note)
            && normalizedMerchant == SmartTransactionSuggestionService.normalize(merchant)
    }
}

enum ClassificationEventLookup: Sendable {
    case present(SuggestionHistory)
    case missing
    case unknown
}

enum ClassificationEventValidity: Equatable, Sendable {
    case existsMatching, existsChanged, deletedOrMissingConfirmed, lookupUnknown

    static func evaluate(_ event: ClassificationLearningEvent, lookup: ClassificationEventLookup) -> Self {
        switch lookup {
        case .unknown: return .lookupUnknown
        case .missing: return .deletedOrMissingConfirmed
        case let .present(current):
            guard !current.isDeleted else { return .deletedOrMissingConfirmed }
            guard current.type == event.type, current.categoryID == event.categoryID,
                  current.id == event.transactionID,
                  event.matchesInput(note: current.note, merchant: current.merchant) else { return .existsChanged }
            return .existsMatching
        }
    }
}

enum ClassificationFeatureKind: String, Hashable, Sendable {
    case exactNote
    case merchantPhrase
    case merchant
    case phrase
    case token
    case cjkBigram
    case cjkTrigram
}

struct ClassificationFeature: Hashable, Sendable {
    let kind: ClassificationFeatureKind
    let value: String
}

enum ClassificationFeatureExtractor {
    private static let maximumInputCharacters = 96
    private static let maximumNGramsPerSize = 24

    static func features(note: String, merchant: String) -> [ClassificationFeature] {
        let fullNote = SmartTransactionSuggestionService.normalize(note)
        let fullMerchant = SmartTransactionSuggestionService.normalize(merchant)
        let normalizedNote = String(fullNote.prefix(maximumInputCharacters))
        let normalizedMerchant = String(fullMerchant.prefix(maximumInputCharacters))
        var features: [ClassificationFeature] = []

        if !normalizedNote.isEmpty {
            features.append(.init(kind: .exactNote, value: boundedIdentity(fullNote)))
            features.append(.init(kind: .phrase, value: normalizedNote))
            features.append(contentsOf: tokens(in: note).map {
                ClassificationFeature(kind: .token, value: $0)
            })
            features.append(contentsOf: cjkNGrams(in: normalizedNote, length: 2).map {
                ClassificationFeature(kind: .cjkBigram, value: $0)
            })
            features.append(contentsOf: cjkNGrams(in: normalizedNote, length: 3).map {
                ClassificationFeature(kind: .cjkTrigram, value: $0)
            })
        }

        if !normalizedMerchant.isEmpty {
            features.append(.init(kind: .merchant, value: boundedIdentity(fullMerchant)))
            if !normalizedNote.isEmpty {
                features.append(.init(
                    kind: .merchantPhrase,
                    value: boundedIdentity(fullMerchant) + "|" + boundedIdentity(fullNote)
                ))
            }
        }
        return Array(Set(features))
    }

    private static func boundedIdentity(_ normalized: String) -> String {
        guard normalized.count > maximumInputCharacters else { return normalized }
        return "sha256:" + SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func tokens(in text: String) -> [String] {
        let folded = text.lowercased().precomposedStringWithCanonicalMapping
        let pieces = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return pieces.compactMap { piece in
            let normalized = SmartTransactionSuggestionService.normalize(piece)
            guard normalized.count >= 2 else { return nil }
            return String(normalized.prefix(maximumInputCharacters))
        }
    }

    private static func cjkNGrams(in text: String, length: Int) -> [String] {
        let cjk = text.filter { character in
            character.unicodeScalars.contains { scalar in
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x4E00...0x9FFF).contains(scalar.value)
            }
        }
        guard cjk.count >= length else { return [] }
        var values: [String] = []
        var start = cjk.startIndex
        while let end = cjk.index(start, offsetBy: length, limitedBy: cjk.endIndex),
              values.count < maximumNGramsPerSize {
            values.append(String(cjk[start..<end]))
            guard start < cjk.endIndex else { break }
            start = cjk.index(after: start)
        }
        return values
    }
}

struct ClassificationProfile: Sendable {
    struct Statistics: Sendable {
        var rawSupport = 0
        var strongSupport = 0
        var positiveWeight = 0.0
        var negativeWeight = 0.0
        var latestAt = Date.distantPast
        var tagWeights: [UUID: Double] = [:]
        var strongestSource = ClassificationLearningSource.importedBootstrap
    }

    struct Key: Hashable, Sendable {
        let type: TransactionType
        let feature: ClassificationFeature
    }

    let statistics: [Key: [UUID: Statistics]]
    let sampleCount: Int

    static let empty = ClassificationProfile(statistics: [:], sampleCount: 0)

    func candidates(
        note: String,
        merchant: String,
        type: TransactionType,
        activeCategoryIDs: Set<UUID>
    ) -> [ClassificationProfileCandidate] {
        let queryFeatures = ClassificationFeatureExtractor.features(note: note, merchant: merchant)
        var bestByCategory: [UUID: ClassificationProfileCandidate] = [:]
        var bestFeatureKindByCategory: [UUID: ClassificationFeatureKind] = [:]
        var matchingNGramCounts: [UUID: Int] = [:]

        for feature in queryFeatures {
            guard let distribution = statistics[Key(type: type, feature: feature)] else { continue }
            let total = distribution.values.reduce(0.0) { $0 + max(0, $1.positiveWeight - $1.negativeWeight) }
            guard total > 0 else { continue }
            for (categoryID, stats) in distribution where activeCategoryIDs.contains(categoryID) {
                let effectiveWeight = max(0, stats.positiveWeight - stats.negativeWeight)
                guard effectiveWeight > 0 else { continue }
                let purity = effectiveWeight / total
                guard let score = score(feature: feature, stats: stats, purity: purity) else {
                    continue
                }
                if feature.kind == .cjkBigram || feature.kind == .cjkTrigram {
                    matchingNGramCounts[categoryID, default: 0] += 1
                }
                let tagIDs = Set(stats.tagWeights.compactMap { id, weight in
                    weight >= stats.positiveWeight * 0.5 ? id : nil
                })
                let candidate = ClassificationProfileCandidate(
                    categoryID: categoryID,
                    score: score,
                    latestAt: stats.latestAt,
                    tagIDs: tagIDs,
                    explanation: explanation(feature: feature.kind, support: stats.rawSupport)
                )
                if candidate.score > (bestByCategory[categoryID]?.score ?? -1) {
                    bestByCategory[categoryID] = candidate
                    bestFeatureKindByCategory[categoryID] = feature.kind
                }
            }
        }

        for (categoryID, count) in matchingNGramCounts where count >= 2 {
            guard let featureKind = bestFeatureKindByCategory[categoryID],
                  (featureKind == .cjkBigram || featureKind == .cjkTrigram),
                  var candidate = bestByCategory[categoryID], candidate.score < 90 else { continue }
            candidate = ClassificationProfileCandidate(
                categoryID: candidate.categoryID,
                score: min(96, candidate.score + min(12, (count - 1) * 3)),
                latestAt: candidate.latestAt,
                tagIDs: candidate.tagIDs,
                explanation: candidate.explanation
            )
            bestByCategory[categoryID] = candidate
        }
        return Array(bestByCategory.values)
    }

    private func score(
        feature: ClassificationFeature,
        stats: Statistics,
        purity: Double
    ) -> Int? {
        switch feature.kind {
        case .exactNote:
            if stats.strongestSource == .explicitCorrection && purity >= 0.55 { return 125 }
            if stats.strongSupport >= 2 && purity >= 0.65 { return 108 }
            if stats.strongSupport >= 1 && purity >= 0.65 { return 84 }
            if stats.rawSupport >= 2 && purity >= 0.8 { return 72 }
        case .merchantPhrase:
            if stats.strongSupport >= 2 && purity >= 0.8 { return 106 }
            if stats.strongSupport >= 1 && purity >= 0.65 { return 80 }
        case .merchant:
            if stats.strongSupport >= 3 && purity >= 0.88 { return 98 }
            if stats.strongSupport >= 2 && purity >= 0.8 { return 76 }
        case .phrase:
            if stats.strongSupport >= 2 && purity >= 0.9 { return 96 }
            if stats.strongSupport >= 1 && purity >= 0.75 { return 68 }
        case .token:
            if stats.rawSupport >= 3 && stats.strongSupport >= 2 && purity >= 0.9 { return 90 }
        case .cjkBigram, .cjkTrigram:
            if stats.rawSupport >= 3 && stats.strongSupport >= 2 && purity >= 0.92 { return 78 }
        }
        return nil
    }

    private func explanation(feature: ClassificationFeatureKind, support: Int) -> String {
        switch feature {
        case .exactNote: "参考个人相同备注（\(support) 次）"
        case .merchantPhrase: "参考个人商户与备注组合（\(support) 次）"
        case .merchant: "参考高一致性的个人商户记录（\(support) 次）"
        case .phrase, .token: "参考个人常用表达（\(support) 次）"
        case .cjkBigram, .cjkTrigram: "参考相似中文表达（\(support) 次）"
        }
    }
}

struct ClassificationProfileCandidate: Sendable {
    let categoryID: UUID
    let score: Int
    let latestAt: Date
    let tagIDs: Set<UUID>
    let explanation: String
}

enum ClassificationProfileBuilder {
    static func build(
        history: [SuggestionHistory],
        events: [ClassificationLearningEvent],
        eventLookups: [UUID: ClassificationEventLookup] = [:],
        eligibleCategoryIDs: Set<UUID>? = nil,
        now: Date = Date()
    ) -> ClassificationProfile {
        let diagnosticStart = ContinuousClock.now
        var validity = LocalDiagnostics.ProfileCounts()
        var table: [ClassificationProfile.Key: [UUID: ClassificationProfile.Statistics]] = [:]
        let historyByID = Dictionary(grouping: history, by: \.id).compactMapValues(\.first)
        var currentEvents: [UUID: (ClassificationLearningEvent, SuggestionHistory)] = [:]
        for event in events {
            if Task.isCancelled { return .empty }
            guard eligibleCategoryIDs?.contains(event.categoryID) != false else { validity.ineligible += 1; continue }
            let lookup = eventLookups[event.transactionID]
                ?? historyByID[event.transactionID].map(ClassificationEventLookup.present) ?? .unknown
            switch ClassificationEventValidity.evaluate(event, lookup: lookup) {
            case .existsChanged: validity.changed += 1; continue
            case .deletedOrMissingConfirmed: validity.missing += 1; continue
            case .lookupUnknown: validity.unknown += 1; continue
            case .existsMatching: break
            }
            guard case let .present(current) = lookup else { continue }
            if let previous = currentEvents[event.transactionID] {
                validity.duplicates += 1
                if previous.0.recordedAt > event.recordedAt { continue }
            }
            currentEvents[event.transactionID] = (event, current)
        }
        let eventTransactionIDs = Set(currentEvents.keys)
        var sampleCount = 0

        for item in history where !eventTransactionIDs.contains(item.id) {
            if Task.isCancelled { return .empty }
            guard !item.isDeleted, let categoryID = item.categoryID,
                  eligibleCategoryIDs?.contains(categoryID) != false else { continue }
            let source: ClassificationLearningSource
            if item.decisionSource == .manualConfirmed {
                source = .manualChoice
            } else if item.isImported {
                source = .importedBootstrap
            } else {
                switch item.decisionSource {
                case .manualConfirmed: source = .manualChoice
                case .automaticAccepted: source = .automaticAccepted
                case .unchanged: source = .historicalBootstrap
                case .timePrior: continue
                }
            }
            add(
                type: item.type,
                note: item.note,
                merchant: item.merchant,
                categoryID: categoryID,
                rejectedCategoryID: nil,
                tagIDs: item.tagIDs,
                date: item.occurredAt,
                source: source,
                now: now,
                table: &table
            )
            sampleCount += 1
        }

        for (event, current) in currentEvents.values.sorted(by: { $0.0.transactionID.uuidString < $1.0.transactionID.uuidString }) {
            if Task.isCancelled { return .empty }
            add(
                type: event.type,
                note: current.note,
                merchant: current.merchant,
                categoryID: event.categoryID,
                rejectedCategoryID: event.rejectedCategoryID,
                tagIDs: current.tagIDs,
                date: event.recordedAt,
                source: event.source,
                now: now,
                table: &table
            )
            sampleCount += 1
        }
        validity.matched = currentEvents.count
        LocalDiagnostics.shared.profile(historyCount: history.count, eventCount: events.count,
            sampleCount: sampleCount, validity: validity, elapsed: diagnosticStart.duration(to: .now))
        return ClassificationProfile(statistics: table, sampleCount: sampleCount)
    }

    private static func add(
        type: TransactionType,
        note: String,
        merchant: String,
        categoryID: UUID,
        rejectedCategoryID: UUID?,
        tagIDs: Set<UUID>,
        date: Date,
        source: ClassificationLearningSource,
        now: Date,
        table: inout [ClassificationProfile.Key: [UUID: ClassificationProfile.Statistics]]
    ) {
        let ageDays = max(0, now.timeIntervalSince(date) / 86_400)
        let halfLife = source == .historicalBootstrap || source == .importedBootstrap ? 45.0 : 180.0
        let recency = pow(0.5, ageDays / halfLife)
        let weight = source.strength * recency

        for feature in ClassificationFeatureExtractor.features(note: note, merchant: merchant) {
            let key = ClassificationProfile.Key(type: type, feature: feature)
            var distribution = table[key, default: [:]]
            var stats = distribution[categoryID, default: .init()]
            stats.rawSupport += 1
            if source.isStrong { stats.strongSupport += 1 }
            stats.positiveWeight += weight
            stats.latestAt = max(stats.latestAt, date)
            if source.strength > stats.strongestSource.strength {
                stats.strongestSource = source
            }
            for tagID in tagIDs {
                stats.tagWeights[tagID, default: 0] += weight
            }
            distribution[categoryID] = stats

            if let rejectedCategoryID, rejectedCategoryID != categoryID {
                var rejected = distribution[rejectedCategoryID, default: .init()]
                rejected.negativeWeight += weight * negativeFeedbackMultiplier(for: feature.kind)
                distribution[rejectedCategoryID] = rejected
            }
            table[key] = distribution
        }
    }

    private static func negativeFeedbackMultiplier(
        for feature: ClassificationFeatureKind
    ) -> Double {
        switch feature {
        case .exactNote, .merchantPhrase, .phrase:
            1
        case .merchant:
            0.15
        case .token:
            0.1
        case .cjkBigram, .cjkTrigram:
            0.05
        }
    }
}

struct ClassificationMemoryDocument: Codable, Equatable, Sendable {
    static let currentVersion = 2
    var version = currentVersion
    var events: [ClassificationLearningEvent] = []
}

struct ClassificationLearningGeneration: Equatable, Sendable {
    let epoch: UUID
    let revision: UInt64
}

/// Process-local lifecycle only; this is not a synced approval or business event log.
private final class ClassificationLearningLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ClassificationLearningGeneration(epoch: UUID(), revision: 0)

    var current: ClassificationLearningGeneration {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func invalidate() -> ClassificationLearningGeneration {
        lock.lock()
        defer { lock.unlock() }
        value = .init(epoch: UUID(), revision: value.revision &+ 1)
        return value
    }

    func didUpdateMemory(epoch: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if value.epoch == epoch { value = .init(epoch: epoch, revision: value.revision &+ 1) }
    }
}

actor ClassificationProfileStore {
    static let shared = ClassificationProfileStore(fileURL: defaultFileURL())
    private static let maximumEvents = 4_000

    enum Failure: Error, LocalizedError, Equatable {
        case unreadableDocument, unsupportedVersion, unwritableDocument, staleSnapshot
        var errorDescription: String? {
            switch self {
            case .unreadableDocument: "学习记录暂时无法读取，原文件已保留。"
            case .unsupportedVersion: "学习记录来自更新版本，原文件已保留。"
            case .unwritableDocument: "学习记录暂时无法保存，已保存的账本不受影响。"
            case .staleSnapshot: "学习记录已变化，请重新计算。"
            }
        }
    }

    struct Snapshot: Sendable {
        let events: [ClassificationLearningEvent]
        let generation: ClassificationLearningGeneration
    }

    private let fileURL: URL
    private var cachedDocument: ClassificationMemoryDocument?
    private var needsPersistence = false
    private var processedEpoch: UUID
    private nonisolated let lifetime: ClassificationLearningLifetime

    init(fileURL: URL) {
        self.fileURL = fileURL
        let lifetime = ClassificationLearningLifetime()
        self.lifetime = lifetime
        processedEpoch = lifetime.current.epoch
    }

    nonisolated var generation: ClassificationLearningGeneration { lifetime.current }

    /// Capture synchronously at the clear action, before dispatching any async work.
    nonisolated func beginClear() -> ClassificationLearningGeneration { lifetime.invalidate() }

    func snapshot() throws -> Snapshot {
        let generation = lifetime.current
        let events = processedEpoch == generation.epoch ? try loadDocument().events : []
        guard lifetime.current == generation else { throw Failure.staleSnapshot }
        return Snapshot(events: events, generation: generation)
    }

    func events() throws -> [ClassificationLearningEvent] { try snapshot().events }

    @discardableResult
    func record(_ event: ClassificationLearningEvent, generation: ClassificationLearningGeneration) throws -> Bool {
        try record([event], generation: generation)
    }

    @discardableResult
    func record(_ events: [ClassificationLearningEvent], generation: ClassificationLearningGeneration) throws -> Bool {
        guard lifetime.current.epoch == generation.epoch else { return false }
        guard !events.isEmpty else { return true }
        var document = processedEpoch == generation.epoch ? try loadDocument() : ClassificationMemoryDocument()
        document.version = ClassificationMemoryDocument.currentVersion
        let ids = Set(events.map(\.transactionID))
        document.events.removeAll { ids.contains($0.transactionID) }
        document.events.append(contentsOf: events)
        if document.events.count > Self.maximumEvents {
            document.events = Array(document.events.suffix(Self.maximumEvents))
        }
        try persist(document, epoch: generation.epoch)
        return lifetime.current.epoch == generation.epoch
    }

    @discardableResult
    func reset(generation: ClassificationLearningGeneration) throws -> Bool {
        guard lifetime.current.epoch == generation.epoch else { return false }
        // A post-clear record may reach this actor before reset. Its document has
        // already excluded the previous epoch; do not delete the new user's event.
        if processedEpoch != generation.epoch {
            try persist(ClassificationMemoryDocument(), epoch: generation.epoch)
        } else if needsPersistence, let cachedDocument {
            try persist(cachedDocument, epoch: generation.epoch)
        }
        return lifetime.current.epoch == generation.epoch
    }

    @discardableResult
    func reset() throws -> Bool { try reset(generation: beginClear()) }

    private func loadDocument() throws -> ClassificationMemoryDocument {
        if let cachedDocument { return cachedDocument }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let empty = ClassificationMemoryDocument()
            cachedDocument = empty
            return empty
        } catch { throw Failure.unreadableDocument }
        let decoded: ClassificationMemoryDocument
        do { decoded = try JSONDecoder().decode(ClassificationMemoryDocument.self, from: data) }
        catch { throw Failure.unreadableDocument }
        guard decoded.version == 1 || decoded.version == ClassificationMemoryDocument.currentVersion else {
            throw Failure.unsupportedVersion
        }
        guard decoded.events.count <= Self.maximumEvents else { throw Failure.unreadableDocument }
        cachedDocument = decoded
        return decoded
    }

    private func persist(_ document: ClassificationMemoryDocument, epoch: UUID) throws {
        guard lifetime.current.epoch == epoch else { return }
        // The ledger has already committed. Publish bounded session evidence before
        // disk I/O so a sidecar failure cannot restore an older suggestion profile.
        if cachedDocument != document || processedEpoch != epoch {
            cachedDocument = document
            processedEpoch = epoch
            needsPersistence = true
            lifetime.didUpdateMemory(epoch: epoch)
        }
        guard needsPersistence else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(document).write(to: fileURL, options: .atomic)
            needsPersistence = false
        } catch { throw Failure.unwritableDocument }
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PersonalFinanceOS", isDirectory: true)
            .appendingPathComponent("classification-memory-v1.json")
    }
}
