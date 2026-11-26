import SwiftData
import XCTest
@testable import PersonalFinanceOS

final class SmartClassificationV2Tests: XCTestCase {
    private let diningRootID = UUID()
    private let diningID = UUID()
    private let shoppingRootID = UUID()
    private let digitalID = UUID()

    func testExplicitCorrectionMakesExactNotePersonalHighAndOverridesLexicon() {
        let event = learningEvent(
            note: "苹果",
            categoryID: digitalID,
            rejectedCategoryID: diningID,
            source: .explicitCorrection
        )
        let result = suggestion(
            "苹果",
            profile: buildVerifiedProfile(history: [], events: [event])
        )

        XCTAssertEqual(result.categoryID, digitalID)
        XCTAssertEqual(result.categoryConfidence, .high)
        XCTAssertEqual(result.evidenceType, .personalMemory)
    }

    func testMerchantPhraseNeedsRepeatedStrongEvidenceAndMerchantNeedsPurity() {
        let first = learningEvent(
            note: "周末固定单",
            merchant: "自定义咖啡馆",
            categoryID: diningID,
            source: .manualChoice
        )
        let second = learningEvent(
            transactionID: UUID(),
            note: "周末固定单",
            merchant: "自定义咖啡馆",
            categoryID: diningID,
            source: .manualChoice
        )
        XCTAssertEqual(
            suggestion("周末固定单", merchant: "自定义咖啡馆", profile: .init(
                statistics: buildVerifiedProfile(history: [], events: [first]).statistics,
                sampleCount: 1
            )).categoryConfidence,
            .medium
        )
        XCTAssertEqual(
            suggestion(
                "周末固定单",
                merchant: "自定义咖啡馆",
                profile: buildVerifiedProfile(history: [], events: [first, second])
            ).categoryConfidence,
            .high
        )

        let mixed = [
            learningEvent(note: "A", merchant: "京东", categoryID: diningID, source: .manualChoice),
            learningEvent(transactionID: UUID(), note: "B", merchant: "京东", categoryID: digitalID, source: .manualChoice),
            learningEvent(transactionID: UUID(), note: "C", merchant: "京东", categoryID: diningID, source: .manualChoice)
        ]
        XCTAssertNil(suggestion("", merchant: "京东", profile: buildVerifiedProfile(
            history: [], events: mixed
        )).categoryID)

        let pure = (0..<3).map { _ in
            learningEvent(
                transactionID: UUID(),
                note: UUID().uuidString,
                merchant: "单一用途商户",
                categoryID: diningID,
                source: .manualChoice
            )
        }
        XCTAssertEqual(
            suggestion(
                "",
                merchant: "单一用途商户",
                profile: buildVerifiedProfile(history: [], events: pure)
            ).categoryConfidence,
            .high
        )
    }

    func testCJKSimilarityRequiresMultipleConsistentSamples() {
        let notes = ["公司午餐食堂", "公司午餐外卖", "公司午餐套餐"]
        let events = notes.map {
            learningEvent(transactionID: UUID(), note: $0, categoryID: diningID, source: .manualChoice)
        }
        let result = suggestion(
            "公司午餐聚会",
            profile: buildVerifiedProfile(history: [], events: events)
        )
        XCTAssertEqual(result.categoryID, diningID)
        XCTAssertEqual(result.categoryConfidence, .high)
    }

    func testIneligibleNoisyCJKFragmentsCannotInflateOneEligibleCandidateToHigh() {
        let eligible = profileStatistics(rawSupport: 3, strongSupport: 2, positiveWeight: 10)
        let noisy = profileStatistics(rawSupport: 1, strongSupport: 0, positiveWeight: 0.3)
        let profile = ClassificationProfile(
            statistics: [
                profileKey(.cjkBigram, "甲乙"): [diningID: eligible],
                profileKey(.cjkBigram, "乙丙"): [diningID: noisy],
                profileKey(.cjkBigram, "丙丁"): [diningID: noisy],
                profileKey(.cjkTrigram, "甲乙丙"): [diningID: noisy],
                profileKey(.cjkTrigram, "乙丙丁"): [diningID: noisy]
            ],
            sampleCount: 7
        )

        let result = suggestion("甲乙丙丁", profile: profile)

        XCTAssertEqual(result.categoryID, diningID)
        XCTAssertEqual(result.score, 78)
        XCTAssertEqual(result.categoryConfidence, .medium)
    }

