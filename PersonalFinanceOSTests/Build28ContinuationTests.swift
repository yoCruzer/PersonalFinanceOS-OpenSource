import Foundation
import SwiftData
import XCTest
@testable import PersonalFinanceOS

@MainActor
final class Build28ContinuationTests: XCTestCase {
    func testDeletedBooksAndCoursesOnlySuppressTheirActualSuccessors() throws {
        try assertDeletion("expense.health-education.books",
            suppressed: ["expense.education.books", "expense.education.stationery"],
            allowed: ["expense.education", "expense.education.courses", "expense.education.school-fees", "expense.education.exams", "expense.health"])
        try assertDeletion("expense.health-education.courses",
            suppressed: ["expense.education.courses"],
            allowed: ["expense.education", "expense.education.books", "expense.education.school-fees", "expense.education.exams"])
    }

    func testDeletedSubscriptionsAndSportsDoNotSuppressUnrelatedPurchases() throws {
        try assertDeletion("expense.entertainment.subscriptions",
            suppressed: ["expense.digital-services.media", "expense.digital-services.reading", "expense.digital-services.software", "expense.digital-services.ai-tools", "expense.digital-services.cloud-storage", "expense.digital-services.hosting", "expense.hobbies.gym"],
            allowed: ["expense.digital-services", "expense.digital-services.phone-plan", "expense.digital-services.broadband", "expense.entertainment.movie", "expense.entertainment.game-purchase"])
        try assertDeletion("expense.entertainment.sports",
            suppressed: ["expense.hobbies.gym", "expense.hobbies.venue", "expense.hobbies.coaching", "expense.hobbies.gear", "expense.hobbies.camping"],
            allowed: ["expense.hobbies", "expense.hobbies.camera", "expense.hobbies.music-art"])
    }

    func testOtherLeavesAreNotDeletionOfTheirWholeFormerRoot() throws {
        try assertDeletion("expense.shopping.other",
            suppressed: ["expense.household.other", "expense.clothing.other", "expense.devices.other", "expense.childcare.other", "expense.personal-care.other"],
            allowed: ["expense.household", "expense.clothing", "expense.devices", "expense.childcare", "expense.personal-care", "expense.clothing.clothes"])
        try assertDeletion("expense.health-education.other",
            suppressed: ["expense.health.other", "expense.education.other"],
            allowed: ["expense.health", "expense.education", "expense.health.medicine", "expense.education.books", "expense.education.courses"])
    }

    func testSpecificGoodsAndGatheringsDoNotDeleteSiblingPurposes() throws {
        try assertDeletion("expense.shopping.daily-goods",
            suppressed: ["expense.household.paper-cleaning", "expense.household.toiletries", "expense.household.kitchen"],
            allowed: ["expense.household", "expense.household.furniture", "expense.household.appliances", "expense.household.appliance-service"])
        try assertDeletion("expense.shopping.beauty",
            suppressed: ["expense.personal-care.skincare", "expense.personal-care.makeup", "expense.personal-care.beauty"],
            allowed: ["expense.personal-care", "expense.personal-care.haircut", "expense.personal-care.hair-treatment", "expense.personal-care.massage"])
        try assertDeletion("expense.entertainment.gatherings",
            suppressed: ["expense.entertainment.tabletop", "expense.entertainment.karaoke-bar", "expense.dining.regular-meal"],
            allowed: ["expense.entertainment.movie", "expense.entertainment.show", "expense.entertainment.game-purchase", "expense.entertainment.game-topup"])
        try assertDeletion("expense.travel.shopping",
            suppressed: ["expense.gifts.gifts", "expense.devices.phone"],
            allowed: ["expense.gifts.charity", "expense.gifts.family-support", "expense.household.appliance-service", "expense.clothing.laundry", "expense.clothing.repair", "expense.devices.repair", "expense.personal-care.haircut", "expense.personal-care.massage"], emptyCatalog: true)
    }

    func testDeletedMedicalDoesNotSuppressIndependentCheckupOrWellnessInIncompleteCatalog() throws {
        // A legal partial catalog has no old checkup/wellness rows. Their absence
        // is not deletion intent; only the old medical-and-medicine key is deleted.
        try assertDeletion("expense.health-education.medical",
            suppressed: ["expense.health.outpatient", "expense.health.medicine", "expense.health.inpatient", "expense.health.rehab"],
            allowed: ["expense.health", "expense.health.checkup", "expense.health.wellness"], emptyCatalog: true)
    }

    func testDeletedBroadRootStillProtectsBothSuccessorFamilies() throws {
        try assertDeletion("expense.health-education",
            suppressed: ["expense.education", "expense.education.books", "expense.education.exams", "expense.health", "expense.health.medicine"],
            allowed: ["expense.pets", "expense.pets.food", "expense.digital-services"])
        try assertDeletion("expense.shopping",
            suppressed: ["expense.household", "expense.clothing", "expense.devices", "expense.childcare", "expense.personal-care"],
            allowed: ["expense.education", "expense.health"])
    }

