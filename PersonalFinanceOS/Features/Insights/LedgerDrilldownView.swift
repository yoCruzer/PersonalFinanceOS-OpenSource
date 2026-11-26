import SwiftData
import SwiftUI

struct LedgerDrilldownView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @Environment(\.locale) private var locale
    @State private var filter: LedgerFilter
    @State private var store = LedgerAnalysisStore()
    @State private var anchorID: UUID?
    @State private var showFilters = false
    @State private var showBatch = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var isExporting = false
    private let requiresExactRevision: Bool
    private let showsCategoryBreakdown: Bool

    init(filter: LedgerFilter, title _: String = "筛选明细", showsCategoryBreakdown: Bool = false, requiresExactRevision: Bool = false) {
        _filter = State(initialValue: filter)
        self.requiresExactRevision = requiresExactRevision
        self.showsCategoryBreakdown = showsCategoryBreakdown
    }

    private var currentSnapshot: LedgerAnalysisSnapshot? {
        guard let snapshot = store.snapshot else { return nil }
        var expected = filter
        var actual = snapshot.filter
        expected.revision = nil
        actual.revision = nil
        return expected == actual ? snapshot : nil
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PFSpacing.large) {
                filterChips
                if store.isLoading { ProgressView("正在统计完整范围…") }
                if store.isPresentationStale { Text("显示上次结果，更新完成前暂不可操作。").font(.caption) }
                if let message = store.errorMessage {
                    Text(message).foregroundStyle(PFColor.danger)
                    Button("重新加载") { Task { await reload() } }
                }
                if let snapshot = currentSnapshot {
                    totals(snapshot.totals)
                    if showsCategoryBreakdown {
                        categoryBreakdown(snapshot).disabled(!store.permitsPresentationActions)
                    }
                    Group {
                        if store.hasPrevious {
                            Button("加载前面的记录") {
                                Task { await Self.loadPage(.previous, store: store, actor: LedgerAnalysisActor(modelContainer: modelContext.container), anchor: $anchorID) }
                            }.disabled(store.isLoadingPage)
                            .accessibilityIdentifier("analysis-load-previous")
                        }
                        ForEach(store.rows) { row in
                            NavigationLink {
                                LedgerTransactionDestination(id: row.id)
                            } label: {
                                LedgerFilteredTransactionRow(row: row, metadata: snapshot.metadata, searchQuery: snapshot.filter.query)
                            }
                            .id(row.id)
                            .accessibilityIdentifier("filtered-transaction-\(row.id)")
                        }
                        if store.hasMore {
                            Button(store.isLoadingPage ? "正在加载…" : "加载更多") {
                                Task { await Self.loadPage(.next, store: store, actor: LedgerAnalysisActor(modelContainer: modelContext.container), anchor: $anchorID) }
                            }
                            .disabled(store.isLoadingPage)
                            .accessibilityIdentifier("analysis-load-more")
                        }
                        if snapshot.totals.totalCount == 0 { Text("当前条件下没有记录") }
                    }.disabled(!store.permitsPresentationActions)
                }
                if let exportURL, store.permitsPresentationActions {
                    ShareLink("分享完整筛选结果", item: exportURL)
                        .accessibilityIdentifier("analysis-share-export")
                }
                if let exportError { Text(exportError).foregroundStyle(PFColor.danger) }
            }
            .scrollTargetLayout()
            .padding(PFSpacing.xLarge)
        }
        .scrollPosition(id: $anchorID)
        .background(PFColor.background)
        .navigationTitle(currentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            HStack {
                Button { showFilters = true } label: {
                    Label("筛选", systemImage: "line.3.horizontal.decrease").frame(minHeight: 44).contentShape(Rectangle())
                }
                    .accessibilityIdentifier("analysis-filter")
                Spacer()
                Menu {
                    Picker("排序", selection: $filter.sortOrder) {
                        ForEach(TransactionSortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Button("批量操作完整筛选结果") { showBatch = true }
                        .disabled(!store.permitsPresentationActions || (currentSnapshot?.transactionIDs.isEmpty ?? true))
                    Button("导出完整筛选结果") { Task { await export() } }
                        .disabled(!store.permitsPresentationActions || currentSnapshot == nil || isExporting)
                } label: { Label("排序与导出", systemImage: "ellipsis.circle").frame(minHeight: 44).contentShape(Rectangle()) }
                .accessibilityIdentifier("analysis-actions")
            }
            .frame(minHeight: 44)
            .padding(.horizontal, PFSpacing.xLarge)
            .background(PFColor.card)
        }
        .searchable(text: $filter.query, placement: .navigationBarDrawer(displayMode: .always),
            prompt: "在当前范围搜索备注、分类、标签或账户")
        .sheet(isPresented: $showFilters) {
            LedgerFilterEditor(filter: $filter, metadata: store.snapshot?.metadata)
        }
        .sheet(isPresented: $showBatch) {
            if let snapshot = currentSnapshot, store.permitsPresentationActions { LedgerFullResultBatchView(snapshot: snapshot) }
        }
        .task(id: filter) {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            await reload()
        }
        .onChange(of: ledgerChangeCenter.revision) {
            exportURL = nil
            showBatch = false
            Task { await reload() }
        }
        .onChange(of: filter) { anchorID = nil; exportURL = nil; showBatch = false }
    }

    private var filterChips: some View {
        VStack(alignment: .leading, spacing: PFSpacing.small) {
            if let cutoff = filter.occurredThrough {
                Text("比较证据截至 " + cutoff.formatted(date: .abbreviated, time: .shortened))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("analysis-evidence-cutoff")
            } else if requiresExactRevision {
                Text("普通分析 · 已退出原比较依据")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("analysis-ordinary-context")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Text(filter.dateTitle(locale: locale))
                    Text(filter.mode.title)
                    switch filter.category {
                    case .all: EmptyView()
                    case .uncategorized: Button("待分类 ×") { filter.category = .all }
                    case let .node(id): Button((store.snapshot?.metadata.path(id) ?? "指定分类") + " ×") { filter.category = .all }
                    case let .direct(id): Button((store.snapshot?.metadata.path(id) ?? "指定分类") + " · 直接挂账 ×") { filter.category = .all }
                    }
                    if let id = filter.accountID { Button((store.snapshot?.metadata.accounts[id] ?? "账户") + " ×") { filter.accountID = nil } }
                    if !filter.tagIDs.isEmpty { Button("同时包含 \(filter.tagIDs.count) 个标签 ×") { filter.tagIDs = [] } }
                    if !filter.merchant.isEmpty { Button("商户：\(filter.merchant) ×") { filter.merchant = "" } }
                }
                .font(.caption)
                .frame(minHeight: 44)
                .padding(.vertical, PFSpacing.small)
            }
            .accessibilityIdentifier("analysis-filter-chips")
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentTitle: String {
        switch filter.category {
        case .all: return filter.mode == .all ? "交易明细" : filter.mode.title
        case .uncategorized: return "待分类"
        case let .node(id), let .direct(id): return store.snapshot?.metadata.path(id) ?? "分类明细"
        }
    }

    private func totals(_ value: LedgerTotals) -> some View {
        LedgerContextSummary(totals: value, mode: filter.mode)
            .padding(PFSpacing.large)
            .background(PFColor.card, in: RoundedRectangle(cornerRadius: PFRadius.medium))
            .accessibilityIdentifier("analysis-filtered-summary")
    }

    private func categoryBreakdown(_ snapshot: LedgerAnalysisSnapshot) -> some View {
        let keys = snapshot.directCategoryTotals.keys.sorted {
            let left = snapshot.directCategoryTotals[$0]?.amount(for: filter.mode) ?? 0
            let right = snapshot.directCategoryTotals[$1]?.amount(for: filter.mode) ?? 0
            return left == right ? ($0?.uuidString ?? "") < ($1?.uuidString ?? "") : left > right
        }
        return VStack(alignment: .leading, spacing: PFSpacing.medium) {
            Text("小类构成").font(.headline)
            ForEach(keys, id: \.self) { id in
                let direct = id.flatMap { snapshot.metadata.categories[$0] }?.parentID == nil && id != nil
                var childFilter: LedgerFilter { var value = filter; value.category = id.map { .direct($0) } ?? .uncategorized; value.revision = nil; return value }
                NavigationLink {
                    LedgerDrilldownView(filter: childFilter, title: snapshot.metadata.path(id))
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(snapshot.metadata.path(id) + (direct ? " · 父级直接挂账" : ""))
                            Text("\(snapshot.directCategoryTotals[id]?.totalCount ?? 0) 笔").font(.caption)
                        }
                        Spacer()
                        Text(amount(snapshot.directCategoryTotals[id]?.amount(for: filter.mode) ?? 0))
                    }.frame(minHeight: 44)
                }
            }
        }
    }

    enum PageDirection { case previous, next }

    /// The page buttons share this action so both directions follow the live scroll binding.
    @MainActor
    static func loadPage(_ direction: PageDirection, store: LedgerAnalysisStore,
                         actor: LedgerAnalysisActor, anchor: Binding<UUID?>) async {
        switch direction {
        case .previous: await store.loadPreviousPage(actor: actor, anchorProvider: { anchor.wrappedValue })
        case .next: await store.loadNextPage(actor: actor, anchorProvider: { anchor.wrappedValue })
        }
        guard !Task.isCancelled, store.permitsPresentationActions else { return }
        anchor.wrappedValue = store.anchorAfterPublication(current: anchor.wrappedValue)
    }

    private func reload() async {
        await store.reload(filter: filter, actor: LedgerAnalysisActor(modelContainer: modelContext.container), anchorID: anchorID, anchorProvider: { anchorID }, requiresExactRevision: requiresExactRevision && filter.occurredThrough != nil)
        guard !Task.isCancelled else { return }
        anchorID = store.anchorAfterPublication(current: anchorID)
    }

    private func export() async {
        guard store.permitsPresentationActions, let snapshot = currentSnapshot else { return }
        isExporting = true
        exportError = nil
        defer { isExporting = false }
        do {
            let data = try await LedgerAnalysisActor(modelContainer: modelContext.container).exportData(snapshot: snapshot)
            guard store.permitsPresentationActions, currentSnapshot?.filter == snapshot.filter, (try? LedgerSaveRevision.shared.readContentStamp()) == snapshot.revision else {
                throw LedgerAnalysisError.staleSnapshot
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FilteredExport-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("筛选明细.csv")
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch { exportError = error.localizedDescription }
    }

    private func amount(_ value: Int64) -> String { (Decimal(value) / 100).formatted(.currency(code: Money.cnyCode).locale(locale)) }
}

struct LedgerTransactionDestination: View {
    @Query private var transactions: [FinanceTransaction]
    init(id: UUID) {
        _transactions = Query(filter: #Predicate<FinanceTransaction> { $0.id == id })
    }
    var body: some View {
        if let transaction = transactions.first, transaction.deletedAt == nil {
            TransactionDetailView(transaction: transaction)
        } else {
            ContentUnavailableView("这笔记录已删除", systemImage: "trash", description: Text("返回明细可查看更新后的结果。"))
        }
    }
}

private struct LedgerFilterEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: LedgerFilter
    let metadata: LedgerFilterMetadata?
    @State private var start = Date()
    @State private var end = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("日期范围") {
                    if filter.occurredThrough != nil {
                        Text("选择日期范围将转为普通分析，不再作为原比较依据。")
                    }
                    Button("本月") { filter.selectDateRange(LedgerFilter.month(Date()).dateRange) }
                    Button("本年") {
                        let calendar = Calendar.current
                        let range = calendar.dateInterval(of: .year, for: Date())!
                        filter.selectDateRange(LocalDayRange(lowerBound: LocalDayKey.make(for: range.start, timeZone: calendar.timeZone),
                            upperBound: LocalDayKey.make(for: range.end, timeZone: calendar.timeZone)))
                    }
                    Button("全部历史") { filter.selectDateRange(nil) }
                    DatePicker("开始日期", selection: $start, displayedComponents: .date)
                    DatePicker("结束日期（含）", selection: $end, displayedComponents: .date)
                    Button("应用自定义日期") {
                        guard let range = LedgerRangeSelection.inclusiveRange(start: start, end: end) else { return }
                        filter.selectDateRange(range)
                    }.disabled(LedgerRangeSelection.inclusiveRange(start: start, end: end) == nil)
                }
                Picker("统计口径", selection: $filter.mode) {
                    ForEach(LedgerFilter.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Section("账户与商户") {
                    Picker("账户", selection: $filter.accountID) {
                        Text("全部账户").tag(nil as UUID?)
                        ForEach((metadata?.accounts.keys.sorted { $0.uuidString < $1.uuidString }) ?? [], id: \.self) { id in
                            Text(metadata?.accounts[id] ?? "").tag(Optional(id))
                        }
                    }
                    TextField("商户包含", text: $filter.merchant)
                }
                Section("同时包含以下标签") {
                    ForEach((metadata?.tags.keys.sorted { $0.uuidString < $1.uuidString }) ?? [], id: \.self) { id in
                        Toggle(metadata?.tags[id] ?? "", isOn: Binding(get: { filter.tagIDs.contains(id) }, set: {
                            if $0 { filter.tagIDs.insert(id) } else { filter.tagIDs.remove(id) }
                        }))
                    }
                }
            }
            .navigationTitle("明细筛选")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                let dates = LedgerRangeSelection.editorDates(filter, asOf: Date())
                start = dates.start; end = dates.end
                guard let range = filter.dateRange else { return }
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                if let value = formatter.date(from: range.lowerBound) { start = value }
                if let value = formatter.date(from: range.upperBound) {
                    end = Calendar.current.date(byAdding: .day, value: -1, to: value) ?? value
                }
            }
        }
    }
}
