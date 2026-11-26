import XCTest
@testable import PersonalFinanceOS

final class SmartTransactionSuggestionServiceTests: XCTestCase {
    private let diningID = UUID()
    private let shoppingID = UUID()
    private let transportID = UUID()
    private let housingID = UUID()

    private var dining: SuggestionCategory {
        SuggestionCategory(id: diningID, name: "餐饮", kind: .expense, isActive: true)
    }
    private var shopping: SuggestionCategory {
        SuggestionCategory(id: shoppingID, name: "购物", kind: .expense, isActive: true)
    }
    private var transport: SuggestionCategory {
        SuggestionCategory(id: transportID, name: "交通", kind: .expense, isActive: true)
    }
    private var housing: SuggestionCategory {
        SuggestionCategory(id: housingID, name: "居家", kind: .expense, isActive: true)
    }

    private var keywordCategories: [SuggestionCategory] {
        [
            dining,
            shopping,
            transport,
            housing,
            SuggestionCategory(id: UUID(), name: "水果", kind: .expense, isActive: true, parentID: diningID),
            SuggestionCategory(id: UUID(), name: "咖啡奶茶", kind: .expense, isActive: true, parentID: diningID),
            SuggestionCategory(id: UUID(), name: "婴幼儿养护", kind: .expense, isActive: true, parentID: shoppingID),
            SuggestionCategory(id: UUID(), name: "地铁", kind: .expense, isActive: true, parentID: transportID),
            SuggestionCategory(id: UUID(), name: "水电燃气", kind: .expense, isActive: true, parentID: housingID)
        ]
    }

    func testNormalizationPreservesMeaningAndRemovesCommonQuantityNoise() {
        XCTAssertEqual(SmartTransactionSuggestionService.normalize(" 火龙果 2个！！ "), "火龙果")
        XCTAssertEqual(SmartTransactionSuggestionService.normalize("买火龙果×2"), "火龙果")
        XCTAssertNotEqual(
            SmartTransactionSuggestionService.normalize("苹果手机"),
            SmartTransactionSuggestionService.normalize("苹果")
        )
    }

    func testTimePriorUsesOccurredAtAndHonorsWindowBoundaries() {
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let breakfast = timePriorCategory(key: "expense.dining.breakfast")
        let lunch = timePriorCategory(key: "expense.dining.lunch")
        let dinner = timePriorCategory(key: "expense.dining.dinner")
        let categories = [breakfast, lunch, dinner]
        let cases: [(Int, Int, UUID?)] = [
            (7, 0, breakfast.id), (9, 59, breakfast.id), (10, 0, nil),
            (11, 0, lunch.id), (14, 59, lunch.id), (15, 0, nil),
            (17, 0, dinner.id), (20, 59, dinner.id), (21, 0, nil),
            (22, 0, nil), (23, 59, nil), (0, 30, nil), (1, 0, nil)
        ]

        for (hour, minute, expectedID) in cases {
            XCTAssertEqual(
                QuickAddTimePriorService.categoryID(
                    occurredAt: date(hour: hour, minute: minute, timeZone: timeZone),
                    timeZone: timeZone,
                    categories: categories
                ),
                expectedID,
                "\(hour):\(minute)"
            )
        }
    }

    func testTimePriorRequiresAnActiveDefaultTarget() {
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let breakfast = timePriorCategory(key: "expense.dining.breakfast")
        let inactiveBreakfast = SuggestionCategory(
            id: breakfast.id,
            name: breakfast.name,
            kind: breakfast.kind,
            isActive: false,
            defaultDefinitionKey: breakfast.defaultDefinitionKey
        )
        let occurredAt = date(hour: 8, minute: 0, timeZone: timeZone)

        XCTAssertNil(QuickAddTimePriorService.categoryID(
            occurredAt: occurredAt,
            timeZone: timeZone,
            categories: []
        ))
        XCTAssertNil(QuickAddTimePriorService.categoryID(
            occurredAt: occurredAt,
            timeZone: timeZone,
            categories: [inactiveBreakfast]
        ))
    }

