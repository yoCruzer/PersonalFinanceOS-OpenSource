import SwiftData
import SwiftUI

struct BillCalendarView: View {
    @Environment(\.locale) private var locale

    @Environment(\.modelContext) private var modelContext
    let snapshot: LedgerAnalysisSnapshot
    @State private var dayStore = LedgerAnalysisStore()
    @Binding var month: Date
    @State private var selectedDayKey: String?
    @State private var quickAddDate: Date?

    private var days: [BillCalendarDay?] {
        BillCalendarService.days(in: month, totalsByDay: snapshot.dayTotals)
    }

    private var selectedDay: BillCalendarDay? {
        days.compactMap { $0 }.first { $0.localDayKey == selectedDayKey }
    }

    private var heatLevels: [String: ExpenseHeatLevel] {
        let calendarDays = days.compactMap { $0 }
        let levels = BillCalendarHeatmap.levels(for: calendarDays.map(\.expenseMinorUnits))
        return Dictionary(uniqueKeysWithValues: zip(calendarDays.map(\.localDayKey), levels))
    }

    private var dayFilter: LedgerFilter? {
        guard let day = selectedDay else { return nil }
        var filter = snapshot.filter
        filter.dateRange = LedgerFilter.day(day.date).dateRange
        // A stale calendar must refresh as a whole before publishing day details.
        filter.revision = snapshot.revision
        return filter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PFSpacing.large) {
            Button("回到今天") {
                month = Date()
                selectedDayKey = LocalDayKey.make(for: Date(), timeZone: .current)
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .trailing)

            weekdayHeader
            calendarGrid
            dayDetail
        }
        .task(id: dayFilter) {
            guard let dayFilter else { return }
            await dayStore.reload(filter: dayFilter, actor: LedgerAnalysisActor(modelContainer: modelContext.container),
                requiresExactRevision: true)
        }
        .onAppear { chooseDefaultDay() }
        .onChange(of: month) { chooseDefaultDay() }
        .sheet(isPresented: Binding(
            get: { quickAddDate != nil },
            set: { if !$0 { quickAddDate = nil } }
        )) {
            if let quickAddDate {
                TransactionFormView(initialDate: quickAddDate)
                    .presentationDetents([.large])
            }
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: PFSpacing.xSmall) {
            ForEach(AppDateFormatter.weekdaySymbols(locale: locale), id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PFColor.secondaryText)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var calendarGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: PFSpacing.xSmall), count: 7),
            spacing: PFSpacing.xSmall
        ) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 66)
                }
            }
        }
    }

    private func dayCell(_ day: BillCalendarDay) -> some View {
        let selected: Bool = selectedDayKey == day.localDayKey
        let today: Bool = Calendar.current.isDateInToday(day.date)
        let heatLevel: ExpenseHeatLevel = heatLevels[day.localDayKey] ?? .none
        return Button {
            selectedDayKey = day.localDayKey
        } label: {
            dayCellLabel(day, selected: selected, today: today, heatLevel: heatLevel)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dayAccessibilityLabel(day))
        .accessibilityValue(heatLevel == .none ? "无支出热力" : "支出热力 \(heatLevel.rawValue) 级")
        .accessibilityIdentifier("calendar-day-\(day.localDayKey)")
    }

    private func dayCellLabel(_ day: BillCalendarDay, selected: Bool, today: Bool,
                              heatLevel: ExpenseHeatLevel) -> some View {
        let dayColor: Color = selected || heatLevel == .high ? .white : PFColor.primaryText
        let amountColor: Color = selected || heatLevel == .high ? .white : PFColor.expense
        let markerColor: Color = selected ? .white : (day.transactionCount > 0 ? PFColor.accent : .clear)
        let backgroundColor: Color = selected ? PFColor.accent : heatColor(heatLevel)
        let borderColor: Color = today ? PFColor.accent : .clear
        return VStack(spacing: 3) {
            Text(AppDateFormatter.dayNumber(day.date, locale: locale))
                .font(.subheadline.weight(today || selected ? .bold : .regular))
                .foregroundStyle(dayColor)
            dayAmountLabel(day, color: amountColor)
            Circle()
                .fill(markerColor)
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: PFRadius.small))
        .overlay {
            RoundedRectangle(cornerRadius: PFRadius.small)
                .stroke(borderColor, lineWidth: 2)
        }
    }

    @ViewBuilder
    private func dayAmountLabel(_ day: BillCalendarDay, color: Color) -> some View {
        let amount: Int64? = day.displayedAmount(for: snapshot.filter.mode)
        if let amount {
            let presentation: BillCalendarAmountPresentation = BillCalendarAmountFormatter.presentation(for: amount)
            Text(presentation.text)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .foregroundStyle(color)
        } else if day.transferCount > 0 {
            Text("转账 \(day.transferCount) 笔").font(.caption2)
        } else {
            Text(" ")
                .font(.caption2)
        }
    }

    private func dayAccessibilityLabel(_ day: BillCalendarDay) -> String {
        let description: String
        if let amount = day.displayedAmount(for: snapshot.filter.mode) {
            description = day.displayedAmountTitle(for: snapshot.filter.mode) + " " + money(amount)
        } else if day.transferCount > 0 {
            description = "转账 \(day.transferCount) 笔"
        } else {
            description = "没有记录"
        }
        return "\(AppDateFormatter.fullDate(day.date, locale: locale))，\(day.transactionCount) 笔，" + description
    }

    @ViewBuilder
    private var dayDetail: some View {
        if let day = selectedDay {
            VStack(alignment: .leading, spacing: PFSpacing.medium) {
                HStack {
                    Text(AppDateFormatter.fullDate(day.date, locale: locale))
                        .font(.headline)
                    Spacer()
                    Button {
                        quickAddDate = dateWithCurrentTime(day.date)
                    } label: {
                        Label("补记", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("calendar-quick-add")
                }
                if let totals = snapshot.dayTotals[day.localDayKey] {
                    LedgerContextSummary(totals: totals, mode: snapshot.filter.mode)
                }

                if dayStore.isLoading {
                    ProgressView("正在加载当天明细…")
                } else if let error = dayStore.errorMessage {
                    Text(error).foregroundStyle(PFColor.danger)
                } else if dayStore.rows.isEmpty {
                    PFEmptyState(symbol: "calendar.badge.plus", title: "当天没有交易",
                        message: "可以补记，但空白日期不等于漏记。")
                } else {
                    VStack(spacing: 0) {
                        ForEach(dayStore.rows) { row in
                            NavigationLink {
                                LedgerTransactionDestination(id: row.id)
                            } label: {
                                LedgerFilteredTransactionRow(row: row, metadata: snapshot.metadata, showsDate: false, searchQuery: snapshot.filter.query)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("calendar-transaction-\(row.id)")
                            Divider()
                        }
                        if dayStore.hasMore {
                            Button(dayStore.isLoadingPage ? "正在加载…" : "加载更多当天记录") {
                                Task { await dayStore.loadNextPage(actor: LedgerAnalysisActor(modelContainer: modelContext.container)) }
                            }.disabled(dayStore.isLoadingPage)
                        }
                    }
                    .padding(.horizontal, PFSpacing.large)
                    .background(PFColor.card, in: RoundedRectangle(cornerRadius: PFRadius.medium))
                }
                if let filter = dayFilter {
                    NavigationLink("查看当天完整筛选明细") {
                        LedgerDrilldownView(filter: filter, title: "当天明细")
                    }
                }
            }
        }
    }

    private func chooseDefaultDay() {
        let key = LocalDayKey.make(for: Date(), timeZone: .current)
        selectedDayKey = days.compactMap { $0 }.contains { $0.localDayKey == key }
            ? key
            : days.compactMap { $0 }.first?.localDayKey
    }

    private func dateWithCurrentTime(_ date: Date) -> Date {
        var day = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let time = Calendar.current.dateComponents([.hour, .minute], from: Date())
        day.hour = time.hour
        day.minute = time.minute
        return Calendar.current.date(from: day) ?? date
    }

    private func money(_ value: Int64) -> String {
        (Decimal(value) / 100).formatted(.currency(code: Money.cnyCode).locale(locale))
    }

    private func heatColor(_ level: ExpenseHeatLevel) -> Color {
        switch level {
        case .none: PFColor.card
        case .low: PFColor.expense.opacity(0.10)
        case .mediumLow: PFColor.expense.opacity(0.20)
        case .mediumHigh: PFColor.expense.opacity(0.38)
        case .high: PFColor.expense.opacity(0.76)
        }
    }

}
