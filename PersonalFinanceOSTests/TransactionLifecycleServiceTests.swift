import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class TransactionLifecycleServiceTests: XCTestCase {
    private let occurredAt = Date(timeIntervalSince1970: 1_750_000_000)
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    func testStaleDraftRejectsBatchCorrectionWithUnchangedTimestamp() async throws {
        let setup = try makeSetup()
        let replacement = Category(kind: .expense, name: "新分类", symbolName: "basket", colorToken: "teal")
        setup.context.insert(replacement)
        try setup.context.save()
        let original = try TransactionLifecycleService.save(
            draft: makeDraft(type: .expense, amount: "12", accountID: setup.account.id, categoryID: setup.expenseCategory.id),
            accounts: setup.accounts, categories: setup.categories, in: setup.context, now: occurredAt
        )
        var draft = TransactionDraft(transaction: original)
        draft.amountText = "22"
        _ = try await LedgerBatchOperationActor(modelContainer: setup.context.container).migrateCategory(
            selectedIDs: [original.id], targetID: replacement.id, now: occurredAt
        )
        XCTAssertThrowsError(try TransactionLifecycleService.save(
            draft: draft, editing: original, accounts: setup.accounts, categories: setup.categories,
            in: setup.context
        )) { XCTAssertEqual($0 as? TransactionDraftError, .staleDraft) }
        let latest = try XCTUnwrap(ModelContext(setup.context.container).fetch(FetchDescriptor<FinanceTransaction>()).first)
        XCTAssertEqual(latest.categoryID, replacement.id)
        XCTAssertEqual(latest.amountMinorUnits, 1200)
        XCTAssertEqual(latest.updatedAt, occurredAt)
        XCTAssertEqual(draft.amountText, "22")
    }

    func testDraftCannotSaveAfterOriginalWasSoftDeleted() async throws {
        let setup = try makeSetup()
        let original = try TransactionLifecycleService.save(
            draft: makeDraft(type: .expense, amount: "12", accountID: setup.account.id, categoryID: setup.expenseCategory.id),
            accounts: setup.accounts, categories: setup.categories, in: setup.context
        )
        var draft = TransactionDraft(transaction: original)
        draft.note = "保留草稿"
        _ = try await LedgerBatchOperationActor(modelContainer: setup.context.container).softDelete(selectedIDs: [original.id])
        XCTAssertThrowsError(try TransactionLifecycleService.save(
            draft: draft, editing: original, accounts: setup.accounts, categories: setup.categories, in: setup.context
        )) { XCTAssertEqual($0 as? TransactionDraftError, .transactionUnavailable) }
        let latest = try XCTUnwrap(ModelContext(setup.context.container).fetch(FetchDescriptor<FinanceTransaction>()).first)
        XCTAssertNotNil(latest.deletedAt)
        XCTAssertEqual(latest.note, "")
        XCTAssertEqual(draft.note, "保留草稿")
    }

    func testNewDraftDoesNotSilentlyDropDeletedTag() async throws {
        let setup = try makeSetup()
        let tag = Tag(name: "已选择")
        setup.context.insert(tag)
        try setup.context.save()
        var draft = makeDraft(type: .expense, amount: "12", accountID: setup.account.id, categoryID: setup.expenseCategory.id)
        draft.tagIDs = [tag.id]
        _ = try await MetadataMutationActor(modelContainer: setup.context.container).deleteTag(id: tag.id, resolution: .remove)
        XCTAssertThrowsError(try TransactionLifecycleService.save(
            draft: draft, accounts: setup.accounts, categories: setup.categories, tags: [tag], in: setup.context
        )) { XCTAssertEqual($0 as? TransactionDraftError, .unavailableReference) }
        XCTAssertEqual(draft.tagIDs, [tag.id])
        XCTAssertEqual(try ModelContext(setup.context.container).fetchCount(FetchDescriptor<FinanceTransaction>()), 0)
    }

    func testInactiveCategoryCanBeRetainedButNotNewlySelected() throws {
        let setup = try makeSetup()
        let original = try TransactionLifecycleService.save(
            draft: makeDraft(type: .expense, amount: "12", accountID: setup.account.id, categoryID: setup.expenseCategory.id),
            accounts: setup.accounts, categories: setup.categories, in: setup.context
        )
        var edit = TransactionDraft(transaction: original)
        edit.note = "仍可编辑历史"
        setup.expenseCategory.isHidden = true
        try setup.context.save()
        let saved = try TransactionLifecycleService.save(
            draft: edit, editing: original, accounts: setup.accounts, categories: setup.categories, in: setup.context
        )
        XCTAssertEqual(saved.note, edit.note)
        XCTAssertEqual(saved.categoryID, setup.expenseCategory.id)
        let newDraft = makeDraft(type: .expense, amount: "12", accountID: setup.account.id, categoryID: setup.expenseCategory.id)
        XCTAssertThrowsError(try TransactionLifecycleService.save(
            draft: newDraft, accounts: setup.accounts, categories: setup.categories, in: setup.context
        )) { XCTAssertEqual($0 as? TransactionDraftError, .unavailableReference) }
    }

    func testValidExpenseCreationIsImmediatelyFetchable() throws {
        let setup = try makeSetup()
        var draft = makeDraft(
            type: .expense,
            amount: "12.80",
            accountID: setup.account.id,
            categoryID: setup.expenseCategory.id
        )
        draft.note = "午餐"

        let saved = try TransactionLifecycleService.save(
            draft: draft,
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone,
            now: occurredAt
        )
        let fetched = try setup.context.fetch(FetchDescriptor<FinanceTransaction>())

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.id, saved.id)
        XCTAssertEqual(fetched.first?.type, .expense)
        XCTAssertEqual(fetched.first?.amountMinorUnits, 1_280)
        XCTAssertEqual(fetched.first?.note, "午餐")
    }

    func testValidIncomeCreationUsesIncomeCategory() throws {
        let setup = try makeSetup()
        let draft = makeDraft(
            type: .income,
            amount: "8000",
            accountID: setup.account.id,
            categoryID: setup.incomeCategory.id
        )

        let saved = try TransactionLifecycleService.save(
            draft: draft,
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone
        )

        XCTAssertEqual(saved.type, .income)
        XCTAssertEqual(saved.amountMinorUnits, 800_000)
        XCTAssertEqual(saved.categoryID, setup.incomeCategory.id)
    }

    func testNewTransactionsPersistAutomaticManualAndTimePriorCategoryDecisionSources() throws {
        let setup = try makeSetup()
        let draft = makeDraft(
            type: .expense,
            amount: "88.60",
            accountID: setup.account.id,
            categoryID: setup.expenseCategory.id
        )
        let original = try TransactionLifecycleService.save(
            draft: draft,
            accounts: setup.accounts,
            categories: setup.categories,
            categoryDecisionSource: .automaticAccepted,
            in: setup.context,
            timeZone: timeZone
        )
        XCTAssertEqual(original.categoryDecisionSource, .automaticAccepted)

        let manual = try TransactionLifecycleService.save(
            draft: makeDraft(
                type: .expense,
                amount: "42",
                accountID: setup.account.id,
                categoryID: setup.expenseCategory.id
            ),
            accounts: setup.accounts,
            categories: setup.categories,
            categoryDecisionSource: .manualConfirmed,
            in: setup.context,
            timeZone: timeZone
        )

        XCTAssertEqual(manual.categoryDecisionSource, .manualConfirmed)

        let timePrior = try TransactionLifecycleService.save(
            draft: makeDraft(
                type: .expense,
                amount: "10",
                accountID: setup.account.id,
                categoryID: setup.expenseCategory.id
            ),
            accounts: setup.accounts,
            categories: setup.categories,
            categoryDecisionSource: .timePrior,
            in: setup.context,
            timeZone: timeZone
        )
        XCTAssertEqual(timePrior.categoryDecisionSource, .timePrior)
    }

    func testNonCategoryEditsPreserveExistingCategoryDecisionSource() throws {
        let setup = try makeSetup()
        let tag = Tag(name: "保留")
        setup.context.insert(tag)
        try setup.context.save()

        let manual = try TransactionLifecycleService.save(
            draft: makeDraft(
                type: .expense,
                amount: "88.60",
                accountID: setup.account.id,
                categoryID: setup.expenseCategory.id
            ),
            accounts: setup.accounts,
            categories: setup.categories,
            categoryDecisionSource: .manualConfirmed,
            in: setup.context,
            timeZone: timeZone
        )
        var manualEdit = TransactionDraft(transaction: manual)
        manualEdit.amountText = "99.10"
        manualEdit.occurredAt = occurredAt.addingTimeInterval(3_600)
        manualEdit.note = "只改事实"
        manualEdit.tagIDs = [tag.id]
        _ = try TransactionLifecycleService.save(
            draft: manualEdit,
            editing: manual,
            accounts: setup.accounts,
            categories: setup.categories,
            tags: [tag],
            in: setup.context,
            timeZone: timeZone
        )
        XCTAssertEqual(manual.categoryDecisionSource, .manualConfirmed)
        XCTAssertEqual(manual.tags.map(\.id), [tag.id])

        let automatic = try TransactionLifecycleService.save(
            draft: makeDraft(
                type: .expense,
                amount: "12",
                accountID: setup.account.id,
                categoryID: setup.expenseCategory.id
            ),
            accounts: setup.accounts,
            categories: setup.categories,
            categoryDecisionSource: .automaticAccepted,
            in: setup.context,
            timeZone: timeZone
        )
        var automaticEdit = TransactionDraft(transaction: automatic)
        automaticEdit.note = "只改备注"
        _ = try TransactionLifecycleService.save(
            draft: automaticEdit,
            editing: automatic,
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone
        )
        XCTAssertEqual(automatic.categoryDecisionSource, .automaticAccepted)

        let timePrior = try TransactionLifecycleService.save(
            draft: makeDraft(
                type: .expense,
                amount: "10",
                accountID: setup.account.id,
                categoryID: setup.expenseCategory.id
            ),
            accounts: setup.accounts,
            categories: setup.categories,
            categoryDecisionSource: .timePrior,
            in: setup.context,
            timeZone: timeZone
        )
        var timePriorEdit = TransactionDraft(transaction: timePrior)
        timePriorEdit.note = "只改备注"
        _ = try TransactionLifecycleService.save(
            draft: timePriorEdit,
            editing: timePrior,
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone
        )
        XCTAssertEqual(timePrior.categoryDecisionSource, .timePrior)
    }

    func testManualCategoryChangeRecordsManualDecisionSource() throws {
        let setup = try makeSetup()
        let replacement = Category(
            kind: .expense,
            name: "日用",
            symbolName: "basket",
            colorToken: "teal"
        )
        setup.context.insert(replacement)
        try setup.context.save()
        let original = try TransactionLifecycleService.save(
            draft: makeDraft(
                type: .expense,
                amount: "18",
                accountID: setup.account.id,
                categoryID: setup.expenseCategory.id
            ),
            accounts: setup.accounts,
            categories: setup.categories,
            categoryDecisionSource: .automaticAccepted,
            in: setup.context,
            timeZone: timeZone
        )
        var edit = TransactionDraft(transaction: original)
        edit.categoryID = replacement.id
        _ = try TransactionLifecycleService.save(
            draft: edit,
            editing: original,
            accounts: setup.accounts,
            categories: setup.categories + [replacement],
            categoryDecisionSource: .manualConfirmed,
            in: setup.context,
            timeZone: timeZone
        )

        XCTAssertEqual(original.categoryID, replacement.id)
        XCTAssertEqual(original.categoryDecisionSource, .manualConfirmed)
    }

    func testInvalidAmountsAreRejectedWithoutInsertion() throws {
        let setup = try makeSetup()

        for amount in ["", "0", "-1", "1.001", "abc"] {
            let draft = makeDraft(
                type: .expense,
                amount: amount,
                accountID: setup.account.id,
                categoryID: setup.expenseCategory.id
            )

            XCTAssertThrowsError(try TransactionLifecycleService.save(
                draft: draft,
                accounts: setup.accounts,
                categories: setup.categories,
                in: setup.context,
                timeZone: timeZone
            )) { error in
                XCTAssertEqual(error as? TransactionDraftError, .invalidAmount)
            }
        }

        XCTAssertTrue(try setup.context.fetch(FetchDescriptor<FinanceTransaction>()).isEmpty)
    }

    func testEditUpdatesOriginalWithoutCreatingDuplicate() throws {
        let setup = try makeSetup()
        let original = try TransactionLifecycleService.save(
            draft: makeDraft(
                type: .expense,
                amount: "10",
                accountID: setup.account.id,
                categoryID: setup.expenseCategory.id
            ),
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone,
            now: occurredAt
        )
        var edit = TransactionDraft(transaction: original)
        edit.type = .income
        edit.amountText = "25.50"
        edit.categoryID = setup.incomeCategory.id
        edit.note = "已修改"

        let saved = try TransactionLifecycleService.save(
            draft: edit,
            editing: original,
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone,
            now: occurredAt.addingTimeInterval(60)
        )
        let fetched = try setup.context.fetch(FetchDescriptor<FinanceTransaction>())

        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.type, .income)
        XCTAssertEqual(fetched.first?.amountMinorUnits, 2_550)
        XCTAssertEqual(fetched.first?.note, "已修改")
    }

    func testEditingWithoutAmountInputPreservesPrefilledAmount() throws {
        let setup = try makeSetup()
        let original = try TransactionLifecycleService.save(
            draft: makeDraft(
                type: .expense,
                amount: "123.45",
                accountID: setup.account.id,
                categoryID: setup.expenseCategory.id
            ),
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone,
            now: occurredAt
        )
        var edit = TransactionDraft(transaction: original)
        edit.note = "金额未修改"

        let saved = try TransactionLifecycleService.save(
            draft: edit,
            editing: original,
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone,
            now: occurredAt.addingTimeInterval(60)
        )

        XCTAssertEqual(saved.amountMinorUnits, 12_345)
        XCTAssertEqual(saved.note, "金额未修改")
    }

    func testEditPreservesStoredTimeZoneAndLocalDayNearMidnight() throws {
        let setup = try makeSetup()
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let nearMidnight = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-02T00:15:00-07:00")
        )
        var originalDraft = makeDraft(
            type: .expense,
            amount: "10",
            accountID: setup.account.id,
            categoryID: setup.expenseCategory.id
        )
        originalDraft.occurredAt = nearMidnight
        let original = try TransactionLifecycleService.save(
            draft: originalDraft,
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: losAngeles
        )

        var edit = TransactionDraft(transaction: original)
        edit.note = "只改备注"
        let saved = try TransactionLifecycleService.save(
            draft: edit,
            editing: original,
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context
        )

        XCTAssertEqual(saved.timeZoneIdentifier, losAngeles.identifier)
        XCTAssertEqual(saved.localDayKey, "2026-08-02")
        XCTAssertEqual(saved.occurredAt, nearMidnight)
    }

    func testEditingForeignCurrencyTransactionPreservesCurrency() throws {
        let setup = try makeSetup()
        let usdAccount = Account(name: "USD Cash", type: .cash, currencyCode: "USD")
        setup.context.insert(usdAccount)
        let original = FinanceTransaction(
            type: .expense,
            amountMinorUnits: 1_234,
            currencyCode: "USD",
            occurredAt: occurredAt,
            localDayKey: "2025-06-15",
            timeZoneIdentifier: timeZone.identifier,
            accountID: usdAccount.id,
            categoryID: setup.expenseCategory.id,
            note: "before"
        )
        setup.context.insert(original)
        try setup.context.save()

        var draft = TransactionDraft(transaction: original)
        draft.note = "after"
        let saved = try TransactionLifecycleService.save(
            draft: draft,
            editing: original,
            accounts: setup.accounts + [usdAccount],
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone
        )

        XCTAssertEqual(saved.amountMinorUnits, 1_234)
        XCTAssertEqual(saved.currencyCode, "USD")
        XCTAssertEqual(saved.note, "after")
    }

    func testRefundNoteEditPreservesRelatedTransaction() throws {
        let setup = try makeSetup()
        let relatedID = UUID()
        setup.context.insert(FinanceTransaction(
            id: relatedID, type: .expense, amountMinorUnits: 500,
            occurredAt: occurredAt, localDayKey: LocalDayKey.make(for: occurredAt, timeZone: timeZone),
            timeZoneIdentifier: timeZone.identifier, accountID: setup.account.id, categoryID: setup.expenseCategory.id
        ))
        let refund = FinanceTransaction(
            type: .refund,
            amountMinorUnits: 500,
            occurredAt: occurredAt,
            localDayKey: LocalDayKey.make(for: occurredAt, timeZone: timeZone),
            timeZoneIdentifier: timeZone.identifier,
            accountID: setup.account.id,
            categoryID: setup.expenseCategory.id,
            relatedTransactionID: relatedID
        )
        setup.context.insert(refund)
        try setup.context.save()
        var draft = TransactionDraft(transaction: refund)
        draft.note = "退款备注"

        let saved = try TransactionLifecycleService.save(
            draft: draft,
            editing: refund,
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone
        )

        XCTAssertEqual(saved.type, .refund)
        XCTAssertEqual(saved.relatedTransactionID, relatedID)
    }

    func testChangingRefundToExpenseClearsRelatedTransaction() throws {
        let setup = try makeSetup()
        let refund = FinanceTransaction(
            type: .refund,
            amountMinorUnits: 500,
            occurredAt: occurredAt,
            localDayKey: LocalDayKey.make(for: occurredAt, timeZone: timeZone),
            timeZoneIdentifier: timeZone.identifier,
            accountID: setup.account.id,
            categoryID: setup.expenseCategory.id,
            relatedTransactionID: UUID()
        )
        setup.context.insert(refund)
        try setup.context.save()
        var draft = TransactionDraft(transaction: refund)
        draft.type = .expense
        draft.categoryID = setup.expenseCategory.id

        let saved = try TransactionLifecycleService.save(
            draft: draft,
            editing: refund,
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone
        )

        XCTAssertEqual(saved.type, .expense)
        XCTAssertNil(saved.relatedTransactionID)
    }

    func testChangingRefundToIncomeClearsRelatedTransaction() throws {
        let setup = try makeSetup()
        let refund = FinanceTransaction(
            type: .refund,
            amountMinorUnits: 500,
            occurredAt: occurredAt,
            localDayKey: LocalDayKey.make(for: occurredAt, timeZone: timeZone),
            timeZoneIdentifier: timeZone.identifier,
            accountID: setup.account.id,
            categoryID: setup.expenseCategory.id,
            relatedTransactionID: UUID()
        )
        setup.context.insert(refund)
        try setup.context.save()
        var draft = TransactionDraft(transaction: refund)
        draft.type = .income
        draft.categoryID = setup.incomeCategory.id

        let saved = try TransactionLifecycleService.save(
            draft: draft,
            editing: refund,
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone
        )

        XCTAssertEqual(saved.type, .income)
        XCTAssertNil(saved.relatedTransactionID)
    }

    func testOrdinaryExpenseAndIncomeEditsDoNotCreateRelatedTransaction() throws {
        let setup = try makeSetup()
        for (type, category) in [
            (TransactionType.expense, setup.expenseCategory),
            (TransactionType.income, setup.incomeCategory)
        ] {
            let original = try TransactionLifecycleService.save(
                draft: makeDraft(
                    type: type,
                    amount: "5",
                    accountID: setup.account.id,
                    categoryID: category.id
                ),
                accounts: setup.accounts,
                categories: setup.categories,
                in: setup.context,
                timeZone: timeZone
            )
            var draft = TransactionDraft(transaction: original)
            draft.note = "edited"
            let saved = try TransactionLifecycleService.save(
                draft: draft,
                editing: original,
                accounts: setup.accounts,
                categories: setup.categories,
                in: setup.context,
                timeZone: timeZone
            )
            XCTAssertNil(saved.relatedTransactionID)
        }
    }

    func testTransferDraftSaveAndDuplicationPreserveDestinationAndCurrency() throws {
        let setup = try makeSetup()
        let destination = Account(name: "银行卡", type: .bankCard, currencyCode: "CNY")
        setup.context.insert(destination)
        let original = FinanceTransaction(
            type: .transfer,
            amountMinorUnits: 5_000,
            currencyCode: "CNY",
            occurredAt: occurredAt,
            localDayKey: "2025-06-15",
            timeZoneIdentifier: timeZone.identifier,
            accountID: setup.account.id,
            destinationAccountID: destination.id,
            note: "before"
        )
        setup.context.insert(original)
        try setup.context.save()

        var edit = TransactionDraft(transaction: original)
        edit.note = "after"
        let saved = try TransactionLifecycleService.save(
            draft: edit,
            editing: original,
            accounts: setup.accounts + [destination],
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone
        )
        XCTAssertEqual(saved.type, .transfer)
        XCTAssertEqual(saved.destinationAccountID, destination.id)
        XCTAssertNil(saved.categoryID)

        let duplicateDraft = TransactionDuplicationService.makeDraft(
            from: saved,
            dateProvider: FixedTransactionLifecycleDateProvider(date: occurredAt),
            timeZone: timeZone
        )
        let duplicate = try TransactionLifecycleService.save(
            draft: duplicateDraft,
            accounts: setup.accounts + [destination],
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone
        )
        XCTAssertEqual(duplicate.type, .transfer)
        XCTAssertEqual(duplicate.currencyCode, "CNY")
        XCTAssertEqual(duplicate.accountID, setup.account.id)
        XCTAssertEqual(duplicate.destinationAccountID, destination.id)
        XCTAssertNil(duplicate.categoryID)
    }

    func testCancelEditLeavesOriginalUnchanged() throws {
        let setup = try makeSetup()
        let original = try TransactionLifecycleService.save(
            draft: makeDraft(
                type: .expense,
                amount: "18",
                accountID: setup.account.id,
                categoryID: setup.expenseCategory.id
            ),
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone
        )
        var draft = TransactionDraft(transaction: original)
        draft.amountText = "99"
        draft.note = "未保存"

        XCTAssertEqual(original.amountMinorUnits, 1_800)
        XCTAssertEqual(original.note, "")
        XCTAssertEqual(
            try setup.context.fetch(FetchDescriptor<FinanceTransaction>()).count,
            1
        )
    }

    func testDeleteAndCancelDeleteSemantics() throws {
        let setup = try makeSetup()
        let original = try TransactionLifecycleService.save(
            draft: makeDraft(
                type: .expense,
                amount: "18",
                accountID: setup.account.id,
                categoryID: setup.expenseCategory.id
            ),
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone
        )

        XCTAssertNil(original.deletedAt, "Cancelling confirmation performs no mutation.")
        XCTAssertEqual(
            TransactionLifecycleService.sortedActive([original]).map(\.id),
            [original.id]
        )

        try TransactionLifecycleService.softDelete(
            original,
            in: setup.context,
            now: occurredAt
        )

        XCTAssertEqual(original.deletedAt, occurredAt)
        XCTAssertTrue(TransactionLifecycleService.sortedActive([original]).isEmpty)
    }

    func testDiskReloadRetainsCreateAndEditThenKeepsDeleteHidden() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalFinanceOS-Wave2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Wave2.store")
        let transactionID: UUID

        do {
            let container = try makeDiskContainer(url: storeURL)
            let context = ModelContext(container)
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

            let saved = try TransactionLifecycleService.save(
                draft: makeDraft(
                    type: .expense,
                    amount: "20",
                    accountID: account.id,
                    categoryID: category.id
                ),
                accounts: [account],
                categories: [category],
                in: context,
                timeZone: timeZone
            )
            transactionID = saved.id
        }

        do {
            let container = try makeDiskContainer(url: storeURL)
            let context = ModelContext(container)
            let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
            let accounts = try context.fetch(FetchDescriptor<Account>())
            let categories = try context.fetch(
                FetchDescriptor<PersonalFinanceOS.Category>()
            )
            XCTAssertEqual(TransactionLifecycleService.sortedActive(transactions).count, 1)

            var edit = TransactionDraft(transaction: transactions[0])
            edit.amountText = "30.50"
            edit.note = "重载后编辑"
            try TransactionLifecycleService.save(
                draft: edit,
                editing: transactions[0],
                accounts: accounts,
                categories: categories,
                in: context,
                timeZone: timeZone
            )
        }

        do {
            let container = try makeDiskContainer(url: storeURL)
            let context = ModelContext(container)
            let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
            XCTAssertEqual(transactions.count, 1)
            XCTAssertEqual(transactions[0].id, transactionID)
            XCTAssertEqual(transactions[0].amountMinorUnits, 3_050)
            XCTAssertEqual(transactions[0].note, "重载后编辑")

            try TransactionLifecycleService.softDelete(transactions[0], in: context)
        }

        do {
            let container = try makeDiskContainer(url: storeURL)
            let context = ModelContext(container)
            let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
            XCTAssertEqual(transactions.count, 1)
            XCTAssertNotNil(transactions[0].deletedAt)
            XCTAssertTrue(TransactionLifecycleService.sortedActive(transactions).isEmpty)
        }
    }

    func testMultipleTransactionsUseStableDescendingOrderWithoutMerging() throws {
        let setup = try makeSetup()
        let first = try TransactionLifecycleService.save(
            draft: makeDraft(
                type: .expense,
                amount: "10",
                accountID: setup.account.id,
                categoryID: setup.expenseCategory.id
            ),
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone,
            now: occurredAt
        )
        let second = try TransactionLifecycleService.save(
            draft: makeDraft(
                type: .expense,
                amount: "10",
                accountID: setup.account.id,
                categoryID: setup.expenseCategory.id
            ),
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone,
            now: occurredAt.addingTimeInterval(1)
        )
        var laterDraft = makeDraft(
            type: .expense,
            amount: "10",
            accountID: setup.account.id,
            categoryID: setup.expenseCategory.id
        )
        laterDraft.occurredAt = occurredAt.addingTimeInterval(60)
        let later = try TransactionLifecycleService.save(
            draft: laterDraft,
            accounts: setup.accounts,
            categories: setup.categories,
            in: setup.context,
            timeZone: timeZone,
            now: occurredAt.addingTimeInterval(2)
        )

        let fetched = try setup.context.fetch(FetchDescriptor<FinanceTransaction>())
        let sorted = TransactionLifecycleService.sortedActive(fetched)

        XCTAssertEqual(fetched.count, 3)
        XCTAssertEqual(sorted.first?.id, later.id)
        XCTAssertEqual(Set(sorted.map(\.id)), Set([first.id, second.id, later.id]))
        XCTAssertEqual(
            TransactionLifecycleService.sortedActive(fetched).map(\.id),
            sorted.map(\.id)
        )
    }

    func testDefaultDataBootstrapIsIdempotent() throws {
        let configuration = ModelConfiguration(
            "Wave2Defaults-\(UUID().uuidString)",
            schema: AppSchema.schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AppSchema.schema,
            configurations: [configuration]
        )
        let context = ModelContext(container)

        try DefaultFinanceDataService.ensureDefaults(in: context)
        try DefaultFinanceDataService.ensureDefaults(in: context)

        let accounts = try context.fetch(FetchDescriptor<Account>())
        let categories = try context.fetch(
            FetchDescriptor<PersonalFinanceOS.Category>()
        )
        XCTAssertEqual(accounts.filter { $0.archivedAt == nil }.count, 1)
        XCTAssertEqual(accounts.filter(\.isDefault).count, 1)
        XCTAssertEqual(categories.filter { $0.kind == .expense }.count, 198)
        XCTAssertEqual(categories.filter { $0.kind == .income }.count, 35)
    }

    func testOtherCategoryExpressionAndDatePersistAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalFinanceOS-Other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Other.store")
        let updatedDate = occurredAt.addingTimeInterval(86_400 + 3_600)
        let transactionID: UUID

        do {
            let container = try makeDiskContainer(url: storeURL)
            let context = ModelContext(container)
            try DefaultFinanceDataService.ensureDefaults(in: context)
            let accounts = try context.fetch(FetchDescriptor<Account>())
            let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
            let other = try XCTUnwrap(categories.first {
                $0.kind == .expense && $0.defaultDefinitionKey == "expense.other.other" && $0.parentID != nil
            })
            var draft = makeDraft(
                type: .expense,
                amount: "10+2.34",
                accountID: try XCTUnwrap(accounts.first(where: \.isDefault)).id,
                categoryID: other.id
            )
            draft.occurredAt = updatedDate
            transactionID = try TransactionLifecycleService.save(
                draft: draft,
                accounts: accounts,
                categories: categories,
                in: context,
                timeZone: timeZone
            ).id
        }

        do {
            let container = try makeDiskContainer(url: storeURL)
            let context = ModelContext(container)
            let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
            let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
            let transaction = try XCTUnwrap(transactions.first { $0.id == transactionID })
            let category = try XCTUnwrap(categories.first { $0.id == transaction.categoryID })

            XCTAssertEqual(transaction.amountMinorUnits, 1_234)
            XCTAssertEqual(transaction.occurredAt, updatedDate)
            XCTAssertEqual(transaction.localDayKey, LocalDayKey.make(for: updatedDate, timeZone: timeZone))
            XCTAssertEqual(category.name, "其他支出")
        }
    }

    private func makeSetup() throws -> (
        context: ModelContext,
        account: Account,
        expenseCategory: PersonalFinanceOS.Category,
        incomeCategory: PersonalFinanceOS.Category,
        accounts: [Account],
        categories: [PersonalFinanceOS.Category]
    ) {
        let configuration = ModelConfiguration(
            "Wave2MemoryTests-\(UUID().uuidString)",
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
        let expenseCategory = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let incomeCategory = Category(
            kind: .income,
            name: "薪资",
            symbolName: "banknote",
            colorToken: "green"
        )
        context.insert(account)
        context.insert(expenseCategory)
        context.insert(incomeCategory)
        try context.save()
        return (
            context,
            account,
            expenseCategory,
            incomeCategory,
            [account],
            [expenseCategory, incomeCategory]
        )
    }

    private func makeDraft(
        type: TransactionType,
        amount: String,
        accountID: UUID,
        categoryID: UUID
    ) -> TransactionDraft {
        var draft = TransactionDraft()
        draft.type = type
        draft.amountText = amount
        draft.accountID = accountID
        draft.categoryID = categoryID
        draft.occurredAt = occurredAt
        return draft
    }

    private func makeDiskContainer(url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "Wave2DiskTests",
            schema: AppSchema.schema,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: AppSchema.schema,
            configurations: [configuration]
        )
    }
}

private struct FixedTransactionLifecycleDateProvider: DateProvider {
    let date: Date

    func now() -> Date { date }
}