    func testRepresentativeKeywordRulesPreferExactChildCategory() {
        let categories = keywordCategories
        XCTAssertEqual(suggestion("火龙果", categories: categories).categoryID, child(named: "水果", in: categories).id)
        XCTAssertEqual(suggestion("小宝纸尿裤", categories: categories).categoryID, child(named: "婴幼儿养护", in: categories).id)
        XCTAssertEqual(suggestion("早高峰地铁", categories: categories).categoryID, child(named: "地铁", in: categories).id)
        XCTAssertEqual(suggestion("本月燃气费", categories: categories).categoryID, child(named: "水电燃气", in: categories).id)
        XCTAssertEqual(suggestion("一杯咖啡", categories: categories).confidence, .medium)
        XCTAssertNil(suggestion("苹果手机", categories: categories).categoryID)
        XCTAssertNil(suggestion("咖啡机", categories: categories).categoryID)

        let archivedDining = SuggestionCategory(
            id: dining.id,
            name: dining.name,
            kind: dining.kind,
            isActive: false
        )
        XCTAssertNil(suggestion("火龙果", categories: [archivedDining]).categoryID)
        XCTAssertNil(suggestion("火龙果", categories: [
            SuggestionCategory(id: UUID(), name: "餐饮优惠", kind: .expense, isActive: true)
        ]).categoryID)
        XCTAssertNil(suggestion("火龙果", categories: [
            SuggestionCategory(id: UUID(), name: "餐饮", kind: .income, isActive: true)
        ]).categoryID)
    }

    func testExistingTagNamesMatchWithoutCreatingOrDuplicating() {
        let child = SuggestionTag(id: UUID(), name: "小宝", isActive: true)
        let reimbursable = SuggestionTag(id: UUID(), name: "报销", isActive: true)
        let archived = SuggestionTag(id: UUID(), name: "停用", isActive: false)
        let short = SuggestionTag(id: UUID(), name: "宝", isActive: true)
        let result = suggestion(
            "小宝纸尿裤，记得报销，停用",
            categories: [shopping],
            tags: [child, reimbursable, archived, short]
        )
        XCTAssertEqual(result.tagIDs, [child.id, reimbursable.id])
        XCTAssertEqual(result.tagIDs.count, 2)
        XCTAssertFalse(result.tagIDs.contains(archived.id))
        XCTAssertFalse(result.tagIDs.contains(short.id))
    }

    func testHistoricalExactNormalizedSimilarMerchantFrequencyAndRecency() {
        let now = Date()
        let older = history(note: "买火龙果×2", category: shopping, updatedAt: now.addingTimeInterval(-20))
        let newer = history(note: "火龙果 2个", category: dining, updatedAt: now)
        let normalized = suggestion("火龙果", categories: [dining, shopping], history: [older, newer])
        XCTAssertEqual(normalized.categoryID, dining.id)
        XCTAssertEqual(normalized.confidence, .medium)

        let frequent = (0..<4).map { index in
            history(note: "午饭", category: dining, updatedAt: now.addingTimeInterval(Double(index)))
        }
        let outlier = history(note: "午饭", category: shopping, updatedAt: now.addingTimeInterval(100))
        let dominant = suggestion("午饭", categories: [dining, shopping], history: frequent + [outlier])
        XCTAssertEqual(dominant.categoryID, dining.id)
        XCTAssertEqual(dominant.confidence, .high)

        let similar = suggestion(
            "公司午饭加饮料",
            categories: [dining],
            history: [history(note: "公司午饭", category: dining)]
        )
        XCTAssertEqual(similar.categoryID, dining.id)
        XCTAssertEqual(similar.confidence, .medium)

        let merchant = suggestion(
            "周末消费",
            merchant: "星巴克",
            categories: [dining],
            history: [history(note: "拿铁", merchant: "星巴克", category: dining)]
        )
        XCTAssertEqual(merchant.categoryID, dining.id)
    }

    func testConflictingOrUnavailableHistoryIsConservative() {
        let now = Date()
        let conflict = suggestion(
            "固定备注",
            categories: [dining, shopping],
            history: [
                history(note: "固定备注", category: dining, updatedAt: now),
                history(note: "固定备注", category: shopping, updatedAt: now.addingTimeInterval(1))
            ]
        )
        XCTAssertEqual(conflict.categoryID, shopping.id)
        XCTAssertEqual(conflict.confidence, .medium)

        let archived = SuggestionCategory(id: dining.id, name: dining.name, kind: .expense, isActive: false)
        XCTAssertNil(suggestion(
            "旧记录",
            categories: [archived],
            history: [history(note: "旧记录", category: dining)]
        ).categoryID)
        XCTAssertNil(suggestion(
            "删除记录",
            categories: [dining],
            history: [history(note: "删除记录", category: dining, isDeleted: true)]
        ).categoryID)
    }

