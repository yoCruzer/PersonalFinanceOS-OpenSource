import SwiftData
import SwiftUI

enum CategoryCreationLevel: String, CaseIterable {
    case child = "小类"
    case root = "大类"
}

struct InlineCategoryCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let categories: [Category]
    let kind: CategoryKind
    let onCreated: (Category) -> Void

    @State private var level: CategoryCreationLevel
    @State private var name = ""
    @State private var parentID: UUID?
    @State private var symbolName: String
    @State private var textIconFollowsName = false
    @State private var errorMessage: String?
    @State private var isSaving = false
    @FocusState private var nameIsFocused: Bool

    init(
        categories: [Category],
        kind: CategoryKind,
        initialLevel: CategoryCreationLevel = .child,
        preselectedParentID: UUID? = nil,
        onCreated: @escaping (Category) -> Void
    ) {
        self.categories = categories
        self.kind = kind
        self.onCreated = onCreated
        let roots = CategoryHierarchy(categories: categories)
            .activeCategories(kind: kind)
            .filter(\.isRootCategory)
        let validPreselection = roots.first { $0.id == preselectedParentID }?.id
        _level = State(initialValue: initialLevel)
        _parentID = State(initialValue: validPreselection ?? roots.first?.id)
        _symbolName = State(initialValue: kind == .income ? "plus.circle" : CategoryIconLibrary.fallback)
    }

    private var roots: [Category] {
        CategoryHierarchy(categories: categories)
            .activeCategories(kind: kind)
            .filter(\.isRootCategory)
    }

    private var canSave: Bool {
        !isSaving &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        CategoryIconLibrary.isValidStoredIcon(symbolName) &&
        (level == .root || parentID != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类别层级", selection: $level) {
                        ForEach(CategoryCreationLevel.allCases, id: \.self) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("new-category-level")

                    LabeledContent("收支类型", value: kind == .expense ? "支出" : "收入")

                    if level == .child {
                        Picker("所属大类", selection: $parentID) {
                            Text("请选择").tag(Optional<UUID>.none)
                            ForEach(roots) { root in
                                Text(root.name).tag(Optional(root.id))
                            }
                        }
                        .accessibilityIdentifier("new-category-parent")
                    }
                }

                Section("名称") {
                    TextField(level == .child ? "小类名称" : "大类名称", text: $name)
                        .focused($nameIsFocused)
                        .submitLabel(.done)
                        .accessibilityIdentifier("new-category-name")
                        .onChange(of: name) {
                            if textIconFollowsName {
                                symbolName = CategoryIconLibrary.synchronizedTextIconValue(
                                    currentValue: symbolName,
                                    followsCategoryName: true,
                                    categoryName: name
                                )
                            } else if symbolName == CategoryIconLibrary.fallback || symbolName == "plus.circle" {
                                symbolName = CategoryIconLibrary.suggestedSymbol(for: name, kind: kind)
                            }
                        }
                        .onSubmit(save)
                }

                CategoryIconPicker(
                    selection: $symbolName,
                    suggestedText: name,
                    textIconFollowsSuggestedText: $textIconFollowsName
                )
            }
            .navigationTitle("新增分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                        .accessibilityIdentifier("save-inline-category")
                }
            }
            .task { nameIsFocused = true }
            .onChange(of: level) {
                if level == .child, parentID == nil {
                    parentID = roots.first?.id
                }
            }
            .alert(
                "无法新建类别",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        do {
            let category = try FinanceDataManagementService.addCategory(
                name: name,
                kind: kind,
                parentID: level == .child ? parentID : nil,
                symbolName: symbolName,
                categories: categories,
                in: modelContext
            )
            onCreated(category)
            dismiss()
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }
}
