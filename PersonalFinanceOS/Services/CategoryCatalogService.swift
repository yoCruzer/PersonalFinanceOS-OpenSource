import Foundation
import Observation
import SwiftData

@MainActor
enum CategoryCatalogService {
    struct Preview {
        let plan: CategoryCatalogPlanner.Plan
        fileprivate let admission: ICloudSyncController.CatalogAdmission
    }

    enum Failure: Error, LocalizedError {
        case busyOrStale
        case pendingEdits
        case invalidSelection
        case unavailableParent

        var errorDescription: String? {
            switch self {
            case .busyOrStale: "账本或同步状态已变化，请重新预览分类后重试。"
            case .pendingEdits: "请先处理当前未保存的修改，再更新分类。"
            case .invalidSelection: "部分分类选择存在冲突，请重新预览并确认。"
            case .unavailableParent: "所属大类尚未安装或已停用，请先处理大类。"
            }
        }
    }

    static func preview(in context: ModelContext, sync: ICloudSyncController, additionsOnly: Bool = false) async throws -> Preview {
        let diagnosticStart = ContinuousClock.now
        let admission = await sync.makeCatalogAdmission(for: context.container)
        let snapshot: CategoryCatalogPlanner.Snapshot
        do {
            snapshot = try LedgerSaveRevision.shared.withProjectionBoundary {
                guard !context.hasChanges else { throw Failure.pendingEdits }
                return try capture(in: ModelContext(context.container))
            }
        } catch ReconcileRevision.Failure.stalePlan {
            throw Failure.busyOrStale
        }
        let catalog = try CategoryCatalog.load()
        let readiness = admission.readiness
        let plan = await Task.detached(priority: .userInitiated) {
            additionsOnly ? CategoryCatalogPlanner.additions(catalog: catalog, snapshot: snapshot, readiness: readiness)
                : CategoryCatalogPlanner.make(catalog: catalog, snapshot: snapshot, readiness: readiness)
        }.value
        LocalDiagnostics.shared.catalog(plan: plan, elapsed: diagnosticStart.duration(to: .now))
        return Preview(plan: plan, admission: admission)
    }

    /// Applies only explicit selected operations, with no transaction edits or identity rewrites.
    @discardableResult
    static func commit(
        _ preview: Preview, selected: Set<String>, in context: ModelContext,
        sync: ICloudSyncController, changes: LedgerChangeCenter, now: Date = Date()
    ) throws -> Int {
        let diagnosticStart = ContinuousClock.now
        do {
            return try sync.withCatalogAdmission(preview.admission, for: context.container) {
                try LedgerSaveRevision.shared.withProjectionBoundary {
                    guard !context.hasChanges else { throw Failure.pendingEdits }
                    let fresh = ModelContext(context.container)
                    guard preview.plan.canCommit, try capture(in: fresh) == preview.plan.snapshot else {
                        throw Failure.busyOrStale
                    }
                    let chosen = preview.plan.entries.filter { selected.contains($0.id) }
                    guard chosen.count == selected.count, chosen.allSatisfy({ entry in
                        guard entry.change != .none else { return false }
                        if preview.plan.additionsOnly { return entry.change == .insert && entry.reason == nil }
                        switch entry.reason {
                        case nil, .customized, .legacyDeletionNeedsReview: return true
                        default: return false
                        }
                    }) else { throw Failure.invalidSelection }
                    guard !chosen.isEmpty else { return 0 }
                    do {
                        let count = try apply(chosen, plan: preview.plan, in: fresh, now: now)
                        try fresh.save()
                        changes.recordMutation()
                        LocalDiagnostics.shared.catalog(plan: preview.plan, committedCount: count,
                            elapsed: diagnosticStart.duration(to: .now))
                        return count
                    } catch {
                        fresh.rollbackNotifyingSync()
                        throw error
                    }
                }
            }
        } catch {
            let code: LocalDiagnostics.CatalogFailure
            if case ReconcileRevision.Failure.stalePlan = error {
                code = .busyOrStale
            } else {
                switch error as? Failure {
                case .busyOrStale: code = .busyOrStale
                case .pendingEdits: code = .pendingEdits
                case .invalidSelection: code = .invalidSelection
                case .unavailableParent: code = .unavailableParent
                case nil: code = .storageFailure
                }
            }
            LocalDiagnostics.shared.catalogRejected(reason: code, selectedCount: selected.count,
                elapsed: diagnosticStart.duration(to: .now))
            if case ReconcileRevision.Failure.stalePlan = error { throw Failure.busyOrStale }
            throw error
        }
    }

