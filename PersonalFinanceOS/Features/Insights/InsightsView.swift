import Charts
import SwiftData
import SwiftUI

struct InsightsView: View {
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter

    @Query private var categories: [Category]
    #if DEBUG
    @State private var rangeFilter = LedgerFilter.month(Build21SyntheticFixture.initialMonth)
    #else
    @State private var rangeFilter = LedgerFilter.month(Date())
    #endif
    private var asOf: Date {
        #if DEBUG
        Build21SyntheticFixture.initialMonth
        #else
        Date()
        #endif
    }
    private var selectedMonth: Date { LedgerRangeSelection.trendAnchor(rangeFilter, asOf: asOf) }
    @State private var showsRangePicker = false
    @State private var comparisonStore = RecordedExpenseComparisonStore()
    private var comparison: RecordedExpenseComparison? { comparisonStore.comparison }
    @State private var displayStore = InsightsDisplayStore()
    @State private var selectedTrendCategoryID: UUID?
    @State private var selectedMonthlyTrendDate: Date?
    @State private var selectedCategoryTrendDate: Date?
    @State private var analysisTask: Task<Void, Never>?
    private var analysisStore: LedgerAnalysisStore { displayStore.rangeStore }
    private var snapshot: FinanceInsightsSnapshot { displayStore.finance ?? .empty(selectedMonth: selectedMonth) }
    private var analyzedRange: LedgerFilter? { displayStore.display?.filter.withoutRevision }

