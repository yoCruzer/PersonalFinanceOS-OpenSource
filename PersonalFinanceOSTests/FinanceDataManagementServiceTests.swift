import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class FinanceDataManagementServiceTests: XCTestCase {
    func testCreationRevalidatesCachedListsAgainstCurrentStore() throws {
        let context = try makeContext()
        context.insert(AppMetadata())
        try context.save()
        let other = ModelContext(context.container)
        let first = try FinanceDataManagementService.addAccount(
            name: "已有账户", type: .cash, accounts: [], in: other
        )
        let second = try FinanceDataManagementService.addAccount(
            name: "新增账户", type: .cash, accounts: [], in: context
        )
        XCTAssertTrue(first.isDefault)
        XCTAssertFalse(second.isDefault)
        XCTAssertEqual(second.sortOrder, first.sortOrder + 1)
        _ = try FinanceDataManagementService.addCategory(
            name: "早餐", kind: .expense, categories: [], in: other
        )
        XCTAssertThrowsError(try FinanceDataManagementService.addCategory(
            name: "早餐", kind: .expense, categories: [], in: context
        )) { XCTAssertEqual($0 as? FinanceDataManagementError, .duplicateName) }
        _ = try FinanceDataManagementService.addTag(name: "旅行", tags: [], in: other)
        XCTAssertThrowsError(try FinanceDataManagementService.addTag(
            name: "旅行", tags: [], in: context
        )) { XCTAssertEqual($0 as? FinanceDataManagementError, .duplicateName) }
        XCTAssertFalse(context.hasChanges)
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(context.container))
        XCTAssertEqual(package.accounts.filter(\.isDefault).count, 1)
        XCTAssertEqual(package.categories.count, 1)
        XCTAssertEqual(package.tags.count, 1)
        XCTAssertNoThrow(try NativeBackupService.validate(package))
    }

    func testCreationDoesNotCommitUnrelatedPendingEdits() throws {
        let context = try makeContext()
        let account = try FinanceDataManagementService.addAccount(
            name: "账户", type: .cash, accounts: [], in: context
        )
        account.name = "尚未保存"
        XCTAssertThrowsError(try FinanceDataManagementService.addTag(
            name: "标签", tags: [], in: context
        )) { XCTAssertEqual($0 as? FinanceDataManagementError, .pendingChanges) }
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(account.name, "尚未保存")
        let fresh = ModelContext(context.container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Account>()).first?.name, "账户")
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<Tag>()).isEmpty)
    }

    func testScalarEditorsRejectChangedValuesEvenWithEqualTimestamps() throws {
        let context = try makeContext()
        let instant = Date(timeIntervalSince1970: 100)
        let account = Account(name: "账户", type: .cash, isDefault: true, createdAt: instant, updatedAt: instant)
        let category = Category(kind: .expense, name: "餐饮", symbolName: "fork.knife", colorToken: "orange", createdAt: instant, updatedAt: instant)
        let tag = Tag(name: "旅行", createdAt: instant, updatedAt: instant)
        context.insert(account)
        context.insert(category)
        context.insert(tag)
        try context.save()
        let other = ModelContext(context.container)
        let otherAccount = try XCTUnwrap(other.fetch(FetchDescriptor<Account>()).first)
        let otherCategory = try XCTUnwrap(other.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first)
        let otherTag = try XCTUnwrap(other.fetch(FetchDescriptor<Tag>()).first)
        try FinanceDataManagementService.rename(account: otherAccount, to: "最新账户", in: other, now: instant)
        try FinanceDataManagementService.update(category: otherCategory, name: "最新分类", symbolName: "star", in: other, now: instant)
        try FinanceDataManagementService.rename(tag: otherTag, to: "最新标签", tags: [], in: other, now: instant)
        XCTAssertThrowsError(try FinanceDataManagementService.rename(account: account, to: "旧表单", in: context, now: instant)) {
            XCTAssertEqual($0 as? FinanceDataManagementError, .staleMetadata)
        }
        XCTAssertThrowsError(try FinanceDataManagementService.update(category: category, name: "旧表单", symbolName: "moon.stars", in: context, now: instant)) {
            XCTAssertEqual($0 as? FinanceDataManagementError, .staleMetadata)
        }
        XCTAssertThrowsError(try FinanceDataManagementService.rename(tag: tag, to: "旧表单", tags: [], in: context, now: instant)) {
            XCTAssertEqual($0 as? FinanceDataManagementError, .staleMetadata)
        }
        XCTAssertFalse(context.hasChanges)
        let fresh = ModelContext(context.container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Account>()).first?.name, "最新账户")
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first?.symbolName, "star")
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Tag>()).first?.name, "最新标签")
    }

    func testFormBaselineRemainsStaleAfterRegisteredObjectRefreshes() throws {
        let context = try makeContext()
        let account = try FinanceDataManagementService.addAccount(name: "原名称", type: .cash, accounts: [], in: context)
        let baseline = MetadataEditSnapshot.AccountValue(account)
        let other = ModelContext(context.container)
        let current = try XCTUnwrap(other.fetch(FetchDescriptor<Account>()).first)
        try FinanceDataManagementService.rename(account: current, to: "最新名称", in: other, now: account.updatedAt)
        // The editor's @State snapshot survives SwiftData refreshing its registered object.
        _ = try context.fetch(FetchDescriptor<Account>())
        XCTAssertThrowsError(try FinanceDataManagementService.rename(
            account: account, to: "旧表单输入", baseline: baseline, in: context
        )) { XCTAssertEqual($0 as? FinanceDataManagementError, .staleMetadata) }
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try ModelContext(context.container).fetch(FetchDescriptor<Account>()).first?.name, "最新名称")
    }

    func testDefaultAccountEditIgnoresIncompleteCachedArray() throws {
        let context = try makeContext()
        let first = try FinanceDataManagementService.addAccount(name: "一", type: .cash, accounts: [], in: context)
        let second = try FinanceDataManagementService.addAccount(name: "二", type: .cash, accounts: [], in: context)
        try FinanceDataManagementService.setDefault(second, accounts: [second], in: context)
        XCTAssertFalse(first.isDefault)
        XCTAssertTrue(second.isDefault)
        try FinanceDataManagementService.setAccountActive(second, isActive: false, accounts: [], in: context)
        XCTAssertTrue(first.isDefault)
        XCTAssertFalse(second.isDefault)
    }

    func testCategoryTextIconSavesAndRejectsEmptyValue() throws {
        let context = try makeContext()
        let category = try FinanceDataManagementService.addCategory(
            name: "早餐",
            kind: .expense,
            symbolName: "text:早餐",
            categories: [],
            in: context
        )
        XCTAssertEqual(category.symbolName, "text:早餐")

        try FinanceDataManagementService.update(
            category: category,
            name: "早餐",
            symbolName: "text:AI",
            in: context
        )
        XCTAssertEqual(category.symbolName, "text:AI")

        XCTAssertThrowsError(try FinanceDataManagementService.update(
            category: category,
            name: "早餐",
            symbolName: "text:",
            in: context
        )) {
            XCTAssertEqual($0 as? FinanceDataManagementError, .invalidCategoryIcon)
        }
        XCTAssertEqual(category.name, "早餐")
        XCTAssertEqual(category.symbolName, "text:AI")
    }

    func testCategoryReorderingNormalizesOnlyRequestedSiblingLevel() throws {
        let context = try makeContext()
        let dining = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange",
            sortOrder: 8
        )
        let travel = Category(
            kind: .expense,
            name: "旅行",
            symbolName: "airplane",
            colorToken: "blue",
            sortOrder: 2
        )
        let salary = Category(
            kind: .income,
            name: "工资",
            symbolName: "banknote",
            colorToken: "green",
            sortOrder: 4
        )
        let breakfast = Category(
            kind: .expense,
            name: "早餐",
            parentID: dining.id,
            symbolName: "sunrise",
            colorToken: "orange",
            sortOrder: 20
        )
        let dinner = Category(
            kind: .expense,
            name: "晚餐",
            parentID: dining.id,
            symbolName: "moon.stars",
            colorToken: "orange",
            sortOrder: 10
        )
        for category in [dining, travel, salary, breakfast, dinner] {
            context.insert(category)
        }
        try context.save()

        try FinanceDataManagementService.reorderCategories(
            orderedIDs: [dining.id, travel.id],
            kind: .expense,
            parentID: nil,
            categories: [dining, travel, salary, breakfast, dinner],
            in: context
        )
        XCTAssertEqual(dining.sortOrder, 0)
        XCTAssertEqual(travel.sortOrder, 1)
        XCTAssertEqual(salary.sortOrder, 4)
        XCTAssertEqual(breakfast.sortOrder, 20)
        XCTAssertEqual(dinner.sortOrder, 10)

        try FinanceDataManagementService.reorderCategories(
            orderedIDs: [breakfast.id, dinner.id],
            kind: .expense,
            parentID: dining.id,
            categories: [dining, travel, salary, breakfast, dinner],
            in: context
        )
        XCTAssertEqual(breakfast.sortOrder, 0)
        XCTAssertEqual(dinner.sortOrder, 1)
        XCTAssertEqual(breakfast.parentID, dining.id)
        XCTAssertEqual(dinner.parentID, dining.id)
    }

    func testCategoryReorderingRejectsCrossKindAndCrossParentMoves() throws {
        let context = try makeContext()
        let dining = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let travel = Category(
            kind: .expense,
            name: "旅行",
            symbolName: "airplane",
            colorToken: "blue"
        )
        let breakfast = Category(
            kind: .expense,
            name: "早餐",
            parentID: dining.id,
            symbolName: "sunrise",
            colorToken: "orange"
        )
        let hotel = Category(
            kind: .expense,
            name: "住宿",
            parentID: travel.id,
            symbolName: "bed.double",
            colorToken: "blue"
        )
        for category in [dining, travel, breakfast, hotel] { context.insert(category) }
        try context.save()

        XCTAssertThrowsError(try FinanceDataManagementService.reorderCategories(
            orderedIDs: [breakfast.id, hotel.id],
            kind: .expense,
            parentID: dining.id,
            categories: [dining, travel, breakfast, hotel],
            in: context
        )) {
            XCTAssertEqual($0 as? FinanceDataManagementError, .invalidCategoryOrder)
        }
        XCTAssertEqual(breakfast.parentID, dining.id)
        XCTAssertEqual(hotel.parentID, travel.id)
    }
    func testDefaultAccountMovesSafelyWhenCurrentDefaultIsArchived() throws {
        let context = try makeContext()
        let first = Account(name: "日常", type: .cash, isDefault: true, sortOrder: 0)
        let second = Account(name: "旅行", type: .other, sortOrder: 1)
        context.insert(first)
        context.insert(second)
        try context.save()

        try FinanceDataManagementService.setAccountActive(
            first,
            isActive: false,
            accounts: [first, second],
            in: context
        )

        XCTAssertNotNil(first.archivedAt)
        XCTAssertFalse(first.isDefault)
        XCTAssertTrue(second.isDefault)
    }

    func testLastActiveAccountCannotBeArchived() throws {
        let context = try makeContext()
        let account = Account(name: "唯一账户", type: .cash, isDefault: true)
        context.insert(account)
        try context.save()

        XCTAssertThrowsError(
            try FinanceDataManagementService.setAccountActive(
                account,
                isActive: false,
                accounts: [account],
                in: context
            )
        ) { error in
            XCTAssertEqual(error as? FinanceDataManagementError, .lastActiveAccount)
        }
        XCTAssertNil(account.archivedAt)
        XCTAssertTrue(account.isDefault)
    }

    func testCategoryArchivePreservesHistoricalTransactionRelationship() throws {
        let context = try makeContext()
        let account = Account(name: "账户", type: .cash, isDefault: true)
        let other = Category(
            kind: .expense,
            name: "其他",
            symbolName: "ellipsis.circle",
            colorToken: "teal"
        )
        let backup = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let transaction = FinanceTransaction(
            type: .expense,
            amountMinorUnits: 1_000,
            occurredAt: Date(),
            localDayKey: "2026-07-31",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: account.id,
            categoryID: other.id
        )
        context.insert(account)
        context.insert(other)
        context.insert(backup)
        context.insert(transaction)
        try context.save()

        try FinanceDataManagementService.setCategoryActive(
            other,
            isActive: false,
            categories: [other, backup],
            in: context
        )

        XCTAssertNotNil(other.archivedAt)
        XCTAssertEqual(transaction.categoryID, other.id)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FinanceTransaction>()).first?.categoryID,
            other.id
        )
    }

    func testAddRenameAndReactivateDataWithoutSchemaChanges() throws {
        let context = try makeContext()
        let account = try FinanceDataManagementService.addAccount(
            name: " 新账户 ",
            type: .bankCard,
            accounts: [],
            in: context
        )
        let category = try FinanceDataManagementService.addCategory(
            name: " 新分类 ",
            kind: .income,
            categories: [],
            in: context
        )
        let peer = Category(
            kind: .income,
            name: "备用",
            symbolName: "plus",
            colorToken: "green"
        )
        context.insert(peer)
        try context.save()

        try FinanceDataManagementService.rename(
            account: account,
            to: "工资卡",
            in: context
        )
        try FinanceDataManagementService.setCategoryActive(
            category,
            isActive: false,
            categories: [category, peer],
            in: context
        )
        try FinanceDataManagementService.setCategoryActive(
            category,
            isActive: true,
            categories: [category, peer],
            in: context
        )

        XCTAssertEqual(account.name, "工资卡")
        XCTAssertTrue(account.isDefault)
        XCTAssertEqual(category.name, "新分类")
        XCTAssertNil(category.archivedAt)
    }

    func testSystemCategoryCanBeRenamedAndArchivedWhenAnotherLeafRemains() throws {
        let context = try makeContext()
        let other = Category(
            kind: .expense,
            name: "其他",
            symbolName: "ellipsis.circle",
            colorToken: "teal",
            isSystemCategory: true
        )
        let peer = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        context.insert(other)
        context.insert(peer)
        try context.save()

        try FinanceDataManagementService.rename(category: other, to: "杂项", in: context)
        try FinanceDataManagementService.setCategoryActive(
            other,
            isActive: false,
            categories: [other, peer],
            in: context
        )
        XCTAssertEqual(other.name, "杂项")
        XCTAssertNotNil(other.archivedAt)
    }

    func testUnreferencedCategoryCanBePermanentlyDeletedAfterAnalysis() throws {
        let context = try makeContext()
        let source = Category(
            kind: .expense,
            name: "购物",
            symbolName: "bag",
            colorToken: "purple"
        )
        let peer = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        context.insert(source)
        context.insert(peer)
        try context.save()

        let analysis = try FinanceDataManagementService.analyzeDeletion(
            of: source,
            in: context
        )
        XCTAssertEqual(analysis.affectedTransactionCount, 0)
        XCTAssertEqual(analysis.childObjectCount, 0)

        try FinanceDataManagementService.permanentlyDelete(
            category: source,
            in: context
        )
        XCTAssertFalse(
            try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
                .contains { $0.id == source.id }
        )
    }

    func testReferencedCategoryRequiresMigrationThenPreservesHistoricalTransaction() throws {
        let context = try makeContext()
        let account = Account(name: "现金", type: .cash, isDefault: true)
        let source = Category(
            kind: .expense,
            name: "购物",
            symbolName: "bag",
            colorToken: "purple",
            isPinnedForQuickAdd: true
        )
        let target = Category(
            kind: .expense,
            name: "日用",
            symbolName: "basket",
            colorToken: "teal"
        )
        let tag = Tag(name: "家庭")
        let transaction = makeTransaction(
            accountID: account.id,
            categoryID: source.id,
            note: "保持不变",
            categoryDecisionSource: .manualConfirmed,
            tags: [tag]
        )
        context.insert(account)
        context.insert(source)
        context.insert(target)
        context.insert(tag)
        context.insert(transaction)
        try context.save()

        XCTAssertThrowsError(try FinanceDataManagementService.permanentlyDelete(
            category: source,
            in: context
        )) { error in
            XCTAssertEqual(error as? FinanceDataManagementError, .migrationRequired)
        }
        XCTAssertEqual(transaction.categoryID, source.id)

        let originalAmount = transaction.amountMinorUnits
        let originalDate = transaction.occurredAt
        try FinanceDataManagementService.permanentlyDelete(
            category: source,
            migratingTo: target,
            in: context
        )

        XCTAssertEqual(transaction.categoryID, target.id)
        XCTAssertEqual(transaction.categoryDecisionSource, .unchanged)
        XCTAssertEqual(transaction.amountMinorUnits, originalAmount)
        XCTAssertEqual(transaction.occurredAt, originalDate)
        XCTAssertEqual(transaction.accountID, account.id)
        XCTAssertEqual(transaction.note, "保持不变")
        XCTAssertEqual(transaction.tags.map(\.id), [tag.id])
        XCTAssertTrue(target.isPinnedForQuickAdd)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FinanceTransaction>()).count, 1)
        XCTAssertFalse(
            try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
                .contains { $0.id == source.id }
        )
    }

    func testCategoryMigrationRejectsWrongKindAndArchivedTargetsAndAllowsSystemDeletion() throws {
        let context = try makeContext()
        let source = Category(
            kind: .expense,
            name: "购物",
            symbolName: "bag",
            colorToken: "purple"
        )
        let wrongKind = Category(
            kind: .income,
            name: "工资",
            symbolName: "banknote",
            colorToken: "green"
        )
        let archived = Category(
            kind: .expense,
            name: "旧分类",
            symbolName: "archivebox",
            colorToken: "teal",
            archivedAt: Date()
        )
        let protected = Category(
            kind: .expense,
            name: "其他",
            symbolName: "ellipsis.circle",
            colorToken: "teal",
            isSystemCategory: true
        )
        let transaction = makeTransaction(accountID: UUID(), categoryID: source.id)
        context.insert(source)
        context.insert(wrongKind)
        context.insert(archived)
        context.insert(protected)
        context.insert(transaction)
        try context.save()

        for target in [wrongKind, archived] {
            XCTAssertThrowsError(try FinanceDataManagementService.permanentlyDelete(
                category: source,
                migratingTo: target,
                in: context
            )) { error in
                XCTAssertEqual(error as? FinanceDataManagementError, .invalidMigrationTarget)
            }
        }
        try FinanceDataManagementService.permanentlyDelete(category: protected, in: context)
        XCTAssertFalse(try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
            .contains { $0.id == protected.id })
    }

    func testParentDeletionRequiresChildrenFirstAndChildMigrationPreservesFacts() throws {
        let context = try makeContext()
        let account = Account(name: "现金", type: .cash, isDefault: true)
        let parent = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let child = Category(
            kind: .expense,
            name: "水果",
            parentID: parent.id,
            symbolName: "apple.logo",
            colorToken: "orange"
        )
        let target = Category(
            kind: .expense,
            name: "零食",
            parentID: parent.id,
            symbolName: "takeoutbag.and.cup.and.straw",
            colorToken: "orange"
        )
        let transaction = makeTransaction(
            accountID: account.id,
            categoryID: child.id,
            note: "火龙果"
        )
        let originalAmount = transaction.amountMinorUnits
        let originalDate = transaction.occurredAt
        for model in [parent, child, target] { context.insert(model) }
        context.insert(account)
        context.insert(transaction)
        try context.save()

        let analysis = try FinanceDataManagementService.analyzeDeletion(of: parent, in: context)
        XCTAssertEqual(analysis.childObjectCount, 2)
        XCTAssertTrue(analysis.hasUnmigratableRelationships)
        XCTAssertThrowsError(try FinanceDataManagementService.permanentlyDelete(
            category: parent,
            in: context
        )) { error in
            XCTAssertEqual(error as? FinanceDataManagementError, .categoryHasChildren)
        }

        XCTAssertThrowsError(try FinanceDataManagementService.permanentlyDelete(
            category: child,
            in: context
        )) { error in
            XCTAssertEqual(error as? FinanceDataManagementError, .migrationRequired)
        }
        try FinanceDataManagementService.permanentlyDelete(
            category: child,
            migratingTo: target,
            in: context
        )
        XCTAssertEqual(transaction.categoryID, target.id)
        XCTAssertEqual(transaction.amountMinorUnits, originalAmount)
        XCTAssertEqual(transaction.occurredAt, originalDate)
        XCTAssertEqual(transaction.note, "火龙果")
        XCTAssertEqual(try context.fetch(FetchDescriptor<FinanceTransaction>()).count, 1)
    }

    func testTagDeleteSupportsUnreferencedRemoveAndReplacementWithoutDuplicates() throws {
        let context = try makeContext()
        let unreferenced = Tag(name: "未使用")
        let source = Tag(name: "旧标签")
        let replacement = Tag(name: "新标签")
        let other = Tag(name: "其他标签")
        let first = makeTransaction(
            accountID: UUID(),
            categoryID: UUID(),
            tags: [source, other]
        )
        let second = makeTransaction(
            accountID: UUID(),
            categoryID: UUID(),
            tags: [source, replacement, other]
        )
        context.insert(unreferenced)
        context.insert(source)
        context.insert(replacement)
        context.insert(other)
        context.insert(first)
        context.insert(second)
        try context.save()

        try FinanceDataManagementService.permanentlyDelete(
            tag: unreferenced,
            in: context
        )
        XCTAssertThrowsError(try FinanceDataManagementService.permanentlyDelete(
            tag: source,
            in: context
        )) { error in
            XCTAssertEqual(error as? FinanceDataManagementError, .migrationRequired)
        }
        try FinanceDataManagementService.permanentlyDelete(
            tag: source,
            resolution: .replace(with: replacement.id),
            in: context
        )

        XCTAssertEqual(Set(first.tags.map(\.id)), Set([replacement.id, other.id]))
        XCTAssertEqual(first.tags.filter { $0.id == replacement.id }.count, 1)
        XCTAssertEqual(Set(second.tags.map(\.id)), Set([replacement.id, other.id]))
        XCTAssertEqual(second.tags.filter { $0.id == replacement.id }.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FinanceTransaction>()).count, 2)
    }

    func testTagRemoveDeletesOnlySourceRelationshipIncludingArchivedTag() throws {
        let context = try makeContext()
        let source = Tag(name: "旧标签", archivedAt: Date())
        let other = Tag(name: "保留")
        let transaction = makeTransaction(
            accountID: UUID(),
            categoryID: UUID(),
            tags: [source, other]
        )
        context.insert(source)
        context.insert(other)
        context.insert(transaction)
        try context.save()

        try FinanceDataManagementService.permanentlyDelete(
            tag: source,
            resolution: .remove,
            in: context
        )

        XCTAssertEqual(transaction.tags.map(\.id), [other.id])
        XCTAssertEqual(transaction.amountMinorUnits, 1_000)
    }

    func testAccountDeleteMigratesIncomeExpenseAndBothTransferEndpoints() throws {
        let context = try makeContext()
        let source = Account(name: "旧账户", type: .cash, isDefault: true)
        let target = Account(name: "新账户", type: .bankCard)
        let third = Account(name: "转账对端", type: .other)
        let category = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let expense = makeTransaction(accountID: source.id, categoryID: category.id)
        let income = makeTransaction(
            type: .income,
            accountID: source.id,
            categoryID: category.id
        )
        let outgoing = makeTransaction(
            type: .transfer,
            accountID: source.id,
            destinationAccountID: third.id,
            categoryID: nil
        )
        let incoming = makeTransaction(
            type: .transfer,
            accountID: third.id,
            destinationAccountID: source.id,
            categoryID: nil
        )
        context.insert(source)
        context.insert(target)
        context.insert(third)
        context.insert(category)
        for transaction in [expense, income, outgoing, incoming] {
            context.insert(transaction)
        }
        try context.save()

        let analysis = try FinanceDataManagementService.analyzeDeletion(of: source, in: context)
        XCTAssertEqual(analysis.directTransactionCount, 3)
        XCTAssertEqual(analysis.indirectTransactionCount, 1)
        XCTAssertEqual(analysis.affectedTransferCount, 2)
        XCTAssertTrue(analysis.isDefaultOrPreferred)

        try FinanceDataManagementService.permanentlyDelete(
            account: source,
            migratingTo: target,
            in: context
        )

        XCTAssertEqual(expense.accountID, target.id)
        XCTAssertEqual(income.accountID, target.id)
        XCTAssertEqual(outgoing.accountID, target.id)
        XCTAssertEqual(outgoing.destinationAccountID, third.id)
        XCTAssertEqual(incoming.accountID, third.id)
        XCTAssertEqual(incoming.destinationAccountID, target.id)
        XCTAssertTrue(target.isDefault)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FinanceTransaction>()).count, 4)
        XCTAssertFalse(try context.fetch(FetchDescriptor<Account>()).contains { $0.id == source.id })
    }

    func testAccountDeleteProtectsLastAccountAndTransferConflicts() throws {
        let context = try makeContext()
        let source = Account(name: "来源", type: .cash, isDefault: true)
        let target = Account(name: "目标", type: .bankCard)
        let transfer = makeTransaction(
            type: .transfer,
            accountID: source.id,
            destinationAccountID: target.id,
            categoryID: nil
        )
        context.insert(source)
        context.insert(target)
        context.insert(transfer)
        try context.save()

        XCTAssertThrowsError(try FinanceDataManagementService.permanentlyDelete(
            account: source,
            migratingTo: target,
            in: context
        )) { error in
            XCTAssertEqual(error as? FinanceDataManagementError, .transferMigrationConflict)
        }
        XCTAssertEqual(transfer.accountID, source.id)
        XCTAssertEqual(transfer.destinationAccountID, target.id)

        context.delete(transfer)
        context.delete(target)
        try context.save()
        XCTAssertThrowsError(try FinanceDataManagementService.permanentlyDelete(
            account: source,
            in: context
        )) { error in
            XCTAssertEqual(error as? FinanceDataManagementError, .lastActiveAccount)
        }
    }

    func testUnreferencedArchivedAccountDeletesAndInvalidTargetDoesNotMutate() throws {
        let context = try makeContext()
        let source = Account(name: "已停用", type: .cash, archivedAt: Date())
        let active = Account(name: "可用", type: .bankCard, isDefault: true)
        let archivedTarget = Account(name: "无效目标", type: .other, archivedAt: Date())
        let transaction = makeTransaction(accountID: source.id, categoryID: UUID())
        context.insert(source)
        context.insert(active)
        context.insert(archivedTarget)
        context.insert(transaction)
        try context.save()

        XCTAssertThrowsError(try FinanceDataManagementService.permanentlyDelete(
            account: source,
            migratingTo: archivedTarget,
            in: context
        )) { error in
            XCTAssertEqual(error as? FinanceDataManagementError, .invalidMigrationTarget)
        }
        XCTAssertEqual(transaction.accountID, source.id)

        context.delete(transaction)
        try context.save()
        try FinanceDataManagementService.permanentlyDelete(account: source, in: context)
        XCTAssertFalse(try context.fetch(FetchDescriptor<Account>()).contains { $0.id == source.id })
    }

    func testFailedCategoryMigrationRollsBackSourceAndTransaction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagementRollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Core Data can retain SQLite cleanup callbacks beyond the ModelContainer scope.
        // Let the process temporary directory clean this fixture up instead of unlinking
        // a store that may still have a live WAL/SHM descriptor.
        let storeURL = directory.appendingPathComponent("rollback.store")
        let sourceID: UUID
        let targetID: UUID
        let transactionID: UUID

        do {
            let context = try makeDiskContext(url: storeURL, allowsSave: true)
            let source = Category(
                kind: .expense,
                name: "来源",
                symbolName: "bag",
                colorToken: "purple"
            )
            let target = Category(
                kind: .expense,
                name: "目标",
                symbolName: "basket",
                colorToken: "teal"
            )
            let transaction = makeTransaction(
                accountID: UUID(),
                categoryID: source.id,
                categoryDecisionSource: .automaticAccepted
            )
            context.insert(source)
            context.insert(target)
            context.insert(transaction)
            try context.save()
            sourceID = source.id
            targetID = target.id
            transactionID = transaction.id
        }

        do {
            let context = try makeDiskContext(url: storeURL, allowsSave: false)
            let categories = try context.fetch(
                FetchDescriptor<PersonalFinanceOS.Category>()
            )
            let source = try XCTUnwrap(categories.first { $0.id == sourceID })
            let target = try XCTUnwrap(categories.first { $0.id == targetID })
            XCTAssertThrowsError(try FinanceDataManagementService.permanentlyDelete(
                category: source,
                migratingTo: target,
                in: context
            ))

            let currentCategories = try context.fetch(
                FetchDescriptor<PersonalFinanceOS.Category>()
            )
            let transaction = try XCTUnwrap(
                context.fetch(FetchDescriptor<FinanceTransaction>()).first { $0.id == transactionID }
            )
            XCTAssertTrue(currentCategories.contains { $0.id == sourceID })
            XCTAssertEqual(transaction.categoryID, sourceID)
            XCTAssertEqual(transaction.categoryDecisionSource, .automaticAccepted)
        }
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(
            "Management-\(UUID().uuidString)",
            schema: AppSchema.schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AppSchema.schema,
            configurations: [configuration]
        )
        return ModelContext(container)
    }

    private func makeDiskContext(url: URL, allowsSave: Bool) throws -> ModelContext {
        let configuration = ModelConfiguration(
            "ManagementRollback",
            schema: AppSchema.schema,
            url: url,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: AppSchema.schema,
            configurations: [configuration]
        )
        return ModelContext(container)
    }

    private func makeTransaction(
        type: TransactionType = .expense,
        accountID: UUID,
        destinationAccountID: UUID? = nil,
        categoryID: UUID?,
        note: String = "测试",
        categoryDecisionSource: CategoryDecisionSource = .unchanged,
        tags: [Tag] = []
    ) -> FinanceTransaction {
        FinanceTransaction(
            type: type,
            amountMinorUnits: 1_000,
            occurredAt: Date(timeIntervalSince1970: 1_750_000_000),
            localDayKey: "2025-06-15",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: accountID,
            destinationAccountID: destinationAccountID,
            categoryID: categoryID,
            note: note,
            categoryDecisionSource: categoryDecisionSource,
            tags: tags
        )
    }
}