    func testHighMediumAndLowConfidenceBoundaries() {
        XCTAssertEqual(suggestion("火龙果", categories: keywordCategories).confidence, .high)
        XCTAssertEqual(suggestion(
            "普通午饭",
            categories: [dining],
            history: [history(note: "普通午饭", category: dining)]
        ).confidence, .high)
        XCTAssertEqual(suggestion("完全未知", categories: [dining]).confidence, .low)
        XCTAssertFalse(suggestion("完全未知", categories: [dining]).hasContent)
    }

    func testRequestTrackerRejectsStaleRapidInputResults() {
        var tracker = SmartSuggestionRequestTracker()
        let first = tracker.begin(note: "火龙", merchant: "", type: .expense)
        let second = tracker.begin(note: "火龙果", merchant: "果园", type: .expense)
        XCTAssertFalse(tracker.accepts(revision: first, note: "火龙", merchant: "", type: .expense))
        XCTAssertTrue(tracker.accepts(
            revision: second,
            note: "火龙果",
            merchant: "果园",
            type: .expense
        ))
    }

    @MainActor
    func testDebounceGateBuildsOnlyLatestSnapshot() async throws {
        var tracker = SmartSuggestionRequestTracker()
        let first = tracker.begin(note: "火龙", merchant: "", type: .expense)
        let second = tracker.begin(note: "火龙果", merchant: "", type: .expense)
        try await Task.sleep(for: .milliseconds(10))

        var snapshotBuildCount = 0
        if tracker.accepts(revision: first, note: "火龙", merchant: "", type: .expense) {
            snapshotBuildCount += 1
        }
        if tracker.accepts(revision: second, note: "火龙果", merchant: "", type: .expense) {
            snapshotBuildCount += 1
        }
        XCTAssertEqual(snapshotBuildCount, 1)
    }

    func testMerchantAloneCanLearnFromHistory() {
        let result = suggestion(
            "",
            merchant: "星巴克",
            categories: [dining],
            history: [history(note: "拿铁", merchant: "星巴克", category: dining)]
        )
        XCTAssertEqual(result.categoryID, dining.id)
    }

    func testHistoryCutoffExcludesOldLearningWithoutMutatingHistory() {
        let cutoff = Date()
        let old = history(
            note: "固定午饭",
            category: dining,
            updatedAt: cutoff.addingTimeInterval(-1)
        )
        let recent = history(
            note: "固定午饭",
            category: shopping,
            updatedAt: cutoff.addingTimeInterval(1)
        )
        let original = [old, recent]
        let result = SmartTransactionSuggestionService.suggest(
            note: "固定午饭",
            type: .expense,
            categories: [dining, shopping],
            tags: [],
            history: original,
            historyCutoff: cutoff
        )
        XCTAssertEqual(result.categoryID, shopping.id)
        XCTAssertEqual(original, [old, recent])
    }

    func testSessionProtectsManualCategoryAndRemovedAutomaticTags() {
        let firstTag = UUID()
        let secondTag = UUID()
        var session = SmartSuggestionSession(
            editingExisting: false,
            hasInitialCategory: false,
            initialTagIDs: []
        )
        XCTAssertTrue(session.canAutoFillCategory(currentCategoryID: nil))
        session.markManualCategorySelection()
        XCTAssertFalse(session.canAutoFillCategory(currentCategoryID: nil))

        _ = session.reconcileAutomaticTags(
            [firstTag, secondTag],
            currentTagIDs: []
        )
        session.markManualTagChange(id: firstTag, isSelected: false)
        XCTAssertEqual(session.eligibleAutomaticTags([firstTag, secondTag]), [secondTag])

        session.requestRefresh()
        XCTAssertFalse(session.allowsAutomaticRun)
        XCTAssertFalse(session.canAutoFillCategory(currentCategoryID: dining.id))
    }

    func testAutomaticCategoryCanChangeAndRestoresThePreAutomaticSelection() {
        let initialID = UUID()
        var session = SmartSuggestionSession(
            editingExisting: false,
            hasInitialCategory: false,
            initialTagIDs: []
        )

        XCTAssertEqual(
            session.applyAutomaticCategory(dining.id, currentCategoryID: initialID),
            dining.id
        )
        XCTAssertEqual(session.categoryBeforeAutomaticSuggestion, initialID)
        XCTAssertEqual(session.currentAutomaticCategoryID, dining.id)
        XCTAssertEqual(session.selectionState, .automatic)

        XCTAssertEqual(
            session.applyAutomaticCategory(shopping.id, currentCategoryID: dining.id),
            shopping.id
        )
        XCTAssertEqual(session.categoryBeforeAutomaticSuggestion, initialID)
        XCTAssertEqual(
            session.categoryAfterAutomaticSuggestionUnavailable(currentCategoryID: shopping.id),
            initialID
        )
        XCTAssertNil(session.currentAutomaticCategoryID)
        XCTAssertEqual(session.selectionState, .default)
    }