    private var categoriesByID: [UUID: Category] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }

    private var summary: FinanceMonthSummary {
        snapshot.summary
    }

    private var spending: [CategorySpending] {
        snapshot.categorySpending
    }

    private var trend: [MonthlyTrendPoint] {
        displayStore.trendFinance?.trend ?? []
    }

    private var activity: FinanceMonthActivity {
        snapshot.activity
    }

    private var categoryTrend: [CategoryTrendPoint] {
        displayStore.trendFinance?.categoryTrend(for: selectedTrendCategoryID, categories: categories) ?? []
    }

    private var selectedMonthlyTrendPoint: MonthlyTrendPoint? {
        selectedPoint(in: trend, selection: selectedMonthlyTrendDate, month: \.month)
    }

    private var selectedCategoryTrendPoint: CategoryTrendPoint? {
        let points = categoryTrend
        return selectedPoint(in: points, selection: selectedCategoryTrendDate, month: \.month)
    }

    private var trendCategories: [Category] {
        let hierarchy = CategoryHierarchy(categories: categories)
        return hierarchy.orderedCategories(kind: .expense, activeOnly: false)
    }

    private var totalCategorySpending: Int64 {
        currentTotals.netExpenseMinorUnits
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PFSpacing.xxLarge) {
                    HStack {
                        if LedgerRangeSelection.wholeMonth(rangeFilter) != nil {
                            Button { moveMonth(-1) } label: {
                                Image(systemName: "chevron.left").frame(width: 44, height: 44)
                            }.accessibilityLabel("上个月")
                        }
                        Spacer()
                        Button { showsRangePicker = true } label: {
                            Label(rangeFilter.dateTitle(locale: locale), systemImage: "calendar")
                                .font(.headline).frame(minHeight: 44).contentShape(Rectangle())
                        }.accessibilityIdentifier("insights-range")
                        Spacer()
                        if LedgerRangeSelection.wholeMonth(rangeFilter) != nil {
                            Button { moveMonth(1) } label: {
                                Image(systemName: "chevron.right").frame(width: 44, height: 44)
                            }.accessibilityLabel("下个月")
                        }
                    }
                    if displayStore.isRefreshing { ProgressView("正在刷新统计…") }
                    if let error = analysisStore.errorMessage { Text(error).foregroundStyle(PFColor.danger) }
                    if analyzedRange == rangeFilter.withoutRevision {
                        Group {
                            summarySection
                            if let comparison { RecordedExpenseFactsView(comparison: comparison) }
                            categorySection
                        }.disabled(!analysisStore.permitsPresentationActions)
                        switch displayStore.trendState {
                        case .idle, .loading: ProgressView("正在刷新最近六个月趋势…")
                        case let .failed(message): Text("趋势更新失败：\(message)").foregroundStyle(PFColor.danger)
                        case .cancelled: Text("趋势更新已取消，可重试。")
                        case .ready:
                            Group {
                                trendSection
                                categoryTrendSection
                            }.disabled(!displayStore.trendStore.permitsPresentationActions)
                        }
                    }
                }
                .padding(.horizontal, PFSpacing.xLarge)
                .padding(.top, PFSpacing.xSmall)
                .padding(.bottom, 108)
            }
            .background(PFColor.background)
            .navigationTitle("统计")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showsRangePicker) { InsightsRangePicker(filter: $rangeFilter) }
        .task(id: rangeFilter) { reloadSnapshot(for: selectedMonth) }
        .onChange(of: ledgerChangeCenter.revision) { reloadSnapshot(for: selectedMonth) }
        .onDisappear { analysisTask?.cancel() }
    }

    private var summarySection: some View {
        LedgerContextSummary(totals: currentTotals, mode: .all, primaryPointSize: 34)
            .padding(PFSpacing.large)
            .background(PFColor.card, in: RoundedRectangle(cornerRadius: PFRadius.medium))
            .accessibilityIdentifier("insights-summary")
    }

    private var canShowCategoryShares: Bool {
        totalCategorySpending > 0 && spending.allSatisfy { $0.amountMinorUnits >= 0 }
    }

    @ViewBuilder
    private var categorySection: some View {
        VStack(alignment: .leading, spacing: PFSpacing.medium) {
            PFSectionHeader(title: "支出构成")

            if spending.isEmpty {
                PFEmptyState(
                    symbol: "chart.pie",
                    title: "没有分类支出",
                    message: "本月有支出后，这里会显示分类占比和排行。"
                )
                .frame(maxWidth: .infinity)
            } else {
                if canShowCategoryShares {
                Chart(spending, id: \.categoryID) { item in
                    let category = item.categoryID.flatMap { categoriesByID[$0] }
                    SectorMark(
                        angle: .value("金额", item.amountMinorUnits),
                        innerRadius: .ratio(0.62),
                        angularInset: 2
                    )
                    .cornerRadius(4)
                    .foregroundStyle(PFColor.category(category?.colorToken ?? "teal"))
                }
                .chartLegend(.hidden)
                .frame(height: 190)
                .overlay {
                    VStack(spacing: PFSpacing.xSmall) {
                        Text("支出")
                            .font(.caption)
                            .foregroundStyle(PFColor.secondaryText)
                        Text(formatted(totalCategorySpending))
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                .accessibilityLabel("当前范围分类支出占比")

                } else {
                    Text("退款影响已计入；正负金额见下方分类").font(.caption).foregroundStyle(PFColor.secondaryText)
                }

                VStack(spacing: 0) {
                    ForEach(Array(spending.enumerated()), id: \.offset) { index, item in
                        let category = item.categoryID.flatMap { categoriesByID[$0] }
                        NavigationLink {
                            LedgerDrilldownView(filter: drilldownFilter(.netExpense, category: item.categoryID.map { .node($0) } ?? .uncategorized),
                                title: category?.name ?? "待分类", showsCategoryBreakdown: true)
                        } label: { HStack(spacing: PFSpacing.medium) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PFColor.secondaryText)
                                .frame(width: 20)
                            Circle()
                                .fill(PFColor.category(category?.colorToken ?? "teal"))
                                .frame(width: 10, height: 10)
                            Text(category?.name ?? "待分类")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(formatted(item.amountMinorUnits))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                Text(canShowCategoryShares ? "\(percentage(item.amountMinorUnits)) · \(item.transactionCount) 笔" : "\(item.transactionCount) 笔")
                                    .font(.caption2)
                                    .foregroundStyle(PFColor.secondaryText)
                            }
                        }.padding(.vertical, PFSpacing.medium).frame(minHeight: 44).contentShape(Rectangle()) }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "第 \(index + 1) 名，\(category?.name ?? "待分类")，\(formatted(item.amountMinorUnits))，" +
                            (canShowCategoryShares ? "占 \(percentage(item.amountMinorUnits))，" : "") + "\(item.transactionCount) 笔"
                        )
                        if index < spending.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, PFSpacing.large)
                .background(PFColor.card, in: RoundedRectangle(
                    cornerRadius: PFRadius.medium,
                    style: .continuous
                ))
            }
        }
        .accessibilityIdentifier("category-spending")
    }

    private var categoryTrendSection: some View {
        VStack(alignment: .leading, spacing: PFSpacing.medium) {
            PFSectionHeader(title: "分类支出趋势 · 最近六个月")
            Text("截至 " + AppDateFormatter.monthYear(selectedMonth, locale: locale)).font(.caption).foregroundStyle(PFColor.secondaryText)
            Picker("支出分类", selection: $selectedTrendCategoryID) {
                Text("全部净支出").tag(Optional<UUID>.none)
                ForEach(trendCategories) { category in
                    HStack(spacing: PFSpacing.small) {
                        CategoryIconView(
                            symbolName: category.symbolName,
                            color: PFColor.category(category.colorToken),
                            size: 20
                        )
                        Text(category.displayPath(in: categories))
                    }
                        .tag(Optional(category.id))
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedTrendCategoryID) {
                selectedCategoryTrendDate = nil
            }

            if categoryTrend.allSatisfy({ $0.transactionCount == 0 }) {
                PFEmptyState(
                    symbol: "chart.xyaxis.line",
                    title: "暂无趋势",
                    message: "所选分类最近六个月没有支出。"
                )
            } else {
                Chart {
                    ForEach(categoryTrend, id: \.monthKey) { point in
                        BarMark(
                            x: .value("月份", point.month, unit: .month),
                            y: .value("金额", point.amountMinorUnits)
                        )
                        .foregroundStyle(PFColor.accent.gradient)
                        .opacity(
                            selectedCategoryTrendPoint == nil ||
                            selectedCategoryTrendPoint?.monthKey == point.monthKey ? 1 : 0.42
                        )
                    }
                    if let selectedCategoryTrendPoint {
                        RuleMark(
                            x: .value("选中月份", selectedCategoryTrendPoint.month, unit: .month)
                        )
                        .foregroundStyle(PFColor.secondaryText.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: AppDateFormatter.monthAbbreviatedStyle(locale: locale))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let amount = value.as(Int64.self) {
                                Text(compactAmount(amount))
                            }
                        }
                    }
                }
                .monthSelectionOverlay(
                    selection: $selectedCategoryTrendDate,
                    months: categoryTrend.map(\.month)
                )
                .frame(height: 210)
                .accessibilityLabel("分类净支出最近六个月趋势")
                .accessibilityIdentifier("category-trend-chart")

                if let selectedCategoryTrendPoint {
                    Text("\(AppDateFormatter.monthYear(selectedCategoryTrendPoint.month, locale: locale)) · \(formatted(selectedCategoryTrendPoint.amountMinorUnits)) · \(selectedCategoryTrendPoint.transactionCount)笔")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .accessibilityIdentifier("category-trend-selection")
                    NavigationLink("查看该月明细") {
                        LedgerDrilldownView(filter: drilldownFilter(.netExpense,
                            category: selectedTrendCategoryID.map { .node($0) } ?? .all, month: selectedCategoryTrendPoint.month))
                    }
                }

                let current = categoryTrend.last
                let completeKeys = Set(ExpenseTrendSummaryService.completeMonths(trend,
                    earliestKnownDay: displayStore.trendDisplay?.dayTotals.keys.min()).map(\.monthKey))
                let complete = categoryTrend.filter { completeKeys.contains($0.monthKey) }
                let average = ExpenseTrendSummaryService.summarize(complete.map { MonthlyTrendPoint(monthKey: $0.monthKey, month: $0.month, incomeMinorUnits: 0, expenseMinorUnits: $0.amountMinorUnits) }).averageMinorUnits
                let highest = complete.max { $0.amountMinorUnits < $1.amountMinorUnits }
                VStack(spacing: PFSpacing.small) {
                    LabeledContent(Calendar.current.isDate(selectedMonth, equalTo: Date(), toGranularity: .month) ? "本月至今" : "窗口末月", value: formatted(current?.amountMinorUnits ?? 0))
                    LabeledContent("当前月笔数", value: "\(current?.transactionCount ?? 0)")
                    if !complete.isEmpty {
                        LabeledContent("完整月份月均（含无记录月）", value: formatted(average))
                    } else { Text("完整月份不足，暂不比较") }
                    if let highest {
                        LabeledContent(
                            "最高完整月份",
                            value: "\(AppDateFormatter.monthYear(highest.month, locale: locale)) · \(formatted(highest.amountMinorUnits))"
                        )
                    }

                }
                .font(.subheadline)
                .padding(PFSpacing.large)
                .background(PFColor.card, in: RoundedRectangle(cornerRadius: PFRadius.medium))
            }
        }
        .accessibilityIdentifier("category-trend")
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: PFSpacing.medium) {
            PFSectionHeader(title: "最近六个月")
            Text("趋势范围：\(LedgerFilter.sixMonths(endingAt: selectedMonth).dateTitle(locale: locale))；独立于上方分析范围。本月数据截至目前。")
                .font(.caption).foregroundStyle(PFColor.secondaryText)

            Chart {
                if let selectedMonthlyTrendPoint {
                    RuleMark(
                        x: .value("选中月份", selectedMonthlyTrendPoint.month, unit: .month)
                    )
                    .foregroundStyle(PFColor.secondaryText.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                }
                ForEach(trend, id: \.monthKey) { point in
                    LineMark(
                        x: .value("月份", point.month, unit: .month),
                        y: .value("金额", point.expenseMinorUnits),
                        series: .value("类型", "净支出")
                    )
                    .foregroundStyle(by: .value("类型", "净支出"))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(
                        x: .value("月份", point.month, unit: .month),
                        y: .value("金额", point.expenseMinorUnits)
                    )
                    .foregroundStyle(by: .value("类型", "净支出"))

                    LineMark(
                        x: .value("月份", point.month, unit: .month),
                        y: .value("金额", point.incomeMinorUnits),
                        series: .value("类型", "收入")
                    )
                    .foregroundStyle(by: .value("类型", "收入"))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, dash: [7, 5]))
                    PointMark(
                        x: .value("月份", point.month, unit: .month),
                        y: .value("金额", point.incomeMinorUnits)
                    )
                    .foregroundStyle(by: .value("类型", "收入"))

                    if point.monthKey == selectedMonthlyTrendPoint?.monthKey {
                        PointMark(
                            x: .value("选中月份", point.month, unit: .month),
                            y: .value("选中净支出", point.expenseMinorUnits)
                        )
                        .symbolSize(105)
                        .foregroundStyle(PFColor.expense)
                        PointMark(
                            x: .value("选中月份", point.month, unit: .month),
                            y: .value("选中收入", point.incomeMinorUnits)
                        )
                        .symbolSize(105)
                        .foregroundStyle(PFColor.income)
                    }
                }
            }
            .chartForegroundStyleScale([
                "净支出": PFColor.expense,
                "收入": PFColor.income
            ])
            .chartYScale(domain: min(0, trend.map(\.expenseMinorUnits).min() ?? 0)...trendUpperBound)
            .chartLegend(position: .top, alignment: .leading)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { value in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel(
                        format: AppDateFormatter.monthAbbreviatedStyle(locale: locale)
                    )
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Int64.self) {
                            Text(compactAmount(amount))
                        }
                    }
                }
            }
            .monthSelectionOverlay(
                selection: $selectedMonthlyTrendDate,
                months: trend.map(\.month)
            )
            .frame(height: 230)
            .id(snapshot.selectedMonth)
            .padding(PFSpacing.large)
            .background(PFColor.card, in: RoundedRectangle(
                cornerRadius: PFRadius.medium,
                style: .continuous
            ))
            .accessibilityLabel("最近六个月收入与净支出趋势")
            .accessibilityIdentifier("monthly-trend-chart")

            if let selectedMonthlyTrendPoint {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppDateFormatter.monthYear(selectedMonthlyTrendPoint.month, locale: locale))
                    Text("净支出 \(formatted(selectedMonthlyTrendPoint.expenseMinorUnits)) · 收入 \(formatted(selectedMonthlyTrendPoint.incomeMinorUnits))")
                }
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("monthly-trend-selection")
                HStack {
                    NavigationLink("查看该月净支出") {
                        LedgerDrilldownView(filter: drilldownFilter(.netExpense, month: selectedMonthlyTrendPoint.month))
                    }
                    NavigationLink("查看该月收入") {
                        LedgerDrilldownView(filter: drilldownFilter(.income, month: selectedMonthlyTrendPoint.month))
                    }
                }
            }
        }
        .accessibilityIdentifier("monthly-trend")
    }

    private var trendUpperBound: Int64 {
        max(1, trend.flatMap { [$0.incomeMinorUnits, $0.expenseMinorUnits] }.max() ?? 0)
    }

    private func moveMonth(_ offset: Int) {
        guard let month = Calendar.current.date(byAdding: .month, value: offset, to: selectedMonth) else {
            return
        }
        selectedMonthlyTrendDate = nil
        selectedCategoryTrendDate = nil
        rangeFilter.dateRange = LedgerFilter.month(month).dateRange
    }

    private func reloadSnapshot(for month: Date) {
        analysisTask?.cancel()
        let comparisonRequest = comparisonStore.begin()
        let requestedAsOf = asOf
        let requestedRange = rangeFilter
        analysisTask = Task {
            let actor = LedgerAnalysisActor(modelContainer: modelContext.container)
            await displayStore.reload(filter: requestedRange, month: month, actor: actor)
            guard !Task.isCancelled, rangeFilter == requestedRange else { return }
            await comparisonStore.reload(request: comparisonRequest, query: {
                try await actor.recordedExpenseComparison(filter: requestedRange, asOf: requestedAsOf)
            }, accepts: { result in
                rangeFilter == requestedRange && result.revision == LedgerSaveRevision.shared.contentRevision &&
                    result.revision == displayStore.display?.revision
            })
        }
    }

    private var currentTotals: LedgerTotals {
        displayStore.currentTotals
    }

    private func drilldownFilter(_ mode: LedgerFilter.Mode, category: LedgerFilter.CategoryScope = .all, month: Date? = nil) -> LedgerFilter {
        var value = month.map { LedgerFilter.month($0) } ?? rangeFilter
        value.mode = mode
        value.category = category
        return value
    }

    private func selectedPoint<Point>(
        in points: [Point],
        selection: Date?,
        month: (Point) -> Date
    ) -> Point? {
        guard let index = MonthTrendSelectionService.nearestIndex(
            to: selection,
            in: points.map(month)
        ), points.indices.contains(index) else {
            return nil
        }
        return points[index]
    }

    private func formatted(_ value: Int64) -> String {
        (Decimal(value) / 100).formatted(.currency(code: Money.cnyCode).locale(locale))
    }

    private func signedFormatted(_ value: Int64) -> String {
        formatted(value)
    }

    private func percentage(_ value: Int64) -> String {
        guard canShowCategoryShares else { return "不适用占比" }
        return (Double(value) / Double(totalCategorySpending))
            .formatted(.percent.precision(.fractionLength(0)))
    }

    private func compactAmount(_ value: Int64) -> String {
        let yuan = Decimal(value) / 100
        return "¥\(yuan.formatted(.number.notation(.compactName)))"
    }
}

