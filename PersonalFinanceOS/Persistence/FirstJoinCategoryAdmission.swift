import Foundation

/// Admission is computed from complete snapshots; it never filters captureLocal input.
enum FirstJoinCategoryAdmission {
    enum Outcome: Sendable {
        case ready
        case waitingForGraph
        case review([Conflict])
    }

    struct Conflict: Identifiable, Sendable {
        let id: String
        let local: NativeBackupPackage.CategoryPayload?
        let remote: NativeBackupPackage.CategoryPayload?
        let remoteDeleted: Bool
    }

    enum Choice: String, CaseIterable, Sendable {
        case local, remote
    }

    enum Failure: LocalizedError {
        case incompleteChoices, localDeletionNeedsReview, staleChoices

        var errorDescription: String? {
            switch self {
            case .staleChoices: "分类、账本或同步状态已变化，请重新审阅后再确认。"
            case .incompleteChoices: "请逐项确认分类，或稍后再处理。本机记账仍可使用。"
            case .localDeletionNeedsReview:
                "本机删除意图已保留。若继续保留删除，请先在已同步设备完成对应删除后重试；也可以明确选择采用云端分类。"
            }
        }
    }

    static func evaluate(local: [String: Data], remote: ProtectedLedgerReplica) throws -> Outcome {
        guard !remote.records.isEmpty else { return .ready }
        let remotePackage: NativeBackupPackage
        do {
            remotePackage = try LedgerSyncIdentity.wirePackage(from: remote.livePayloads)
            _ = try ValidatedLedgerSnapshot(remotePackage)
        } catch { return .waitingForGraph }
        let localPackage = try LedgerSyncIdentity.wirePackage(from: local)
        let localCategories = Dictionary(uniqueKeysWithValues: localPackage.categories.map { (key($0.id), $0) })
        let remoteCategories = Dictionary(uniqueKeysWithValues: remotePackage.categories.map { (key($0.id), $0) })
        let localDeletions = DefaultFinanceDataService.migratedTombstones(
            Set(localPackage.appMetadata.flatMap(\.deletedDefaultCategoryKeys))
        )
        let remoteDeletions = DefaultFinanceDataService.migratedTombstones(
            Set(remotePackage.appMetadata.flatMap(\.deletedDefaultCategoryKeys))
        )
        var conflicts: [Conflict] = []
        for (id, value) in localCategories.sorted(by: { $0.key < $1.key }) {
            let remoteValue = remoteCategories[id]
            let deleted = remote.records[id].map { $0.payload == nil } == true
                || remoteDeletions.contains(value.defaultDefinitionKey)
            let differs = try remoteValue.map { try semanticData($0) != semanticData(value) } ?? false
            let absentDefault = remoteValue == nil && !value.defaultDefinitionKey.isEmpty
            if differs || deleted || absentDefault {
                conflicts.append(Conflict(id: id, local: value, remote: remoteValue, remoteDeleted: deleted))
            }
        }
        for (id, value) in remoteCategories.sorted(by: { $0.key < $1.key })
        where localCategories[id] == nil && localDeletions.contains(value.defaultDefinitionKey) {
            conflicts.append(Conflict(id: id, local: nil, remote: value, remoteDeleted: false))
        }
        return conflicts.isEmpty ? .ready : .review(conflicts)
    }

    /// Produces the complete desired local graph for an explicit user decision.
    /// Normal validation rejects cloud deletions that still have local references.
    static func applying(
        _ choices: [String: Choice], conflicts: [Conflict],
        local: [String: Data], remote: ProtectedLedgerReplica
    ) throws -> [String: Data] {
        guard Set(choices.keys) == Set(conflicts.map(\.id)) else { throw Failure.incompleteChoices }
        var result = local
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for conflict in conflicts {
            switch choices[conflict.id] {
            case .local:
                guard conflict.local != nil else { throw Failure.localDeletionNeedsReview }
            case .remote:
                if let value = conflict.remote {
                    result[conflict.id] = try encoder.encode(value)
                    if let parentID = value.parentID, result[key(parentID)] == nil {
                        guard let parent = remote.livePayloads[key(parentID)] else {
                            throw NativeBackupError.invalidReference("first join category parent")
                        }
                        result[key(parentID)] = parent
                    }
                } else {
                    guard conflict.remoteDeleted else { throw Failure.incompleteChoices }
                    result.removeValue(forKey: conflict.id)
                }
            case nil: throw Failure.incompleteChoices
            }
        }
        // Existing deletion facts stay intact. Receiving them is not a request to
        // manufacture missing template categories or to clear local markers.
        for (id, payload) in remote.livePayloads where id.hasPrefix("seedDeletion:") {
            result[id] = payload
        }
        return result
    }

    private static func key(_ id: UUID) -> String { "categories:\(id.uuidString)" }

    private static func semanticData(_ value: NativeBackupPackage.CategoryPayload) throws -> Data {
        var normalized = value
        normalized.createdAt = Date(timeIntervalSince1970: 0)
        normalized.updatedAt = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(normalized)
    }
}
