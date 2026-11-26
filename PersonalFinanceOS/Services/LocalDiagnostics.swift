import CryptoKit
import Foundation

/// Session-only diagnostics. Every recording method defines its own allowlist;
/// raw notes, merchant/account/category names, money and business IDs are never exported.
final class LocalDiagnostics: @unchecked Sendable {
    static let shared = LocalDiagnostics()
    private let lock = NSLock()
    private let sessionID = UUID()
    private let filterKey = SymmetricKey(size: .bits256)
    private var entries: [Entry] = []
    private var discardedEntryCount = 0
    private static let capacity = 128

    enum Stage: String, Codable { case classification, profile, analysis, page, export, catalogPreview, catalogCommit, sync }
    enum RevisionKind: String, Codable { case save, content }
    struct Entry: Codable, Equatable {
        let operationID: UUID
        let stage: Stage
        let revision: UInt64
        let elapsedMilliseconds: Int
        var recordedAt = Date()
        var revisionKind: RevisionKind = .save
        var filterFingerprint: String? = nil
        var counts: [String: Int] = [:]
        var flags: [String: Bool] = [:]
        var codes: [String] = []
        var scores: [Int] = []
    }
    struct Report: Codable {
        let formatVersion: Int
        let sessionID: UUID
        let appVersion: String
        let build: String
        let gitCommit: String
        let gitDirty: Bool?
        let systemVersion: String
        let exportedAt: Date
        let discardedEntryCount: Int
        let catalogInstallation: CategoryCatalogService.Completion?
        let catalogCheckFailed: Bool
        let catalogCheckInProgress: Bool
        let sync: ICloudSyncController.DisplaySnapshot?
        let modelVersion: String
        let catalogVersion: Int?
        let lexiconVersion: Int?
        let learningFormatVersion: Int
        let entryLimit: Int
        let localOnly: Bool
        let entries: [Entry]
        let classificationCounters: SmartClassificationDiagnosticSnapshot?
    }

    struct ProfileCounts {
        var matched = 0
        var changed = 0
        var missing = 0
        var unknown = 0
        var ineligible = 0
        var duplicates = 0
    }

    func classification(noteLength: Int, merchantLength: Int, type: TransactionType,
                        suggestion: SmartTransactionSuggestion, targetAvailable: Bool,
                        manualLocked: Bool, modelEnabled: Bool, eligibleCategoryCount: Int = 0, promptCandidateCount: Int = 0, elapsed: Duration) {
        var entry = Entry(operationID: UUID(), stage: .classification, revision: LedgerSaveRevision.shared.contentRevision,
            elapsedMilliseconds: Self.milliseconds(elapsed))
        entry.revisionKind = .content
        entry.counts = ["noteLength": noteLength, "merchantLength": merchantLength,
            "topCandidateCount": suggestion.alternatives.count, "score": suggestion.score,
            "eligibleCategories": eligibleCategoryCount, "promptCandidates": promptCandidateCount]
        if let margin = suggestion.diagnosticMargin { entry.counts["scoreMargin"] = margin }
        entry.flags = ["inputTriggered": noteLength + merchantLength > 0, "targetAvailable": targetAvailable,
            "manualLocked": manualLocked, "modelEnabled": modelEnabled, "requiresChoice": suggestion.requiresUserChoice]
        entry.codes = [type.rawValue, String(describing: suggestion.categoryConfidence),
            suggestion.evidenceType.map { String(describing: $0) } ?? "noEvidence",
            manualLocked ? "manualLock" : suggestion.requiresUserChoice ? "ambiguousInput" : "unlocked"]
        // Only identifiers from the bundled static rule resource are accepted.
        let allowed = Set(SemanticClassificationLexicon.bundled?.rules.map(\.id) ?? [])
        entry.codes += suggestion.diagnosticRuleIDs.filter { allowed.contains($0) }.prefix(8)
        entry.scores = suggestion.alternatives.map(\.score)
        append(entry)
    }