    func testLaterUncertainResultRevokesAutomaticDecisionWithoutChangingManualChoice() {
        let high = SmartTransactionSuggestion(
            categoryConfidence: .high, tagConfidence: .low,
            categoryID: diningID, tagIDs: [], explanation: "基础规则"
        )
        let conflictingPersonalResult = SmartTransactionSuggestion(
            categoryConfidence: .medium, tagConfidence: .low,
            categoryID: shoppingID, tagIDs: [], explanation: "个人证据冲突"
        )
        var session = SmartSuggestionSession(
            editingExisting: false, hasInitialCategory: false, initialTagIDs: []
        )
        XCTAssertEqual(session.categoryAfterSuggestion(high, currentCategoryID: nil), diningID)
        XCTAssertEqual(session.categoryDecisionSource, .automaticAccepted)
        XCTAssertNil(session.categoryAfterSuggestion(
            conflictingPersonalResult, currentCategoryID: diningID
        ))
        XCTAssertEqual(session.categoryDecisionSource, .unchanged)

        XCTAssertEqual(session.categoryAfterSuggestion(high, currentCategoryID: nil), diningID)
        XCTAssertNil(session.categoryAfterSuggestion(.none, currentCategoryID: diningID))
        XCTAssertEqual(session.categoryDecisionSource, .unchanged)

        let explicitChoice = SmartTransactionSuggestion(
            categoryConfidence: .high, tagConfidence: .low,
            categoryID: diningID, tagIDs: [], explanation: "需要确认",
            requiresUserChoice: true
        )
        XCTAssertNil(session.categoryAfterSuggestion(explicitChoice, currentCategoryID: nil))
        XCTAssertEqual(session.categoryDecisionSource, .unchanged)

        session.markManualCategorySelection(selectedCategoryID: shoppingID)
        XCTAssertEqual(session.categoryAfterSuggestion(high, currentCategoryID: shoppingID), shoppingID)
        XCTAssertEqual(session.categoryDecisionSource, .manualConfirmed)

        var editing = SmartSuggestionSession(
            editingExisting: true, hasInitialCategory: true, initialTagIDs: []
        )
        XCTAssertEqual(editing.categoryAfterSuggestion(high, currentCategoryID: shoppingID), shoppingID)
        XCTAssertEqual(editing.categoryDecisionSource, .unchanged)
    }

    func testTimePriorYieldsToAutomaticAndManualCategoriesAndRefreshesOnTimeChange() {
        let breakfastID = UUID()
        let lunchID = UUID()
        let fuelID = UUID()
        let manualID = UUID()
        var session = SmartSuggestionSession(
            editingExisting: false,
            hasInitialCategory: false,
            initialTagIDs: []
        )

        XCTAssertEqual(session.applyTimePriorCategory(breakfastID, currentCategoryID: nil), breakfastID)
        XCTAssertEqual(session.categoryDecisionSource, .timePrior)
        XCTAssertEqual(session.applyAutomaticCategory(fuelID, currentCategoryID: breakfastID), fuelID)
        XCTAssertEqual(session.categoryDecisionSource, .automaticAccepted)
        XCTAssertEqual(session.applyTimePriorCategory(lunchID, currentCategoryID: fuelID), fuelID)
        XCTAssertEqual(
            session.categoryAfterAutomaticSuggestionUnavailable(currentCategoryID: fuelID),
            lunchID
        )
        XCTAssertEqual(session.categoryDecisionSource, .timePrior)

        session.markManualCategorySelection()
        XCTAssertEqual(session.applyTimePriorCategory(breakfastID, currentCategoryID: manualID), manualID)
        XCTAssertNil(session.applyAutomaticCategory(fuelID, currentCategoryID: manualID))
        XCTAssertEqual(session.categoryDecisionSource, .manualConfirmed)
    }

    func testTimePriorHistoryDoesNotProduceSmartClassificationEvidence() {
        let result = suggestion(
            "固定商户",
            categories: [dining],
            history: [history(
                note: "固定商户",
                category: dining,
                decisionSource: .timePrior
            )]
        )

        XCTAssertNil(result.categoryID)
        XCTAssertEqual(result.evidenceType, nil)
    }

