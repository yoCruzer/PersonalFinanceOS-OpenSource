import SwiftData
import SwiftUI

struct TransactionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @Query private var categories: [Category]
    @Query private var accounts: [Account]

    let transaction: FinanceTransaction
    let onChanged: () -> Void
    @State private var isEditing = false
    @State private var duplicateDraft: TransactionDraft?
    @State private var isDeleteConfirmationPresented = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    init(
        transaction: FinanceTransaction,
        onChanged: @escaping () -> Void = {}
    ) {
        self.transaction = transaction
        self.onChanged = onChanged
    }
    @State private var editSucceeded = false

    private var category: Category? {
        categories.first { $0.id == transaction.categoryID }
    }

    private var account: Account? {
        accounts.first { $0.id == transaction.accountID }
    }

    private var typePresentation: TransactionTypePresentation {
        TransactionAccountingSemantics.presentation(for: transaction.type)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PFSpacing.large) {
                amountHeader
                detailFields

                HStack(spacing: PFSpacing.medium) {
                    Button {
                        duplicateDraft = TransactionDuplicationService.makeDraft(from: transaction)
                    } label: {
                        Label("复制", systemImage: "plus.square.on.square")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(PFColor.accent)
                    .disabled(transaction.type == .transfer)
                    .accessibilityIdentifier("transaction-duplicate")

                    Button("删除", role: .destructive) {
                        isDeleteConfirmationPresented = true
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(PFColor.danger)
                    .background(
                        PFColor.danger.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: PFRadius.medium, style: .continuous)
                    )
                    .popover(isPresented: $isDeleteConfirmationPresented, arrowEdge: .bottom) {
                        deleteConfirmation
                            .presentationCompactAdaptation(.popover)
                    }
                    .accessibilityIdentifier("transaction-delete")
                }
            }
            .padding(PFSpacing.xLarge)
        }
        .background(PFColor.background)
        .navigationTitle("交易详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") {
                    isEditing = true
                }
                .disabled(transaction.type == .transfer)
                .accessibilityIdentifier("transaction-edit")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if transaction.type == .transfer {
                Text("为保护转出与转入账户，当前版本暂不支持编辑或复制转账。")
                    .font(.footnote)
                    .foregroundStyle(PFColor.secondaryText)
                    .padding(.horizontal, PFSpacing.xLarge)
                    .padding(.vertical, PFSpacing.small)
                    .background(.bar)
            }
        }
        .sheet(isPresented: $isEditing) {
            TransactionFormView(transaction: transaction) {
                editSucceeded = true
                onChanged()
                Task {
                    try? await Task.sleep(for: .seconds(1.8))
                    editSucceeded = false
                }
            }
                .presentationDetents([.large])
        }
        .sheet(
            isPresented: Binding(
                get: { duplicateDraft != nil },
                set: { if !$0 { duplicateDraft = nil } }
            )
        ) {
            if let duplicateDraft {
                TransactionFormView(initialDraft: duplicateDraft, onSaved: onChanged)
                    .presentationDetents([.large])
            }
        }
        .overlay(alignment: .bottom) {
            if editSucceeded {
                Label("修改已保存", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, PFSpacing.large)
                    .padding(.vertical, PFSpacing.medium)
                    .background(.black.opacity(0.78), in: Capsule())
                    .padding(.bottom, PFSpacing.xLarge)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: editSucceeded)
        .alert(
            "无法删除交易",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var amountHeader: some View {
        VStack(spacing: PFSpacing.small) {
            CategoryIconView(
                symbolName: category?.symbolName ?? CategoryIconLibrary.fallback,
                color: PFColor.category(category?.colorToken ?? "teal"),
                size: 42
            )
            Text(typePresentation.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(typePresentation.color)
            AmountText(
                minorUnits: transaction.amountMinorUnits,
                currencyCode: transaction.currencyCode,
                style: .largeTitle,
                prefix: typePresentation.amountPrefix
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PFSpacing.medium)
    }

    private var deleteConfirmation: some View {
        VStack(alignment: .leading, spacing: PFSpacing.medium) {
            Text("删除这笔交易？")
                .font(.subheadline.weight(.semibold))
            Text("删除后将不再显示在流水中。")
                .font(.caption)
                .foregroundStyle(PFColor.secondaryText)
            HStack(spacing: PFSpacing.medium) {
                Button("确认删除", role: .destructive) {
                    guard !isDeleting else { return }
                    isDeleting = true
                    delete()
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.borderedProminent)
                .tint(PFColor.danger)
                .disabled(isDeleting)
                .accessibilityIdentifier("transaction-delete-confirm")

                Button("取消", role: .cancel) {
                    isDeleteConfirmationPresented = false
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.bordered)
                .disabled(isDeleting)
                .accessibilityIdentifier("transaction-delete-cancel")
            }
        }
        .padding(PFSpacing.large)
        .background(
            PFColor.danger.opacity(0.08),
            in: RoundedRectangle(cornerRadius: PFRadius.medium, style: .continuous)
        )
        .frame(width: 280)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transaction-delete-confirmation")
    }

    private var detailFields: some View {
        VStack(spacing: 0) {
            detailRow(label: "类型", value: typePresentation.title)
            Divider()
            detailRow(
                label: "分类",
                value: category?.displayPath(in: categories) ?? "待分类"
            )
            Divider()
            detailRow(label: "账户", value: account?.name ?? "未知账户")
            Divider()
            detailRow(
                label: "日期与时间",
                value: AppDateFormatter.dateTime(
                    transaction.occurredAt,
                    locale: locale,
                    timeZone: transactionTimeZone
                )
            )
            if !transaction.rawMerchantText.isEmpty {
                Divider()
                detailRow(label: "商户", value: transaction.rawMerchantText)
            }
            if !transaction.note.isEmpty {
                Divider()
                detailRow(label: "备注", value: transaction.note)
            }
            if !transaction.tags.isEmpty {
                Divider()
                detailRow(
                    label: "标签",
                    value: transaction.tags.map(\.name).sorted().joined(separator: " · ")
                )
            }
        }
        .padding(.horizontal, PFSpacing.large)
        .background(
            PFColor.elevatedSurface,
            in: RoundedRectangle(cornerRadius: PFRadius.medium, style: .continuous)
        )
    }

    private var transactionTimeZone: TimeZone {
        TimeZone(identifier: transaction.timeZoneIdentifier) ?? .autoupdatingCurrent
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PFSpacing.large) {
            Text(label)
                .foregroundStyle(PFColor.secondaryText)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, PFSpacing.medium)
    }

    private func delete() {
        do {
            try TransactionLifecycleService.softDelete(transaction, in: modelContext)
            ledgerChangeCenter.recordMutation()
            onChanged()
            dismiss()
        } catch {
            isDeleting = false
            deleteError = error.localizedDescription
        }
    }
}
