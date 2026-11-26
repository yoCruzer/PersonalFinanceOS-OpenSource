import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class TransactionDuplicationServiceTests: XCTestCase {
    private let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let clickDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let saveDate = Date(timeIntervalSince1970: 1_800_000_060)
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    func testDuplicateMapsBusinessFieldsAndSaveCreatesIndependentManualTransaction() throws {
        let setup = try makeSetup()
        let merchantID = UUID()
        setup.context.insert(Merchant(id: merchantID, canonicalName: "原商户", normalizedSearchKey: "原商户"))
        let originalID = UUID()
        let importBatchID = UUID()
        let relatedID = UUID()
        let original = FinanceTransaction(
            id: originalID,
            type: .expense,
            amountMinorUnits: 12_345,
            occurredAt: sourceDate,
            localDayKey: LocalDayKey.make(for: sourceDate, timeZone: timeZone),
            timeZoneIdentifier: timeZone.identifier,
            accountID: setup.account.id,
            categoryID: setup.category.id,
            merchantID: merchantID,
            rawMerchantText: "原商户",
            note: "原备注",
            reviewStatus: .needsReview,
            reviewReasons: [.uncategorized],
            relatedTransactionID: relatedID,
            importBatchID: importBatchID,
            externalSource: .alipay,
            externalTransactionID: "external-1",
            importFingerprint: "fingerprint-1",
            createdAt: sourceDate.addingTimeInterval(-100),
            updatedAt: sourceDate,
            tags: [setup.firstTag, setup.secondTag]
        )
        setup.context.insert(original)
        try setup.context.save()

        let draft = TransactionDuplicationService.makeDraft(
            from: original,
            dateProvider: FixedDateProvider(date: clickDate),
            timeZone: timeZone
        )

        XCTAssertEqual(draft.type, .expense)
        XCTAssertEqual(draft.amountText, "123.45")
        XCTAssertEqual(draft.accountID, setup.account.id)
        XCTAssertEqual(draft.categoryID, setup.category.id)
        XCTAssertEqual(draft.merchantID, merchantID)
        XCTAssertEqual(draft.rawMerchantText, "原商户")
        XCTAssertEqual(draft.note, "原备注")
        XCTAssertEqual(draft.tagIDs, Set([setup.firstTag.id, setup.secondTag.id]))
        XCTAssertEqual(draft.occurredAt, clickDate)
        XCTAssertNotEqual(draft.occurredAt, original.occurredAt)
        XCTAssertEqual(draft.timeZoneIdentifier, timeZone.identifier)

        let duplicate = try TransactionLifecycleService.save(
            draft: draft,
            accounts: [setup.account],
            categories: [setup.category],
            tags: [setup.firstTag, setup.secondTag],
            in: setup.context,
            now: saveDate
        )

        XCTAssertNotEqual(duplicate.id, originalID)
        XCTAssertEqual(duplicate.createdAt, saveDate)
        XCTAssertEqual(duplicate.updatedAt, saveDate)
        XCTAssertEqual(duplicate.occurredAt, clickDate)
        XCTAssertNil(duplicate.importBatchID)
        XCTAssertNil(duplicate.externalSource)
        XCTAssertEqual(duplicate.externalTransactionID, "")
        XCTAssertEqual(duplicate.importFingerprint, "")
        XCTAssertNil(duplicate.relatedTransactionID)
        XCTAssertEqual(duplicate.reviewStatus, .complete)
        XCTAssertTrue(duplicate.reviewReasons.isEmpty)
        XCTAssertNil(duplicate.deletedAt)
        XCTAssertEqual(Set(duplicate.tags.map(\.id)), Set([setup.firstTag.id, setup.secondTag.id]))

        XCTAssertEqual(original.id, originalID)
        XCTAssertEqual(original.occurredAt, sourceDate)
        XCTAssertEqual(original.importBatchID, importBatchID)
        XCTAssertEqual(original.externalTransactionID, "external-1")
        XCTAssertEqual(original.importFingerprint, "fingerprint-1")
        XCTAssertEqual(try setup.context.fetch(FetchDescriptor<FinanceTransaction>()).count, 2)
    }

    func testPreparingThenCancellingDuplicateDoesNotWrite() throws {
        let setup = try makeSetup()
        let original = try insertOriginal(in: setup)

        _ = TransactionDuplicationService.makeDraft(
            from: original,
            dateProvider: FixedDateProvider(date: clickDate),
            timeZone: timeZone
        )

        let fetched = try setup.context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(fetched.map(\.id), [original.id])
    }

    func testContinuousDuplicatesGetDistinctIDsWithoutImportDeduplicationMetadata() throws {
        let setup = try makeSetup()
        let original = try insertOriginal(in: setup)
        let drafts = [clickDate, clickDate.addingTimeInterval(1)].map { date in
            TransactionDuplicationService.makeDraft(
                from: original,
                dateProvider: FixedDateProvider(date: date),
                timeZone: timeZone
            )
        }

        let duplicates = try drafts.enumerated().map { index, draft in
            try TransactionLifecycleService.save(
                draft: draft,
                accounts: [setup.account],
                categories: [setup.category],
                tags: [setup.firstTag, setup.secondTag],
                in: setup.context,
                now: saveDate.addingTimeInterval(TimeInterval(index))
            )
        }

        XCTAssertEqual(Set(duplicates.map(\.id)).count, 2)
        XCTAssertFalse(duplicates.contains { $0.id == original.id })
        XCTAssertTrue(duplicates.allSatisfy {
            $0.importBatchID == nil &&
            $0.externalSource == nil &&
            $0.externalTransactionID.isEmpty &&
            $0.importFingerprint.isEmpty
        })
        XCTAssertEqual(try setup.context.fetch(FetchDescriptor<FinanceTransaction>()).count, 3)
    }

    func testDuplicateRejectsArchivedReferencesAndKeepsDraftSelections() throws {
        let setup = try makeSetup()
        setup.account.archivedAt = sourceDate
        setup.category.archivedAt = sourceDate
        setup.firstTag.archivedAt = sourceDate
        let original = try insertOriginal(in: setup, tags: [setup.firstTag, setup.secondTag])
        let draft = TransactionDuplicationService.makeDraft(
            from: original,
            dateProvider: FixedDateProvider(date: clickDate),
            timeZone: timeZone
        )

        // X5: copying is a new transaction, so inactive references require a new choice.
        // The prior expectation silently omitted a selected tag; X4/X5 forbid that.
        XCTAssertThrowsError(try TransactionLifecycleService.save(
            draft: draft, accounts: [setup.account], categories: [setup.category],
            tags: [setup.firstTag], in: setup.context, now: saveDate
        )) { XCTAssertEqual($0 as? TransactionDraftError, .unavailableReference) }
        XCTAssertEqual(draft.accountID, setup.account.id)
        XCTAssertEqual(draft.categoryID, setup.category.id)
        XCTAssertEqual(draft.tagIDs, Set([setup.firstTag.id, setup.secondTag.id]))
        XCTAssertEqual(try setup.context.fetchCount(FetchDescriptor<FinanceTransaction>()), 1)
        XCTAssertEqual(original.tags.count, 2)
    }

    func testDuplicateResolvesAllSelectedTagsFromCurrentStore() throws {
        let setup = try makeSetup()
        let original = try insertOriginal(in: setup)
        let draft = TransactionDuplicationService.makeDraft(from: original)
        let duplicate = try TransactionLifecycleService.save(
            draft: draft, accounts: [setup.account], categories: [setup.category],
            tags: [setup.firstTag], in: setup.context, now: saveDate
        )
        XCTAssertEqual(Set(duplicate.tags.map(\.id)), draft.tagIDs)
        XCTAssertEqual(duplicate.tags.count, 2)
    }

    func testDuplicateWithoutTagsSavesWithoutTagRelationships() throws {
        let setup = try makeSetup()
        let original = try insertOriginal(in: setup, tags: [])
        let draft = TransactionDuplicationService.makeDraft(
            from: original,
            dateProvider: FixedDateProvider(date: clickDate),
            timeZone: timeZone
        )
        let duplicate = try TransactionLifecycleService.save(
            draft: draft,
            accounts: [setup.account],
            categories: [setup.category],
            tags: [setup.firstTag, setup.secondTag],
            in: setup.context,
            now: saveDate
        )

        XCTAssertTrue(draft.tagIDs.isEmpty)
        XCTAssertTrue(duplicate.tags.isEmpty)
    }

    private func insertOriginal(
        in setup: Setup,
        tags: [Tag]? = nil
    ) throws -> FinanceTransaction {
        let original = FinanceTransaction(
            type: .expense,
            amountMinorUnits: 2_000,
            occurredAt: sourceDate,
            localDayKey: LocalDayKey.make(for: sourceDate, timeZone: timeZone),
            timeZoneIdentifier: timeZone.identifier,
            accountID: setup.account.id,
            categoryID: setup.category.id,
            note: "可复制",
            importBatchID: UUID(),
            externalSource: .wechat,
            externalTransactionID: "source-id",
            importFingerprint: "source-fingerprint",
            tags: tags ?? [setup.firstTag, setup.secondTag]
        )
        setup.context.insert(original)
        try setup.context.save()
        return original
    }

    private func makeSetup() throws -> Setup {
        let configuration = ModelConfiguration(
            "TransactionDuplication-\(UUID().uuidString)",
            schema: AppSchema.schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AppSchema.schema,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let account = Account(name: "现金", type: .cash, isDefault: true)
        let category = PersonalFinanceOS.Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let firstTag = Tag(name: "工作")
        let secondTag = Tag(name: "报销")
        context.insert(account)
        context.insert(category)
        context.insert(firstTag)
        context.insert(secondTag)
        try context.save()
        return Setup(
            context: context,
            account: account,
            category: category,
            firstTag: firstTag,
            secondTag: secondTag
        )
    }
}

private struct FixedDateProvider: DateProvider {
    let date: Date

    func now() -> Date { date }
}

@MainActor
private struct Setup {
    let context: ModelContext
    let account: Account
    let category: PersonalFinanceOS.Category
    let firstTag: Tag
    let secondTag: Tag
}