    func testManualCategoryPermanentlyLocksTheCurrentSession() {
        var session = SmartSuggestionSession(
            editingExisting: false,
            hasInitialCategory: false,
            initialTagIDs: []
        )
        session.markManualCategorySelection()

        XCTAssertTrue(session.manualOverride)
        XCTAssertFalse(session.allowsAutomaticRun)
        XCTAssertNil(session.applyAutomaticCategory(dining.id, currentCategoryID: shopping.id))

        session.requestRefresh(currentCategoryID: shopping.id)
        XCTAssertTrue(session.manualOverride)
        XCTAssertFalse(session.allowsAutomaticRun)
        XCTAssertNil(session.applyAutomaticCategory(dining.id, currentCategoryID: shopping.id))
        XCTAssertEqual(session.categoryDecisionSource, .manualConfirmed)
    }

    func testEditingSessionRequiresExplicitRefreshAndStillProtectsExistingValues() {
        var session = SmartSuggestionSession(
            editingExisting: true,
            hasInitialCategory: true,
            initialTagIDs: [UUID()]
        )
        XCTAssertFalse(session.allowsAutomaticRun)
        session.requestRefresh()
        XCTAssertTrue(session.allowsAutomaticRun)
        XCTAssertTrue(session.canAutoFillCategory(currentCategoryID: dining.id))

        let copiedDraftSession = SmartSuggestionSession(
            editingExisting: false,
            hasInitialCategory: true,
            initialTagIDs: [UUID()]
        )
        XCTAssertFalse(copiedDraftSession.allowsAutomaticRun)
    }

    func testAutomaticTagsReplaceClearAndPreserveUserControlledTags() {
        let initial = UUID()
        let firstAutomatic = UUID()
        let secondAutomatic = UUID()
        let manuallyAdded = UUID()
        var session = SmartSuggestionSession(
            editingExisting: false,
            hasInitialCategory: false,
            initialTagIDs: [initial]
        )
        session.requestRefresh()

        var tags = session.reconcileAutomaticTags(
            [firstAutomatic],
            currentTagIDs: [initial]
        )
        XCTAssertEqual(tags, [initial, firstAutomatic])
        XCTAssertEqual(session.initialUserTagIDs, [initial])
        XCTAssertEqual(session.currentAutomaticTagIDs, [firstAutomatic])

        tags.insert(manuallyAdded)
        session.markManualTagChange(id: manuallyAdded, isSelected: true)
        tags = session.reconcileAutomaticTags(
            [secondAutomatic],
            currentTagIDs: tags
        )
        XCTAssertEqual(tags, [initial, manuallyAdded, secondAutomatic])
        XCTAssertEqual(session.currentAutomaticTagIDs, [secondAutomatic])

        tags = session.clearAutomaticTags(currentTagIDs: tags)
        XCTAssertEqual(tags, [initial, manuallyAdded])
        XCTAssertTrue(session.currentAutomaticTagIDs.isEmpty)
    }

    func testManuallyRemovedAutomaticTagIsNotReapplied() {
        let automatic = UUID()
        var session = SmartSuggestionSession(
            editingExisting: false,
            hasInitialCategory: false,
            initialTagIDs: []
        )

        var tags = session.reconcileAutomaticTags([automatic], currentTagIDs: [])
        XCTAssertEqual(tags, [automatic])
        tags.remove(automatic)
        session.markManualTagChange(id: automatic, isSelected: false)
        tags = session.reconcileAutomaticTags([automatic], currentTagIDs: tags)
        XCTAssertTrue(tags.isEmpty)
        XCTAssertEqual(session.manuallyExcludedTagIDs, [automatic])
    }

    func testManuallyRemovedInitialTagIsExcludedUntilManuallyReselected() {
        let initial = UUID()
        var session = SmartSuggestionSession(
            editingExisting: true,
            hasInitialCategory: false,
            initialTagIDs: [initial]
        )

        var tags: Set<UUID> = [initial]
        tags.remove(initial)
        session.markManualTagChange(id: initial, isSelected: false)
        tags = session.reconcileAutomaticTags([initial], currentTagIDs: tags)
        XCTAssertTrue(tags.isEmpty)
        XCTAssertEqual(session.manuallyExcludedTagIDs, [initial])

        tags.insert(initial)
        session.markManualTagChange(id: initial, isSelected: true)
        tags = session.reconcileAutomaticTags([initial], currentTagIDs: tags)
        XCTAssertEqual(tags, [initial])
        XCTAssertTrue(session.manuallyExcludedTagIDs.isEmpty)
        XCTAssertTrue(session.currentAutomaticTagIDs.isEmpty)
    }

