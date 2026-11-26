import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter

    private enum DisplayMode: String, CaseIterable {
        case list = "列表"
        case calendar = "日历"
    }
    private enum SearchScope: String, CaseIterable {
        case month = "本月"
        case all = "全部记录"
    }
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]

    #if DEBUG
    @State private var selectedMonth = Build21SyntheticFixture.initialMonth
    #else
    @State private var selectedMonth = Date()
    #endif
    @State private var selectedType: TransactionType?
    @State private var selectedCategoryID: UUID?
    @State private var selectedAccountID: UUID?
    @State private var selectedTagID: UUID?
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool
    @State private var showsFilters = false
    @State private var searchScope: SearchScope = .month
    @State private var analysisStore = LedgerAnalysisStore()
    #if DEBUG
    @State private var diagnosticFrames: [UUID: CGRect] = [:]
    @State private var diagnosticViewport: CGRect = .zero
    @State private var diagnosticAnchorUpdates = 0
    private var probesScroll: Bool {
        Build21SyntheticFixture.isEnabled && ProcessInfo.processInfo.arguments.contains("-ledgerScrollProbe")
    }
    private var scrollDiagnostic: String {
        let viewport = diagnosticViewport
        let visible = diagnosticFrames.filter { $0.value.intersects(viewport) && $0.value.height > 0 }
        let index = anchorID.flatMap { id in displayedTransactions.firstIndex { $0.id == id } }
        let frame = anchorID.flatMap { diagnosticFrames[$0] }
        let visibleIndices = displayedTransactions.indices.filter { visible[displayedTransactions[$0].id] != nil }
        return "anchor=\(index.map(String.init) ?? "nil");visible=\(anchorID.map { visible[$0] != nil } ?? false);updates=\(diagnosticAnchorUpdates);frames=\(visible.count);height=\(Int(diagnosticViewport.height));rows=\(displayedTransactions.count);start=\(analysisStore.loadedRange.lowerBound);end=\(analysisStore.loadedRange.upperBound);stale=\(analysisStore.isPresentationStale);loading=\(analysisStore.isLoading);total=\(analysisStore.snapshot?.totals.totalCount ?? 0);net=\(analysisStore.snapshot?.totals.netExpenseMinorUnits ?? 0);anchorY=\(frame.map { Int($0.minY) } ?? -99999);anchorBottom=\(frame.map { Int($0.maxY) } ?? -99999);firstVisible=\(visibleIndices.first ?? -1);lastVisible=\(visibleIndices.last ?? -1);sort=\(analysisStore.snapshot?.filter.sortOrder.rawValue ?? "none")"
    }
    #endif
    @State private var anchorID: UUID?
    @State private var searchHistory = RecentSearchHistoryStore()
    @State private var immediateSearchText: String?
    @State private var searchSubmissionNonce = 0
    @State private var displayMode: DisplayMode = .list
    @State private var selectedSortOrder: TransactionSortOrder = .timeNewest
    @State private var isBatchSelecting = false
    @State private var batchSelection = TransactionBatchSelection()
    @State private var calendarStore = LedgerAnalysisStore()
    @State private var calendarTask: Task<Void, Never>?

    private var categoriesByID: [UUID: Category] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }

    private var accountsByID: [UUID: Account] {
        Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    }

    private var listSnapshot: LedgerAnalysisSnapshot? {
        guard let snapshot = analysisStore.snapshot else { return nil }
        var filter = snapshot.filter
        filter.revision = nil
        return filter == analysisFilter ? snapshot : nil
    }
    private var calendarSnapshot: LedgerAnalysisSnapshot? {
        guard let snapshot = calendarStore.snapshot,
              calendarFilter == snapshot.filter.withoutRevision else { return nil }
        return snapshot
    }
    private var displayedTransactions: [LedgerFilteredRow] { listSnapshot == nil ? [] : analysisStore.rows }
    private var completeResultIDs: [UUID] { listSnapshot?.transactionIDs ?? [] }
    private var currentSummary: LedgerAnalysisSnapshot? {
        displayMode == .calendar ? calendarSnapshot : listSnapshot
    }
    private var analysisFilter: LedgerFilter {
        var filter = searchScope == .all ? LedgerFilter(dateRange: nil) : .month(selectedMonth)
        if let type = selectedType { filter.mode = LedgerFilter.Mode(rawValue: type.rawValue)! }
        filter.category = selectedCategoryID.map { .node($0) } ?? .all
        filter.accountID = selectedAccountID
        filter.tagIDs = selectedTagID.map { [$0] } ?? []
        filter.query = searchText
        filter.sortOrder = selectedSortOrder
        return filter
    }
    private var calendarFilter: LedgerFilter {
        var value = analysisFilter
        let month = LedgerFilter.month(selectedMonth).dateRange!
        if let original = value.dateRange {
            value.dateRange = LocalDayRange(lowerBound: max(original.lowerBound, month.lowerBound),
                upperBound: min(original.upperBound, month.upperBound))
        } else { value.dateRange = month }
        return value
    }
    private var analysisTaskKey: TodayAnalysisTaskKey {
        TodayAnalysisTaskKey(filter: analysisFilter, revision: ledgerChangeCenter.revision,
            submission: searchSubmissionNonce, isList: displayMode == .list)
    }

    private var transactionGroups: [TransactionDayGroup] {
        Dictionary(grouping: displayedTransactions, by: \.localDayKey)
            .map { TransactionDayGroup(dayKey: $0.key, transactions: $0.value, totals: analysisStore.snapshot?.dayTotals[$0.key] ?? LedgerTotals()) }
            .sorted {
                selectedSortOrder == .timeOldest
                    ? $0.dayKey < $1.dayKey
                    : $0.dayKey > $1.dayKey
            }
    }

    private var hasFilters: Bool {
        selectedType != nil ||
        selectedCategoryID != nil ||
        selectedAccountID != nil ||
        selectedTagID != nil ||
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: PFSpacing.medium) {
                            if isSearchPresented { searchControls }
                            HStack {
                                Button { isSearchPresented = true; isSearchFocused = true } label: {
                                    Label("搜索", systemImage: "magnifyingglass").frame(minHeight: 44).contentShape(Rectangle())
                                }
                                Spacer()
                                Button { showsFilters.toggle() } label: {
                                    Label(showsFilters ? "收起筛选" : "筛选", systemImage: "line.3.horizontal.decrease")
                                        .frame(minHeight: 44).contentShape(Rectangle())
                                }.accessibilityValue(showsFilters ? "展开" : "收起")
                                Menu {
                                    Picker("流水视图", selection: $displayMode) {
                                        ForEach(DisplayMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                    }
                                    if displayMode == .list {
                                        Button("选择多笔记录") { isBatchSelecting = true }
                                            .disabled(displayedTransactions.isEmpty)
                                            .accessibilityIdentifier("toggle-batch-selection")
                                    }
                                } label: { Label(displayMode.rawValue, systemImage: displayMode == .list ? "list.bullet" : "calendar").frame(minHeight: 44) }
                            }.frame(minHeight: 44)
                            if hasFilters { activeConditions }
                            if showsFilters { filterBar }
                            if displayMode == .list, searchScope == .all {
                                Text("全部历史")
                                    .font(.title3.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .accessibilityIdentifier("transactions-all-history-title")
                            } else {
                                PFMonthSwitcher(month: selectedMonth, move: moveMonth)
                                    .accessibilityIdentifier("selected-month")
                            }
                            if currentSummary != nil || (displayMode == .list ? analysisStore.errorMessage : calendarStore.errorMessage) == nil {
                                monthSummary
                                    .disabled(displayMode == .list ? !analysisStore.permitsPresentationActions : !calendarStore.permitsPresentationActions)
                            }
                        }.padding(.bottom, PFSpacing.medium)
                            .id("ledger-header")
                        if displayMode == .list {
                            if isBatchSelecting, !batchSelection.isEmpty, let snapshot = listSnapshot {
                                TransactionBatchActionsView(
                                    selectedIDs: batchSelection.ids,
                                    snapshot: snapshot,
                                    categories: categories,
                                    accounts: accounts,
                                    tags: tags,
                                    onDeleted: { batchSelection.clear() }
                                )
                                // Selection totals and plans belong to this exact published revision.
                                .id(snapshot.revision)
                                .disabled(!analysisStore.permitsPresentationActions)
                            }
                            transactionList
                                .disabled(!analysisStore.permitsPresentationActions)
                        } else {
                            if let snapshot = calendarSnapshot {
                                if calendarStore.isPresentationStale {
                                    Text("显示上次日历结果，更新完成前暂不可操作。").font(.caption)
                                }
                                BillCalendarView(snapshot: snapshot, month: $selectedMonth)
                                    .disabled(!calendarStore.permitsPresentationActions)
                            } else if calendarStore.errorMessage != nil {
                                EmptyView()
                            } else {
                                ProgressView("正在加载日历…")
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, PFSpacing.xLarge)
                    .padding(.top, PFSpacing.xSmall)
                    .padding(.bottom, 96)
                }
                .scrollPosition(id: $anchorID, anchor: .top)
                #if DEBUG
                .onPreferenceChange(LedgerRowFramePreference.self) { diagnosticFrames = $0 }
                .onChange(of: probesScroll ? anchorID : nil) { diagnosticAnchorUpdates += 1 }
                .overlay(alignment: .bottomTrailing) {
                    if probesScroll {
                        GeometryReader { proxy in
                            let frame = proxy.frame(in: .global)
                            Color.clear.onAppear { diagnosticViewport = frame }
                                .onChange(of: frame) { _, value in diagnosticViewport = value }
                        }.allowsHitTesting(false)
                        Text(scrollDiagnostic).font(.system(size: 8)).padding(2)
                            .background(.regularMaterial)
                            .accessibilityIdentifier("ledger-scroll-diagnostic")
                    }
                }
                #endif
                .background(PFColor.background)
                .overlay(alignment: .top) {
                    if analysisStore.isLoading, listSnapshot != nil, displayMode == .list {
                        ProgressView("正在更新流水…")
                            .padding(PFSpacing.small)
                            .background(.regularMaterial, in: Capsule())
                            .accessibilityIdentifier("ledger-refreshing")
                    }
                }
                #if DEBUG
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if Build21SyntheticFixture.queryGate.isEnabled {
                        VStack {
                            Text(Build21SyntheticFixture.queryGate.phase)
                                .accessibilityIdentifier("ledger-gate-phase")
                            HStack {
                                Button("Arm") { Build21SyntheticFixture.queryGate.arm() }
                                    .accessibilityIdentifier("ledger-gate-arm")
                                Button("Release") { Build21SyntheticFixture.queryGate.release(.success) }
                                    .accessibilityIdentifier("ledger-gate-release")
                                Button("Cancel") { Build21SyntheticFixture.queryGate.release(.cancelled) }
                                    .accessibilityIdentifier("ledger-gate-cancel")
                                Button("Fail") { Build21SyntheticFixture.queryGate.release(.failure) }
                                    .accessibilityIdentifier("ledger-gate-fail")
                            }.buttonStyle(.bordered)
                        }.font(.caption).padding(4).background(.regularMaterial)
                    }
                }
                #endif
                .safeAreaInset(edge: .top, spacing: 0) {
                    let store = displayMode == .list ? analysisStore : calendarStore
                    if let error = store.errorMessage {
                        HStack {
                            Text(store.isPresentationStale ? "显示上次结果。" + error : error).font(.caption).foregroundStyle(PFColor.danger)
                                .accessibilityIdentifier("ledger-error-message")
                            Spacer()
                            Button {
                                if displayMode == .list { searchSubmissionNonce &+= 1 }
                                else { reloadCalendar() }
                            } label: {
                                Text("重新加载")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("ledger-retry")
                        }
                        .padding(PFSpacing.medium)
                        .background(.regularMaterial)
                    }
                }
                .navigationTitle("流水")
                .navigationBarTitleDisplayMode(.inline)
                .task(id: analysisTaskKey) {
                    guard displayMode == .list else { return }
                    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if immediateSearchText != query, !query.isEmpty {
                        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    }
                    let requestedAnchor = anchorID
                    #if DEBUG
                    let beforeQuery: (() async throws -> Void)? = Build21SyntheticFixture.isEnabled
                        ? { try await Build21SyntheticFixture.ledgerQueryCheckpoint() } : nil
                    #else
                    let beforeQuery: (() async throws -> Void)? = nil
                    #endif
                    await analysisStore.reload(filter: analysisFilter,
                        actor: LedgerAnalysisActor(modelContainer: modelContext.container), anchorID: requestedAnchor, anchorProvider: { anchorID }, beforeQuery: beforeQuery)
                    guard !Task.isCancelled else { return }
                    anchorID = analysisStore.anchorAfterPublication(current: anchorID)
                    immediateSearchText = nil
                }
                .task(id: calendarFilter) { reloadCalendar() }
                .onAppear(perform: reloadCalendar)
                .onChange(of: ledgerChangeCenter.revision) { reloadCalendar() }
                .onChange(of: analysisFilter) {
                    anchorID = nil
                    batchSelection.clear()
                    scrollProxy.scrollTo("ledger-header", anchor: .top)
                }
                .onChange(of: displayMode) { _, mode in
                    anchorID = nil
                    scrollProxy.scrollTo("ledger-header", anchor: .top)
                    if mode != .list { isBatchSelecting = false; batchSelection.clear(); reloadCalendar() }
                }
                .onChange(of: completeResultIDs) { _, ids in
                    if !analysisStore.isLoading { batchSelection.reconcile(currentResultIDs: ids) }
                }
                .onDisappear { calendarTask?.cancel() }
            }
        }
    }

    @ViewBuilder
    private var searchControls: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: PFSpacing.medium) {
            HStack {
                TextField("搜索备注、标签、分类、账户或商户", text: $searchText)
                    .focused($isSearchFocused).submitLabel(.search)
                    .onSubmit { submitSearch(); isSearchFocused = false }
                    .textFieldStyle(.roundedBorder).frame(minHeight: 44)
                    .accessibilityIdentifier("transaction-search-input")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Text("清空搜索").frame(minHeight: 44).contentShape(Rectangle()) }
                        .accessibilityIdentifier("clear-transaction-search")
                }
                Button { isSearchPresented = false; isSearchFocused = false } label: { Text("收起").frame(minHeight: 44).contentShape(Rectangle()) }
            }
            Picker("搜索范围", selection: $searchScope) {
                ForEach(SearchScope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("transaction-search-scope")

            if isSearchPresented, query.isEmpty, !searchHistory.values.isEmpty {
                HStack {
                    Text("最近搜索")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button { searchHistory.clear() } label: { Text("清除").frame(minHeight: 44).contentShape(Rectangle()) }
                        .font(.subheadline)
                        .accessibilityIdentifier("clear-recent-searches")
                }
                SearchHistoryFlowLayout(spacing: PFSpacing.small) {
                    ForEach(searchHistory.values, id: \.self) { value in
                        Button { executeHistorySearch(value) } label: { Text(value).frame(minHeight: 44).contentShape(Rectangle()) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .accessibilityIdentifier("recent-search-\(value)")
                    }
                }
            }
        }
    }

    private var activeConditions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                if selectedType != nil { typeMenu }
                if selectedCategoryID != nil { categoryMenu }
                if selectedAccountID != nil { accountMenu }
                if selectedTagID != nil { tagMenu }
                if !searchText.isEmpty { Button("搜索：\(searchText) ×") { searchText = "" } }
                Button("清除筛选") { clearFilters() }
                    .accessibilityIdentifier("clear-filters")
            }.frame(minHeight: 44)
        }.font(.caption)
    }

    private var monthSummary: some View {
        VStack(alignment: .leading, spacing: PFSpacing.small) {
            if let totals = currentSummary?.totals {
                if displayMode == .calendar {
                    Text("当前展示月份 · \(calendarFilter.dateTitle(locale: locale))")
                        .font(.caption).foregroundStyle(PFColor.secondaryText)
                }
                if displayMode == .calendar, searchScope == .all {
                    Text("范围仍为全部历史；日历合计仅含当前月份").font(.caption)
                }
                LedgerContextSummary(totals: totals, mode: analysisFilter.mode)
            } else if (displayMode == .calendar ? calendarStore.errorMessage : analysisStore.errorMessage) != nil {
                EmptyView()
            } else { ProgressView("正在统计…") }
        }
        .padding(PFSpacing.medium)
        .background(PFColor.card, in: RoundedRectangle(cornerRadius: PFRadius.medium))
        .accessibilityIdentifier("transactions-month-summary")
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PFSpacing.small) {
                typeMenu
                categoryMenu
                accountMenu
                tagMenu
                sortMenu
                if hasFilters {
                    Button("清空") {
                        clearFilters()
                    }
                    .buttonStyle(.bordered)
                    .tint(PFColor.danger)
                    .accessibilityIdentifier("clear-filters")
                }
            }
        }
    }

    private var typeMenu: some View {
        Menu {
            Button("全部") { selectedType = nil }
            Button("支出") { selectedType = .expense }
            Button("收入") { selectedType = .income }
            Button("退款") { selectedType = .refund }
            Button("转账") { selectedType = .transfer }
        } label: {
            filterLabel(
                selectedType.map { LedgerFilter.Mode(rawValue: $0.rawValue)!.title } ?? "全部类型",
                isActive: selectedType != nil
            )
        }
        .accessibilityIdentifier("type-filter")
    }

    private var categoryMenu: some View {
        Menu {
            Button("全部分类") { selectedCategoryID = nil }
            ForEach(orderedFilterCategories) { category in
                Button(category.displayPath(in: categories)) { selectedCategoryID = category.id }
            }
        } label: {
            filterLabel(
                selectedCategoryID.flatMap {
                    categoriesByID[$0]?.displayPath(in: categories)
                } ?? "分类",
                isActive: selectedCategoryID != nil
            )
        }
        .accessibilityIdentifier("category-filter")
    }

    private var orderedFilterCategories: [Category] {
        let hierarchy = CategoryHierarchy(categories: categories)
        switch selectedType {
        case .expense, .refund:
            return hierarchy.orderedCategories(kind: .expense, activeOnly: false)
        case .income:
            return hierarchy.orderedCategories(kind: .income, activeOnly: false)
        case .transfer:
            return []
        case nil:
            return hierarchy.orderedCategories(kind: .expense, activeOnly: false)
                + hierarchy.orderedCategories(kind: .income, activeOnly: false)
        }
    }

    private var accountMenu: some View {
        Menu {
            Button("全部账户") { selectedAccountID = nil }
            ForEach(accounts) { account in
                Button(account.name) { selectedAccountID = account.id }
            }
        } label: {
            filterLabel(
                selectedAccountID.flatMap { accountsByID[$0]?.name } ?? "账户",
                isActive: selectedAccountID != nil
            )
        }
        .accessibilityIdentifier("account-filter")
    }

    private var tagMenu: some View {
        Menu {
            Button("全部标签") { selectedTagID = nil }
            ForEach(tags) { tag in
                Button(tag.name) { selectedTagID = tag.id }
            }
        } label: {
            filterLabel(
                selectedTagID.flatMap { id in tags.first { $0.id == id }?.name } ?? "标签",
                isActive: selectedTagID != nil
            )
        }
        .accessibilityIdentifier("tag-filter")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(TransactionSortOrder.allCases, id: \.self) { order in
                Button {
                    selectedSortOrder = order
                } label: {
                    if selectedSortOrder == order {
                        Label(order.title, systemImage: "checkmark")
                    } else {
                        Text(order.title)
                    }
                }
            }
        } label: {
            filterLabel(selectedSortOrder.title, isActive: selectedSortOrder != .timeNewest)
        }
        .accessibilityIdentifier("transaction-sort")
    }

    private func filterLabel(_ title: String, isActive: Bool) -> some View {
        HStack(spacing: PFSpacing.xSmall) {
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(isActive ? PFColor.accent : PFColor.primaryText)
        .padding(.horizontal, PFSpacing.medium)
        .frame(minHeight: 44)
        .background(
            isActive ? PFColor.accent.opacity(0.12) : PFColor.elevatedSurface,
            in: Capsule()
        )
    }

    @ViewBuilder
    private var transactionList: some View {
        Group {
            if isBatchSelecting, !displayedTransactions.isEmpty {
                HStack {
                    Button("完成") { isBatchSelecting = false; batchSelection.clear() }.frame(minHeight: 44)
                    Spacer()
                        Button(batchSelection.count == completeResultIDs.count ? "取消全选" : "全选当前结果") {
                            if batchSelection.count == completeResultIDs.count { batchSelection.clear() }
                            else { batchSelection.selectAll(currentResultIDs: completeResultIDs) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("select-all-current-results")
                }
            }
            if listSnapshot != nil, analysisStore.hasPrevious {
                Button("加载前面的记录") {
                    Task {
                        await analysisStore.loadPreviousPage(actor: LedgerAnalysisActor(modelContainer: modelContext.container), anchorProvider: { anchorID })
                        guard !Task.isCancelled else { return }
                        anchorID = analysisStore.anchorAfterPublication(current: anchorID)
                    }
                }.accessibilityIdentifier("ledger-previous-page")
            }
            if listSnapshot == nil && analysisStore.errorMessage == nil {
                ProgressView("正在查询完整筛选范围…").frame(maxWidth: .infinity)
                    .accessibilityIdentifier("global-search-loading")
            } else if analysisStore.errorMessage != nil, listSnapshot == nil {
                EmptyView()
            } else if displayedTransactions.isEmpty {
                PFEmptyState(symbol: hasFilters ? "line.3.horizontal.decrease.circle" : "calendar",
                    title: hasFilters ? "没有符合条件的交易" : "当前范围还没有交易",
                    message: hasFilters ? "尝试清空搜索或筛选条件。" : "点击底部的加号，记录第一笔交易。")
                    .frame(maxWidth: .infinity)
                if hasFilters {
                    Button("清空筛选") { clearFilters() }.buttonStyle(.borderedProminent)
                }
            } else if selectedSortOrder.isAmountOrder {
                transactionRows(displayedTransactions)
            } else {
                ForEach(transactionGroups) { group in
                    HStack {
                        Text(group.dayKey).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(group.subtitle(locale: locale)).font(.caption).foregroundStyle(PFColor.secondaryText)
                    }.padding(.bottom, PFSpacing.small)
                    transactionRows(group.transactions)
                }
            }
            if listSnapshot != nil, analysisStore.hasMore {
                Text("已加载 \(displayedTransactions.count) / 共 \(completeResultIDs.count) 笔").font(.caption)
                    .padding(.bottom, PFSpacing.medium)
                Button(analysisStore.isLoadingPage ? "正在加载…" : "加载更多") {
                    Task {
                        await analysisStore.loadNextPage(actor: LedgerAnalysisActor(modelContainer: modelContext.container), anchorProvider: { anchorID })
                        guard !Task.isCancelled else { return }
                        anchorID = analysisStore.anchorAfterPublication(current: anchorID)
                    }
                }
                .disabled(!analysisStore.permitsPresentationActions || analysisStore.isLoadingPage)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("global-search-next-page")
            }
        }
    }

    @ViewBuilder
    private func transactionRows(_ values: [LedgerFilteredRow]) -> some View {
        if let metadata = analysisStore.snapshot?.metadata {
            ForEach(Array(values.enumerated()), id: \.element.id) { index, transaction in
                VStack(spacing: 0) {
                    if isBatchSelecting {
                        Button { batchSelection.toggle(transaction.id) } label: {
                            HStack(spacing: PFSpacing.medium) {
                                Image(systemName: batchSelection.contains(transaction.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(PFColor.accent)
                                LedgerFilteredTransactionRow(row: transaction, metadata: metadata, showsDate: selectedSortOrder.isAmountOrder, searchQuery: analysisFilter.query)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("batch-select-\(transaction.id.uuidString)")
                    } else {
                        NavigationLink { LedgerTransactionDestination(id: transaction.id) } label: {
                            LedgerFilteredTransactionRow(row: transaction, metadata: metadata, showsDate: selectedSortOrder.isAmountOrder, searchQuery: analysisFilter.query)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("transaction-row-\(transaction.id.uuidString)")
                        #if DEBUG
                        .accessibilityValue(probesScroll ? "probe-index=\(displayedTransactions.firstIndex { $0.id == transaction.id } ?? -1)" : "")
                        .background {
                            if probesScroll {
                                GeometryReader { proxy in
                                    Color.clear.preference(key: LedgerRowFramePreference.self,
                                        value: [transaction.id: proxy.frame(in: .global)])
                                }
                            }
                        }
                        #endif
                    }
                    if index < values.count - 1 { Divider() }
                }
                .padding(.horizontal, PFSpacing.large)
                .background(PFColor.card, in: UnevenRoundedRectangle(
                    topLeadingRadius: index == 0 ? PFRadius.medium : 0,
                    bottomLeadingRadius: index == values.count - 1 ? PFRadius.medium : 0,
                    bottomTrailingRadius: index == values.count - 1 ? PFRadius.medium : 0,
                    topTrailingRadius: index == 0 ? PFRadius.medium : 0))
                .padding(.bottom, index == values.count - 1 ? PFSpacing.medium : 0)
                .id(transaction.id)
            }
        }
    }

    private func moveMonth(_ offset: Int) {
        if let month = Calendar.current.date(byAdding: .month, value: offset, to: selectedMonth) {
            withAnimation {
                selectedMonth = month
            }
        }
    }

    private func clearFilters() {
        selectedType = nil
        selectedCategoryID = nil
        selectedAccountID = nil
        selectedTagID = nil
    }

    private func submitSearch() {
        guard let normalized = searchHistory.submit(searchText) else { return }
        searchText = normalized
        immediateSearchText = normalized
        searchSubmissionNonce &+= 1
    }

    private func executeHistorySearch(_ value: String) {
        guard let normalized = searchHistory.submit(value) else { return }
        searchText = normalized
        immediateSearchText = normalized
        searchSubmissionNonce &+= 1
    }

    private func reloadCalendar() {
        guard displayMode == .calendar else { return }
        calendarTask?.cancel()
        let filter = calendarFilter
        calendarTask = Task {
            await calendarStore.reload(filter: filter, actor: LedgerAnalysisActor(modelContainer: modelContext.container))
        }
    }
}

private struct TodayAnalysisTaskKey: Equatable {
    let filter: LedgerFilter
    let revision: UInt64
    let submission: Int
    let isList: Bool
}

private struct SearchHistoryFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(subviews: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(subviews: subviews, width: bounds.width)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(subviews: Subviews, width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}

private struct TransactionDayGroup: Identifiable {
    let dayKey: String
    let transactions: [LedgerFilteredRow]
    let totals: LedgerTotals
    var id: String { dayKey }
    func subtitle(locale: Locale) -> String {
        let expense = (Decimal(totals.netExpenseMinorUnits) / 100).formatted(.currency(code: Money.cnyCode).locale(locale))
        let income = (Decimal(totals.incomeMinorUnits) / 100).formatted(.currency(code: Money.cnyCode).locale(locale))
        var values: [String] = []
        if totals.expenseCount + totals.refundCount > 0 { values.append("支出 " + expense) }
        if totals.incomeCount > 0 { values.append("收入 " + income) }
        if values.isEmpty, totals.transferCount > 0 { values.append("转账 \(totals.transferCount) 笔") }
        return values.joined(separator: " · ")
    }
}

#if DEBUG
private struct LedgerRowFramePreference: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
#endif
