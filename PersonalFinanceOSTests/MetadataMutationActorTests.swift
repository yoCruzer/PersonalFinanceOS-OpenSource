import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class MetadataMutationActorTests: XCTestCase {
    func testLargeAccountCategoryAndTagMigrationsRunThroughActor() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let sourceAccount = Account(name: "Source", type: .cash, isDefault: true)
        let targetAccount = Account(name: "Target", type: .bankCard)
        let transferDestination = Account(name: "Destination", type: .bankCard)
        let sourceCategory = Category(
            kind: .expense, name: "Source Category",
            symbolName: "folder", colorToken: "orange"
        )
        let targetCategory = Category(
            kind: .expense, name: "Target Category",
            symbolName: "folder.fill", colorToken: "teal"
        )
        let sourceTag = Tag(name: "Source Tag")
        let targetTag = Tag(name: "Target Tag")
        [sourceAccount, targetAccount, transferDestination].forEach(context.insert)
        [sourceCategory, targetCategory].forEach(context.insert)
        [sourceTag, targetTag].forEach(context.insert)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<4_000 {
            context.insert(FinanceTransaction(
                type: index == 0 ? .transfer : .expense,
                amountMinorUnits: Int64(index + 1),
                occurredAt: now,
                localDayKey: "2027-01-15",
                timeZoneIdentifier: "UTC",
                accountID: sourceAccount.id,
                destinationAccountID: index == 0 ? transferDestination.id : nil,
                categoryID: index == 0 ? nil : sourceCategory.id,
                updatedAt: now,
                deletedAt: index.isMultiple(of: 100) ? now : nil,
                tags: [sourceTag]
            ))
        }
        try context.save()

        let worker = MetadataMutationActor(modelContainer: container)
        let accountPlan = try await worker.analyzeAccount(id: sourceAccount.id)
        XCTAssertEqual(accountPlan.analysis.affectedTransactionCount, 4_000)
        XCTAssertTrue(accountPlan.validTargetIDs.contains(targetAccount.id))
        XCTAssertFalse(accountPlan.validTargetIDs.contains(transferDestination.id))
        let accountResult = try await worker.deleteAccount(
            id: sourceAccount.id,
            targetID: targetAccount.id,
            now: now.addingTimeInterval(10)
        )
        XCTAssertEqual(accountResult.changedTransactionCount, 4_000)

        let categoryPlan = try await worker.analyzeCategory(id: sourceCategory.id)
        XCTAssertEqual(categoryPlan.analysis.affectedTransactionCount, 3_999)
        let categoryResult = try await worker.deleteCategory(
            id: sourceCategory.id,
            targetID: targetCategory.id,
            now: now.addingTimeInterval(20)
        )
        XCTAssertEqual(categoryResult.changedTransactionCount, 3_999)

        let tagPlan = try await worker.analyzeTag(id: sourceTag.id)
        XCTAssertEqual(tagPlan.analysis.affectedTransactionCount, 4_000)
        let tagResult = try await worker.deleteTag(
            id: sourceTag.id,
            resolution: .replace(with: targetTag.id),
            now: now.addingTimeInterval(30)
        )
        XCTAssertEqual(tagResult.changedTransactionCount, 4_000)

        let verification = ModelContext(container)
        let transactions = try verification.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(transactions.count, 4_000)
        XCTAssertTrue(transactions.allSatisfy { $0.accountID == targetAccount.id })
        XCTAssertEqual(transactions.first { $0.type == .transfer }?.destinationAccountID, transferDestination.id)
        XCTAssertTrue(transactions.filter { $0.type != .transfer }.allSatisfy {
            $0.categoryID == targetCategory.id
        })
        XCTAssertTrue(transactions.allSatisfy { $0.tags.map(\.id) == [targetTag.id] })
        XCTAssertFalse(try verification.fetch(FetchDescriptor<Account>()).contains {
            $0.id == sourceAccount.id
        })
        XCTAssertFalse(try verification.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).contains {
            $0.id == sourceCategory.id
        })
        XCTAssertFalse(try verification.fetch(FetchDescriptor<Tag>()).contains {
            $0.id == sourceTag.id
        })
    }
}