private struct InsightsRangePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: LedgerFilter
    @State private var start: Date
    @State private var end: Date

    init(filter: Binding<LedgerFilter>) {
        _filter = filter
        let dates = LedgerRangeSelection.editorDates(filter.wrappedValue, asOf: Date())
        _start = State(initialValue: dates.start)
        _end = State(initialValue: dates.end)
    }

    var body: some View {
        NavigationStack {
            Form {
                Button("本月") { filter.dateRange = LedgerFilter.month(Date()).dateRange; dismiss() }
                Button("本年") {
                    let calendar = Calendar.current
                    let year = calendar.dateInterval(of: .year, for: Date())!
                    filter.dateRange = LocalDayRange(lowerBound: LocalDayKey.make(for: year.start, timeZone: calendar.timeZone),
                        upperBound: LocalDayKey.make(for: year.end, timeZone: calendar.timeZone))
                    dismiss()
                }
                Button("全部历史") { filter.dateRange = nil; dismiss() }
                Section("自定义日期") {
                    DatePicker("开始日期", selection: $start, displayedComponents: .date).accessibilityIdentifier("range-start")
                    DatePicker("结束日期（含）", selection: $end, displayedComponents: .date).accessibilityIdentifier("range-end")
                    Button("应用范围") {
                        guard let range = LedgerRangeSelection.inclusiveRange(start: start, end: end) else { return }
                        filter.dateRange = range
                        dismiss()
                    }.disabled(LedgerRangeSelection.inclusiveRange(start: start, end: end) == nil)
                }
            }
            .navigationTitle("分析范围")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}
