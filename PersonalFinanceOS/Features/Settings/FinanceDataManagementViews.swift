import SwiftData
import SwiftUI

struct AccountManagementView: View {
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    private struct CountRefresh: Hashable { let ids: [UUID]; let revision: UInt64 }
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @State private var isAdding = false
    @State private var editingAccount: Account?
    @State private var accountEditBaseline: MetadataEditSnapshot.AccountValue?
    @State private var deletingAccount: Account?
    @State private var editName = ""
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var transactionCounts: [UUID: Int] = [:]
    @State private var countsFailed = false

    var body: some View {
        List {
            if countsFailed { Button("重新统计笔数") { Task { await reloadTransactionCounts() } } }
            ForEach(accounts) { account in
                HStack(spacing: PFSpacing.medium) {
                    Image(systemName: accountSymbol(account.type))
                        .foregroundStyle(account.archivedAt == nil ? PFColor.accent : PFColor.secondaryText)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
                        Text(account.name)
                        HStack(spacing: PFSpacing.small) {
                            if let count = transactionCounts[account.id] { Text("\(count) 笔交易") }
                            else { Text(countsFailed ? "交易笔数暂不可用" : "正在统计笔数") }
                            if account.isDefault {
                                Label("默认", systemImage: "checkmark.circle.fill")
                            }
                            if account.archivedAt != nil {
                                Text("已停用")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(PFColor.secondaryText)
                    }

                    Spacer()

                    Menu {
                        Button("重命名", systemImage: "pencil") {
                            editName = account.name
                            accountEditBaseline = MetadataEditSnapshot.AccountValue(account)
                            editingAccount = account
                        }
                        if account.archivedAt == nil && !account.isDefault {
                            Button("设为默认", systemImage: "checkmark.circle") {
                                perform(success: "默认账户已更新") {
                                    try FinanceDataManagementService.setDefault(
                                        account,
                                        accounts: accounts,
                                        in: modelContext
                                    )
                                }
                            }
                        }
                        Button(
                            account.archivedAt == nil ? "停用" : "启用",
                            systemImage: account.archivedAt == nil ? "archivebox" : "arrow.uturn.backward"
                        ) {
                            perform(success: account.archivedAt == nil ? "账户已停用" : "账户已启用") {
                                try FinanceDataManagementService.setAccountActive(
                                    account,
                                    isActive: account.archivedAt != nil,
                                    accounts: accounts,
                                    in: modelContext
                                )
                            }
                        }
                        Button("永久删除", systemImage: "trash", role: .destructive) {
                            deletingAccount = account
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("\(account.name)操作")
                    .accessibilityIdentifier("account-actions-\(account.name)")
                }
            }
        }
        .overlay {
            if accounts.isEmpty {
                PFEmptyState(
                    symbol: "creditcard",
                    title: "没有账户",
                    message: "新增一个账户后即可继续记账。"
                )
            }
        }
        .navigationTitle("账户")
        .task(id: CountRefresh(ids: accounts.map(\.id), revision: ledgerChangeCenter.revision)) { await reloadTransactionCounts() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新增账户")
            }
        }
        .sheet(isPresented: $isAdding) {
            AddAccountView(
                accounts: accounts,
                reportError: { errorMessage = $0 },
                reportSuccess: { showSuccess($0) }
            )
        }
        .sheet(isPresented: Binding(
            get: { deletingAccount != nil },
            set: { if !$0 { deletingAccount = nil } }
        )) {
            if let account = deletingAccount {
                AccountDeletionView(account: account) { message in
                    deletingAccount = nil
                    showSuccess(message)
                }
            }
        }
        .alert("重命名账户", isPresented: Binding(
            get: { editingAccount != nil },
            set: { if !$0 { editingAccount = nil } }
        )) {
            TextField("账户名称", text: $editName)
            Button("取消", role: .cancel) {
                editingAccount = nil
            }
            Button("保存") {
                guard let account = editingAccount else { return }
                perform(success: "账户名称已更新") {
                    try FinanceDataManagementService.rename(
                        account: account,
                        to: editName,
                        baseline: accountEditBaseline,
                        in: modelContext
                    )
                }
                editingAccount = nil
            }
        }
        .errorAlert(message: $errorMessage)
        .successToast(message: $successMessage)
    }

    private func perform(success: String, _ operation: () throws -> Void) {
        do {
            try operation()
            showSuccess(success)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func showSuccess(_ message: String) {
        successMessage = message
    }

    private func accountSymbol(_ type: AccountType) -> String {
        switch type {
        case .cash: "banknote"
        case .bankCard, .creditCard: "creditcard"
        case .wechat: "message"
        case .alipay: "a.circle"
        case .other: "wallet.bifold"
        }
    }

    private func reloadTransactionCounts() async {
        let ids = accounts.map(\.id)
        let requestedRevision = ledgerChangeCenter.revision
        transactionCounts = [:]
        countsFailed = false
        do {
            let result = try await LedgerAnalysisActor(modelContainer: modelContext.container).accountTransactionCounts(ids: ids)
            try Task.checkCancellation()
            try LedgerSaveRevision.shared.withProjectionBoundary {
                guard requestedRevision == ledgerChangeCenter.revision, ids == accounts.map(\.id),
                      result.revision == LedgerSaveRevision.shared.contentRevision else { throw LedgerAnalysisError.staleSnapshot }
                transactionCounts = result.values
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, requestedRevision == ledgerChangeCenter.revision, ids == accounts.map(\.id) else { return }
            transactionCounts = [:]
            countsFailed = true
        }
    }

}

private struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let accounts: [Account]
    let reportError: (String) -> Void
    let reportSuccess: (String) -> Void
    @State private var name = ""
    @State private var type: AccountType = .other

    var body: some View {
        NavigationStack {
            Form {
                TextField("账户名称", text: $name)
                Picker("账户类型", selection: $type) {
                    Text("现金").tag(AccountType.cash)
                    Text("银行卡").tag(AccountType.bankCard)
                    Text("信用卡").tag(AccountType.creditCard)
                    Text("微信").tag(AccountType.wechat)
                    Text("支付宝").tag(AccountType.alipay)
                    Text("其他").tag(AccountType.other)
                }
            }
            .navigationTitle("新增账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            _ = try FinanceDataManagementService.addAccount(
                                name: name,
                                type: type,
                                accounts: accounts,
                                in: modelContext
                            )
                            reportSuccess("账户已新增")
                            dismiss()
                        } catch {
                            reportError(error.localizedDescription)
                        }
                    }
                }
            }
        }
    }
}