    func testBooksDeletionCompletionIsIdempotentAndPreservesHistoricalRows() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: context)
        let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<AppMetadata>()).first)
        metadata.deletedDefaultCategoryKeys.insert("expense.health-education.books")
        let books = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).first { $0.defaultDefinitionKey == "expense.health-education.books" })
        books.isHidden = true
        context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 123,
            occurredAt: Date(), localDayKey: "2020-01-01", timeZoneIdentifier: "GMT", categoryID: books.id))
        try context.save()
        let before = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: context))
        let sync = ICloudSyncController()
        await sync.disable()
        _ = try await CategoryCatalogService.completeMissing(in: ModelContext(context.container), sync: sync, changes: LedgerChangeCenter())
        let first = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: ModelContext(context.container)))
        _ = try await CategoryCatalogService.completeMissing(in: ModelContext(context.container), sync: sync, changes: LedgerChangeCenter())
        let second = try LedgerSnapshotCodec.records(LedgerSnapshotCodec.capture(in: ModelContext(context.container)))
        XCTAssertEqual(first, second)
        for (key, value) in before where key.hasPrefix("categories:") || key.hasPrefix("transactions:") {
            XCTAssertEqual(second[key], value)
        }
        let rows = try ModelContext(context.container).fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertTrue(rows.contains { $0.defaultDefinitionKey == "expense.education.exams" })
        XCTAssertFalse(rows.contains { $0.defaultDefinitionKey == "expense.education.books" })
        XCTAssertFalse(rows.contains { $0.defaultDefinitionKey == "expense.education.stationery" })
    }

    func testRealReadBoundaryReleaseRecoversWithoutBusinessNotification() async throws {
        try await assertBoundaryRecovery(modifyWhileWaiting: false)
    }

    func testRealMutationWhileWaitingPublishesFreshMetrics() async throws {
        try await assertBoundaryRecovery(modifyWhileWaiting: true)
    }

    private func assertBoundaryRecovery(modifyWhileWaiting: Bool) async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        _ = LedgerSaveRevision.shared
        context.insert(AppMetadata(createdAt: .distantPast))
        try context.save()
        let originalStamp = LedgerSaveRevision.shared.contentRevision
        let container = context.container
        let reader = LedgerUsageMetricsActor(modelContainer: container)
        let gate = ContinuationBoundaryGate()
        let holder = Task.detached { gate.holdBoundary() }
        let acquired = await Task.detached { gate.waitUntilAcquired() }.value
        XCTAssertTrue(acquired)
        defer { gate.release.signal() }
        let attempts = ContinuationAttempts()
        let store = LedgerUsageMetricsStore()
        await store.refreshIfNeeded(revision: 1) {
            await attempts.increment()
            do { return try await reader.compute() }
            catch ReconcileRevision.Failure.stalePlan {
                // The real lock made BOTH immediate actor attempts fail. Release it
                // without a notification or another refreshIfNeeded call.
                gate.release.signal()
                await holder.value
                if modifyWhileWaiting {
                    await MainActor.run {
                        let context = ModelContext(container)
                        context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 100,
                            occurredAt: Date(), localDayKey: "2024-01-02", timeZoneIdentifier: "GMT"))
                        do { try context.save() } catch { XCTFail("\(error)") }
                    }
                }
                throw ReconcileRevision.Failure.stalePlan
            }
        }
        await holder.value
        XCTAssertEqual(store.metrics?.activeTransactionCount, modifyWhileWaiting ? 1 : 0)
        XCTAssertEqual(store.metrics?.earliestLocalDayKey, modifyWhileWaiting ? "2024-01-02" : nil)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
        let count = await attempts.count
        XCTAssertEqual(count, 2)
        if !modifyWhileWaiting { XCTAssertEqual(LedgerSaveRevision.shared.contentRevision, originalStamp) }
    }

    func testPublicationConflictRereadsAndPublishesCurrentVersion() async throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        context.insert(AppMetadata(createdAt: .distantPast))
        try context.save()
        let reader = LedgerUsageMetricsActor(modelContainer: context.container)
        let stale = try await reader.compute()
        context.insert(FinanceTransaction(type: .expense, amountMinorUnits: 100,
            occurredAt: Date(), localDayKey: "2023-03-04", timeZoneIdentifier: "GMT"))
        try context.save()
        let store = LedgerUsageMetricsStore()
        let attempts = ContinuationAttempts()
        await store.refreshIfNeeded(revision: 1) {
            await attempts.increment()
            if await attempts.count == 1 { return stale }
            return try await reader.compute()
        }
        let count = await attempts.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.metrics?.activeTransactionCount, 1)
        XCTAssertEqual(store.metrics?.earliestLocalDayKey, "2023-03-04")
        XCTAssertEqual(store.revisionAtComputation, 1)
        XCTAssertNil(store.errorMessage)
    }

    func testPersistentContentionStopsAndManualRetryRemainsAvailable() async {
        let store = LedgerUsageMetricsStore()
        let attempts = ContinuationAttempts()
        await store.refreshIfNeeded(revision: 1) {
            await attempts.increment()
            throw ReconcileRevision.Failure.stalePlan
        }
        let count = await attempts.count
        XCTAssertEqual(count, 5)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.revisionAtComputation)
        XCTAssertFalse(store.isLoading)
        await store.refreshIfNeeded(revision: 1) { Self.value(7) }
        XCTAssertEqual(store.metrics?.activeTransactionCount, 7)
        XCTAssertNil(store.errorMessage)
    }

    func testRealErrorsDoNotRetryOrBecomeSuccess() async {
        let store = LedgerUsageMetricsStore()
        let attempts = ContinuationAttempts()
        await store.refreshIfNeeded(revision: 1) { Self.value(3) }
        await store.refreshIfNeeded(revision: 2) {
            await attempts.increment()
            throw CocoaError(.fileReadCorruptFile)
        }
        let count = await attempts.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.metrics?.activeTransactionCount, 3)
        XCTAssertEqual(store.revisionAtComputation, 1)
        XCTAssertEqual(store.errorMessage, CocoaError(.fileReadCorruptFile).localizedDescription)
    }

    func testCancellationDuringRetryWaitStopsReadsAndPreservesValues() async {
        let store = LedgerUsageMetricsStore()
        await store.refreshIfNeeded(revision: 1) { Self.value(3) }
        let attempted = expectation(description: "transient read attempted")
        let attempts = ContinuationAttempts()
        let request = Task {
            await store.refreshIfNeeded(revision: 2) {
                await attempts.increment()
                attempted.fulfill()
                throw ReconcileRevision.Failure.stalePlan
            }
        }
        await fulfillment(of: [attempted], timeout: 3)
        request.cancel()
        await request.value
        let count = await attempts.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.metrics?.activeTransactionCount, 3)
        XCTAssertEqual(store.revisionAtComputation, 1)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }

    func testSupersededRetryCannotReadAgainOrOverwriteNewRequest() async {
        let store = LedgerUsageMetricsStore()
        let attempted = expectation(description: "old read attempted")
        let attempts = ContinuationAttempts()
        let old = Task {
            await store.refreshIfNeeded(revision: 1) {
                await attempts.increment()
                attempted.fulfill()
                throw ReconcileRevision.Failure.stalePlan
            }
        }
        await fulfillment(of: [attempted], timeout: 3)
        store.invalidatePendingRequest()
        await store.refreshIfNeeded(revision: 2) { Self.value(9) }
        await old.value
        let count = await attempts.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.metrics?.activeTransactionCount, 9)
        XCTAssertEqual(store.revisionAtComputation, 2)
        XCTAssertNil(store.errorMessage)
    }

    nonisolated private static func value(_ count: Int) -> LedgerUsageMetricsComputation {
        .init(metrics: .init(appCreatedAt: .distantPast, activeTransactionCount: count,
            earliestLocalDayKey: "2020-01-01", distinctActiveDayCount: 1),
            scannedRecordCount: count, maximumBatchCount: count)
    }

    private func assertDeletion(_ key: String, suppressed: [String], allowed: [String], emptyCatalog: Bool = false) throws {
        let context = ModelContext(try ModelContainerFactory.make(isStoredInMemoryOnly: true))
        try seedFrozenV3Ledger(in: context)
        let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<AppMetadata>()).first)
        metadata.deletedDefaultCategoryKeys.insert(key)
        try context.save()
        let snapshot = try CategoryCatalogService.capture(in: context)
        let plan = CategoryCatalogPlanner.additions(catalog: try CategoryCatalog.load(),
            snapshot: emptyCatalog ? .init(categories: [], metadata: snapshot.metadata) : snapshot, readiness: .offline)
        for semantic in suppressed {
            let entry = try XCTUnwrap(plan.entries.first { $0.id == semantic })
            XCTAssertFalse(entry.selectedByDefault, "\(key) must protect \(semantic)")
            XCTAssertEqual(entry.installation, .suppressedByUserIntent, "\(key) → \(semantic)")
        }
        for semantic in allowed {
            let entry = try XCTUnwrap(plan.entries.first { $0.id == semantic })
            XCTAssertTrue(entry.selectedByDefault, "\(key) must allow \(semantic)")
        }
    }
}

private actor ContinuationAttempts {
    private(set) var count = 0
    func increment() { count += 1 }
}

private final class ContinuationBoundaryGate: @unchecked Sendable {
    let acquired = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func holdBoundary() {
        LedgerSaveRevision.shared.withImportBoundary {
            acquired.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        }
    }
    func waitUntilAcquired() -> Bool { acquired.wait(timeout: .now() + 10) == .success }
}