    func testPersonalConflictRevokesEarlierHighBaseDecision() {
        let breakfastID = UUID()
        let lunchID = UUID()
        let categories = [
            SuggestionCategory(id: diningRootID, name: "餐饮饮品", kind: .expense, isActive: true,
                               defaultDefinitionKey: "expense.dining"),
            SuggestionCategory(id: breakfastID, name: "早餐", kind: .expense, isActive: true,
                               parentID: diningRootID, defaultDefinitionKey: "expense.dining.breakfast"),
            SuggestionCategory(id: lunchID, name: "午餐", kind: .expense, isActive: true,
                               parentID: diningRootID, defaultDefinitionKey: "expense.dining.lunch")
        ]
        let base = suggestion("早餐", categories: categories, profile: .empty)
        XCTAssertEqual(base.categoryID, breakfastID)
        XCTAssertEqual(base.categoryConfidence, .high)

        let profile = ClassificationProfile(
            statistics: [profileKey(.phrase, "早餐"): [
                lunchID: profileStatistics(rawSupport: 2, strongSupport: 2, positiveWeight: 10)
            ]],
            sampleCount: 2
        )
        let complete = suggestion("早餐", categories: categories, profile: profile)
        XCTAssertEqual(complete.categoryConfidence, .medium)
        XCTAssertEqual(complete.categoryID, lunchID)

        var session = SmartSuggestionSession(
            editingExisting: false, hasInitialCategory: false, initialTagIDs: []
        )
        XCTAssertEqual(session.categoryAfterSuggestion(base, currentCategoryID: nil), breakfastID)
        XCTAssertEqual(session.categoryDecisionSource, .automaticAccepted)
        XCTAssertNil(session.categoryAfterSuggestion(complete, currentCategoryID: breakfastID))
        XCTAssertEqual(session.categoryDecisionSource, .unchanged)
    }

    func testRecentHabitSupersedesOlderBehavior() {
        let now = Date()
        let old = (0..<10).map { _ in
            learningEvent(
                transactionID: UUID(),
                recordedAt: now.addingTimeInterval(-600 * 86_400),
                note: "固定用途",
                categoryID: diningID,
                source: .manualChoice
            )
        }
        let recent = (0..<2).map { _ in
            learningEvent(
                transactionID: UUID(),
                recordedAt: now,
                note: "固定用途",
                categoryID: digitalID,
                source: .manualChoice
            )
        }
        let profile = buildVerifiedProfile(history: [], events: old + recent, now: now)
        XCTAssertEqual(suggestion("固定用途", profile: profile).categoryID, digitalID)
    }

    func testCategoryIdentityRenameHiddenAndDeletedSemantics() {
        let profile = buildVerifiedProfile(
            history: [],
            events: [learningEvent(note: "个人习惯", categoryID: digitalID, source: .explicitCorrection)]
        )
        var renamed = categories
        let index = renamed.firstIndex { $0.id == digitalID }!
        renamed[index] = SuggestionCategory(
            id: digitalID,
            name: "数码产品",
            kind: .expense,
            isActive: true,
            parentID: shoppingRootID
        )
        XCTAssertEqual(suggestion("个人习惯", categories: renamed, profile: profile).categoryID, digitalID)

        let inactive = renamed.map { category in
            category.id == digitalID
                ? SuggestionCategory(id: category.id, name: category.name, kind: category.kind, isActive: false, parentID: category.parentID)
                : category
        }
        XCTAssertNil(suggestion("个人习惯", categories: inactive, profile: profile).categoryID)
        XCTAssertNil(suggestion(
            "个人习惯",
            categories: renamed.filter { $0.id != digitalID },
            profile: profile
        ).categoryID)
    }