    func profile(historyCount: Int, eventCount: Int, sampleCount: Int, validity: ProfileCounts, elapsed: Duration) {
        var entry = Entry(operationID: UUID(), stage: .profile, revision: LedgerSaveRevision.shared.contentRevision,
            elapsedMilliseconds: Self.milliseconds(elapsed))
        entry.revisionKind = .content
        entry.counts = ["historyLoaded": historyCount, "eventsLoaded": eventCount, "samples": sampleCount,
            "matchingEvents": validity.matched, "changedEvents": validity.changed, "missingEvents": validity.missing,
            "unknownEvents": validity.unknown, "ineligibleEvents": validity.ineligible, "duplicateEvents": validity.duplicates]
        append(entry)
    }

    func analysis(stage: Stage, filter: LedgerFilter, revision: UInt64, expectedCount: Int,
                  actualCount: Int, scannedCount: Int = 0, selectedSubset: Bool = false, elapsed: Duration) {
        precondition(stage == .analysis || stage == .page || stage == .export)
        var entry = Entry(operationID: UUID(), stage: stage, revision: revision, elapsedMilliseconds: Self.milliseconds(elapsed))
        entry.revisionKind = .content
        entry.filterFingerprint = fingerprint(filter)
        entry.counts = ["expectedRows": expectedCount, "actualRows": actualCount, "scannedRows": scannedCount,
            "tagCount": filter.tagIDs.count, "queryLength": filter.query.count, "merchantLength": filter.merchant.count]
        entry.flags = ["countsMatch": expectedCount == actualCount, "allHistory": filter.dateRange == nil,
            "accountFiltered": filter.accountID != nil, "selectedSubset": selectedSubset]
        entry.codes = [filter.mode.rawValue, String(describing: filter.sortOrder), String(describing: filter.deletion)]
        append(entry)
    }

    func catalog(plan: CategoryCatalogPlanner.Plan, committedCount: Int? = nil, elapsed: Duration) {
        var entry = Entry(operationID: UUID(), stage: committedCount == nil ? .catalogPreview : .catalogCommit,
            revision: LedgerSaveRevision.shared.revision, elapsedMilliseconds: Self.milliseconds(elapsed))
        entry.counts = ["catalogVersion": plan.catalogVersion, "entries": plan.entries.count,
            "retainedLegacy": plan.retainedLegacyIDs.count, "selectedByDefault": plan.entries.filter(\.selectedByDefault).count]
        if let committedCount { entry.counts["committedChanges"] = committedCount }
        entry.flags = ["canCommit": plan.canCommit]
        if committedCount != nil { entry.flags["commitSucceeded"] = true }
        entry.codes = [String(describing: plan.readiness)]
        let reasons = Dictionary(grouping: plan.entries.compactMap(\.reason), by: { String(describing: $0) })
        for (reason, entries) in reasons { entry.counts["reason." + reason] = entries.count }
        append(entry)
    }

    enum CatalogFailure: String { case busyOrStale, pendingEdits, invalidSelection, unavailableParent, storageFailure }
    func catalogRejected(reason: CatalogFailure, selectedCount: Int, elapsed: Duration) {
        var entry = Entry(operationID: UUID(), stage: .catalogCommit, revision: LedgerSaveRevision.shared.revision,
            elapsedMilliseconds: Self.milliseconds(elapsed))
        entry.counts = ["selectedEntries": selectedCount]
        entry.flags = ["commitSucceeded": false]
        entry.codes = [reason.rawValue]
        append(entry)
    }

    func report(bundle: Bundle = .main, classificationCounters: SmartClassificationDiagnosticSnapshot? = nil,
                sync: ICloudSyncController.DisplaySnapshot? = nil,
                catalogInstallation: CategoryCatalogService.Completion? = nil,
                catalogCheckFailed: Bool = false, catalogCheckInProgress: Bool = false) -> Report {
        lock.lock()
        let copy = entries
        let discarded = discardedEntryCount
        lock.unlock()
        let identity = Self.buildIdentity(bundle: bundle)
        return Report(formatVersion: 2, sessionID: sessionID,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unavailable",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unavailable",
            gitCommit: identity.commit, gitDirty: identity.dirty,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString, exportedAt: Date(),
            discardedEntryCount: discarded,
            catalogInstallation: catalogCheckFailed || catalogCheckInProgress ? nil : catalogInstallation,
            catalogCheckFailed: catalogCheckFailed, catalogCheckInProgress: catalogCheckInProgress, sync: sync,
            modelVersion: "V4", catalogVersion: (try? CategoryCatalog.load())?.proposedCategoryCatalogRevision,
            lexiconVersion: SemanticClassificationLexicon.bundled?.version,
            learningFormatVersion: ClassificationMemoryDocument.currentVersion, entryLimit: Self.capacity,
            localOnly: true, entries: copy, classificationCounters: classificationCounters)
    }