    func testManuallyRemovedUserAddedTagIsExcludedFromAutomaticSuggestion() {
        let manuallyAdded = UUID()
        var session = SmartSuggestionSession(
            editingExisting: false,
            hasInitialCategory: false,
            initialTagIDs: []
        )

        var tags: Set<UUID> = [manuallyAdded]
        session.markManualTagChange(id: manuallyAdded, isSelected: true)
        tags.remove(manuallyAdded)
        session.markManualTagChange(id: manuallyAdded, isSelected: false)
        tags = session.reconcileAutomaticTags([manuallyAdded], currentTagIDs: tags)

        XCTAssertTrue(tags.isEmpty)
        XCTAssertEqual(session.manuallyExcludedTagIDs, [manuallyAdded])
    }

    func testSuggestionEvaluationDoesNotMutateHistoricalFacts() {
        let original = [history(note: "火龙果", category: dining)]
        let snapshot = original
        _ = suggestion("火龙果", categories: [dining], history: original)
        XCTAssertEqual(original, snapshot)
    }

    func testHighConfidenceKeywordOutranksConflictingHistoricalCandidate() {
        let categories = keywordCategories
        let wrongHistory = history(
            note: "火龙果",
            category: shopping,
            updatedAt: Date(),
            decisionSource: .automaticAccepted
        )

        let result = suggestion(
            "火龙果",
            categories: categories,
            history: [wrongHistory]
        )

        XCTAssertEqual(result.categoryID, child(named: "水果", in: categories).id)
        XCTAssertEqual(result.categoryConfidence, .high)
    }

    func testCompleteDefaultTaxonomyCorpusAndContextConflicts() {
        let categories = completeLexiconCategories
        let cases: [(String, TransactionType, String, String)] = [
            ("豆浆油条", .expense, "餐饮", "早餐"),
            ("公司午饭", .expense, "餐饮", "午餐"),
            ("晚饭火锅", .expense, "餐饮", "晚餐"),
            ("美团外卖", .expense, "餐饮", "外卖零食"),
            ("买水果", .expense, "餐饮", "水果"),
            ("瑞幸", .expense, "餐饮", "咖啡奶茶"),
            ("超市买菜", .expense, "餐饮", "买菜食材"),
            ("公交卡", .expense, "交通", "公交"),
            ("地铁通勤", .expense, "交通", "地铁"),
            ("滴滴", .expense, "交通", "打车"),
            ("中石化加油", .expense, "交通", "加油"),
            ("停车费", .expense, "交通", "停车"),
            ("高速费", .expense, "交通", "高速过路"),
            ("换机油", .expense, "交通", "维修保养"),
            ("纸巾牙膏", .expense, "购物", "日用品"),
            ("买鞋", .expense, "购物", "服饰鞋包"),
            ("电脑配件", .expense, "购物", "数码"),
            ("床单", .expense, "购物", "家居"),
            ("纸尿裤", .expense, "购物", "婴幼儿养护"),
            ("防晒", .expense, "购物", "美妆护肤"),
            ("生日礼物", .expense, "购物", "礼物"),
            ("交房租", .expense, "居家", "房租房贷"),
            ("燃气费", .expense, "居家", "水电燃气"),
            ("物业费", .expense, "居家", "物业"),
            ("手机流量", .expense, "居家", "通讯网络"),
            ("修水管", .expense, "居家", "家政维修"),
            ("感冒药", .expense, "医疗教育", "医疗药品"),
            ("年度体检", .expense, "医疗教育", "体检"),
            ("维生素", .expense, "医疗教育", "保健"),
            ("英语课", .expense, "医疗教育", "学习课程"),
            ("买书", .expense, "医疗教育", "书籍文具"),
            ("电影票", .expense, "娱乐", "电影演出"),
            ("游戏充值", .expense, "娱乐", "游戏"),
            ("羽毛球", .expense, "娱乐", "运动"),
            ("朋友聚餐", .expense, "娱乐", "聚会"),
            ("摄影器材", .expense, "娱乐", "兴趣爱好"),
            ("视频会员", .expense, "娱乐", "会员订阅"),
            ("发红包", .expense, "人情", "红包"),
            ("婚礼礼金", .expense, "人情", "礼金"),
            ("给父母生活费", .expense, "人情", "孝敬长辈"),
            ("酒店", .expense, "旅行", "住宿"),
            ("景区门票", .expense, "旅行", "门票"),
            ("机票", .expense, "旅行", "旅行交通"),
            ("旅行吃饭", .expense, "旅行", "旅行餐饮"),
            ("旅行买纪念品", .expense, "旅行", "旅行购物"),
            ("工资到账", .income, "工作收入", "工资"),
            ("年终奖", .income, "工作收入", "奖金"),
            ("公司报销", .income, "工作收入", "报销"),
            ("兼职收入", .income, "工作收入", "兼职"),
            ("银行利息", .income, "理财收入", "利息"),
            ("基金分红", .income, "理财收入", "分红"),
            ("股票收益", .income, "理财收入", "投资收益"),
            ("退款到账", .income, "其他收入", "退款"),
            ("收到红包", .income, "其他收入", "红包"),
            ("收到礼金", .income, "其他收入", "礼金")
        ]

        for (note, type, root, child) in cases {
            let result = suggestion(note, type: type, categories: categories)
            XCTAssertEqual(
                result.categoryID,
                category(root: root, child: child, kind: type == .income ? .income : .expense, in: categories)?.id,
                "语料未覆盖：\(note)"
            )
            // These frozen V3 mixed categories cannot stand in for a missing V4
            // fine-grained target. Refund wording also needs explicit type review.
            let requiresReview: Set<String> = ["瑞幸", "超市买菜", "纸巾牙膏", "买鞋", "电脑配件", "床单", "纸尿裤",
                "交房租", "燃气费", "修水管", "视频会员", "年终奖", "退款到账"]
            XCTAssertEqual(result.categoryConfidence, requiresReview.contains(note) ? .medium : .high, "旧目录兼容语料：\(note)")
        }

        let train = suggestion("火车票", categories: categories)
        XCTAssertEqual(train.categoryConfidence, .medium)
        XCTAssertEqual(
            train.categoryID,
            category(root: "旅行", child: "旅行交通", kind: .expense, in: categories)?.id
        )
        XCTAssertEqual(
            suggestion("旅行吃饭", categories: categories).categoryID,
            category(root: "旅行", child: "旅行餐饮", kind: .expense, in: categories)?.id
        )
        XCTAssertNil(suggestion("其他消费", categories: categories).categoryID)
        XCTAssertNil(suggestion("普通支出", categories: categories).categoryID)
    }