    func testAutomaticAcceptedSingleSampleDoesNotCreatePersonalHigh() {
        let event = learningEvent(note: "新的习惯", categoryID: diningID, source: .automaticAccepted)
        let result = suggestion(
            "新的习惯",
            profile: buildVerifiedProfile(history: [], events: [event])
        )
        XCTAssertNotEqual(result.categoryConfidence, .high)
    }

    func testImportedBootstrapRemainsWeakAndFoundationSettingDefaultsOn() {
        let now = Date()
        let imported = (0..<3).map { _ in
            SuggestionHistory(
                id: UUID(),
                type: .expense,
                note: "导入的固定备注",
                merchant: "",
                categoryID: diningID,
                tagIDs: [],
                occurredAt: now,
                updatedAt: now,
                isDeleted: false,
                isImported: true,
                decisionSource: .unchanged
            )
        }
        let result = suggestion(
            "导入的固定备注",
            profile: buildVerifiedProfile(history: imported, events: [], now: now)
        )
        XCTAssertNotEqual(result.categoryConfidence, .high)
        XCTAssertTrue(SmartSuggestionPreferences.defaultEnabled)
    }

    func testLearningEventReusesLedgerTagsWithoutDoubleCountingCategoryEvidence() {
        let transactionID = UUID()
        let ledgerTagID = UUID()
        let now = Date()
        let history = SuggestionHistory(
            id: transactionID,
            type: .expense,
            note: "公司采购",
            merchant: "",
            categoryID: digitalID,
            tagIDs: [ledgerTagID],
            occurredAt: now,
            updatedAt: now,
            isDeleted: false,
            decisionSource: .manualConfirmed
        )
        let correction = learningEvent(
            transactionID: transactionID,
            recordedAt: now,
            note: "公司采购",
            categoryID: digitalID,
            rejectedCategoryID: diningID,
            source: .explicitCorrection
        )

        let profile = buildVerifiedProfile(
            history: [history],
            events: [correction],
            now: now
        )
        let result = suggestion(
            "公司采购",
            tags: [SuggestionTag(id: ledgerTagID, name: "项目", isActive: true)],
            profile: profile
        )

        XCTAssertEqual(profile.sampleCount, 1, "Category evidence must not be counted twice.")
        XCTAssertEqual(result.categoryID, digitalID)
        XCTAssertEqual(result.tagIDs, [ledgerTagID])
    }

    func testSpecificCorrectionDoesNotPoisonStableGenericMerchantPrior() {
        let merchant = "星巴克"
        let stableCoffee = (0..<12).map { index in
            learningEvent(
                transactionID: UUID(),
                note: "日常咖啡\(index)",
                merchant: merchant,
                categoryID: diningID,
                source: .manualChoice
            )
        }
        let reimbursement = learningEvent(
            transactionID: UUID(),
            note: "公司报销",
            merchant: merchant,
            categoryID: digitalID,
            rejectedCategoryID: diningID,
            source: .explicitCorrection
        )
        let profile = buildVerifiedProfile(
            history: [],
            events: stableCoffee + [reimbursement]
        )

        let generic = suggestion("", merchant: merchant, profile: profile)
        XCTAssertEqual(generic.categoryID, diningID)
        XCTAssertEqual(generic.categoryConfidence, .high)

        let specific = suggestion("公司报销", merchant: merchant, profile: profile)
        XCTAssertEqual(specific.categoryID, digitalID)
        XCTAssertEqual(specific.categoryConfidence, .high)
    }

