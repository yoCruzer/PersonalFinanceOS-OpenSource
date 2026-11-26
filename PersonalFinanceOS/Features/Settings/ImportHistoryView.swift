import SwiftData
import SwiftUI

struct ImportHistoryView: View {
    @Query(sort: \ImportBatch.startedAt, order: .reverse) private var batches: [ImportBatch]

    var body: some View {
        List {
            ForEach(batches) { batch in
                NavigationLink {
                    ImportBatchDetailView(batch: batch)
                } label: {
                    VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
                        HStack {
                            Text(batch.sourceDisplayName.isEmpty ? sourceName(batch.sourceType) : batch.sourceDisplayName)
                                .font(.headline)
                            Spacer()
                            Text(statusName(batch.status))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(batch.status == .rolledBack ? PFColor.danger : PFColor.accent)
                        }
                        Text("\(sourceName(batch.sourceType)) · \(batch.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(PFColor.secondaryText)
                        Text("导入 \(batch.importedRowCount) · 跳过 \(batch.skippedRowCount) · 重复 \(duplicateCount(batch)) · 错误 \(batch.errorRowCount)")
                            .font(.caption)
                        Text(ImportBatchHistoryService.hasRecordedTotals(batch) ? "收入 \(money(batch.incomeMinorUnits)) · 支出 \(money(batch.expenseMinorUnits))" : "原始合计未记录")
                            .font(.caption)
                            .foregroundStyle(PFColor.secondaryText)
                    }
                    .padding(.vertical, PFSpacing.xSmall)
                }
            }
        }
        .overlay {
            if batches.isEmpty {
                PFEmptyState(
                    symbol: "clock.arrow.circlepath",
                    title: "还没有导入记录",
                    message: "完成一次账单导入后，可在这里查看批次和安全撤销。"
                )
            }
        }
        .navigationTitle("导入历史")
    }
}