    struct Completion: Codable, Equatable, Sendable {
        let added: Int
        let installed: Int
        let skipped: Int
        let waiting: Int
        var available: Int = 0
    }

    static func completeMissing(in context: ModelContext, sync: ICloudSyncController,
                                changes: LedgerChangeCenter) async throws -> Completion {
        let preview = try await preview(in: context, sync: sync, additionsOnly: true)
        let plan = preview.plan
        let selected = Set(plan.entries.filter(\.selectedByDefault).map(\.id))
        let added: Int
        if plan.readiness == .pendingRemoteGraph { added = 0 }
        else { added = try commit(preview, selected: selected, in: context, sync: sync, changes: changes) }
        let byID = Dictionary(uniqueKeysWithValues: plan.snapshot.categories.map { ($0.id, $0) })
        let existing = plan.entries.filter { $0.installation == .installed }
        let available = existing.filter { entry in
            let id = plan.reusableIDs[entry.id] ?? plan.snapshot.categories.first {
                $0.defaultDefinitionKey == entry.definition.storageDefaultKey
            }?.id
            guard let id, let value = byID[id], !value.isHidden, value.archivedAt == nil,
                  value.kindRawValue == entry.definition.kind.rawValue else { return false }
            guard let parentID = value.parentID else { return true }
            guard let parent = byID[parentID] else { return false }
            return !parent.isHidden && parent.archivedAt == nil && parent.parentID == nil && parent.kindRawValue == value.kindRawValue
        }.count
        return Completion(added: added, installed: existing.count + added,
            skipped: plan.entries.filter { $0.reason != nil && $0.change == .insert }.count + existing.count - available,
            waiting: plan.entries.filter { $0.installation == .pendingRemoteGraph && $0.change == .insert }.count,
            available: available + added)
    }

