import SwiftData
import XCTest
@testable import PersonalFinanceOS

final class Round1FeatureTests: XCTestCase {
    @MainActor
    func testTagsPersistRenameArchiveAndRemainRelated() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(name: "现金", type: .cash, isDefault: true)
        let category = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        context.insert(account)
        context.insert(category)
        try context.save()
        let tag1 = try FinanceDataManagementService.addTag(
            name: "报销",
            tags: [],
            in: context
        )
        let tag2 = try FinanceDataManagementService.addTag(
            name: "工作",
            tags: [tag1],
            in: context
        )
        var draft = TransactionDraft()
        draft.amountText = "12.34"
        draft.accountID = account.id
        draft.categoryID = category.id
        draft.tagIDs = [tag1.id, tag2.id]
        let transaction = try TransactionLifecycleService.save(
            draft: draft,
            accounts: [account],
            categories: [category],
            tags: [tag1, tag2],
            in: context
        )
        XCTAssertEqual(Set(transaction.tags.map(\.name)), ["报销", "工作"])

        try FinanceDataManagementService.rename(
            tag: tag1,
            to: "待报销",
            tags: [tag1, tag2],
            in: context
        )
        try FinanceDataManagementService.setTagActive(tag1, isActive: false, in: context)
        XCTAssertEqual(transaction.tags.first { $0.id == tag1.id }?.name, "待报销")
        XCTAssertNotNil(tag1.archivedAt)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FinanceTransaction>()).count, 1)
    }

    func testCategoryIconSuggestionsAndFallbackAreDeterministic() {
        XCTAssertEqual(
            CategoryIconLibrary.suggestedSymbol(for: "咖啡", kind: .expense),
            "cup.and.saucer"
        )
        XCTAssertEqual(CategoryIconLibrary.safeSymbol("not.a.real.choice"), "square.grid.2x2")
        XCTAssertTrue(CategoryIconLibrary.allSymbols.contains("banknote"))
    }

    func testCategoryTextIconParsingPreservesSystemIconCompatibility() {
        XCTAssertEqual(
            CategoryIconLibrary.descriptor(for: "fork.knife"),
            .systemSymbol("fork.knife")
        )
        XCTAssertEqual(
            CategoryIconLibrary.descriptor(for: "text:早餐"),
            .text("早餐")
        )
        XCTAssertEqual(CategoryIconLibrary.normalizedStoredValue("text:AI"), "text:AI")
        XCTAssertNil(CategoryIconLibrary.normalizedStoredValue("text:"))
        XCTAssertNil(CategoryIconLibrary.normalizedStoredValue("text:三个字"))
        XCTAssertEqual(CategoryIconLibrary.textIconValue(from: " 早餐 "), "text:早餐")
        XCTAssertGreaterThanOrEqual(CategoryIconLibrary.allSymbols.count, 75)
    }

    func testBuild15SystemIconCompatibilitySurfaceIsPreserved() {
        let build15Symbols: Set<String> = [
            "fork.knife", "cup.and.saucer", "takeoutbag.and.cup.and.straw", "birthday.cake",
            "sunrise", "apple.logo", "basket", "car", "bus", "tram", "bicycle", "airplane",
            "fuelpump", "parkingsign.circle", "road.lanes", "wrench.and.screwdriver", "bag", "cart",
            "tshirt", "gift", "desktopcomputer", "sofa", "comb", "house", "bed.double", "lightbulb",
            "washer", "bolt.house", "building.2", "wifi", "cross.case", "pills", "heart.text.clipboard",
            "heart", "gamecontroller", "film", "music.note", "sportscourt", "figure.run", "person.3",
            "paintpalette", "rectangle.stack.badge.play", "book", "graduationcap", "pencil.and.ruler",
            "person.2", "figure.2.and.child.holdinghands", "suitcase.rolling", "map", "envelope", "ticket",
            "banknote", "briefcase", "chart.line.uptrend.xyaxis", "plus.circle", "doc.text",
            "clock.arrow.circlepath", "percent", "chart.pie", "arrow.uturn.backward.circle", "square.grid.2x2",
            "ellipsis.circle", "star", "tag"
        ]

        XCTAssertEqual(build15Symbols.count, 64)
        XCTAssertTrue(build15Symbols.isSubset(of: CategoryIconLibrary.allSymbols))
        XCTAssertTrue(CategoryIconLibrary.allSymbols.contains("sofa"))
    }

    func testAutomaticTextIconFollowsCategoryNameUntilManualOverride() {
        let firstCharacter = CategoryIconLibrary.synchronizedTextIconValue(
            currentValue: "text:",
            followsCategoryName: true,
            categoryName: "早"
        )
        XCTAssertEqual(firstCharacter, "text:早")
        XCTAssertEqual(
            CategoryIconLibrary.synchronizedTextIconValue(
                currentValue: firstCharacter,
                followsCategoryName: true,
                categoryName: "早餐"
            ),
            "text:早餐"
        )
        XCTAssertEqual(
            CategoryIconLibrary.synchronizedTextIconValue(
                currentValue: "text:AI",
                followsCategoryName: false,
                categoryName: "早餐"
            ),
            "text:AI"
        )
    }

    @MainActor
    func testTagFilterAndTextSearchCombineWithOtherCriteria() throws {
        let tag = Tag(name: "旅行")
        let category = Category(
            kind: .expense,
            name: "交通",
            symbolName: "car",
            colorToken: "blue"
        )
        let account = Account(name: "卡", type: .bankCard)
        let date = date("2026-07-10 12:00")
        let included = transaction(
            amount: 100,
            date: date,
            account: account,
            category: category,
            note: "高铁",
            tags: [tag]
        )
        let excluded = transaction(
            amount: 200,
            date: date,
            account: account,
            category: category,
            note: "午餐"
        )
        let result = TransactionDiscoveryService.filter(
            [included, excluded],
            criteria: TransactionDiscoveryCriteria(
                month: date,
                categoryID: category.id,
                accountID: account.id,
                tagID: tag.id,
                searchText: "旅行"
            ),
            categoriesByID: [category.id: category],
            accountsByID: [account.id: account]
        )
        XCTAssertEqual(result.map(\.id), [included.id])
    }

    func testCSVParsesBOMChineseQuotesAndMultilineFields() throws {
        let csv = "\u{FEFF}类型,金额,日期时间,分类,账户,备注,标签\n支出,\"1,234.56\",2026-07-01 08:30,餐饮,现金,\"早餐,\"\"很好\"\"\n第二行\",工作|报销"
        let document = try FinanceCSVService.parseDocument(data: Data(csv.utf8))
        XCTAssertEqual(document.rows.count, 1)
        XCTAssertEqual(document.rows[0][5], "早餐,\"很好\"\n第二行")
        let plan = try FinanceCSVService.makePlan(
            document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "挖财账单.csv",
            existingTransactions: []
        )
        XCTAssertEqual(plan.source, .genericCSV)
        XCTAssertEqual(plan.rowsToImport.first?.amountMinorUnits, 123_456)
        XCTAssertEqual(plan.rowsToImport.first?.tagNames, ["工作", "报销"])
    }

    func testDuplicateUsesFullFingerprintNotOnlySameDayAndAmount() throws {
        let csv = """
        type,amount,date_time,category,account,note
        expense,10.00,2026-07-02 10:00,餐饮,现金,早餐
        expense,10.00,2026-07-02 10:00,餐饮,现金,早餐
        expense,10.00,2026-07-02 10:00,餐饮,现金,午餐
        """
        let document = try FinanceCSVService.parseDocument(data: Data(csv.utf8))
        let plan = try FinanceCSVService.makePlan(
            document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "generic.csv",
            existingTransactions: []
        )
        XCTAssertEqual(plan.candidates.count, 3)
        XCTAssertEqual(plan.duplicateCount, 0)
        XCTAssertEqual(plan.withinFileDuplicateCount, 1)
        let effectiveRows = plan.effectiveRowsToImport(includeSuspectedDuplicates: true)
        XCTAssertEqual(effectiveRows.count, 3)
        XCTAssertEqual(effectiveRows.filter { $0.note == "早餐" }.count, 2)
        XCTAssertEqual(effectiveRows.filter { $0.note == "午餐" }.count, 1)
    }

    func testGenericAndWacaiFixturesSupportPartialInvalidRowsAndDateFormats() throws {
        let generic = try fixture("generic")
        let genericDocument = try FinanceCSVService.parseDocument(data: generic)
        let genericPlan = try FinanceCSVService.makePlan(
            document: genericDocument,
            mapping: FinanceCSVService.autoMapping(headers: genericDocument.headers),
            fileName: "generic.csv",
            existingTransactions: []
        )
        XCTAssertEqual(genericPlan.rowsToImport.count, 2)
        XCTAssertEqual(genericPlan.invalidRows.count, 1)
        XCTAssertEqual(genericPlan.incomeMinorUnits, 10_000)
        XCTAssertEqual(genericPlan.expenseMinorUnits, 1_234)

        let wacai = try fixture("wacai")
        let wacaiDocument = try FinanceCSVService.parseDocument(data: wacai)
        let wacaiPlan = try FinanceCSVService.makePlan(
            document: wacaiDocument,
            mapping: FinanceCSVService.autoMapping(headers: wacaiDocument.headers),
            fileName: "挖财.csv",
            existingTransactions: []
        )
        XCTAssertEqual(wacaiPlan.source, .genericCSV)
        XCTAssertEqual(wacaiPlan.rowsToImport.count, 2)
    }

    func testEmptyAndUnsupportedCSVFailWithoutWriting() {
        XCTAssertThrowsError(try FinanceCSVService.parseDocument(data: Data())) {
            XCTAssertEqual($0 as? FinanceCSVError, .emptyFile)
        }
        XCTAssertThrowsError(try FinanceCSVService.parseDocument(data: Data([0xFF, 0xFE, 0x00])))
    }

    func testLargeCSVParsesDeterministically() throws {
        let header = "type,amount,date_time,category,account,note\n"
        let rows = (0..<2_000).map {
            "expense,1.01,2026-07-10 12:00,餐饮,现金,row-\($0)"
        }.joined(separator: "\n")
        let document = try FinanceCSVService.parseDocument(data: Data((header + rows).utf8))
        let plan = try FinanceCSVService.makePlan(
            document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "large.csv",
            existingTransactions: []
        )
        XCTAssertEqual(plan.rowsToImport.count, 2_000)
        XCTAssertEqual(plan.expenseMinorUnits, 202_000)
    }

    @MainActor
    func testExportImportRoundTripPreservesCoreSemanticsAndExcludesDeleted() throws {
        let source = try makeContainer()
        let sourceContext = source.mainContext
        let account = Account(name: "日常账户", type: .cash, isDefault: true)
        let category = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let tag = Tag(name: "工作")
        sourceContext.insert(account)
        sourceContext.insert(category)
        sourceContext.insert(tag)
        let first = transaction(
            amount: 1_234,
            date: date("2026-07-03 09:15"),
            account: account,
            category: category,
            note: "咖啡,\"双份\"\n自带杯",
            tags: [tag]
        )
        let deleted = transaction(
            amount: 999,
            date: date("2026-07-04 09:15"),
            account: account,
            category: category,
            note: "删除"
        )
        deleted.softDelete()
        sourceContext.insert(first)
        sourceContext.insert(deleted)
        try sourceContext.save()

        let data = FinanceCSVService.exportData(
            transactions: [first, deleted],
            categories: [category],
            accounts: [account]
        )
        XCTAssertTrue(data.starts(with: [0xEF, 0xBB, 0xBF]))
        let document = try FinanceCSVService.parseDocument(data: data)
        XCTAssertEqual(document.rows.count, 1)

        let target = try makeContainer()
        let targetContext = target.mainContext
        let targetAccount = Account(name: "日常账户", type: .cash, isDefault: true)
        let targetCategory = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        targetContext.insert(targetAccount)
        targetContext.insert(targetCategory)
        try targetContext.save()
        let plan = try FinanceCSVService.makePlan(
            document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "roundtrip.csv",
            existingTransactions: []
        )
        let result = try FinanceCSVService.commit(
            plan: plan,
            accounts: [targetAccount],
            categories: [targetCategory],
            tags: [],
            in: targetContext,
            createMissingTags: true
        )
        XCTAssertEqual(result.importedCount, 1)
        let imported = try XCTUnwrap(
            targetContext.fetch(FetchDescriptor<FinanceTransaction>()).first
        )
        XCTAssertEqual(imported.amountMinorUnits, first.amountMinorUnits)
        XCTAssertEqual(imported.type, first.type)
        XCTAssertEqual(imported.localDayKey, first.localDayKey)
        XCTAssertEqual(imported.note, first.note)
        XCTAssertEqual(imported.tags.map(\.name), ["工作"])
        XCTAssertEqual(imported.categoryID, targetCategory.id)
        XCTAssertEqual(imported.accountID, targetAccount.id)
    }

    func testCalendarCoversLeapYearOffsetsTotalsAndSoftDelete() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        let month = date("2024-02-10 12:00", calendar: calendar)
        let account = Account(name: "现金", type: .cash)
        let category = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let day = date("2024-02-29 23:30", calendar: calendar)
        let expense = transaction(
            amount: 800,
            date: day,
            account: account,
            category: category,
            note: ""
        )
        let deleted = transaction(
            amount: 900,
            date: day,
            account: account,
            category: category,
            note: ""
        )
        deleted.softDelete()
        let days = BillCalendarService.days(
            in: month,
            transactions: [expense, deleted],
            calendar: calendar
        )
        XCTAssertEqual(days.compactMap { $0 }.count, 29)
        let leapDay = days.compactMap { $0 }.last
        XCTAssertEqual(leapDay?.expenseMinorUnits, 800)
        XCTAssertEqual(leapDay?.expenseCount, 1)
    }

    func testCountsAveragesAndCategoryTrendExcludeDeletedAndIncome() {
        let account = Account(name: "现金", type: .cash)
        let food = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let july = date("2026-07-15 12:00")
        let expense1 = transaction(amount: 100, date: july, account: account, category: food, note: "")
        let expense2 = transaction(amount: 300, date: july, account: account, category: food, note: "")
        let income = transaction(
            amount: 1_000,
            date: july,
            account: account,
            category: food,
            note: "",
            type: .income
        )
        let deleted = transaction(amount: 999, date: july, account: account, category: food, note: "")
        deleted.softDelete()
        let all = [expense1, expense2, income, deleted]
        let activity = FinanceInsightsService.activity(for: all, month: july)
        XCTAssertEqual(activity.totalCount, 3)
        XCTAssertEqual(activity.expenseCount, 2)
        XCTAssertEqual(activity.incomeCount, 1)
        XCTAssertEqual(activity.averageExpenseMinorUnits, 200)
        let spending = FinanceInsightsService.categorySpending(for: all, month: july)
        XCTAssertEqual(spending.first?.transactionCount, 2)
        let trend = FinanceInsightsService.categoryTrend(
            for: all,
            categoryID: food.id,
            endingAt: july
        )
        XCTAssertEqual(trend.last?.amountMinorUnits, 400)
        XCTAssertEqual(trend.last?.transactionCount, 2)
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: AppSchema.schema, configurations: [configuration])
    }

    private func transaction(
        amount: Int64,
        date: Date,
        account: Account,
        category: PersonalFinanceOS.Category,
        note: String,
        type: TransactionType = .expense,
        tags: [Tag] = []
    ) -> FinanceTransaction {
        FinanceTransaction(
            type: type,
            amountMinorUnits: amount,
            occurredAt: date,
            localDayKey: LocalDayKey.make(for: date, timeZone: .current),
            timeZoneIdentifier: TimeZone.current.identifier,
            accountID: account.id,
            categoryID: category.id,
            note: note,
            tags: tags
        )
    }

    private func date(
        _ value: String,
        calendar: Calendar = .current
    ) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)!
    }

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Round1FeatureTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures")
                ?? bundle.url(forResource: name, withExtension: "csv")
        )
        return try Data(contentsOf: url)
    }
}
