import Charts
import SwiftData
import SwiftUI

struct OverviewView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter

    @Query private var categories: [Category]
    @Query private var accounts: [Account]

    let onShowTransactions: () -> Void
    @State private var snapshot = FinanceInsightsSnapshot.empty(selectedMonth: Date())
    @State private var recentTransactions: [FinanceTransaction] = []
    @State private var selectedTrendDate: Date?
    @State private var analysisStore = LedgerAnalysisStore()
    @State private var analysisTask: Task<Void, Never>?

    private var categoriesByID: [UUID: Category] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }

    private var accountsByID: [UUID: Account] {
        Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    }

    private var currentMonth: Date {
        #if DEBUG
        Build21SyntheticFixture.initialMonth
        #else
        Date()
        #endif
    }

    private var summary: FinanceMonthSummary {
        snapshot.summary
    }

    private var categorySpending: [CategorySpending] {
        Array(snapshot.categorySpending.filter { $0.amountMinorUnits >= 0 }.prefix(4)) +
            snapshot.categorySpending.filter { $0.amountMinorUnits < 0 }
    }

    private var trend: [MonthlyTrendPoint] {
        snapshot.trend
    }

    private var trendUpperBound: Int64 {
        let maximum = trend.map(\.expenseMinorUnits).max() ?? 0
        guard maximum > 0 else { return 1 }
        let padding = max(1, maximum / 5)
        let (upperBound, overflow) = maximum.addingReportingOverflow(padding)
        return overflow ? .max : upperBound
    }

    private var trendSummary: ExpenseTrendSummary {
        ExpenseTrendSummaryService.summarize(completeTrendMonths)
    }

    private var completeTrendMonths: [MonthlyTrendPoint] {
        ExpenseTrendSummaryService.completeMonths(trend, earliestKnownDay: analysisStore.snapshot?.dayTotals.keys.min())
    }

    private var selectedTrendPoint: MonthlyTrendPoint? {
        MonthTrendSelectionService.nearestIndex(
            to: selectedTrendDate,
            in: trend.map(\.month)
        ).map { trend[$0] }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PFSpacing.xxLarge) {
                    if analysisStore.isLoading { ProgressView("正在统计…") }
                    if let error = analysisStore.errorMessage { Text(error).foregroundStyle(PFColor.danger) }
                    if analysisStore.snapshot != nil { hero }

                    if analysisStore.snapshot == nil {
                        EmptyView()
                    } else if snapshot.activity.totalCount == 0 {
                        emptyState
                    } else {
                        categoryOverview
                        trendOverview
                        recentActivity
                    }
                }
                .padding(.horizontal, PFSpacing.xLarge)
                .padding(.top, PFSpacing.xSmall)
                .padding(.bottom, 108)
            }
            .background(PFColor.background)
            .navigationTitle("概览")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { reload() }
        .onAppear(perform: reload)
        .onChange(of: ledgerChangeCenter.revision) { reload() }
        .onDisappear { analysisTask?.cancel() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: PFSpacing.small) {
            Text(AppDateFormatter.monthYear(currentMonth, locale: locale)).font(.subheadline)
            NavigationLink {
                LedgerDrilldownView(filter: drilldownFilter(.netExpense), title: "本月支出")
            } label: {
                VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
                    Text("支出").font(.caption).foregroundStyle(PFColor.secondaryText)
                    PFPrimaryAmount(minorUnits: summary.expenseMinorUnits, pointSize: 38)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }.accessibilityIdentifier("overview-net-expense-details")
            if summary.incomeMinorUnits != 0 {
                secondaryAmount("收入", value: summary.incomeMinorUnits)
                secondaryAmount("结余", value: summary.balanceMinorUnits)
            }
            if let totals = analysisStore.snapshot?.monthTotals[String(LocalDayKey.make(for: currentMonth, timeZone: .current).prefix(7))], totals.refundCount > 0 {
                NavigationLink("已扣退款 \(amount(totals.refundMinorUnits)) · 金额说明") {
                    LedgerDrilldownView(filter: drilldownFilter(.netExpense))
                }.font(.caption).frame(minHeight: 44)
            }
        }
        .padding(PFSpacing.large)
        .background(PFColor.card, in: RoundedRectangle(cornerRadius: PFRadius.medium))
    }

    @ViewBuilder
    private func secondaryAmount(_ title: String, value: Int64) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
                Text(title).font(.caption).foregroundStyle(PFColor.secondaryText)
                PFCompleteAmount(text: amount(value))
                    .font(.headline)
            }
        } else {
            LabeledContent(title, value: amount(value))
        }
    }

    private var emptyState: some View {
        PFEmptyState(
            symbol: "sparkles",
            title: "从第一笔开始",
            message: "记录收入或支出后，这里会出现本月概览、分类分布和趋势。"
        )
        .frame(maxWidth: .infinity)
    }

    private var categoryOverview: some View {
        VStack(alignment: .leading, spacing: PFSpacing.medium) {
            PFSectionHeader(title: "主要支出分类")
            NavigationLink("查看全部支出分类") {
                LedgerDrilldownView(filter: drilldownFilter(.netExpense), showsCategoryBreakdown: true)
            }.frame(minHeight: 44)

            VStack(spacing: PFSpacing.medium) {
                ForEach(categorySpending, id: \.categoryID) { item in
                    let category = item.categoryID.flatMap { categoriesByID[$0] }
                    NavigationLink {
                        LedgerDrilldownView(filter: drilldownFilter(.netExpense, category: item.categoryID.map { .node($0) } ?? .uncategorized),
                            title: category?.name ?? "待分类", showsCategoryBreakdown: true)
                    } label: { HStack(spacing: PFSpacing.medium) {
                        CategoryIconView(
                            symbolName: category?.symbolName ?? CategoryIconLibrary.fallback,
                            color: PFColor.category(category?.colorToken ?? "teal"),
                            size: 34
                        )
                        let name = Text(category?.name ?? "待分类")
                            .font(.subheadline.weight(.medium))
                        let value = PFCompleteAmount(text: amount(item.amountMinorUnits))
                            .font(.subheadline.weight(.semibold))
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
                                name
                                value
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            name
                            Spacer()
                            value
                        }
                    } }
                }
            }
            .padding(PFSpacing.large)
            .background(PFColor.card, in: RoundedRectangle(
                cornerRadius: PFRadius.medium,
                style: .continuous
            ))
        }
    }

    private var trendOverview: some View {
        VStack(alignment: .leading, spacing: PFSpacing.medium) {
            PFSectionHeader(title: "最近趋势")
            Text("本月至今；平均线仅含首笔记录之后、当前月之前的完整月份（含无记录月）")
                .font(.caption).foregroundStyle(PFColor.secondaryText)

            Chart {
                if let selectedTrendPoint {
                    RuleMark(x: .value("选中月份", selectedTrendPoint.month, unit: .month))
                        .foregroundStyle(PFColor.secondaryText.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                if !completeTrendMonths.isEmpty {
                    RuleMark(y: .value("平均净支出", trendSummary.averageMinorUnits))
                        .foregroundStyle(PFColor.secondaryText)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("平均 \(compactAmount(trendSummary.averageMinorUnits))")
                                .font(.caption2)
                                .foregroundStyle(PFColor.secondaryText)
                        }
                }
                ForEach(trend, id: \.monthKey) { point in
                LineMark(
                    x: .value("月份", point.month, unit: .month),
                    y: .value("净支出", point.expenseMinorUnits)
                )
                .foregroundStyle(PFColor.accent)
                .interpolationMethod(.linear)
                PointMark(
                    x: .value("月份", point.month, unit: .month),
                    y: .value("净支出", point.expenseMinorUnits)
                )
                .foregroundStyle(PFColor.accent)
                if point.monthKey == selectedTrendPoint?.monthKey {
                    PointMark(
                        x: .value("选中月份", point.month, unit: .month),
                        y: .value("选中净支出", point.expenseMinorUnits)
                    )
                    .symbolSize(110)
                    .foregroundStyle(PFColor.accent)
                }
                if point.monthKey == trendSummary.maximum?.monthKey {
                    PointMark(
                        x: .value("最高月份", point.month, unit: .month),
                        y: .value("最高净支出", point.expenseMinorUnits)
                    )
                    .symbolSize(64)
                    .foregroundStyle(PFColor.expense)
                    .annotation(position: .top) {
                        Text("高 \(compactAmount(point.expenseMinorUnits))")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PFColor.expense)
                    }
                } else if point.monthKey == trendSummary.minimum?.monthKey {
                    PointMark(
                        x: .value("最低月份", point.month, unit: .month),
                        y: .value("最低净支出", point.expenseMinorUnits)
                    )
                    .symbolSize(52)
                    .foregroundStyle(PFColor.income)
                    .annotation(position: .bottom) {
                        Text("低 \(compactAmount(point.expenseMinorUnits))")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PFColor.income)
                    }
                }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(PFColor.secondaryText.opacity(0.18))
                    AxisValueLabel {
                        if let amount = value.as(Int64.self) {
                            Text(compactAmount(amount))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: 2)) { value in
                    AxisValueLabel(
                        format: AppDateFormatter.monthAbbreviatedStyle(locale: locale)
                    )
                }
            }
            .chartYScale(domain: min(0, trend.map(\.expenseMinorUnits).min() ?? 0)...trendUpperBound)
            .monthSelectionOverlay(
                selection: $selectedTrendDate,
                months: trend.map(\.month)
            )
            .frame(height: 158)
            .padding(PFSpacing.large)
            .background(PFColor.card, in: RoundedRectangle(
                cornerRadius: PFRadius.medium,
                style: .continuous
            ))
            .accessibilityLabel("最近六个月净支出趋势")
            .accessibilityValue(trendAccessibilityValue)
            .accessibilityIdentifier("overview-expense-trend")

            if let selectedTrendPoint {
                Text("\(AppDateFormatter.monthYear(selectedTrendPoint.month, locale: locale))\(Calendar.current.isDate(selectedTrendPoint.month, equalTo: Date(), toGranularity: .month) ? " · 本月至今" : "") · 支出 \(amount(selectedTrendPoint.expenseMinorUnits))")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityIdentifier("overview-trend-selection")
                NavigationLink("查看该月明细") {
                    LedgerDrilldownView(filter: drilldownFilter(.netExpense, month: selectedTrendPoint.month), title: "该月净支出")
                }
            }
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: PFSpacing.medium) {
            PFSectionHeader(title: "最近交易", actionTitle: "查看全部", action: onShowTransactions)

            VStack(spacing: 0) {
                ForEach(Array(recentTransactions.enumerated()), id: \.element.id) { index, transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction, onChanged: reload)
                    } label: {
                        if let metadata = analysisStore.snapshot?.metadata {
                            LedgerFilteredTransactionRow(row: LedgerFilteredRow(transaction), metadata: metadata)
                        }

                    }
                    .buttonStyle(.plain)
                    if index < recentTransactions.count - 1 {
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

    private func amount(_ value: Int64) -> String {
        (Decimal(value) / 100).formatted(.currency(code: Money.cnyCode).locale(locale))
    }

    private func signedAmount(_ value: Int64) -> String {
        amount(value)
    }

    private func compactAmount(_ value: Int64) -> String {
        let yuan = Decimal(value) / 100
        return "¥\(yuan.formatted(.number.notation(.compactName)))"
    }

    private var trendAccessibilityValue: String {
        guard let maximum = trendSummary.maximum else { return "暂无可比较的完整月份" }
        var parts = [
            "平均净支出 \(amount(trendSummary.averageMinorUnits))",
            "最高净支出 \(amount(maximum.expenseMinorUnits))，\(AppDateFormatter.monthYear(maximum.month, locale: locale))"
        ]
        if let minimum = trendSummary.minimum {
            parts.append("最低净支出 \(amount(minimum.expenseMinorUnits))，\(AppDateFormatter.monthYear(minimum.month, locale: locale))")
        }
        return parts.joined(separator: "；")
    }

    private func reload() {
        analysisTask?.cancel()
        let month = currentMonth
        analysisTask = Task {
            await analysisStore.reload(filter: .sixMonths(endingAt: month), actor: LedgerAnalysisActor(modelContainer: modelContext.container))
            guard !Task.isCancelled, let result = analysisStore.snapshot else { return }
            snapshot = .from(result, selectedMonth: month)
            recentTransactions = (try? LedgerQueryService.fetchRecent(limit: 5, in: modelContext)) ?? []
        }
    }

    private func drilldownFilter(_ mode: LedgerFilter.Mode, category: LedgerFilter.CategoryScope = .all, month: Date? = nil) -> LedgerFilter {
        var value = LedgerFilter.month(month ?? currentMonth)
        value.mode = mode
        value.category = category
        return value
    }
}
