import SwiftData
import SwiftUI

struct TagPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]

    @Binding var tagIDs: Set<UUID>
    @Binding var suggestionSession: SmartSuggestionSession
    @State private var isNewTagSheetPresented = false
    @State private var newTagName = ""
    @State private var creationError: String?
    @State private var isCreating = false

    private var selectedTags: [Tag] {
        tags.filter { tagIDs.contains($0.id) }
    }

    private var activeUnselectedTags: [Tag] {
        tags.filter { $0.archivedAt == nil && !tagIDs.contains($0.id) }
    }

    private var missingTagCount: Int {
        tagIDs.subtracting(Set(tags.map(\.id))).count
    }

    var body: some View {
        NavigationStack {
            List {
                if !selectedTags.isEmpty {
                    Section("已选择") {
                        ForEach(selectedTags) { tag in
                            tagButton(tag, isSelected: true)
                        }
                    }
                }

                if !activeUnselectedTags.isEmpty {
                    Section("可用标签") {
                        ForEach(activeUnselectedTags) { tag in
                            tagButton(tag, isSelected: false)
                        }
                    }
                }

                if missingTagCount > 0 {
                    Section {
                        Label(
                            "\(missingTagCount) 个原标签已不可用，保存时不会带入。",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(PFColor.secondaryText)
                        .accessibilityIdentifier("missing-tag-warning")
                    }
                }

                Section {
                    Button {
                        newTagName = ""
                        creationError = nil
                        isNewTagSheetPresented = true
                    } label: {
                        Label("新建标签", systemImage: "plus")
                    }
                    .accessibilityIdentifier("create-tag")
                }
            }
            .navigationTitle("选择标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("tag-picker-done")
                }
            }
            .accessibilityIdentifier("tag-picker-sheet")
            .sheet(isPresented: $isNewTagSheetPresented) {
                newTagSheet
            }
        }
    }

    private func tagButton(_ tag: Tag, isSelected: Bool) -> some View {
        Button {
            if isSelected {
                tagIDs.remove(tag.id)
            } else {
                tagIDs.insert(tag.id)
            }
            suggestionSession.markManualTagChange(id: tag.id, isSelected: !isSelected)
        } label: {
            HStack {
                Text(tag.archivedAt == nil ? tag.name : "\(tag.name)（已停用）")
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? PFColor.accent : PFColor.secondaryText)
            }
        }
        .accessibilityIdentifier("tag-\(tag.name)")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }

    private var newTagSheet: some View {
        NavigationStack {
            Form {
                Section("标签名称") {
                    TextField("标签名称", text: $newTagName)
                        .accessibilityIdentifier("new-tag-name")
                }
                if let creationError {
                    Section {
                        Label(creationError, systemImage: "exclamationmark.circle")
                            .foregroundStyle(PFColor.danger)
                            .accessibilityIdentifier("new-tag-error")
                    }
                }
            }
            .navigationTitle("新建标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isNewTagSheetPresented = false }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { createTag() }
                        .disabled(isCreating)
                        .accessibilityIdentifier("create-new-tag")
                }
            }
        }
    }

    private func createTag() {
        guard !isCreating else { return }
        isCreating = true
        defer { isCreating = false }

        do {
            let tag = try FinanceDataManagementService.addTag(
                name: newTagName,
                tags: tags,
                in: modelContext
            )
            tagIDs.insert(tag.id)
            suggestionSession.markManualTagChange(id: tag.id, isSelected: true)
            isNewTagSheetPresented = false
        } catch {
            creationError = error.localizedDescription
        }
    }
}
