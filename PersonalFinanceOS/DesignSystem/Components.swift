import Charts
import SwiftUI

private struct MonthSelectionOverlayModifier: ViewModifier {
    @Binding var selection: Date?
    let months: [Date]

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        SpatialTapGesture().onEnded { value in
                            updateSelection(at: value.location, proxy: proxy, geometry: geometry)
                        }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            updateSelection(at: value.location, proxy: proxy, geometry: geometry)
                        }
                    )
            }
        }
    }

    private func updateSelection(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrameAnchor = proxy.plotFrame else { return }
        let plotFrame = geometry[plotFrameAnchor]
        guard plotFrame.contains(location) else { return }
        guard let date: Date = proxy.value(atX: location.x - plotFrame.minX),
              let index = MonthTrendSelectionService.nearestIndex(to: date, in: months) else {
            return
        }
        selection = months[index]
    }
}

extension View {
    func monthSelectionOverlay(
        selection: Binding<Date?>,
        months: [Date]
    ) -> some View {
        modifier(MonthSelectionOverlayModifier(selection: selection, months: months))
    }
}

struct CategoryIconView: View {
    let symbolName: String
    let color: Color
    let size: CGFloat
    var isSelected = false

    var body: some View {
        let foreground = isSelected ? Color.white : color
        ZStack {
            switch CategoryIconLibrary.descriptor(for: symbolName) {
            case .systemSymbol(let symbol):
                Image(systemName: CategoryIconLibrary.availableSymbol(symbol))
                    .font(.system(size: size * 0.48, weight: .medium))
            case .text(let text):
                Text(text)
                    .font(.system(size: size * (text.count == 1 ? 0.46 : 0.34), weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(foreground)
        .frame(width: size, height: size)
        .background(
            isSelected ? color : color.opacity(0.12),
            in: Circle()
        )
        .accessibilityHidden(true)
    }
}

struct AmountText: View {
    let minorUnits: Int64
    var currencyCode: String = Money.cnyCode
    var style: Font.TextStyle = .title
    var prefix: String = ""

    var body: some View {
        Text(prefix + formattedAmount)
            .font(.system(style, design: .rounded, weight: .semibold))
            .monospacedDigit()
            .accessibilityLabel(accessibilityAmount)
    }

    private var formattedAmount: String {
        guard let money = try? Money(
            minorUnits: max(0, minorUnits),
            currencyCode: currencyCode
        ) else {
            return "\(currencyCode) —"
        }
        return money.formatted()
    }

    private var accessibilityAmount: String {
        guard let money = try? Money(
            minorUnits: max(0, minorUnits),
            currencyCode: currencyCode
        ) else {
            return "金额不可用"
        }
        return "\(prefix)\(money.formatted())"
    }
}

struct PFPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.white)
            .background(
                PFColor.accent.opacity(
                    isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.35
                ),
                in: RoundedRectangle(cornerRadius: PFRadius.medium, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}

struct PFEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: PFSpacing.medium) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(PFColor.accent)
                .frame(width: 56, height: 56)
                .background(PFColor.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(PFColor.primaryText)

            Text(message)
                .font(.body)
                .foregroundStyle(PFColor.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360)
        .padding(PFSpacing.xLarge)
    }
}

struct PFErrorState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: PFSpacing.medium) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(PFColor.danger)
                .accessibilityHidden(true)

            Text(title)
                .font(.title3.weight(.semibold))

            Text(message)
                .font(.body)
                .foregroundStyle(PFColor.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(PFSpacing.xLarge)
        .background(PFColor.elevatedSurface, in: RoundedRectangle(
            cornerRadius: PFRadius.large,
            style: .continuous
        ))
        .padding(PFSpacing.large)
    }
}

struct PFSectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.medium))
            }
        }
    }
}

struct PFMonthSwitcher: View {
    @Environment(\.locale) private var locale

    let month: Date
    let move: (Int) -> Void

    var body: some View {
        HStack {
            monthButton(symbol: "chevron.left", label: "上个月", offset: -1)
            Spacer()
            Text(AppDateFormatter.monthYear(month, locale: locale))
                .font(.title3.weight(.semibold))
                .contentTransition(.numericText())
            Spacer()
            monthButton(symbol: "chevron.right", label: "下个月", offset: 1)
        }
    }

