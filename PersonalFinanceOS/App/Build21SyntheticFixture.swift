#if DEBUG
import Foundation
import SwiftData

/// Explicit UI-test launch only; never opens or changes an on-device ledger.
@MainActor
enum Build21SyntheticFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-build21SyntheticFixture") }
    static var initialMonth: Date {
        isEnabled && ProcessInfo.processInfo.arguments.contains("-productReviewFixture")
            ? ISO8601DateFormatter().date(from: "2026-11-04T12:00:00Z")!
            : isEnabled ? ISO8601DateFormatter().date(from: "2026-10-04T12:00:00Z")! : Date()
    }

    static let queryGate = LedgerRefreshTestGate()
    private static var ledgerQueryFaultConsumed = false

    /// One-shot query faults are armed only for the isolated in-memory UI fixture.
    static func ledgerQueryCheckpoint() async throws {
        guard isEnabled else { return }
        try await queryGate.checkpoint()
        guard !ledgerQueryFaultConsumed else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ledgerQueryTestStale") {
            ledgerQueryFaultConsumed = true
            throw LedgerAnalysisError.staleSnapshot
        }
        if arguments.contains("-ledgerQueryTestCancel") {
            ledgerQueryFaultConsumed = true
            throw CancellationError()
        }
        if arguments.contains("-ledgerQueryTestFailure") {
            ledgerQueryFaultConsumed = true
            throw CocoaError(.fileReadUnknown)
        }
    }

    static func seed(in context: ModelContext) throws {
        if ProcessInfo.processInfo.arguments.contains("-productReviewFixture") {
            try ProductReviewSyntheticFixture.seed(in: context)
            return
        }
        let account = Account(name: "合成现金", type: .cash, currencyCode: "CNY")
        let destination = Account(name: "合成储蓄", type: .cash, currencyCode: "CNY")
        let dining = Category(kind: .expense, name: "合成餐饮", symbolName: "fork.knife", colorToken: "orange")
        let meal = Category(kind: .expense, name: "合成正餐", parentID: dining.id, symbolName: "fork.knife", colorToken: "orange")
        let transit = Category(kind: .expense, name: "合成交通", symbolName: "bus", colorToken: "blue")
        let shopping = Category(kind: .expense, name: "合成购物", symbolName: "bag", colorToken: "green")
        let income = Category(kind: .income, name: "合成工资", symbolName: "banknote", colorToken: "green")
        context.insert(account)
        context.insert(destination)
        [dining, meal, transit, shopping, income].forEach { context.insert($0) }
        if ProcessInfo.processInfo.arguments.contains("-build23ComparisonFixture") {
            // A known ordinary-month row independent of the two historical evidence windows.
            let calendar = Calendar.current
            let month = calendar.dateInterval(of: .month, for: Date())!.start
            let ordinaryDate = calendar.date(byAdding: .day, value: 19, to: month)!
            let previousDate = calendar.date(byAdding: .month, value: -1, to: ordinaryDate)!
            for (date, note) in [(ordinaryDate, "本月普通分析对照"), (previousDate, "上月普通分析对照")] {
                context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 123,
                    occurredAt: date, localDayKey: LocalDayKey.make(for: date, timeZone: calendar.timeZone),
                    timeZoneIdentifier: calendar.timeZone.identifier, accountID: account.id,
                    categoryID: transit.id, note: note))
            }
            transit.createdAt = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")!
            transit.updatedAt = transit.createdAt
            for (day, amount) in [("2026-09-02", Int64(1_000)), ("2026-10-02", Int64(4_000))] {
                context.insert(FinanceTransaction(type: .expense, amountMinorUnits: amount,
                    occurredAt: ISO8601DateFormatter().date(from: day + "T12:00:00Z")!, localDayKey: day,
                    timeZoneIdentifier: "GMT", accountID: account.id, categoryID: transit.id, note: "合成比较记录"))
            }
        }
        let rows: [(String, TransactionType, UUID?, Int64, String)] = [
            ("2026-09-20", .expense, meal.id, 10_000, "合成九月正餐"),
            ("2026-10-02", .refund, meal.id, 3_000, "合成跨月退款"),
            ("2026-10-03", .expense, meal.id, 8_000, "合成十月正餐"),
            ("2026-10-03", .refund, meal.id, 2_000, "合成餐饮退款"),
            ("2026-10-04", .expense, transit.id, 4_000, "合成公共交通"),
            ("2026-10-04", .refund, shopping.id, 9_000, "合成购物退款"),
            ("2026-10-05", .income, income.id, 50_000, "合成工资到账"),
            ("2026-10-05", .transfer, nil, 30_000, "合成账户转账"),
            ("2026-10-02", .expense, dining.id, 1_000, "合成父级直记")
        ]
        for (day, type, categoryID, amount, note) in rows {
            let date = ISO8601DateFormatter().date(from: day + "T12:00:00Z")!
            context.insert(FinanceTransaction(type: type, amountMinorUnits: (ProcessInfo.processInfo.arguments.contains("-build23LargeAmountFixture") && categoryID == transit.id) ? 123_456_789_012_345_600 : amount, occurredAt: date,
                localDayKey: day, timeZoneIdentifier: "GMT", accountID: account.id,
                destinationAccountID: type == .transfer ? destination.id : nil, categoryID: categoryID, note: note))
        }
        if ProcessInfo.processInfo.arguments.contains("-foreignMidnightTransaction") {
            let foreign = Account(name: "合成美元账户", type: .cash, currencyCode: "USD")
            context.insert(foreign)
            context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 1234, currencyCode: "USD",
                occurredAt: ISO8601DateFormatter().date(from: "2026-10-05T10:15:00Z")!,
                localDayKey: "2026-10-06", timeZoneIdentifier: "Pacific/Kiritimati",
                accountID: foreign.id, categoryID: meal.id, note: "跨时区美元记录"))
        }
        if ProcessInfo.processInfo.arguments.contains("-ledgerBlankFixture") {
            for index in 0..<320 {
                let date = ISO8601DateFormatter().date(from: "2026-10-04T12:00:00Z")!.addingTimeInterval(Double(index))
                context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 1, occurredAt: date,
                    localDayKey: "2026-10-04", timeZoneIdentifier: "GMT", accountID: account.id,
                    categoryID: meal.id, note: "合成流水-\(index)"))
            }
        }
        try context.save()
    }
}
#endif