    func testManualConfirmationOutranksAutomaticHistoryAndConflictsDowngrade() {
        let categories = completeLexiconCategories
        let fruit = category(root: "餐饮", child: "水果", kind: .expense, in: categories)!
        let digital = category(root: "购物", child: "数码", kind: .expense, in: categories)!
        let manualCorrection = history(
            note: "苹果",
            category: digital,
            decisionSource: .manualConfirmed
        )
        let automaticHistory = (0..<6).map { _ in
            history(
                note: "苹果",
                category: fruit,
                decisionSource: .automaticAccepted
            )
        }
        let corrected = suggestion(
            "苹果",
            categories: categories,
            history: automaticHistory + [manualCorrection]
        )
        XCTAssertEqual(corrected.categoryID, digital.id)
        XCTAssertEqual(corrected.evidenceType, .exactConfirmedNote)
        XCTAssertEqual(corrected.categoryConfidence, .high)

        let conflict = suggestion(
            "固定用途",
            categories: categories.filter { [fruit.id, digital.id, fruit.parentID, digital.parentID].contains($0.id) },
            history: [
                history(note: "固定用途", category: fruit, decisionSource: .manualConfirmed),
                history(note: "固定用途", category: digital, decisionSource: .manualConfirmed)
            ]
        )
        XCTAssertEqual(conflict.categoryConfidence, .medium)
        XCTAssertTrue(conflict.explanation.contains("冲突"))
    }

    func testMerchantNeedsRepeatedManualConfirmationAndInactiveLearningExpires() {
        let categories = completeLexiconCategories
        let coffee = category(root: "餐饮", child: "咖啡奶茶", kind: .expense, in: categories)!
        let one = history(
            note: "拿铁",
            merchant: "自定义咖啡馆",
            category: coffee,
            decisionSource: .manualConfirmed
        )
        XCTAssertEqual(
            suggestion("周末", merchant: "自定义咖啡馆", categories: categories, history: [one]).categoryConfidence,
            .medium
        )
        let two = history(
            note: "美式",
            merchant: "自定义咖啡馆",
            category: coffee,
            decisionSource: .manualConfirmed
        )
        XCTAssertEqual(
            suggestion("周末", merchant: "自定义咖啡馆", categories: categories, history: [one, two]).categoryConfidence,
            .high
        )

        let inactive = SuggestionCategory(
            id: coffee.id,
            name: coffee.name,
            kind: coffee.kind,
            isActive: false,
            parentID: coffee.parentID
        )
        XCTAssertNil(suggestion(
            "固定拿铁",
            categories: categories.filter { $0.id != coffee.id } + [inactive],
            history: [history(note: "固定拿铁", category: coffee, decisionSource: .manualConfirmed)]
        ).categoryID)
    }

