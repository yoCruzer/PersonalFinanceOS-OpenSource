import SwiftUI

struct RecordedExpenseFactsView: View {
    @Environment(\.locale) private var locale
    let comparison: RecordedExpenseComparison
    var body: some View {
        if !comparison.facts.isEmpty {
            VStack(alignment: .leading, spacing: PFSpacing.small) {
                Text(comparison.periods.isWholeMonth ? "已记录支出 · 整月环比" : "已记录支出 · 同期比较")
                    .font(.caption).foregroundStyle(PFColor.secondaryText)
                if let day = comparison.periods.commonDay {
                    Text("两个区间均截至 \(day) 日" + (comparison.periods.current.occurredThrough == comparison.periods.asOf ? "同一时刻" : "结束"))
                        .font(.caption).foregroundStyle(PFColor.secondaryText)
                }
                ForEach(comparison.facts) { fact in
                    NavigationLink {
                        RecordedExpenseEvidenceView(comparison: comparison, fact: fact)
                    } label: {
                        VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
                            Text(headline(fact)).font(.subheadline.weight(.medium))
                            if fact.current.refundMinorUnits != fact.previous.refundMinorUnits {
                                Text("原始支出 \(money(fact.previous.grossExpenseMinorUnits)) → \(money(fact.current.grossExpenseMinorUnits))；退款 \(money(fact.previous.refundMinorUnits)) → \(money(fact.current.refundMinorUnits))")
                                    .font(.caption).foregroundStyle(PFColor.secondaryText)
                            }
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.accessibilityIdentifier("recorded-expense-fact-" + fact.id)
                }
            }
        }
    }
    private func headline(_ fact: RecordedExpenseComparison.Fact) -> String {
        let change = money(fact.delta).replacingOccurrences(of: "-", with: "")
        if let name = fact.categoryName { return "可比分类中，\(name)增加最多：\(change)" }
        return "扣除退款后，比上月" + (comparison.periods.isWholeMonth ? "" : "同期") + (fact.delta > 0 ? "多 " : "少 ") + change
    }
    private func money(_ value: Int64) -> String { SignedAmountFormatting.text(value, locale: locale) }
}

private struct RecordedExpenseEvidenceView: View {
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @Environment(\.locale) private var locale
    let comparison: RecordedExpenseComparison
    let fact: RecordedExpenseComparison.Fact
    @State private var revoked = false
    var body: some View {
        List {
            if revoked {
                Text("账本已更新，请返回统计查看新的比较。")
            } else {
                Text(comparison.periods.isWholeMonth ? "两个完整历史月份的已记录支出" : "两个相同截止规则的已记录支出")
                Text("只说明已记录金额；不判断消费行为或未记录支出。")
                    .font(.caption).foregroundStyle(PFColor.secondaryText)
                Section("当期") { evidence(fact.currentFilter, totals: fact.current) }
                Section("对照期") { evidence(fact.previousFilter, totals: fact.previous) }
            }
        }
        .navigationTitle("比较依据")
        .task { revoked = (try? LedgerSaveRevision.shared.readContentStamp()) != comparison.revision }
        .onChange(of: ledgerChangeCenter.revision) { revoked = true }
    }
    private func evidence(_ filter: LedgerFilter, totals: LedgerTotals) -> some View {
        NavigationLink {
            LedgerDrilldownView(filter: filter, requiresExactRevision: true)
        } label: {
            VStack(alignment: .leading, spacing: PFSpacing.small) {
                Text(filter.dateTitle(locale: locale))
                if let cutoff = filter.occurredThrough, !comparison.periods.isWholeMonth {
                    Text("截止 " + cutoff.formatted(.dateTime.locale(locale).year().month().day().hour().minute())).font(.caption)
                }
                Text("原始支出 " + money(totals.grossExpenseMinorUnits) + " · 退款 " + money(totals.refundMinorUnits))
                    .font(.caption)
                Text("净支出 " + money(totals.netExpenseMinorUnits) + " · 查看全部 \(totals.totalCount) 笔")
            }
        }
    }
    private func money(_ value: Int64) -> String { SignedAmountFormatting.text(value, locale: locale) }
}
