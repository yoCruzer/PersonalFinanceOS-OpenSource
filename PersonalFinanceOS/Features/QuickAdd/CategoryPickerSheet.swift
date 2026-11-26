import SwiftUI

struct CategoryPickerSheet: View {
    enum Purpose { case capture, batchTarget }
    @Environment(\.dismiss) private var dismiss

    let categories: [Category]
    let transactions: [FinanceTransaction]
    let kind: CategoryKind
    let selectedID: UUID?
    var purpose: Purpose = .capture
    let onSelect: (Category) -> Void

    @State private var searchText = ""
    @State private var expandedRootIDs: Set<UUID> = []
    @State private var isCreatingCategory = false

    private var hierarchy: CategoryHierarchy {
        CategoryHierarchy(categories: categories)
    }

    private var roots: [Category] {
        hierarchy.activeCategories(kind: kind).filter {
            $0.isRootCategory && (!isLegacy($0) || !mainChildren(of: $0).isEmpty)
        }
    }

    private var groupsLegacyCategories: Bool {
        guard let index = CategoryCatalogIndex.bundled else { return false }
        return categories.contains { index.newStorageKeys.contains($0.defaultDefinitionKey) }
    }

    private func isLegacy(_ category: Category) -> Bool {
        groupsLegacyCategories && CategoryCatalogIndex.bundled?.legacyStorageKeys.contains(category.defaultDefinitionKey) == true
    }

    private func mainChildren(of root: Category) -> [Category] {
        hierarchy.children(of: root, activeOnly: true).filter { !isLegacy($0) }
    }

    private var legacyCategories: [Category] {
        hierarchy.selectableCategories(kind: kind).filter(isLegacy)
    }

    private var matchingCategories: [Category] {
        hierarchy.selectableCategories(kind: kind).filter {
            hierarchy.matches($0, query: searchText)
        }
    }

    private var recentCategories: [Category] {
        CategoryQuickAccessService.visibleCategories(
            categories: categories,
            transactions: transactions,
            kind: kind,
            selectedID: selectedID,
            suggestedID: nil,
            limit: 6
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if purpose == .batchTarget {
                    Section {
                        let matches = hierarchy.orderedCategories(kind: kind, activeOnly: true)
                            .filter { hierarchy.matches($0, query: searchText) }
                        if matches.isEmpty {
                            Text("没有匹配的大类、小类或完整路径")
                                .foregroundStyle(PFColor.secondaryText)
                        }
                        ForEach(matches) { category in
                            categoryRow(category, path: true)
                        }
                    } header: {
                        Text("目标分类")
                    } footer: {
                        Text("选择后先预览，确认前不会修改交易。")
                    }
                } else {
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !recentCategories.isEmpty {
                            Section("最近与常用") {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: PFSpacing.small) {
                                        ForEach(recentCategories) { category in
                                            compactCategoryButton(category)
                                        }
                                    }
                                    .padding(.vertical, PFSpacing.xSmall)
                                }
                            }
                        }

                        Section("全部分类") {
                            ForEach(roots) { root in
                                let children = mainChildren(of: root)
                                if children.isEmpty {
                                    categoryRow(root, path: false)
                                } else {
                                    DisclosureGroup(
                                        isExpanded: expansionBinding(for: root.id)
                                    ) {
                                        ForEach(children) { child in
                                            categoryRow(child, path: false)
                                                .padding(.leading, PFSpacing.medium)
                                        }
                                    } label: {
                                        rootLabel(root, childCount: children.count)
                                    }
                                    .accessibilityIdentifier("category-root-\(root.name)")
                                }
                            }
                        }
                        if !legacyCategories.isEmpty {
                            Section {
                                ForEach(legacyCategories) { category in
                                    categoryRow(category, path: true)
                                }
                            } header: {
                                Text("旧分类")
                            } footer: {
                                Text("保留历史用途，可继续选择。分类和旧账均未改变。")
                            }
                        }
                    } else {
                        Section("搜索结果") {
                            if matchingCategories.isEmpty {
                                Text("没有匹配的大类、小类或完整路径")
                                    .foregroundStyle(PFColor.secondaryText)
                            } else {
                                ForEach(matchingCategories) { category in
                                    categoryRow(category, path: true)
                                }
                            }
                        }
                    }

                    Section {
                        Button {
                            isCreatingCategory = true
                        } label: {
                            Label("新建类别", systemImage: "plus.circle.fill")
                        }
                        .accessibilityIdentifier("create-category-inline")

                        NavigationLink {
                            CategoryManagementView()
                        } label: {
                            Label("管理分类", systemImage: "slider.horizontal.3")
                        }
                        .accessibilityIdentifier("manage-categories-inline")
                    }
                }
            }
            .navigationTitle(purpose == .batchTarget ? "选择目标分类" : "全部分类")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索分类或完整路径")
            .accessibilityIdentifier("all-category-picker")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                if expandedRootIDs.isEmpty {
                    expandedRootIDs.formUnion(roots.prefix(2).map(\.id))
                }
            }
            .sheet(isPresented: $isCreatingCategory) {
                InlineCategoryCreationSheet(
                    categories: categories,
                    kind: kind
                ) { category in
                    onSelect(category)
                    isCreatingCategory = false
                    dismiss()
                }
                .presentationDetents([.large])
            }
        }
    }

    private func categoryRow(_ category: Category, path: Bool) -> some View {
        Button {
            choose(category)
        } label: {
            HStack(spacing: PFSpacing.medium) {
                categoryIcon(category, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(path ? hierarchy.displayPath(for: category) : category.name)
                        .foregroundStyle(PFColor.primaryText)
                    if path && category.parentID != nil {
                        Text("小类")
                            .font(.caption)
                            .foregroundStyle(PFColor.secondaryText)
                    }
                }
                Spacer()
                if selectedID == category.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(PFColor.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("all-category-\(hierarchy.displayPath(for: category))")
        .accessibilityValue(selectedID == category.id ? "已选择" : "未选择")
    }

    private func compactCategoryButton(_ category: Category) -> some View {
        Button { choose(category) } label: {
            VStack(spacing: PFSpacing.xSmall) {
                categoryIcon(category, size: 38)
                Text(category.name)
                    .font(.caption)
                    .foregroundStyle(PFColor.primaryText)
                    .lineLimit(1)
            }
            .frame(width: 68)
            .frame(minHeight: 64)
        }
        .buttonStyle(.plain)
    }

    private func rootLabel(_ category: Category, childCount: Int) -> some View {
        HStack(spacing: PFSpacing.medium) {
            categoryIcon(category, size: 36)
            Text(category.name)
                .foregroundStyle(PFColor.primaryText)
            Spacer()
            Text("\(childCount)")
                .font(.caption)
                .foregroundStyle(PFColor.secondaryText)
        }
    }

    private func categoryIcon(_ category: Category, size: CGFloat) -> some View {
        CategoryIconView(
            symbolName: category.symbolName,
            color: PFColor.category(category.colorToken),
            size: size
        )
    }

    private func expansionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedRootIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedRootIDs.insert(id)
                } else {
                    expandedRootIDs.remove(id)
                }
            }
        )
    }

    private func choose(_ category: Category) {
        onSelect(category)
        dismiss()
    }
}