    func testProfileStorePreservesCorruptionAndFutureVersionUntilExplicitReset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("classification-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("profile.json")
        let broken = Data("not-json".utf8)
        try broken.write(to: url)
        let store = ClassificationProfileStore(fileURL: url)
        do { _ = try await store.events(); XCTFail("Unreadable history must not be silently reset") }
        catch { XCTAssertEqual(try Data(contentsOf: url), broken) }
        let event = learningEvent(note: "恢复后", categoryID: diningID, source: .manualChoice)
        do { try await store.record(event, generation: store.generation); XCTFail("Must preserve the unreadable document") }
        catch { XCTAssertEqual(try Data(contentsOf: url), broken) }
        try await store.reset()
        try await store.record(event, generation: store.generation)
        let persisted = try await store.events()
        XCTAssertEqual(persisted, [event])
        let incompatible = try JSONEncoder().encode(ClassificationMemoryDocument(version: 999, events: [event]))
        try incompatible.write(to: url, options: .atomic)
        let reloaded = ClassificationProfileStore(fileURL: url)
        do { _ = try await reloaded.events(); XCTFail("Future documents must be retained") }
        catch { XCTAssertEqual(try Data(contentsOf: url), incompatible) }
    }

    func testLearningSidecarAndFoundationRequestInputsAreBounded() {
        let longText = String(repeating: "明", count: 200)
        let event = learningEvent(
            note: longText,
            merchant: longText,
            categoryID: diningID,
            source: .manualChoice
        )
        XCTAssertEqual(event.normalizedNote.count, 96)
        XCTAssertEqual(event.normalizedMerchant.count, 96)

        let request = FoundationClassificationRequest(
            note: longText,
            merchant: longText,
            type: .expense,
            candidates: (0..<60).map {
                FoundationCategoryCandidate(key: "c\($0)", categoryID: UUID(), displayPath: longText)
            },
            memoryEvidence: Array(repeating: longText, count: 5)
        )
        XCTAssertEqual(request.note.count, 160)
        XCTAssertEqual(request.merchant.count, 80)
        XCTAssertEqual(request.candidates.count, 48)
        XCTAssertTrue(request.candidates.allSatisfy { $0.displayPath.count == 80 })
        XCTAssertEqual(request.memoryEvidence.count, 3)
        XCTAssertTrue(request.memoryEvidence.allSatisfy { $0.count == 120 })
    }

    @MainActor
    func testRollingBootstrapUsesOccurredAtAndExcludesOlderThanNinetyDays() async throws {
        let configuration = ModelConfiguration(
            "ClassificationHistoryTests",
            schema: AppSchema.schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppSchema.schema, configurations: [configuration])
        let context = ModelContext(container)
        let now = Date()
        let recent = transaction(note: "recent", occurredAt: now.addingTimeInterval(-89 * 86_400), updatedAt: .distantPast)
        let old = transaction(note: "old", occurredAt: now.addingTimeInterval(-91 * 86_400), updatedAt: now)
        context.insert(recent)
        context.insert(old)
        try context.save()

        let result = try await ClassificationHistoryActor(modelContainer: container)
            .fetchRollingHistory(cutoff: now.addingTimeInterval(-90 * 86_400))
        XCTAssertEqual(result.history.map(\.id), [recent.id])
        XCTAssertEqual(result.maximumBatchCount, 1)
    }

