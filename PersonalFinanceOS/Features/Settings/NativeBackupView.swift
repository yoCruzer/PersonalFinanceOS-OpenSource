import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct NativeBackupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @Environment(ICloudSyncController.self) private var iCloudSync

    @State private var exportURL: URL?
    @State private var pendingData: Data?
    @State private var preview: NativeBackupPreview?
    @State private var restoreResult: NativeRestoreResult?
    @State private var isImporterPresented = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var loadGeneration = UUID()
    @State private var loadingTask: Task<Void, Never>?

    var body: some View {
        List {
            Section("完整语义备份") {
                Text("版本化 JSON 备份保留账户、分类、标签、交易、转账两端、导入身份、时区与软删除状态。")
                    .font(.footnote)
                    .foregroundStyle(PFColor.secondaryText)
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("分享备份", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("share-native-backup")
                } else {
                    Button {
                        prepareBackup()
                    } label: {
                        Label("生成备份", systemImage: "externaldrive.badge.plus")
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("prepare-native-backup")
                }
            }

            Section("恢复") {
                if iCloudSync.isEnabled || iCloudSync.status == .stopping {
                    Text("恢复备份前，请先在设置中关闭 iCloud 同步，避免与尚未收到的云端账本合并。")
                        .font(.footnote)
                        .foregroundStyle(PFColor.secondaryText)
                }
                Button {
                    isImporterPresented = true
                } label: {
                    Label("选择备份文件", systemImage: "doc.badge.plus")
                }
                .disabled(isWorking)
                .accessibilityIdentifier("choose-native-backup")

                if let preview {
                    LabeledContent("备份时间", value: preview.exportedAt.formatted())
                    LabeledContent("账户 / 分类 / 标签", value: "\(preview.accountCount) / \(preview.categoryCount) / \(preview.tagCount)")
                    LabeledContent("有效交易", value: "\(preview.activeTransactionCount)")
                    LabeledContent("软删除交易", value: "\(preview.deletedTransactionCount)")
                    Text("完整恢复仅支持新安装、空账本，或尚未记账且未修改默认数据的初始账本；不会与已有账本合并。")
                        .font(.footnote)
                        .foregroundStyle(PFColor.secondaryText)
                    Button("确认恢复") {
                        restore()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PFColor.accent)
                    .disabled(isWorking || pendingData == nil || iCloudSync.isEnabled || iCloudSync.status == .stopping)
                    .accessibilityIdentifier("confirm-native-restore")
                }
            }

            if let restoreResult {
                Section("恢复结果") {
                    LabeledContent("新增交易", value: "\(restoreResult.insertedTransactionCount)")
                    LabeledContent("其中软删除", value: "\(restoreResult.insertedDeletedTransactionCount)")
                }
            }
        }
        .navigationTitle("完整备份与恢复")
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            loadBackup(result)
        }
        .alert("无法完成", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            loadingTask?.cancel()
            loadGeneration = UUID()
        }
    }

    private func prepareBackup() {
        guard !isWorking else { return }
        let container = modelContext.container
        isWorking = true
        Task {
            do {
                let actor = NativeBackupActor(modelContainer: container)
                exportURL = try await actor.export(
                    fileName: "PersonalFinanceOS_Backup_v1.json"
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func loadBackup(_ result: Result<[URL], Error>) {
        do {
            let url = try result.get().first
            guard let url else { return }
            loadingTask?.cancel()
            let generation = UUID()
            loadGeneration = generation
            isWorking = true
            pendingData = nil
            preview = nil
            restoreResult = nil
            loadingTask = Task {
                do {
                    let loaded = try await NativeBackupFileLoader.load(from: url)
                    guard loadGeneration == generation, !Task.isCancelled else { return }
                    pendingData = loaded.data
                    preview = loaded.preview
                } catch is CancellationError {
                    return
                } catch {
                    guard loadGeneration == generation else { return }
                    errorMessage = error.localizedDescription
                }
                if loadGeneration == generation {
                    isWorking = false
                    loadingTask = nil
                }
            }
        } catch {
            pendingData = nil
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func restore() {
        guard let pendingData, !isWorking else { return }
        let admission: LedgerRestoreAdmission.Ticket
        do { admission = try iCloudSync.makeRestoreAdmission(for: modelContext.container) }
        catch { errorMessage = error.localizedDescription; return }
        let container = modelContext.container
        isWorking = true
        Task {
            do {
                let actor = NativeBackupActor(modelContainer: container)
                let result = try await actor.restore(data: pendingData, admission: admission)
                restoreResult = result
                ledgerChangeCenter.recordMutation()
                if result.learningResetFailed {
                    errorMessage = "账本已恢复，但旧学习记录暂时无法清理。请到设置中重试清除学习记录。"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