    private func monthButton(symbol: String, label: String, offset: Int) -> some View {
        Button {
            move(offset)
        } label: {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
                .background(PFColor.card, in: Circle())
        }
        .accessibilityLabel(label)
    }
}

struct PFSummaryMetric: View {
    let title: String
    let minorUnits: Int64
    var color: Color = PFColor.primaryText
    var signed = false

    var body: some View {
        VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
            Text(title)
                .font(.caption)
                .foregroundStyle(PFColor.secondaryText)
            Text(formatted)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formatted: String {
        let absolute = minorUnits == .min ? Int64.max : abs(minorUnits)
        let amount = (try? Money(minorUnits: absolute).formatted()) ?? "—"
        guard signed else { return amount }
        return minorUnits < 0 ? "−\(amount)" : "+\(amount)"
    }
}

/// Compatibility adapter for previews that already have models loaded.
struct PFTransactionRow: View {
    let transaction: FinanceTransaction
    let category: Category?
    let account: Account?
    var categoryPath: String? = nil
    var destinationAccount: Account? = nil

    var body: some View {
        let categoryValue = category.map { LedgerFilterMetadata.CategoryValue(id: $0.id, name: $0.name,
            parentID: $0.parentID, symbolName: $0.symbolName, colorToken: $0.colorToken) }
        let metadata = LedgerFilterMetadata(categories: categoryValue.map { [$0.id: $0] } ?? [:],
            accounts: Dictionary(([account, destinationAccount].compactMap { $0 }).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            tags: Dictionary(uniqueKeysWithValues: transaction.tags.map { ($0.id, $0.name) }))
        LedgerFilteredTransactionRow(row: LedgerFilteredRow(transaction), metadata: metadata, categoryPathOverride: categoryPath)
    }
}

/// Amounts follow the active query, including refunds in consumption analysis.
struct LedgerContextSummary: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let totals: LedgerTotals
    let mode: LedgerFilter.Mode
    var primaryPointSize: CGFloat = 30

    private func amount(_ value: Int64) -> String {
        (Decimal(value) / 100).formatted(.currency(code: Money.cnyCode).locale(locale))
    }

    private func secondaryAmount(_ title: String, value: Int64) -> some View {
        VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
            Text(title)
            PFCompleteAmount(text: amount(value))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PFSpacing.small) {
            if mode == .transfer {
                Text("转账 \(totals.transferCount) 笔").font(.headline)
                Text("账户间转入与转出，金额见下方记录").font(.caption)
            } else {
                let primary = mode == .all ? totals.netExpenseMinorUnits : totals.amount(for: mode)
                let label = mode == .all || mode == .netExpense ? "支出" : mode.title
                VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
                    HStack {
                        Text(label).font(.caption).foregroundStyle(PFColor.secondaryText)
                        Spacer()
                        Text("\(totals.totalCount) 笔").font(.caption).foregroundStyle(PFColor.secondaryText)
                    }
                    PFPrimaryAmount(minorUnits: primary, pointSize: primaryPointSize,
                        color: mode == .income ? PFColor.income : mode == .refund ? PFColor.refund : PFColor.expense)
                }
                if mode == .all, totals.incomeCount > 0 {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: PFSpacing.small) {
                                secondaryAmount("收入", value: totals.incomeMinorUnits)
                                secondaryAmount("结余", value: totals.balanceMinorUnits)
                            }
                        } else {
                            ViewThatFits(in: .horizontal) {
                                HStack {
                                    Text("收入 \(amount(totals.incomeMinorUnits))")
                                    Spacer()
                                    Text("结余 \(amount(totals.balanceMinorUnits))")
                                }
                                VStack(alignment: .leading) {
                                    Text("收入 \(amount(totals.incomeMinorUnits))")
                                    Text("结余 \(amount(totals.balanceMinorUnits))")
                                }
                            }
                        }
                    }.font(.caption).foregroundStyle(PFColor.secondaryText)
                }
                if (mode == .all || mode == .netExpense), totals.refundCount > 0 {
                    DisclosureGroup {
                        LabeledContent("原始支出", value: amount(totals.grossExpenseMinorUnits))
                        LabeledContent("退款", value: amount(totals.refundMinorUnits))
                        LabeledContent("扣除退款后", value: amount(totals.netExpenseMinorUnits))
                    } label: {
                        Text("已扣退款 \(amount(totals.refundMinorUnits))").frame(minHeight: 44).contentShape(Rectangle())
                    }.font(.caption)
                }
            }
        }
    }
}
