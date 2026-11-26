#if DEBUG
import Foundation
import SwiftData

/// Only reachable from the explicitly launched in-memory Build21 fixture.
/// Full published catalog, realistic synthetic history; no private ledger/cloud input.
@MainActor
enum ProductReviewSyntheticFixture {
    static func seed(in context: ModelContext) throws {
        try DefaultFinanceDataService.ensureDefaults(in: context)
        guard !ProcessInfo.processInfo.arguments.contains("-productReviewEmpty") else { return }
        context.autosaveEnabled = false
        let account = try context.fetch(FetchDescriptor<Account>())[0]
        account.name = "日常账户"
        let savings = Account(name: "储蓄账户", type: .bankCard)
        context.insert(savings)
        let categories = try context.fetch(FetchDescriptor<Category>())
        let byKey = Dictionary(uniqueKeysWithValues: categories.map { ($0.defaultDefinitionKey, $0.id) })
        let metadata = try context.fetch(FetchDescriptor<AppMetadata>())[0]
        metadata.createdAt = ISO8601DateFormatter().date(from: "2020-01-01T00:00:00Z")!
        let examples: [(String, String, Int64)] = [
            ("expense.dining.breakfast", "豆浆与早餐", 850),
            ("expense.dining.lunch", "工作日午餐", 2800),
            ("expense.dining.coffee", "下午咖啡", 1800),
            ("expense.transportation.metro", "地铁通勤", 600),
            ("expense.groceries.vegetables", "周末买菜", 7650),
            ("expense.education.books", "阅读新书", 5900),
            ("expense.home.rent", "月度房租", 320000),
            ("expense.digital-services.media", "影音会员", 2500),
            ("expense.health.medicine", "常备药品", 3860),
            ("expense.hobbies.gym", "健身月卡", 19900),
            ("expense.clothing.clothes", "换季衣物", 23900),
            ("expense.gifts.gifts", "生日礼物", 16800)
        ]
        let end = ISO8601DateFormatter().date(from: "2026-11-04T04:00:00Z")!
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        // Six entries per day across 2,000 days, 12,000 records total.
        for index in 0..<12_000 {
            let day = index / 6
            let date = end.addingTimeInterval(-Double(1999 - day) * 86400 + Double(index % 6) * 1800)
            let example = examples[(day + index % 6) % examples.count]
            let type: TransactionType = index % 100 == 0 ? .income : index % 100 == 1 ? .transfer : index % 100 == 2 ? .refund : .expense
            let key = type == .income ? "income.work.salary" : example.0
            let note = type == .income ? "工资到账" : type == .transfer ? "转入储蓄" : type == .refund ? "订单退款" : example.1
            context.insert(FinanceTransaction(type: type, amountMinorUnits: type == .income ? 1200000 : type == .transfer ? 200000 : example.2,
                occurredAt: date, localDayKey: LocalDayKey.make(for: date, timeZone: zone),
                timeZoneIdentifier: zone.identifier, accountID: account.id,
                destinationAccountID: type == .transfer ? savings.id : nil,
                categoryID: type == .transfer ? nil : byKey[key], note: note))
            if (index + 1).isMultiple(of: 1000) { try context.save() }
        }
        try context.save()
    }
}
#endif