struct CategoryManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @State private var selectedKind: CategoryKind = .expense
    @State private var categoryCreationRequest: CategoryCreationRequest?
    @State private var editingCategory: Category?
    @State private var deletingCategory: Category?
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var expandedRootIDs: Set<UUID> = []
    @State private var isReordering = false
    @State private var usageSummaries: [UUID: CategoryUsageSummary] = [:]

    private var hierarchy: CategoryHierarchy {
        CategoryHierarchy(categories: categories)
    }

    private var displayedRoots: [Category] {
        hierarchy.siblings(kind: selectedKind, parentID: nil)
    }

    var body: some View {
        List {
            NavigationLink("分类补充状态") { CategoryCatalogUpgradeView() }
                .accessibilityIdentifier("category-catalog-upgrade")
            Picker("分类类型", selection: $selectedKind) {
                Text("支出").tag(CategoryKind.expense)
                Text("收入").tag(CategoryKind.income)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            ForEach(displayedRoots) { root in
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedRootIDs.contains(root.id) },
                    set: { expanded in
                        if expanded { expandedRootIDs.insert(root.id) }
                        else { expandedRootIDs.remove(root.id) }
                    }
                )) {
                    ForEach(hierarchy.children(of: root)) { child in
                        categoryRow(child, isRoot: false)
                            .padding(.leading, PFSpacing.large)
                    }
                } label: {
                    categoryRow(root, isRoot: true)
                }
            }
        }
        .overlay {
            if displayedRoots.isEmpty {
                PFEmptyState(
                    symbol: "square.grid.2x2",
                    title: "没有分类",
                    message: "新增一个分类后即可用于记账。"
                )
            }
        }
        .navigationTitle("分类")
        .task(id: categories.map(\.id)) { reloadUsageSummaries() }
        .onChange(of: ledgerChangeCenter.revision) { reloadUsageSummaries() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    isReordering = true
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("编辑分类顺序")
                .accessibilityIdentifier("category-reorder")

                Menu {
                    Button("新增大类", systemImage: "square.grid.2x2") {
                        categoryCreationRequest = CategoryCreationRequest(
                            kind: selectedKind,
                            level: .root,
                            parentID: nil
                        )
                    }
                    Button("新增小类", systemImage: "square.grid.3x1.below.line.grid.1x2") {
                        categoryCreationRequest = CategoryCreationRequest(
                            kind: selectedKind,
                            level: .child,
                            parentID: nil
                        )
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新增分类")
                .accessibilityIdentifier("category-add-menu")
            }
        }
        .sheet(isPresented: $isReordering) {
            CategoryReorderingView(categories: categories, kind: selectedKind) {
                errorMessage = $0
            }
        }
        .sheet(item: $categoryCreationRequest) { request in
            InlineCategoryCreationSheet(
                categories: categories,
                kind: request.kind,
                initialLevel: request.level,
                preselectedParentID: request.parentID
            ) { category in
                selectedKind = category.kind
                if let parentID = category.parentID {
                    expandedRootIDs.insert(parentID)
                }
                successMessage = category.parentID == nil ? "大类已新增" : "小类已新增"
                categoryCreationRequest = nil
            }
        }
        .sheet(isPresented: Binding(
            get: { editingCategory != nil },
            set: { if !$0 { editingCategory = nil } }
        )) {
            if let category = editingCategory {
                EditCategoryView(
                    category: category,
                    reportError: { errorMessage = $0 },
                    reportSuccess: {
                        successMessage = $0
                        editingCategory = nil
                    }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { deletingCategory != nil },
            set: { if !$0 { deletingCategory = nil } }
        )) {
            if let category = deletingCategory {
                CategoryDeletionView(category: category) { message in
                    deletingCategory = nil
                    successMessage = message
                }
            }
        }
        .errorAlert(message: $errorMessage)
        .successToast(message: $successMessage)
    }

    private func perform(success: String, _ operation: () throws -> Void) {
        do {
            try operation()
            successMessage = success
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func categoryRow(_ category: Category, isRoot: Bool) -> some View {
        HStack(spacing: PFSpacing.medium) {
            CategoryIconView(
                symbolName: category.symbolName,
                color: PFColor.category(category.colorToken),
                size: 30
            )
            VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
                Text(category.name)
                if category.archivedAt != nil || category.isHidden {
                    Text("已停用")
                        .font(.caption)
                        .foregroundStyle(PFColor.secondaryText)
                }
            }
            Spacer()
            NavigationLink {
                CategoryTransactionsView(
                    category: category,
                    categoryIDs: isRoot
                        ? hierarchy.descendantIDs(of: category.id)
                        : [category.id],
                    categories: categories
                )
            } label: {
                Text(categoryCountText(category, isRoot: isRoot))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PFColor.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看\(category.name)的\(categoryCountText(category, isRoot: isRoot))交易")
            .accessibilityIdentifier("category-transactions-\(category.name)")
            categoryActions(category)
        }
    }

    private func categoryCountText(_ category: Category, isRoot: Bool) -> String {
        let summary = usageSummaries[category.id] ?? CategoryUsageSummary(
            directCount: 0,
            aggregateCount: 0
        )
        if isRoot, summary.directCount > 0 {
            return "共 \(summary.aggregateCount) 笔 · 本级 \(summary.directCount) 笔"
        }
        return isRoot ? "共 \(summary.aggregateCount) 笔" : "\(summary.directCount) 笔"
    }

    private func reloadUsageSummaries() {
        let hierarchy = CategoryHierarchy(categories: categories)
        var directCounts: [UUID: Int] = [:]
        for category in categories {
            directCounts[category.id] = (try? LedgerQueryService.countActiveForCategory(
                category.id,
                in: modelContext
            )) ?? 0
        }
        usageSummaries = Dictionary(uniqueKeysWithValues: categories.map { category in
            let direct = directCounts[category.id, default: 0]
            let aggregate = category.isRootCategory
                ? hierarchy.descendantIDs(of: category.id).reduce(0) { $0 + directCounts[$1, default: 0] }
                : direct
            return (category.id, CategoryUsageSummary(directCount: direct, aggregateCount: aggregate))
        })
    }

    private func categoryActions(_ category: Category) -> some View {
        Menu {
            if category.isRootCategory && category.isActiveForSelection {
                Button("在此大类下新增小类", systemImage: "plus") {
                    categoryCreationRequest = CategoryCreationRequest(
                        kind: category.kind,
                        level: .child,
                        parentID: category.id
                    )
                }
            }
            Button("重命名", systemImage: "pencil") { editingCategory = category }
            Button(
                category.isActiveForSelection ? "停用" : "启用",
                systemImage: category.isActiveForSelection ? "archivebox" : "arrow.uturn.backward"
            ) {
                perform(success: category.isActiveForSelection ? "分类已停用" : "分类已启用") {
                    try FinanceDataManagementService.setCategoryActive(
                        category,
                        isActive: !category.isActiveForSelection,
                        categories: categories,
                        in: modelContext
                    )
                }
            }
            Button("永久删除", systemImage: "trash", role: .destructive) {
                deletingCategory = category
            }
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
        }
        .accessibilityLabel("\(category.name)操作")
        .accessibilityIdentifier("category-actions-\(category.name)")
    }
}

private struct CategoryTransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    let category: Category
    let categoryIDs: Set<UUID>
    let categories: [Category]

    @State private var transactions: [FinanceTransaction] = []
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let pageSize = 100

    private var categoriesByID: [UUID: Category] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }

    private var accountsByID: [UUID: Account] {
        Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    }

    var body: some View {
        List {
            if transactions.isEmpty, !isLoading {
                PFEmptyState(
                    symbol: "tray",
                    title: "没有交易",
                    message: "该分类暂无历史交易。"
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(transactions) { transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction, onChanged: reload)
                    } label: {
                        PFTransactionRow(
                            transaction: transaction,
                            category: transaction.categoryID.flatMap { categoriesByID[$0] },
                            account: transaction.accountID.flatMap { accountsByID[$0] },
                            categoryPath: transaction.categoryID.flatMap { categoriesByID[$0] }
                                .map { $0.displayPath(in: categories) },
                            destinationAccount: transaction.destinationAccountID.flatMap { accountsByID[$0] }
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("category-transaction-row-\(transaction.id.uuidString)")
                }
            }

            if hasMore {
                Button(isLoading ? "正在加载…" : "加载更多") { loadNextPage() }
                    .frame(maxWidth: .infinity)
                    .disabled(isLoading)
                    .accessibilityIdentifier("category-transactions-load-more")
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("\(category.name) · 全部交易")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ledgerChangeCenter.revision) { reload() }
        .refreshable { reload() }
        .alert(
            "无法读取交易",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .accessibilityIdentifier("category-transactions-list")
    }

    private func reload() {
        transactions = []
        hasMore = false
        loadNextPage()
    }

    private func loadNextPage() {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try LedgerQueryService.fetchActiveCategoryPage(
                categoryIDs: categoryIDs,
                offset: transactions.count,
                limit: pageSize,
                in: modelContext
            )
            transactions.append(contentsOf: page.transactions)
            hasMore = page.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CategoryCreationRequest: Identifiable {
    let id = UUID()
    let kind: CategoryKind
    let level: CategoryCreationLevel
    let parentID: UUID?
}

private struct CategoryReorderingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let categories: [Category]
    let kind: CategoryKind
    let reportError: (String) -> Void

    private var hierarchy: CategoryHierarchy {
        CategoryHierarchy(categories: categories)
    }

    private var roots: [Category] {
        hierarchy.siblings(kind: kind, parentID: nil)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("大类") {
                    ForEach(roots) { root in
                        categoryLabel(root)
                    }
                    .onMove { source, destination in
                        move(source, to: destination, siblings: roots, parentID: nil)
                    }
                }

                ForEach(roots) { root in
                    let children = hierarchy.siblings(kind: kind, parentID: root.id)
                    if !children.isEmpty {
                        Section("\(root.name) · 小类") {
                            ForEach(children) { child in
                                categoryLabel(child)
                            }
                            .onMove { source, destination in
                                move(source, to: destination, siblings: children, parentID: root.id)
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("编辑分类顺序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func categoryLabel(_ category: Category) -> some View {
        HStack(spacing: PFSpacing.medium) {
            CategoryIconView(
                symbolName: category.symbolName,
                color: PFColor.category(category.colorToken),
                size: 30
            )
            Text(category.name)
            Spacer()
            if !category.isActiveForSelection {
                Text("已停用")
                    .font(.caption)
                    .foregroundStyle(PFColor.secondaryText)
            }
        }
        .accessibilityIdentifier("reorder-category-\(category.name)")
    }

    private func move(
        _ source: IndexSet,
        to destination: Int,
        siblings: [Category],
        parentID: UUID?
    ) {
        var orderedIDs = siblings.map(\.id)
        orderedIDs.move(fromOffsets: source, toOffset: destination)
        do {
            try FinanceDataManagementService.reorderCategories(
                orderedIDs: orderedIDs,
                kind: kind,
                parentID: parentID,
                categories: categories,
                in: modelContext
            )
        } catch {
            reportError(error.localizedDescription)
        }
    }
}

private struct EditCategoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let category: Category
    let reportError: (String) -> Void
    let reportSuccess: (String) -> Void
    @State private var editBaseline: MetadataEditSnapshot.CategoryValue
    @State private var name: String
    @State private var symbolName: String
    @State private var textIconFollowsName = false

    init(
        category: Category,
        reportError: @escaping (String) -> Void,
        reportSuccess: @escaping (String) -> Void
    ) {
        self.category = category
        self.reportError = reportError
        self.reportSuccess = reportSuccess
        _editBaseline = State(initialValue: MetadataEditSnapshot.CategoryValue(category))
        _name = State(initialValue: category.name)
        _symbolName = State(initialValue: category.symbolName)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        CategoryIconLibrary.isValidStoredIcon(symbolName)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("分类名称", text: $name)
                CategoryIconPicker(
                    selection: $symbolName,
                    suggestedText: name,
                    textIconFollowsSuggestedText: $textIconFollowsName
                )
            }
            .navigationTitle("编辑分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try FinanceDataManagementService.update(
                                category: category,
                                name: name,
                                symbolName: symbolName,
                                baseline: editBaseline,
                                in: modelContext
                            )
                            reportSuccess("分类已更新")
                            dismiss()
                        } catch {
                            reportError(error.localizedDescription)
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

private enum CategoryIconPickerMode: String, CaseIterable {
    case system = "系统图标"
    case text = "文字图标"
}

struct CategoryIconPicker: View {
    @Binding var selection: String
    let suggestedText: String
    @Binding var textIconFollowsSuggestedText: Bool
    @State private var mode: CategoryIconPickerMode

    init(
        selection: Binding<String>,
        suggestedText: String,
        textIconFollowsSuggestedText: Binding<Bool>
    ) {
        _selection = selection
        self.suggestedText = suggestedText
        _textIconFollowsSuggestedText = textIconFollowsSuggestedText
        if case .text = CategoryIconLibrary.descriptor(for: selection.wrappedValue) {
            _mode = State(initialValue: .text)
        } else {
            _mode = State(initialValue: .system)
        }
    }

    var body: some View {
        Section {
            HStack {
                CategoryIconView(symbolName: selection, color: PFColor.accent, size: 44)
                Text("图标预览")
                    .foregroundStyle(PFColor.secondaryText)
            }

            Picker("图标类型", selection: $mode) {
                ForEach(CategoryIconPickerMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("category-icon-mode")
            .onChange(of: mode) { _, mode in
                switch mode {
                case .system:
                    textIconFollowsSuggestedText = false
                    selection = CategoryIconLibrary.safeSymbol(selection)
                case .text:
                    textIconFollowsSuggestedText = true
                    selection = CategoryIconLibrary.synchronizedTextIconValue(
                        currentValue: selection,
                        followsCategoryName: true,
                        categoryName: suggestedText
                    )
                }
            }

            if mode == .text {
                TextField("最多 2 个字符", text: Binding(
                    get: { CategoryIconLibrary.textIconText(from: selection) ?? "" },
                    set: { value in
                        let limited = String(value.prefix(2))
                        textIconFollowsSuggestedText = false
                        selection = CategoryIconLibrary.textIconValue(from: limited) ?? "text:"
                    }
                ))
                    .accessibilityIdentifier("category-text-icon")
                Text("可用分类名称的前 1～2 个字符，也可自行输入。")
                    .font(.footnote)
                    .foregroundStyle(PFColor.secondaryText)
            } else {
                ForEach(CategoryIconLibrary.groups) { group in
                    VStack(alignment: .leading, spacing: PFSpacing.small) {
                        Text(group.title)
                            .font(.caption)
                            .foregroundStyle(PFColor.secondaryText)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5)) {
                            ForEach(group.symbols, id: \.self) { symbol in
                                Button {
                                    selection = symbol
                                } label: {
                                    Image(systemName: symbol)
                                        .frame(width: 40, height: 40)
                                        .foregroundStyle(selection == symbol ? .white : PFColor.primaryText)
                                        .background(selection == symbol ? PFColor.accent : PFColor.elevatedSurface, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(group.title)图标")
                                .accessibilityValue(selection == symbol ? "已选择" : "未选择")
                            }
                        }
                    }
                }
            }
        } header: {
            Text("选择图标")
        }
    }
}

private extension View {
    func errorAlert(message: Binding<String?>) -> some View {
        alert(
            "无法完成操作",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }

    func successToast(message: Binding<String?>) -> some View {
        overlay(alignment: .bottom) {
            if let value = message.wrappedValue {
                Label(value, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, PFSpacing.large)
                    .padding(.vertical, PFSpacing.medium)
                    .background(.black.opacity(0.78), in: Capsule())
                    .padding(.bottom, PFSpacing.xLarge)
                    .task {
                        try? await Task.sleep(for: .seconds(1.8))
                        if message.wrappedValue == value {
                            message.wrappedValue = nil
                        }
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: message.wrappedValue)
    }
}
