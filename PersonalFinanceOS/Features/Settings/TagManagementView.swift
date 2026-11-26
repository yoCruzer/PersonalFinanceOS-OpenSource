import SwiftData
import SwiftUI

struct TagManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @State private var isAdding = false
    @State private var editingTag: Tag?
    @State private var tagEditBaseline: MetadataEditSnapshot.TagValue?
    @State private var deletingTag: Tag?
    @State private var name = ""
    @State private var errorMessage: String?
    @State private var transactionCounts: [UUID: Int] = [:]

    var body: some View {
        List {
            ForEach(tags) { tag in
                HStack(spacing: PFSpacing.medium) {
                    Image(systemName: "tag")
                        .foregroundStyle(tag.archivedAt == nil ? PFColor.accent : PFColor.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tag.name)
                        Text("\(transactionCounts[tag.id, default: 0]) 笔活跃交易\(tag.archivedAt == nil ? "" : " · 已停用")")
                            .font(.caption)
                            .foregroundStyle(PFColor.secondaryText)
                    }
                    Spacer()
                    Menu {
                        Button("重命名", systemImage: "pencil") {
                            name = tag.name
                            tagEditBaseline = MetadataEditSnapshot.TagValue(tag)
                            editingTag = tag
                        }
                        Button(
                            tag.archivedAt == nil ? "停用" : "重新启用",
                            systemImage: tag.archivedAt == nil ? "archivebox" : "arrow.uturn.backward"
                        ) {
                            perform {
                                try FinanceDataManagementService.setTagActive(
                                    tag,
                                    isActive: tag.archivedAt != nil,
                                    in: modelContext
                                )
                            }
                        }
                        Button("永久删除", systemImage: "trash", role: .destructive) {
                            deletingTag = tag
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("\(tag.name)操作")
                    .accessibilityIdentifier("tag-actions-\(tag.name)")
                }
            }
        }
        .overlay {
            if tags.isEmpty {
                PFEmptyState(
                    symbol: "tag",
                    title: "还没有标签",
                    message: "标签是分类之外的可选维度，可用于项目、场景或报销状态。"
                )
            }
        }
        .navigationTitle("标签")
        .task(id: tags.map(\.id)) { reloadTransactionCounts() }
        .toolbar {
            Button {
                name = ""
                isAdding = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("新增标签")
        }
        .alert("新增标签", isPresented: $isAdding) {
            TextField("标签名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("保存") {
                perform {
                    _ = try FinanceDataManagementService.addTag(
                        name: name,
                        tags: tags,
                        in: modelContext
                    )
                }
            }
        }
        .alert("重命名标签", isPresented: Binding(
            get: { editingTag != nil },
            set: { if !$0 { editingTag = nil } }
        )) {
            TextField("标签名称", text: $name)
            Button("取消", role: .cancel) { editingTag = nil }
            Button("保存") {
                guard let tag = editingTag else { return }
                perform {
                    try FinanceDataManagementService.rename(
                        tag: tag,
                        to: name,
                        tags: tags,
                        baseline: tagEditBaseline,
                        in: modelContext
                    )
                }
                editingTag = nil
            }
        }
        .alert("无法完成操作", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: Binding(
            get: { deletingTag != nil },
            set: { if !$0 { deletingTag = nil } }
        )) {
            if let tag = deletingTag {
                TagDeletionView(tag: tag) {
                    deletingTag = nil
                }
            }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadTransactionCounts() {
        transactionCounts = Dictionary(uniqueKeysWithValues: tags.map { tag in
            let count = (try? LedgerQueryService.fetchForTag(tag.id, in: modelContext)
                .lazy
                .filter { $0.deletedAt == nil }
                .count) ?? 0
            return (tag.id, count)
        })
    }
}