    static func buildIdentity(bundle: Bundle) -> (commit: String, dirty: Bool?) {
        let metadata = bundle.url(forResource: "BuildIdentity", withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0) }
        let git = metadata?["PFOSGitCommit"] as? String
            ?? bundle.object(forInfoDictionaryKey: "PFOSGitCommit") as? String ?? ""
        guard git.count == 40, git.allSatisfy(\.isHexDigit) else { return ("unavailable", nil) }
        return (git, metadata?["PFOSGitDirty"] as? Bool)
    }

    func syncState(_ snapshot: ICloudSyncController.DisplaySnapshot) {
        var entry = Entry(operationID: UUID(), stage: .sync, revision: LedgerSaveRevision.shared.contentRevision,
            elapsedMilliseconds: 0)
        entry.revisionKind = .content
        entry.codes = [snapshot.stage.rawValue] + snapshot.errorCodes.map { "CK." + String($0) }
        entry.counts = ["pendingChanges": snapshot.pendingChanges, "categoryDifferences": snapshot.categoryDifferences, "databaseOperations": snapshot.pendingDatabaseChanges]
        entry.flags = ["currentConfirmation": snapshot.stage == .confirmed, "engineAvailable": snapshot.engineAvailable, "firstFetch": snapshot.firstFetchCompleted, "projectionReady": snapshot.projectionReady, "currentFetchApplied": snapshot.currentFetchApplied]
        append(entry)
    }

    static func encode(_ report: Report) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    func json(bundle: Bundle = .main, classificationCounters: SmartClassificationDiagnosticSnapshot? = nil) throws -> String {
        String(decoding: try Self.encode(report(bundle: bundle, classificationCounters: classificationCounters)), as: UTF8.self)
    }

    /// A per-session secret prevents low-entropy query enumeration. The secret and
    /// canonical filter contents never enter the report or any persistent store.
    func fingerprint(_ filter: LedgerFilter) -> String {
        let fields = [filter.dateRange?.lowerBound ?? "", filter.dateRange?.upperBound ?? "", filter.mode.rawValue,
            String(describing: filter.category), filter.accountID?.uuidString ?? "",
            filter.tagIDs.map(\.uuidString).sorted().joined(separator: ","), filter.merchant, filter.query,
            filter.currencyCode, String(describing: filter.deletion), String(describing: filter.sortOrder)]
        let data = Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        return HMAC<SHA256>.authenticationCode(for: data, using: filterKey).map { String(format: "%02x", $0) }.joined()
    }

    private func append(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        if entries.count > Self.capacity {
            let discarded = entries.count - Self.capacity
            discardedEntryCount += discarded
            entries.removeFirst(discarded)
        }
    }
    private static func milliseconds(_ elapsed: Duration) -> Int {
        Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// One atomic UTF-8 file. Sharing never removes it; the next export cleans only
/// expired diagnostics so an open share controller retains a valid URL.
enum DiagnosticFileStore {
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    static func write(_ report: LocalDiagnostics.Report,
                      root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("PFOSDiagnostics"),
                      now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            where url.lastPathComponent.hasPrefix("PFOS-diagnostic-") && url.pathExtension == "json" {
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, now.timeIntervalSince(modified) > retention { try? FileManager.default.removeItem(at: url) }
        }
        let url = root.appendingPathComponent("PFOS-diagnostic-\(UUID().uuidString).json")
        try LocalDiagnostics.encode(report).write(to: url, options: .atomic)
        return url
    }
}