private struct ImportBatchDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @Query private var categories: [Category]
    @Query private var accounts: [Account]

    let batch: ImportBatch
    @State private var preserveEdited = true
    @State private var includeUncertain = false
    @State private var reviewedSummary: ImportBatchHistorySummary?
    @State private var isRollbackConfirmationPresented = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var loadedTransactions: [FinanceTransaction] = []
    @State private var summarySnapshot: ImportBatchHistorySummary?
    @State private var isRollingBack = false
    @State private var didRollback = false

    private var batchTransactions: [FinanceTransaction] {
        loadedTransactions
    }

    private var summary: ImportBatchHistorySummary {
        summarySnapshot ?? ImportBatchHistorySummary(
            currentActiveCount: 0,
            editedCount: 0,
            uncertainCount: 0,
            reviewRevision: 0,
            manuallyDeletedCount: 0,
            incomeMinorUnits: batch.incomeMinorUnits,
            expenseMinorUnits: batch.expenseMinorUnits
        )
    }

    private var categoriesByID: [UUID: Category] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }

    private var accountsByID: [UUID: Account] {
        Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    }

    var body: some View {
        List {
            Section("批次") {
                LabeledContent("文件", value: batch.sourceDisplayName.isEmpty ? "未知" : batch.sourceDisplayName)
                LabeledContent("来源", value: sourceName(batch.sourceType))
                LabeledContent("时间", value: batch.startedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("状态", value: statusName(batch.status))
                LabeledContent(
                    "导入 / 跳过 / 重复 / 错误",
                    value: "\(batch.importedRowCount) / \(batch.skippedRowCount) / \(duplicateCount(batch)) / \(batch.errorRowCount)"
                )
                let recorded = ImportBatchHistoryService.hasRecordedTotals(batch)
                LabeledContent(recorded ? "收入" : "按现有记录估算收入", value: money(summary.incomeMinorUnits))
                LabeledContent(recorded ? "支出" : "按现有记录估算支出", value: money(summary.expenseMinorUnits))
            }

            Section("当前状态") {
                LabeledContent("有效交易", value: "\(summary.currentActiveCount)")
                LabeledContent("有人工分类确认", value: "\(summary.editedCount)")
                LabeledContent("修改来源不确定", value: "\(summary.uncertainCount)")
                    .accessibilityIdentifier("rollback-uncertain-count")
                LabeledContent("可证明未修改", value: "\(summary.safelyUnmodifiedCount)")
                LabeledContent("已手动删除", value: "\(summary.manuallyDeletedCount)")
                if let rolledBackAt = batch.rolledBackAt {
                    LabeledContent("撤销时间", value: rolledBackAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if batch.status != .rolledBack, !didRollback {
                Section {
                    if summary.editedCount > 0 {
                        Toggle("保留人工分类确认的交易", isOn: $preserveEdited)
                            .accessibilityIdentifier("rollback-preserve-manual")
                        Text("默认保留 \(summary.editedCount) 笔有人工分类确认的交易；此记录不代表所有字段的编辑历史。")
                            .font(.footnote)
                            .foregroundStyle(PFColor.secondaryText)
                    }
                    if summary.uncertainCount > 0 {
                        Toggle("同时撤销来源不确定的交易", isOn: $includeUncertain)
                            .accessibilityIdentifier("rollback-include-uncertain")
                        Text("这 \(summary.uncertainCount) 笔可能未改动，也可能含人工编辑、同步或系统变更。时间戳不能证明修改来源，默认保留；勾选后才会一并软删除。")
                            .font(.footnote)
                            .foregroundStyle(PFColor.secondaryText)
                    }
                    Button("撤销此导入批次", role: .destructive) {
                        prepareConfirmation()
                    }
                    .disabled(isRollingBack || summarySnapshot == nil)
                    .accessibilityIdentifier("rollback-import-batch")
                } footer: {
                    Text("只会软删除此批次关联的交易，不会删除账户、分类或标签。")
                }
            }

            Section("批次交易") {
                if summary.currentActiveCount + summary.manuallyDeletedCount > loadedTransactions.count {
                    Text("为保持页面流畅，仅展示最近 \(loadedTransactions.count) 笔预览。")
                        .font(.footnote)
                        .foregroundStyle(PFColor.secondaryText)
                }
                ForEach(batchTransactions) { transaction in
                    HStack {
                        PFTransactionRow(
                            transaction: transaction,
                            category: transaction.categoryID.flatMap { categoriesByID[$0] },
                            account: transaction.accountID.flatMap { accountsByID[$0] },
                            categoryPath: transaction.categoryID.flatMap { categoriesByID[$0] }
                                .map { $0.displayPath(in: categories) },
                            destinationAccount: transaction.destinationAccountID.flatMap { accountsByID[$0] }
                        )
                        if transaction.deletedAt != nil {
                            Text("已删除")
                                .font(.caption2)
                                .foregroundStyle(PFColor.danger)
                        }
                    }
                }
            }
        }
        .navigationTitle("导入批次")
        .task { reloadBatchDetails() }
        .confirmationDialog(
            "撤销此导入批次？",
            isPresented: $isRollbackConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("确认撤销", role: .destructive) { rollback() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .alert("无法撤销导入", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("撤销完成", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private var confirmationMessage: String {
        guard let current = reviewedSummary else { return "请重新查看交易状态。" }
        let selected = current.safelyUnmodifiedCount + (preserveEdited ? 0 : current.editedCount)
            + (includeUncertain ? current.uncertainCount : 0)
        return "将软删除 \(selected) 笔。人工分类确认 \(current.editedCount) 笔：\(preserveEdited ? "保留" : "一并撤销")；来源不确定 \(current.uncertainCount) 笔：\(includeUncertain ? "已选择一并撤销，可能包含人工修改" : "保留")。"
    }

    private func prepareConfirmation() {
        guard !isRollingBack else { return }
        isRollingBack = true
        let container = modelContext.container
        let batchID = batch.id
        Task {
            defer { isRollingBack = false }
            do {
                let current = try await ImportRollbackActor(modelContainer: container).summary(batchID: batchID)
                guard current.reviewRevision == summarySnapshot?.reviewRevision else {
                    summarySnapshot = current
                    preserveEdited = true
                    includeUncertain = false
                    throw ImportBatchHistoryError.staleReview
                }
                reviewedSummary = current
                isRollbackConfirmationPresented = true
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func rollback() {
        guard !isRollingBack else { return }
        let container = modelContext.container
        let batchID = batch.id
        isRollingBack = true
        Task {
            do {
                let worker = ImportRollbackActor(modelContainer: container)
                let result = try await worker.rollback(
                    batchID: batchID,
                    preserveEdited: preserveEdited,
                    includeUncertain: includeUncertain,
                    reviewedRevision: reviewedSummary?.reviewRevision
                )
                if result.deletedCount > 0 { ledgerChangeCenter.recordMutation() }
                didRollback = result.deletedCount > 0 || result.alreadyRolledBack
                resultMessage = "已软删除 \(result.deletedCount) 笔，保留人工分类确认 \(result.preservedEditedCount) 笔，保留来源不确定 \(result.preservedUncertainCount) 笔。"
                reloadBatchDetails()
            } catch {
                preserveEdited = true
                includeUncertain = false
                reviewedSummary = nil
                errorMessage = error.localizedDescription
                reloadBatchDetails()
            }
            isRollingBack = false
        }
    }

    private func reloadBatchDetails() {
        let container = modelContext.container
        let batchID = batch.id
        Task {
            do {
                let worker = ImportRollbackActor(modelContainer: container)
                summarySnapshot = try await worker.summary(batchID: batchID)
                loadedTransactions = try LedgerQueryService.fetchImportBatch(
                    batchID,
                    limit: 100,
                    in: modelContext
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private func sourceName(_ source: ImportSourceType) -> String {
    switch source {
    case .wacai: "挖财"
    case .wechat: "微信"
    case .alipay: "支付宝"
    case .jd: "京东"
    case .genericCSV: "通用格式"
    }
}

private func duplicateCount(_ batch: ImportBatch) -> String {
    batch.duplicateRowCount.map(String.init) ?? "未知"
}

private func statusName(_ status: ImportBatchStatus) -> String {
    switch status {
    case .preparing: "准备中"
    case .readyForReview: "待确认"
    case .importing: "导入中"
    case .completed: "已完成"
    case .failed: "失败"
    case .rolledBack: "已撤销"
    }
}

private func money(_ minorUnits: Int64) -> String {
    let absolute = minorUnits == .min ? Int64.max : abs(minorUnits)
    let amount = (try? Money(minorUnits: absolute).formatted()) ?? "未知"
    return minorUnits < 0 ? "−\(amount)" : amount
}
