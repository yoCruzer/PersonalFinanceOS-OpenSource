import SwiftData
import SwiftUI

struct FirstJoinCategoryReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ICloudSyncController.self) private var sync
    @Environment(LedgerChangeCenter.self) private var changes
    @Environment(\.dismiss) private var dismiss

    @State var review: ICloudSyncController.CategoryReview
    @State private var choices: [String: FirstJoinCategoryAdmission.Choice] = [:]
    @State private var isWorking = false
    @State private var confirm = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("首次合流前，请确认这些分类使用哪一端的设置。本机交易已保留，稍后处理也可继续记账。")
                Text("采用云端设置会更新所选分类及必要的所属大类。若删除会影响本机交易或小类，需要先在分类管理中处理关联。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("全部保留本机现有分类") {
                    for conflict in review.conflicts where conflict.local != nil {
                        choices[conflict.id] = .local
                    }
                }
                .disabled(isWorking)
            }

            ForEach(review.conflicts) { conflict in
                Section(conflict.local?.name ?? conflict.remote?.name ?? "分类") {
                    description(conflict.local, remote: false)
                    description(conflict.remote, remote: true)
                    if conflict.remoteDeleted {
                        Text("云端有此默认分类的删除记录。保留本机分类会明确将它重新加入同步。")
                            .font(.footnote)
                    } else if conflict.remote == nil {
                        Text("云端尚未出现此分类。可稍后重试，或明确选择加入本机分类。")
                            .font(.footnote)
                    }
                    if conflict.local == nil {
                        Text("本机删除意图已保留。若继续保留删除，请在已同步设备完成对应删除后重试；也可明确采用云端分类。")
                            .font(.footnote)
                    }
                    Picker("处理方式", selection: Binding(
                        get: { choices[conflict.id] },
                        set: { choices[conflict.id] = $0 }
                    )) {
                        Text("请选择").tag(Optional<FirstJoinCategoryAdmission.Choice>.none)
                        if conflict.local != nil {
                            Text("保留本机").tag(Optional(FirstJoinCategoryAdmission.Choice.local))
                        }
                        if conflict.remote != nil || conflict.remoteDeleted {
                            Text(conflict.remote == nil ? "采用云端删除" : "采用云端")
                                .tag(Optional(FirstJoinCategoryAdmission.Choice.remote))
                        }
                    }
                    .disabled(isWorking)
                }
            }

            Section {
                Button("按选择继续同步") { confirm = true }
                    .disabled(isWorking || choices.count != review.conflicts.count)
                    .accessibilityIdentifier("confirm-category-join")
                Button("稍后处理") { dismiss() }
                    .disabled(isWorking)
                Button("重新核对云端状态") {
                    Task { await sync.reconcile(in: modelContext, changes: changes) }
                }
                .disabled(isWorking)
            }
        }
        .navigationTitle("首次合流分类审阅")
        .onChange(of: sync.categoryReview?.id) { _, _ in
            guard !isWorking, let latest = sync.categoryReview, latest.id != review.id else { return }
            review = latest
            choices = [:]
            errorMessage = "分类或账本已变化，请重新确认各项选择。"
        }
        .confirmationDialog("确认采用所选分类方案？", isPresented: $confirm, titleVisibility: .visible) {
            Button("确认并继续同步") { submit() }
        } message: {
            Text("所选分类设置将参与本次合流。两端同时修改同一条记录时，仍沿用现有整条记录的同步规则。")
        }
        .alert("尚未完成分类合流", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("好", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func description(_ value: NativeBackupPackage.CategoryPayload?, remote: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(remote ? "云端" : "本机")：\(review.displayPath(for: value, remote: remote))")
            if let value {
                Text([value.isHidden ? "隐藏" : "显示", value.archivedAt == nil ? "使用中" : "已归档",
                      value.isPinnedForQuickAdd ? "常用分类" : "未设常用", "排序 \(value.sortOrder + 1)"].joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func submit() {
        isWorking = true
        Task {
            do {
                try await sync.resolveCategoryReview(id: review.id, choices: choices, in: modelContext, changes: changes)
                if let latest = sync.categoryReview {
                    review = latest
                    choices = [:]
                    errorMessage = "分类或同步状态已变化，请重新确认。"
                } else {
                    dismiss()
                }
            } catch let error as NativeBackupError {
                if case .invalidReference = error {
                    errorMessage = "该方案会影响本机交易或小类的关联。请先在分类管理中处理关联，再重新审阅。"
                } else { errorMessage = error.localizedDescription }
            } catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }
}