    static func capture(in context: ModelContext) throws -> CategoryCatalogPlanner.Snapshot {
        .init(
            categories: try context.fetch(FetchDescriptor<Category>()).map(MetadataEditSnapshot.CategoryValue.init)
                .sorted { $0.id.uuidString < $1.id.uuidString },
            metadata: try context.fetch(FetchDescriptor<AppMetadata>()).map {
                .init(id: $0.id, seedVersion: $0.defaultCategorySeedVersion, deletedKeys: $0.deletedDefaultCategoryKeys)
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    private static func apply(
        _ entries: [CategoryCatalogPlanner.Entry], plan: CategoryCatalogPlanner.Plan,
        in context: ModelContext, now: Date
    ) throws -> Int {
        var categories = try context.fetch(FetchDescriptor<Category>())
        let groups = Dictionary(grouping: categories.filter { !$0.defaultDefinitionKey.isEmpty }, by: \.defaultDefinitionKey)
        guard groups.values.allSatisfy({ $0.count == 1 }) else { throw Failure.invalidSelection }
        var byKey = groups.mapValues { $0[0] }
        for (semantic, id) in plan.reusableIDs {
            if let definition = plan.entries.first(where: { $0.id == semantic })?.definition,
               let existing = categories.first(where: { $0.id == id }) {
                byKey[definition.storageDefaultKey] = existing
            }
        }
        let definitions = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.id, $0.definition) })
        for entry in entries {
            let definition = entry.definition
            var parent: Category?
            if let semantic = definition.parentSemanticKey {
                guard let key = definitions[semantic]?.storageDefaultKey,
                      let found = byKey[key], found.parentID == nil, found.kind == definition.kind,
                      found.isActiveForSelection else { throw Failure.unavailableParent }
                parent = found
            }
            switch entry.change {
            case .none: throw Failure.invalidSelection
            case .insert:
                guard byKey[definition.storageDefaultKey] == nil else { throw Failure.invalidSelection }
                let style = CategoryCatalogAppearance.style(for: definition)
                let value = Category(
                    kind: definition.kind, name: definition.name, parentID: parent?.id,
                    defaultDefinitionKey: definition.storageDefaultKey,
                    symbolName: style.symbol,
                    colorToken: parent?.colorToken ?? style.color,
                    sortOrder: (categories.filter { $0.kind == definition.kind && $0.parentID == parent?.id }.map(\.sortOrder).max() ?? -1) + 1,
                    isSystemCategory: true, createdAt: now, updatedAt: now
                )
                context.insert(value)
                categories.append(value)
                byKey[definition.storageDefaultKey] = value
            case let .updateDisplayAndParent(id):
                guard let value = byKey[definition.storageDefaultKey], value.id == id else { throw Failure.invalidSelection }
                value.name = definition.name
                value.parentID = parent?.id
                value.updatedAt = now
            }
        }
        try CategoryHierarchy(categories: categories).validateAll()
        guard let metadata = try context.fetch(FetchDescriptor<AppMetadata>()).first else { throw Failure.invalidSelection }
        metadata.defaultCategorySeedVersion = max(metadata.defaultCategorySeedVersion, plan.catalogVersion)
        metadata.updatedAt = now
        return entries.count
    }
}

@MainActor
@Observable
final class CategoryCompletionState {
    private(set) var completion: CategoryCatalogService.Completion?
    private(set) var isRunning = false
    private(set) var failed = false
    private var checkedSnapshot: CategoryCatalogPlanner.Snapshot?
    private var checkedReadiness: CategoryCatalogPlanner.Readiness?

    func refresh(in context: ModelContext, sync: ICloudSyncController, changes: LedgerChangeCenter) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            let admission = await sync.makeCatalogAdmission(for: context.container)
            let input = try CategoryCatalogService.capture(in: ModelContext(context.container))
            if !failed, let previous = completion, previous.waiting == 0,
               checkedReadiness == admission.readiness, checkedSnapshot == input {
                // No mutation or planner diagnostics for identical, completed inputs.
                completion = .init(added: 0, installed: previous.installed, skipped: previous.skipped,
                    waiting: 0, available: previous.available)
                return
            }
            completion = try await CategoryCatalogService.completeMissing(in: context, sync: sync, changes: changes)
            checkedSnapshot = input
            checkedReadiness = admission.readiness
            failed = false
        } catch {
            checkedSnapshot = nil
            checkedReadiness = nil
            failed = true
        }
    }

    func description(sync: ICloudSyncController) -> String {
        if isRunning { return "正在补充分类" }
        if failed { return "分类补充暂未完成，可重试" }
        guard let completion else { return "正在检查缺少的分类" }
        if completion.waiting > 0 {
            if let review = sync.categoryReview { return "需要处理 \(review.conflicts.count) 项分类差异" }
            switch sync.status {
            case .pendingRelationships: return "正在接收分类及关联数据"
            case .retrying, .unavailable, .error, .oversizedRecords: return "等待 iCloud 恢复后补充分类"
            case .accountChanged: return "请先确认当前 iCloud 账户"
            default: return "正在等待首次同步完成"
            }
        }
        return "分类已补充" + (completion.skipped > 0 ? " · 已保留 \(completion.skipped) 项删除、停用或同名设置" : "")
    }
}