    func testProfileBuildAndLookupScaleAcrossTwelveAndFiftyThousandSamples() {
        for count in [12_000, 50_000] {
            let history = (0..<count).map { index in
                SuggestionHistory(
                    id: UUID(),
                    type: .expense,
                    note: index.isMultiple(of: 2) ? "公司午餐" : "日常午餐",
                    merchant: "",
                    categoryID: diningID,
                    tagIDs: [],
                    occurredAt: Date(),
                    updatedAt: Date(),
                    isDeleted: false,
                    decisionSource: .manualConfirmed
                )
            }
            let buildStart = ContinuousClock.now
            let profile = buildVerifiedProfile(history: history, events: [])
            let buildDuration = buildStart.duration(to: .now)
            let lookupStart = ContinuousClock.now
            let result = suggestion("公司午餐", profile: profile)
            let lookupDuration = lookupStart.duration(to: .now)
            print(
                "BUILD20_PROFILE_BENCH count=\(count) " +
                "build_ms=\(milliseconds(buildDuration)) " +
                "lookup_ms=\(milliseconds(lookupDuration))"
            )
            XCTAssertEqual(profile.sampleCount, count)
            XCTAssertEqual(result.categoryID, diningID)
        }
    }

    func testFoundationCoordinatorGatesAndStrictlyValidatesResponses() async {
        let high = SmartTransactionSuggestion(
            categoryConfidence: .high,
            tagConfidence: .low,
            categoryID: diningID,
            tagIDs: [],
            score: 100,
            explanation: "rule"
        )
        let highProvider = FakeFoundationProvider(response: .clearChoice(categoryKey: "c0"))
        _ = await coordinator(highProvider).resolve(
            deterministic: high,
            note: "自然语言备注",
            merchant: "",
            type: .expense,
            categories: categories,
            settingEnabled: true,
            manualLocked: false
        )
        let highInvocations = await highProvider.invocations()
        XCTAssertEqual(highInvocations, 0)

        for input in ["", "123", "!!!", "付款"] {
            let provider = FakeFoundationProvider(response: .clearChoice(categoryKey: "c0"))
            _ = await coordinator(provider).resolve(
                deterministic: .none,
                note: input,
                merchant: "",
                type: .expense,
                categories: categories,
                settingEnabled: true,
                manualLocked: false
            )
            let invocations = await provider.invocations()
            XCTAssertEqual(invocations, 0, input)
        }

        let off = FakeFoundationProvider(response: .clearChoice(categoryKey: "c0"))
        _ = await coordinator(off).resolve(
            deterministic: .none, note: "自然语言备注", merchant: "", type: .expense,
            categories: categories, settingEnabled: false, manualLocked: false
        )
        let offInvocations = await off.invocations()
        XCTAssertEqual(offInvocations, 0)

        let unavailable = FakeFoundationProvider(
            availability: .modelNotReady,
            response: .clearChoice(categoryKey: "c0")
        )
        _ = await coordinator(unavailable).resolve(
            deterministic: .none, note: "自然语言备注", merchant: "", type: .expense,
            categories: categories, settingEnabled: true, manualLocked: false
        )
        let unavailableInvocations = await unavailable.invocations()
        XCTAssertEqual(unavailableInvocations, 0)

        let clear = FakeFoundationProvider(response: .clearChoice(categoryKey: "c0"))
        let applied = await coordinator(clear).resolve(
            deterministic: .none, note: "自然语言备注", merchant: "", type: .expense,
            categories: categories, settingEnabled: true, manualLocked: false
        )
        let sentCandidates = await clear.lastCandidates()
        XCTAssertEqual(applied.categoryID, sentCandidates.first { $0.key == "c0" }?.categoryID)
        XCTAssertEqual(Set(sentCandidates.map(\.categoryID)), Set([diningID, digitalID]))
        XCTAssertEqual(applied.evidenceType, .foundationModel)

        for response in [
            FoundationClassificationResponse.ambiguous,
            .insufficientContext,
            .clearChoice(categoryKey: "unknown")
        ] {
            let provider = FakeFoundationProvider(response: response)
            let result = await coordinator(provider).resolve(
                deterministic: .none, note: "自然语言备注", merchant: "", type: .expense,
                categories: categories, settingEnabled: true, manualLocked: false
            )
            XCTAssertNil(result.categoryID)
        }


        let manyCategories = (0..<49).map { index in
            SuggestionCategory(
                id: UUID(),
                name: "分类\(index)",
                kind: .expense,
                isActive: true
            )
        }
        let outsideBound = FakeFoundationProvider(response: .clearChoice(categoryKey: "c48"))
        let boundedResult = await coordinator(outsideBound).resolve(
            deterministic: .none,
            note: "自然语言备注",
            merchant: "",
            type: .expense,
            categories: manyCategories,
            settingEnabled: true,
            manualLocked: false
        )
        XCTAssertNil(boundedResult.categoryID)
    }