    func testOtherCategoriesRequireExplicitManualHistory() {
        let root = SuggestionCategory(
            id: UUID(),
            name: "其他支出",
            kind: .expense,
            isActive: true
        )
        let other = SuggestionCategory(
            id: UUID(),
            name: "其他",
            kind: .expense,
            isActive: true,
            parentID: root.id
        )
        let automatic = history(
            note: "固定杂项",
            category: other,
            decisionSource: .automaticAccepted
        )
        XCTAssertNil(suggestion(
            "固定杂项",
            categories: [root, other],
            history: [automatic]
        ).categoryID)

        let manual = history(
            note: "固定杂项",
            category: other,
            decisionSource: .manualConfirmed
        )
        let learned = suggestion(
            "固定杂项",
            categories: [root, other],
            history: [manual]
        )
        XCTAssertEqual(learned.categoryID, other.id)
        XCTAssertEqual(learned.categoryConfidence, .high)
    }

    func testLargeHistoryScanRemainsBounded() {
        let history = (0..<10_000).map { index in
            self.history(note: "记录\(index)", category: dining)
        } + [history(note: "目标备注", category: dining)]
        measure {
            XCTAssertEqual(
                suggestion("目标备注", categories: [dining], history: history).categoryID,
                dining.id
            )
        }
    }

    private func suggestion(
        _ note: String,
        merchant: String = "",
        type: TransactionType = .expense,
        categories: [SuggestionCategory],
        tags: [SuggestionTag] = [],
        history: [SuggestionHistory] = []
    ) -> SmartTransactionSuggestion {
        SmartTransactionSuggestionService.suggest(
            note: note,
            merchant: merchant,
            type: type,
            categories: categories,
            tags: tags,
            history: history
        )
    }

    private var completeLexiconCategories: [SuggestionCategory] {
        var categories: [SuggestionCategory] = []
        var rootIDs: [String: UUID] = [:]
        var childPaths: Set<String> = []
        for rule in SmartClassificationLexicon.rules {
            let rootKey = "\(rule.kind.rawValue)|\(rule.rootName)"
            let rootID = rootIDs[rootKey] ?? {
                let id = UUID()
                rootIDs[rootKey] = id
                categories.append(SuggestionCategory(
                    id: id,
                    name: rule.rootName,
                    kind: rule.kind,
                    isActive: true
                ))
                return id
            }()
            let childKey = "\(rootKey)|\(rule.childName)"
            if childPaths.insert(childKey).inserted {
                categories.append(SuggestionCategory(
                    id: UUID(),
                    name: rule.childName,
                    kind: rule.kind,
                    isActive: true,
                    parentID: rootID
                ))
            }
        }
        return categories
    }

    private func category(
        root rootName: String,
        child childName: String,
        kind: CategoryKind,
        in categories: [SuggestionCategory]
    ) -> SuggestionCategory? {
        let rootsByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        return categories.first { category in
            guard category.kind == kind,
                  category.name == childName,
                  let parentID = category.parentID,
                  let root = rootsByID[parentID] else {
                return false
            }
            return root.name == rootName
        }
    }

    private func child(named name: String, in categories: [SuggestionCategory]) -> SuggestionCategory {
        categories.first { $0.name == name && $0.parentID != nil }!
    }

    private func history(
        note: String,
        merchant: String = "",
        category: SuggestionCategory,
        updatedAt: Date = Date(),
        isDeleted: Bool = false,
        decisionSource: CategoryDecisionSource = .manualConfirmed
    ) -> SuggestionHistory {
        SuggestionHistory(
            id: UUID(),
            type: .expense,
            note: note,
            merchant: merchant,
            categoryID: category.id,
            tagIDs: [],
            updatedAt: updatedAt,
            isDeleted: isDeleted,
            decisionSource: decisionSource
        )
    }

    private func timePriorCategory(key: String) -> SuggestionCategory {
        SuggestionCategory(
            id: UUID(),
            name: key.components(separatedBy: ".").last ?? key,
            kind: .expense,
            isActive: true,
            defaultDefinitionKey: key
        )
    }

    private func date(hour: Int, minute: Int, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: 2026,
            month: 8,
            day: 9,
            hour: hour,
            minute: minute
        ))!
    }
}
