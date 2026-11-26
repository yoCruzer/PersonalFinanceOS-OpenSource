import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class PersistenceTests: XCTestCase {
    func testWriteReadUpdateSoftDeleteAndRelationship() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let account = Account(name: "Cash", type: .cash, isDefault: true)
        let category = Category(
            kind: .expense,
            name: "Food",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        let tag = Tag(name: "Work")
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let transaction = FinanceTransaction(
            type: .expense,
            amountMinorUnits: 1_234,
            occurredAt: date,
            localDayKey: "2025-06-15",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: account.id,
            categoryID: category.id,
            note: "Initial",
            tags: [tag]
        )

        context.insert(account)
        context.insert(category)
        context.insert(tag)
        context.insert(transaction)
        try context.save()

        var fetched = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].amountMinorUnits, 1_234)
        XCTAssertEqual(fetched[0].tags.map(\.name), ["Work"])

        fetched[0].note = "Updated"
        fetched[0].updatedAt = date.addingTimeInterval(60)
        try context.save()
        fetched = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(fetched[0].note, "Updated")

        fetched[0].softDelete(at: date.addingTimeInterval(120))
        try context.save()
        fetched = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertNotNil(fetched[0].deletedAt)
    }

    func testDiskPersistenceSurvivesContainerRecreation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalFinanceOS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let storeURL = directory.appendingPathComponent("Wave1.store")
        let transactionID = UUID()
        let occurredAt = Date(timeIntervalSince1970: 1_704_067_800)

        var firstContainer: ModelContainer? = try makeDiskContainer(url: storeURL)
        var firstContext: ModelContext? = ModelContext(firstContainer!)
        firstContext?.insert(FinanceTransaction(
            id: transactionID,
            type: .expense,
            amountMinorUnits: 4_200,
            occurredAt: occurredAt,
            localDayKey: "2024-01-01",
            timeZoneIdentifier: "Asia/Shanghai",
            accountID: UUID(),
            categoryID: UUID(),
            note: "Restart proof"
        ))
        try firstContext?.save()
        firstContext = nil
        firstContainer = nil

        let secondContainer = try makeDiskContainer(url: storeURL)
        let secondContext = ModelContext(secondContainer)
        let fetched = try secondContext.fetch(FetchDescriptor<FinanceTransaction>())

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].id, transactionID)
        XCTAssertEqual(fetched[0].amountMinorUnits, 4_200)
        XCTAssertEqual(fetched[0].occurredAt, occurredAt)
        XCTAssertEqual(fetched[0].localDayKey, "2024-01-01")
        XCTAssertEqual(fetched[0].timeZoneIdentifier, "Asia/Shanghai")
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "Wave1MemoryTests",
            schema: AppSchema.schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: AppSchema.schema,
            configurations: [configuration]
        )
    }

    private func makeDiskContainer(url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "Wave1DiskTests",
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