    func testManualLockAndSaveInvalidationRejectPendingResponse() async {
        let provider = FakeFoundationProvider(
            response: .clearChoice(categoryKey: "c0"),
            delay: .milliseconds(50)
        )
        var tracker = SmartSuggestionRequestTracker()
        let revision = tracker.begin(note: "old", merchant: "", type: .expense)
        let pendingCoordinator = SmartClassificationCoordinator(provider: provider)
        let pendingCategories = categories
        let task = Task {
            await pendingCoordinator.resolve(
                deterministic: .none, note: "old", merchant: "", type: .expense,
                categories: pendingCategories, settingEnabled: true, manualLocked: false
            )
        }
        tracker.invalidate()
        _ = await task.value
        XCTAssertFalse(tracker.accepts(revision: revision, note: "old", merchant: "", type: .expense))

        let locked = FakeFoundationProvider(response: .clearChoice(categoryKey: "c0"))
        _ = await coordinator(locked).resolve(
            deterministic: .none, note: "新备注", merchant: "", type: .expense,
            categories: categories, settingEnabled: true, manualLocked: true
        )
        let lockedInvocations = await locked.invocations()
        XCTAssertEqual(lockedInvocations, 0)
    }

    func testManualSessionTransitionPermanentlyStopsLaterProviderPipeline() async {
        var session = SmartSuggestionSession(
            editingExisting: false,
            hasInitialCategory: false,
            initialTagIDs: []
        )
        var tracker = SmartSuggestionRequestTracker()
        let pendingRevision = tracker.begin(note: "公司午餐", merchant: "", type: .expense)
        XCTAssertEqual(
            session.applyAutomaticCategory(diningID, currentCategoryID: nil),
            diningID
        )

        session.markManualCategorySelection(selectedCategoryID: digitalID)
        tracker.invalidate()
        session.requestRefresh(currentCategoryID: digitalID)

        XCTAssertTrue(session.manualOverride)
        XCTAssertEqual(session.selectionState, .manual)
        XCTAssertFalse(session.allowsAutomaticRun)
        XCTAssertFalse(tracker.accepts(
            revision: pendingRevision,
            note: "公司午餐",
            merchant: "",
            type: .expense
        ))

        let provider = FakeFoundationProvider(response: .clearChoice(categoryKey: "c0"))
        if session.allowsAutomaticRun {
            _ = await coordinator(provider).resolve(
                deterministic: .none,
                note: "新的公司餐备注",
                merchant: "新商户",
                type: .expense,
                categories: categories,
                settingEnabled: true,
                manualLocked: !session.allowsAutomaticRun
            )
        }
        let invocationCount = await provider.invocations()
        XCTAssertEqual(invocationCount, 0)
    }

    private func buildVerifiedProfile(
        history: [SuggestionHistory], events: [ClassificationLearningEvent], now: Date = Date()
    ) -> ClassificationProfile {
        let lookups = Dictionary(uniqueKeysWithValues: events.map { event in
            (event.transactionID, ClassificationEventLookup.present(SuggestionHistory(
                id: event.transactionID, type: event.type, note: event.normalizedNote,
                merchant: event.normalizedMerchant, categoryID: event.categoryID,
                tagIDs: history.first { $0.id == event.transactionID }?.tagIDs ?? [],
                occurredAt: event.recordedAt, updatedAt: event.recordedAt, isDeleted: false,
                decisionSource: .manualConfirmed
            )))
        })
        return ClassificationProfileBuilder.build(history: history, events: events, eventLookups: lookups, now: now)
    }

