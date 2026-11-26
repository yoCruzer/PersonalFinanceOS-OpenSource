import SwiftData
import SwiftUI

struct AccountDeletionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    let account: Account
    let onCompleted: (String) -> Void
    @State private var analysis: MetadataDeletionAnalysis?
    @State private var targetID: UUID?
    @State private var isSubmitting = false
    @State private var isConfirming = false
    @State private var errorMessage: String?
    @State private var validTargetIDs: Set<UUID> = []

    private var targets: [Account] {
        return accounts.filter { target in
            validTargetIDs.contains(target.id)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                deletionHeader(name: account.name, kind: "账户")
                if let analysis {
                    DeletionAnalysisSummary(analysis: analysis)
                    if analysis.affectedTransactionCount > 0 {
                        Section("迁移关联交易") {
                            Text("必须先把全部关联交易迁移到另一个可用账户。")
                                .foregroundStyle(PFColor.secondaryText)
                            Picker("目标账户", selection: $targetID) {
                                Text("请选择").tag(Optional<UUID>.none)
                                ForEach(targets) { target in
                                    Text(target.name).tag(Optional(target.id))
                                }
                            }
                        }
                    }
                    actionSection(
                        canDelete: !analysis.isLastAvailable &&
                        !analysis.hasUnmigratableRelationships &&
                        (analysis.affectedTransactionCount == 0 || targetID != nil)
                    )
                    if !isConfirming, let errorMessage {
                        deletionErrorSection(errorMessage)
                    }
                } else {
                    ProgressView("正在检查全部本地数据…")
                }
            }
            .navigationTitle("删除账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSubmitting)
                }
            }
            .task { loadAnalysis() }
        }
    }

    @ViewBuilder
    private func actionSection(canDelete: Bool) -> some View {
        Section {
            Button(
                analysis?.affectedTransactionCount == 0 ? "永久删除" : "迁移并永久删除",
                role: .destructive
            ) {
                errorMessage = nil
                isConfirming = true
            }
            .disabled(!canDelete || isSubmitting)
            .accessibilityIdentifier("confirm-account-deletion-plan")
            .popover(isPresented: $isConfirming, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                DeletionConfirmationPopover(
                    title: "永久删除“\(account.name)”？",
                    message: accountConfirmationMessage,
                    isSubmitting: isSubmitting,
                    errorMessage: errorMessage,
                    onCancel: cancelConfirmation,
                    onConfirm: deleteAccount
                )
                .presentationCompactAdaptation(.popover)
            }
            if account.archivedAt == nil {
                Button("仅停用") { archiveAccount() }
                    .disabled(isSubmitting)
            }
            Button("取消", role: .cancel) { dismiss() }
                .disabled(isSubmitting)
        } footer: {
            if analysis?.isLastAvailable == true {
                Text("至少需要保留一个可用账户，因此当前账户不能永久删除。")
            } else if analysis?.hasUnmigratableRelationships == true {
                Text("现有目标都会造成转账两端相同，无法安全迁移。")
            } else if analysis?.affectedTransactionCount == 0 {
                Text("没有关联交易。永久删除后不可恢复。")
            }
        }
    }

    private func loadAnalysis() {
        let container = modelContext.container
        let id = account.id
        Task {
            do {
                let plan = try await MetadataMutationActor(
                    modelContainer: container
                ).analyzeAccount(id: id)
                analysis = plan.analysis
                validTargetIDs = plan.validTargetIDs
                targetID = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var accountConfirmationMessage: String {
        let count = analysis?.affectedTransactionCount ?? 0
        guard let target = targetID.flatMap({ id in targets.first { $0.id == id } }) else {
            return "将永久删除“\(account.name)”。此操作不可恢复。"
        }
        return "将把“\(account.name)”关联的 \(count) 笔交易迁移到“\(target.name)”，然后永久删除来源账户。"
    }

    private func deleteAccount() {
        guard !isSubmitting else { return }
        let container = modelContext.container
        let id = account.id
        let destinationID = targetID
        isSubmitting = true
        Task {
            do {
                let result = try await MetadataMutationActor(
                    modelContainer: container
                ).deleteAccount(id: id, targetID: destinationID)
                if result.changedTransactionCount > 0 { ledgerChangeCenter.recordMutation() }
                onCompleted("账户已永久删除")
                dismiss()
            } catch {
                isSubmitting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelConfirmation() {
        isConfirming = false
        errorMessage = nil
    }

    private func archiveAccount() {
        submit(success: "账户已停用") {
            try FinanceDataManagementService.setAccountActive(
                account,
                isActive: false,
                accounts: accounts,
                in: modelContext
            )
        }
    }

    private func submit(success: String, operation: () throws -> Void) {
        guard !isSubmitting else { return }
        isSubmitting = true
        do {
            try operation()
            onCompleted(success)
            dismiss()
        } catch {
            isSubmitting = false
            errorMessage = error.localizedDescription
        }
    }
}

struct CategoryDeletionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    let category: Category
    let onCompleted: (String) -> Void
    @State private var analysis: MetadataDeletionAnalysis?
    @State private var targetID: UUID?
    @State private var isSubmitting = false
    @State private var isConfirming = false
    @State private var errorMessage: String?
    @State private var validTargetIDs: Set<UUID> = []

    private var targets: [Category] {
        CategoryHierarchy(categories: categories)
            .selectableCategories(kind: category.kind)
            .filter { validTargetIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                deletionHeader(name: category.name, kind: "分类")
                if let analysis {
                    DeletionAnalysisSummary(analysis: analysis)
                    if analysis.childObjectCount > 0 {
                        Section("需先处理小类") {
                            Text("“\(category.name)”下仍有 \(analysis.childObjectCount) 个小类。请返回分类管理，逐个迁移、停用或删除小类后，再删除此大类。")
                                .foregroundStyle(PFColor.secondaryText)
                        }
                    }
                    if analysis.affectedTransactionCount > 0 {
                        Section("迁移关联交易") {
                            Text("目标必须是同收支类型的可用分类。")
                                .foregroundStyle(PFColor.secondaryText)
                            Picker("目标分类", selection: $targetID) {
                                Text("请选择").tag(Optional<UUID>.none)
                                ForEach(targets) { target in
                                    Text(target.displayPath(in: categories)).tag(Optional(target.id))
                                }
                            }
                        }
                    }
                    actionSection(
                        canDelete: !analysis.isLastAvailable &&
                        !analysis.hasUnmigratableRelationships &&
                        (analysis.affectedTransactionCount == 0 || targetID != nil)
                    )
                    if !isConfirming, let errorMessage {
                        deletionErrorSection(errorMessage)
                    }
                } else {
                    ProgressView("正在检查全部本地数据…")
                }
            }
            .navigationTitle("删除分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSubmitting)
                }
            }
            .task { loadAnalysis() }
        }
    }

    @ViewBuilder
    private func actionSection(canDelete: Bool) -> some View {
        Section {
            Button(
                analysis?.affectedTransactionCount == 0 ? "永久删除" : "迁移并永久删除",
                role: .destructive
            ) {
                errorMessage = nil
                isConfirming = true
            }
            .disabled(!canDelete || isSubmitting)
            .accessibilityIdentifier("confirm-category-deletion-plan")
            .popover(isPresented: $isConfirming, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                DeletionConfirmationPopover(
                    title: "永久删除“\(category.displayPath(in: categories))”？",
                    message: categoryConfirmationMessage,
                    isSubmitting: isSubmitting,
                    errorMessage: errorMessage,
                    onCancel: cancelConfirmation,
                    onConfirm: deleteCategory
                )
                .presentationCompactAdaptation(.popover)
            }
            if category.archivedAt == nil {
                Button("仅停用") { archiveCategory() }
                    .disabled(isSubmitting)
            }
            Button("取消", role: .cancel) { dismiss() }
                .disabled(isSubmitting)
        } footer: {
            if analysis?.hasUnmigratableRelationships == true {
                Text("大类有小类时不能直接删除，请先处理全部小类。")
            } else if analysis?.isLastAvailable == true {
                Text("每种收支类型至少需要保留一个可用分类。")
            } else if analysis?.affectedTransactionCount == 0 {
                Text("没有关联交易。永久删除后不可恢复。")
            }
        }
    }

    private func loadAnalysis() {
        let container = modelContext.container
        let id = category.id
        Task {
            do {
                let plan = try await MetadataMutationActor(
                    modelContainer: container
                ).analyzeCategory(id: id)
                analysis = plan.analysis
                validTargetIDs = plan.validTargetIDs
                targetID = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var categoryConfirmationMessage: String {
        let count = analysis?.affectedTransactionCount ?? 0
        guard let target = targetID.flatMap({ id in targets.first { $0.id == id } }) else {
            return "将永久删除“\(category.displayPath(in: categories))”。此操作不可恢复。"
        }
        return "将把“\(category.displayPath(in: categories))”关联的 \(count) 笔交易迁移到“\(target.displayPath(in: categories))”，然后永久删除来源分类。"
    }

    private func deleteCategory() {
        guard !isSubmitting else { return }
        let container = modelContext.container
        let id = category.id
        let destinationID = targetID
        isSubmitting = true
        Task {
            do {
                let result = try await MetadataMutationActor(
                    modelContainer: container
                ).deleteCategory(id: id, targetID: destinationID)
                if result.changedTransactionCount > 0 { ledgerChangeCenter.recordMutation() }
                onCompleted("分类已永久删除")
                dismiss()
            } catch {
                isSubmitting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelConfirmation() {
        isConfirming = false
        errorMessage = nil
    }

    private func archiveCategory() {
        submit(success: "分类已停用") {
            try FinanceDataManagementService.setCategoryActive(
                category,
                isActive: false,
                categories: categories,
                in: modelContext
            )
        }
    }

    private func submit(success: String, operation: () throws -> Void) {
        guard !isSubmitting else { return }
        isSubmitting = true
        do {
            try operation()
            onCompleted(success)
            dismiss()
        } catch {
            isSubmitting = false
            errorMessage = error.localizedDescription
        }
    }
}

struct TagDeletionView: View {
    private enum LinkedAction: String, CaseIterable {
        case remove
        case replace
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]

    let tag: Tag
    let onCompleted: () -> Void
    @State private var analysis: MetadataDeletionAnalysis?
    @State private var linkedAction: LinkedAction = .remove
    @State private var targetID: UUID?
    @State private var isSubmitting = false
    @State private var isConfirming = false
    @State private var errorMessage: String?
    @State private var validTargetIDs: Set<UUID> = []

    private var targets: [Tag] {
        tags.filter { validTargetIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                deletionHeader(name: tag.name, kind: "标签")
                if let analysis {
                    DeletionAnalysisSummary(analysis: analysis)
                    if analysis.affectedTransactionCount > 0 {
                        Section("处理关联交易") {
                            Picker("处理方式", selection: $linkedAction) {
                                Text("从交易移除").tag(LinkedAction.remove)
                                Text("替换为其他标签").tag(LinkedAction.replace)
                            }
                            if linkedAction == .replace {
                                Picker("目标标签", selection: $targetID) {
                                    Text("请选择").tag(Optional<UUID>.none)
                                    ForEach(targets) { target in
                                        Text(target.name).tag(Optional(target.id))
                                    }
                                }
                            }
                        }
                    }
                    actionSection(analysis: analysis)
                    if !isConfirming, let errorMessage {
                        deletionErrorSection(errorMessage)
                    }
                } else {
                    ProgressView("正在检查全部本地数据…")
                }
            }
            .navigationTitle("删除标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSubmitting)
                }
            }
            .task { loadAnalysis() }
            .onChange(of: linkedAction) { _, action in
                if action == .replace { targetID = nil }
            }
        }
    }

    @ViewBuilder
    private func actionSection(analysis: MetadataDeletionAnalysis) -> some View {
        Section {
            Button(tagDeleteButtonTitle, role: .destructive) {
                errorMessage = nil
                isConfirming = true
            }
            .disabled(
                isSubmitting ||
                (analysis.affectedTransactionCount > 0 &&
                linkedAction == .replace && targetID == nil)
            )
            .accessibilityIdentifier("confirm-tag-deletion-plan")
            .popover(isPresented: $isConfirming, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                DeletionConfirmationPopover(
                    title: "永久删除“\(tag.name)”？",
                    message: tagConfirmationMessage,
                    isSubmitting: isSubmitting,
                    errorMessage: errorMessage,
                    onCancel: cancelConfirmation,
                    onConfirm: deleteTag
                )
                .presentationCompactAdaptation(.popover)
            }
            if tag.archivedAt == nil {
                Button("仅停用") { archiveTag() }
                    .disabled(isSubmitting)
            }
            Button("取消", role: .cancel) { dismiss() }
                .disabled(isSubmitting)
        } footer: {
            Text("永久删除不可恢复，但不会删除任何交易或其他标签。")
        }
    }

    private func loadAnalysis() {
        let container = modelContext.container
        let id = tag.id
        Task {
            do {
                let plan = try await MetadataMutationActor(
                    modelContainer: container
                ).analyzeTag(id: id)
                analysis = plan.analysis
                validTargetIDs = plan.validTargetIDs
                targetID = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var tagDeleteButtonTitle: String {
        guard (analysis?.affectedTransactionCount ?? 0) > 0 else { return "永久删除" }
        return linkedAction == .replace ? "迁移并永久删除" : "移除并永久删除"
    }

    private var tagConfirmationMessage: String {
        let count = analysis?.affectedTransactionCount ?? 0
        guard count > 0 else {
            return "将永久删除“\(tag.name)”。此操作不可恢复。"
        }
        if linkedAction == .remove {
            return "将从 \(count) 笔交易移除“\(tag.name)”，然后永久删除来源标签。此操作不可恢复。"
        }
        guard let target = targetID.flatMap({ id in targets.first { $0.id == id } }) else {
            return "请选择目标标签后再继续。"
        }
        return "将 \(count) 笔交易中的“\(tag.name)”替换为“\(target.name)”，然后永久删除来源标签。此操作不可恢复。"
    }

    private func deleteTag() {
        let resolution: TagDeletionResolution?
        if analysis?.affectedTransactionCount == 0 {
            resolution = nil
        } else if linkedAction == .remove {
            resolution = .remove
        } else {
            resolution = targetID.map(TagDeletionResolution.replace(with:))
        }
        guard !isSubmitting else { return }
        let container = modelContext.container
        let id = tag.id
        isSubmitting = true
        Task {
            do {
                let result = try await MetadataMutationActor(
                    modelContainer: container
                ).deleteTag(id: id, resolution: resolution)
                if result.changedTransactionCount > 0 { ledgerChangeCenter.recordMutation() }
                onCompleted()
                dismiss()
            } catch {
                isSubmitting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelConfirmation() {
        isConfirming = false
        errorMessage = nil
    }

    private func archiveTag() {
        submit {
            try FinanceDataManagementService.setTagActive(
                tag,
                isActive: false,
                in: modelContext
            )
        }
    }

    private func submit(operation: () throws -> Void) {
        guard !isSubmitting else { return }
        isSubmitting = true
        do {
            try operation()
            onCompleted()
            dismiss()
        } catch {
            isSubmitting = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct DeletionAnalysisSummary: View {
    let analysis: MetadataDeletionAnalysis

    var body: some View {
        Section("影响范围") {
            LabeledContent("直接关联交易", value: "\(analysis.directTransactionCount)")
            LabeledContent("间接关联交易", value: "\(analysis.indirectTransactionCount)")
            LabeledContent("子对象", value: "\(analysis.childObjectCount)")
            if analysis.affectedTransferCount > 0 {
                LabeledContent("受影响转账", value: "\(analysis.affectedTransferCount)")
            }
            if analysis.isDefaultOrPreferred {
                Label("当前为默认或快捷对象", systemImage: "exclamationmark.circle")
                    .foregroundStyle(PFColor.secondaryText)
            }
        }
    }
}

private struct DeletionConfirmationPopover: View {
    let title: String
    let message: String
    let isSubmitting: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @AccessibilityFocusState private var isHeadingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PFSpacing.medium) {
            Text(title)
                .font(.headline)
                .foregroundStyle(PFColor.danger)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isHeadingFocused)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(PFColor.secondaryText)
            Label("此操作不可恢复", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PFColor.danger)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(PFColor.danger)
                    .accessibilityIdentifier("deletion-error")
            }

            if isSubmitting {
                ProgressView("正在重新检查并删除…")
            }

            Button("确认永久删除", role: .destructive, action: onConfirm)
                .buttonStyle(.borderedProminent)
                .tint(PFColor.danger)
                .disabled(isSubmitting)
                .accessibilityIdentifier("confirm-permanent-deletion")
            Button("取消", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .disabled(isSubmitting)
                .accessibilityIdentifier("cancel-permanent-deletion")
        }
        .padding(PFSpacing.large)
        .frame(width: 300)
        .task {
            await Task.yield()
            isHeadingFocused = true
        }
    }
}

private func deletionErrorSection(_ message: String) -> some View {
    Section {
        Label(message, systemImage: "exclamationmark.circle")
            .foregroundStyle(PFColor.danger)
    } header: {
        Text("无法完成操作")
    }
}

private func deletionHeader(name: String, kind: String) -> some View {
    Section {
        VStack(alignment: .leading, spacing: PFSpacing.small) {
            Label("永久删除\(kind)", systemImage: "trash")
                .font(.headline)
                .foregroundStyle(PFColor.danger)
            Text("“\(name)”删除后不可恢复。提交前会先检查完整本地账本。")
                .foregroundStyle(PFColor.secondaryText)
        }
        .padding(.vertical, PFSpacing.small)
    }
}
