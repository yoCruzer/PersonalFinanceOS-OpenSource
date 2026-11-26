import SwiftData
import SwiftUI

struct TransactionBatchActionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var isPresentationEnabled

    let selectedIDs: Set<UUID>
    let snapshot: LedgerAnalysisSnapshot
    let categories: [Category]
    let accounts: [Account]
    let tags: [Tag]
    let onDeleted: () -> Void

    @State private var generation = UUID()
    @State private var totals: LedgerTotals?
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    @State private var pendingAction: PendingBatchAction?
    @State private var isBusy = false
    @State private var isCategoryPickerPresented = false
    @State private var targetCategoryID: UUID?
    @State private var isTagReplacementPresented = false
    @State private var sourceTagID: UUID?
    @State private var targetTagID: UUID?

    private var selectionKey: BatchSelectionKey { BatchSelectionKey(ids: selectedIDs, revision: snapshot.revision, isEnabled: isPresentationEnabled) }
    private var selectedKind: CategoryKind? {
        guard let totals, totals.transferCount == 0 else { return nil }
        if totals.incomeCount == 0 { return .expense }
        if totals.expenseCount + totals.refundCount == 0 { return .income }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PFSpacing.small) {
            if let totals {
                Text("已选 \(totals.totalCount) 笔 · 收入 \(amount(totals.incomeMinorUnits)) · 支出发生额 \(amount(totals.grossExpenseMinorUnits)) · 退款 \(amount(totals.refundMinorUnits)) · 净支出 \(amount(totals.netExpenseMinorUnits))")
                    .font(.caption).foregroundStyle(PFColor.secondaryText)
                    .accessibilityIdentifier("batch-complete-summary")
            } else { ProgressView("正在汇总完整选择…") }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PFSpacing.small) {
                    if let exportURL {
                        ShareLink(item: exportURL) { actionLabel("分享导出", symbol: "square.and.arrow.up") }
                    } else {
                        Button { prepareExport() } label: { actionLabel("导出", symbol: "square.and.arrow.up") }
                    }
                    Button(role: .destructive) {
                        prepare(.delete, title: "确认软删除", target: "所选记录", confirm: "删除")
                    } label: { actionLabel("删除", symbol: "trash") }
                    Menu {
                        ForEach(accounts.filter { $0.archivedAt == nil }) { account in
                            Button(account.name) { prepare(.account(account.id), title: "确认迁移账户", target: account.name) }
                        }
                    } label: { actionLabel("账户", symbol: "creditcard") }
                    Button {
                        targetCategoryID = nil
                        isCategoryPickerPresented = true
                    } label: { actionLabel("分类", symbol: "square.grid.2x2") }
                    .disabled(selectedKind == nil)
                    .accessibilityIdentifier("batch-category-action")
                    tagMenu
                }
                .disabled(isBusy || totals == nil)
            }
            .accessibilityIdentifier("batch-actions-scroll")
            if totals != nil, selectedKind == nil {
                Text("混合收支或转账不能使用同一目标分类")
                    .font(.caption).foregroundStyle(PFColor.secondaryText)
            }
            if isBusy { ProgressView("正在准备或执行…") }
        }
        .task(id: selectionKey) { await reloadSelection() }
        .onChange(of: selectionKey) {
            generation = UUID(); exportURL = nil; pendingAction = nil
            isTagReplacementPresented = false; isBusy = false
            targetCategoryID = nil; isCategoryPickerPresented = false
        }
        .onChange(of: ledgerChangeCenter.revision) { exportURL = nil }
        .sheet(isPresented: $isCategoryPickerPresented, onDismiss: {
            guard let id = targetCategoryID else { return }
            targetCategoryID = nil
            guard let category = categories.first(where: { $0.id == id }), category.kind == selectedKind else { return }
            prepare(.category(id), title: "确认迁移分类", target: category.displayPath(in: categories))
        }) {
            if let kind = selectedKind {
                CategoryPickerSheet(categories: categories, transactions: [], kind: kind,
                    selectedID: nil, purpose: .batchTarget) { category in
                    targetCategoryID = category.id
                }
            }
        }
        .sheet(item: $pendingAction) { action in
            NavigationStack {
                Form {
                    Section("确认计划") {
                        LabeledContent("目标", value: action.target)
                        LabeledContent("选择范围", value: "\(action.plan.selectedIDs.count) 笔")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("选择范围")
                            .accessibilityValue("\(action.plan.selectedIDs.count) 笔")
                            .accessibilityIdentifier("batch-plan-selection-count")
                        LabeledContent("实际变更", value: "\(action.plan.totals.totalCount) 笔")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("实际变更")
                            .accessibilityValue("\(action.plan.totals.totalCount) 笔")
                            .accessibilityIdentifier("batch-plan-impact-count")
                        LabeledContent("收入", value: amount(action.plan.totals.incomeMinorUnits))
                        LabeledContent("支出发生额", value: amount(action.plan.totals.grossExpenseMinorUnits))
                        LabeledContent("退款", value: amount(action.plan.totals.refundMinorUnits))
                        LabeledContent("净支出", value: amount(action.plan.totals.netExpenseMinorUnits))
                    }
                    Text("预览包含完整选择。确认前不会修改交易；账本更新后需要重新预览。")
                        .font(.footnote).foregroundStyle(PFColor.secondaryText)
                    if action.plan.operation == .delete { Text("删除只隐藏记录，不会物理删除数据。").font(.footnote) }
                }
                .navigationTitle(action.title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { pendingAction = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action.confirmTitle) { perform(action.plan) }
                            .disabled(isBusy || action.plan.totals.totalCount == 0)
                            .accessibilityIdentifier("confirm-batch-action-plan")
                    }
                }
            }
        }
        .sheet(isPresented: $isTagReplacementPresented) {
            NavigationStack {
                Form {
                    Picker("来源标签", selection: $sourceTagID) {
                        Text("请选择").tag(nil as UUID?)
                        ForEach(tags) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("目标标签", selection: $targetTagID) {
                        Text("请选择").tag(nil as UUID?)
                        ForEach(tags.filter { $0.archivedAt == nil && $0.id != sourceTagID }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Text("选择来源和目标后，预览完整选择中实际受影响的记录。")
                }
                .navigationTitle("替换标签")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { isTagReplacementPresented = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("预览替换") {
                            guard let sourceTagID, let targetTagID else { return }
                            isTagReplacementPresented = false
                            let source = tags.first { $0.id == sourceTagID }?.name ?? ""
                            let target = tags.first { $0.id == targetTagID }?.name ?? ""
                            prepare(.tags(.replace(sourceID: sourceTagID, targetID: targetTagID)),
                                title: "确认替换标签", target: source + " → " + target, confirm: "替换")
                        }
                        .disabled(sourceTagID == nil || targetTagID == nil || sourceTagID == targetTagID)
                        .accessibilityIdentifier("confirm-batch-tag-replacement")
                    }
                }
            }
        }
        .alert("批量操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var tagMenu: some View {
        Menu {
            Menu("添加") {
                ForEach(tags.filter { $0.archivedAt == nil }) { tag in
                    Button(tag.name) { prepare(.tags(.add(tag.id)), title: "确认添加标签", target: tag.name, confirm: "确认变更") }
                }
            }
            Menu("移除") {
                ForEach(tags) { tag in
                    Button(tag.name) { prepare(.tags(.remove(tag.id)), title: "确认移除标签", target: tag.name, confirm: "确认变更") }
                }
            }
            Button("替换…") { sourceTagID = nil; targetTagID = nil; isTagReplacementPresented = true }
        } label: { actionLabel("标签", symbol: "tag") }
    }

    private func reloadSelection() async {
        totals = nil
        guard isPresentationEnabled else { return }
        let selection = selectionKey
        do {
            guard selectedIDs.isSubset(of: Set(snapshot.transactionIDs)) else { throw LedgerAnalysisError.staleSnapshot }
            let result = try await LedgerBatchOperationActor(modelContainer: modelContext.container)
                .selectionTotals(selectedIDs: selectedIDs, revision: snapshot.revision)
            try Task.checkCancellation()
            guard isPresentationEnabled, selection == selectionKey,
                  try LedgerSaveRevision.shared.readContentStamp() == snapshot.revision else { throw LedgerAnalysisError.staleSnapshot }
            totals = result
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    private func prepare(_ operation: LedgerBatchOperation, title: String, target: String, confirm: String = "确认迁移") {
        guard isPresentationEnabled, !isBusy else { return }
        let selection = selectionKey
        let request = generation
        isBusy = true
        Task {
            defer { if generation == request { isBusy = false } }
            do {
                let plan = try await LedgerBatchOperationActor(modelContainer: modelContext.container)
                    .plan(selectedIDs: selection.ids, operation: operation, revision: selection.revision)
                guard isPresentationEnabled, generation == request, try LedgerSaveRevision.shared.readContentStamp() == selection.revision else { throw LedgerAnalysisError.staleSnapshot }
                pendingAction = PendingBatchAction(title: title, target: target, confirmTitle: confirm, plan: plan)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func perform(_ plan: LedgerBatchPlan) {
        guard isPresentationEnabled, !isBusy else { return }
        let learningGeneration = ClassificationProfileStore.shared.generation
        isBusy = true
        Task {
            defer { isBusy = false; pendingAction = nil }
            do {
                let result = try await LedgerBatchOperationActor(modelContainer: modelContext.container).execute(plan)
                if result.summary.count > 0 { ledgerChangeCenter.recordMutation() }
                if !result.learningEvents.isEmpty {
                    do { try await ClassificationProfileStore.shared.record(result.learningEvents, generation: learningGeneration) }
                    catch { await SmartClassificationDiagnostics.shared.recordLearningWriteFailure() }
                }
                if plan.operation == .delete { onDeleted() }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func prepareExport() {
        guard isPresentationEnabled, !isBusy else { return }
        let selection = selectionKey
        let request = generation
        isBusy = true
        Task {
            defer { if generation == request { isBusy = false } }
            do {
                let data = try await LedgerAnalysisActor(modelContainer: modelContext.container)
                    .exportData(snapshot: snapshot, selectedIDs: selection.ids)
                guard isPresentationEnabled, generation == request, try LedgerSaveRevision.shared.readContentStamp() == selection.revision else {
                    throw LedgerAnalysisError.staleSnapshot
                }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SelectedExport-\(UUID())")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("所选记录.csv")
                try data.write(to: url, options: .atomic)
                exportURL = url
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold))
            .padding(.horizontal, PFSpacing.medium).frame(minHeight: 36)
            .background(PFColor.elevatedSurface, in: Capsule())
    }
    private func amount(_ value: Int64) -> String { (Decimal(value) / 100).formatted(.currency(code: Money.cnyCode).locale(locale)) }
}

private struct BatchSelectionKey: Equatable { let ids: Set<UUID>; let revision: UInt64; let isEnabled: Bool }
private struct PendingBatchAction: Identifiable {
    let id = UUID()
    let title: String
    let target: String
    let confirmTitle: String
    let plan: LedgerBatchPlan
}

struct LedgerFullResultBatchView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    let snapshot: LedgerAnalysisSnapshot

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PFSpacing.large) {
                    Text(snapshot.filter.dateRange.map { $0.lowerBound + " 至 " + $0.upperBound + "（不含）" } ?? "全部历史")
                    Text(snapshot.filter.mode.title + " · 完整筛选结果 \(snapshot.transactionIDs.count) 笔")
                    ForEach(scopeDetails, id: \.self) { Text($0).font(.caption) }
                    TransactionBatchActionsView(selectedIDs: Set(snapshot.transactionIDs), snapshot: snapshot,
                        categories: categories, accounts: accounts, tags: tags, onDeleted: { dismiss() })
                }.padding(PFSpacing.xLarge)
            }
            .navigationTitle("完整结果批量操作")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
    }

    private var scopeDetails: [String] {
        let filter = snapshot.filter
        var values: [String] = []
        switch filter.category {
        case .all: break
        case .uncategorized: values.append("待分类")
        case let .node(id): values.append("分类：" + snapshot.metadata.path(id))
        case let .direct(id): values.append("直接挂账：" + snapshot.metadata.path(id))
        }
        if let id = filter.accountID { values.append("账户：" + (snapshot.metadata.accounts[id] ?? "指定账户")) }
        if !filter.tagIDs.isEmpty {
            values.append("同时包含标签：" + filter.tagIDs.compactMap { snapshot.metadata.tags[$0] }.sorted().joined(separator: "、"))
        }
        if !filter.merchant.isEmpty { values.append("商户包含：" + filter.merchant) }
        if !filter.query.isEmpty { values.append("范围内搜索：" + filter.query) }
        return values
    }

}