    private func coordinator(_ provider: FakeFoundationProvider) -> SmartClassificationCoordinator {
        SmartClassificationCoordinator(provider: provider)
    }

    private var categories: [SuggestionCategory] {
        [
            SuggestionCategory(id: diningRootID, name: "餐饮", kind: .expense, isActive: true),
            SuggestionCategory(id: diningID, name: "水果", kind: .expense, isActive: true, parentID: diningRootID),
            SuggestionCategory(id: shoppingRootID, name: "购物", kind: .expense, isActive: true),
            SuggestionCategory(id: digitalID, name: "数码", kind: .expense, isActive: true, parentID: shoppingRootID)
        ]
    }

    private func suggestion(
        _ note: String,
        merchant: String = "",
        categories: [SuggestionCategory]? = nil,
        tags: [SuggestionTag] = [],
        profile: ClassificationProfile
    ) -> SmartTransactionSuggestion {
        SmartTransactionSuggestionService.suggest(
            note: note,
            merchant: merchant,
            type: .expense,
            categories: categories ?? self.categories,
            tags: tags,
            profile: profile
        )
    }

    private func profileKey(
        _ kind: ClassificationFeatureKind,
        _ value: String
    ) -> ClassificationProfile.Key {
        ClassificationProfile.Key(
            type: .expense,
            feature: ClassificationFeature(kind: kind, value: value)
        )
    }

    private func profileStatistics(
        rawSupport: Int,
        strongSupport: Int,
        positiveWeight: Double
    ) -> ClassificationProfile.Statistics {
        var statistics = ClassificationProfile.Statistics()
        statistics.rawSupport = rawSupport
        statistics.strongSupport = strongSupport
        statistics.positiveWeight = positiveWeight
        statistics.latestAt = Date()
        statistics.strongestSource = .manualChoice
        return statistics
    }

    private func learningEvent(
        transactionID: UUID = UUID(),
        recordedAt: Date = Date(),
        note: String,
        merchant: String = "",
        categoryID: UUID,
        rejectedCategoryID: UUID? = nil,
        source: ClassificationLearningSource
    ) -> ClassificationLearningEvent {
        ClassificationLearningEvent(
            transactionID: transactionID,
            recordedAt: recordedAt,
            type: .expense,
            note: note,
            merchant: merchant,
            categoryID: categoryID,
            rejectedCategoryID: rejectedCategoryID,
            source: source
        )
    }

    private func transaction(note: String, occurredAt: Date, updatedAt: Date) -> FinanceTransaction {
        FinanceTransaction(
            type: .expense,
            amountMinorUnits: 100,
            occurredAt: occurredAt,
            localDayKey: "2026-01-01",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: UUID(),
            categoryID: diningID,
            note: note,
            updatedAt: updatedAt
        )
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 +
            Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private actor FakeFoundationProvider: FoundationClassificationProviding {
    private let modelAvailability: FoundationClassificationAvailability
    private let response: FoundationClassificationResponse
    private let delay: Duration?
    private var invocationCount = 0
    private var candidates: [FoundationCategoryCandidate] = []

    init(
        availability: FoundationClassificationAvailability = .available,
        response: FoundationClassificationResponse,
        delay: Duration? = nil
    ) {
        modelAvailability = availability
        self.response = response
        self.delay = delay
    }

    func availability() -> FoundationClassificationAvailability {
        modelAvailability
    }

    func classify(_ request: FoundationClassificationRequest) async throws
        -> FoundationClassificationResponse {
        invocationCount += 1
        candidates = request.candidates
        if let delay { try await Task.sleep(for: delay) }
        return response
    }

    func invocations() -> Int {
        invocationCount
    }

    func lastCandidates() -> [FoundationCategoryCandidate] { candidates }
}
