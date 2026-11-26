import Foundation
import SwiftData
import XCTest
@testable import PersonalFinanceOS

private final class MetadataBoundaryGate: @unchecked Sendable {
    func waitForValidation() -> Bool { validated.wait(timeout: .now() + 10) == .success }
    func didContend() -> Bool { contention.wait(timeout: .now()) == .success }
    let contention = DispatchSemaphore(value: 0)
    let validated = DispatchSemaphore(value: 0)
    let deletionReachedBoundaryOrFinished = DispatchSemaphore(value: 0)
}

@MainActor
final class ImportMetadataBoundaryTests: XCTestCase {
    func testOrdinaryCaptureReturnsBusyWhileImportOwnsBoundaryAndPreservesDraft() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.insert(AppMetadata())
        let account = Account(name: "Review account", type: .cash, isDefault: true)
        let category = PersonalFinanceOS.Category(kind: .expense, name: "餐饮", symbolName: "fork.knife", colorToken: "orange")
        context.insert(account)
        context.insert(category)
        try context.save()
        let csv = "type,amount,date_time,category,account\nexpense,12.34,2026-01-01 10:00,餐饮,Review account"
        let document = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: "capture.csv")
        let plan = try FinanceCSVService.makePlan(document: document, mapping: FinanceCSVService.autoMapping(headers: document.headers), fileName: "capture.csv", existingTransactions: [])
        let model = FinanceCSVService.makeImportModelSnapshot(accounts: [account], categories: [category], tags: [])
        let request = try FinanceCSVService.makeBackgroundCommitRequest(plan: plan, modelSnapshot: model, createMissingCategories: false, rememberedCategoryMappings: [:])
        let catalogSync = ICloudSyncController()
        await catalogSync.disable()
        let catalogPreview = try await CategoryCatalogService.preview(in: context, sync: catalogSync)
        let catalogChanges = LedgerChangeCenter()
        let gate = MetadataBoundaryGate()
        let importer = ImportCommitActor(modelContainer: container)
        let importing = Task {
            try await importer.commit(request, afterDependencyValidation: {
                XCTAssertFalse(Thread.isMainThread)
                gate.validated.signal()
                guard gate.deletionReachedBoundaryOrFinished.wait(timeout: .now() + 10) == .success else {
                    throw CocoaError(.userCancelled)
                }
            })
        }
        let reached = await Task.detached { gate.waitForValidation() }.value
        XCTAssertTrue(reached)
        var draft = TransactionDraft()
        draft.amountText = "23.45"
        draft.accountID = account.id
        draft.categoryID = category.id
        draft.note = "保留输入"
        XCTAssertThrowsError(try TransactionLifecycleService.save(
            draft: draft, accounts: [account], categories: [category], in: context
        )) { XCTAssertEqual($0 as? TransactionDraftError, .busy) }
        XCTAssertThrowsError(try FinanceDataManagementService.addAccount(
            name: "等待中的账户", type: .cash, accounts: [], in: context
        )) { XCTAssertEqual($0 as? FinanceDataManagementError, .busy) }
        XCTAssertThrowsError(try FinanceDataManagementService.addCategory(
            name: "等待中的分类", kind: .expense, categories: [], in: context
        )) { XCTAssertEqual($0 as? FinanceDataManagementError, .busy) }
        XCTAssertThrowsError(try FinanceDataManagementService.addTag(
            name: "等待中的标签", tags: [], in: context
        )) { XCTAssertEqual($0 as? FinanceDataManagementError, .busy) }
        XCTAssertThrowsError(try DefaultFinanceDataService.ensureDefaults(in: context)) {
            XCTAssertEqual($0 as? FinanceDataManagementError, .busy)
        }
        let metadataEdits: [() throws -> Void] = [
            { try FinanceDataManagementService.rename(account: account, to: "改名", in: context) },
            { try FinanceDataManagementService.setDefault(account, accounts: [], in: context) },
            { try FinanceDataManagementService.setAccountActive(account, isActive: false, accounts: [], in: context) },
            { try FinanceDataManagementService.rename(category: category, to: "改名", in: context) },
            { try FinanceDataManagementService.update(category: category, name: "改名", symbolName: "star", in: context) },
            { try FinanceDataManagementService.update(category: category, name: "改名", parentID: nil, symbolName: "star", categories: [], in: context) },
            { try FinanceDataManagementService.reorderCategories(orderedIDs: [category.id], kind: .expense, parentID: nil, categories: [], in: context) },
            { try FinanceDataManagementService.setCategoryActive(category, isActive: false, categories: [], in: context) }
        ]
        for edit in metadataEdits {
            XCTAssertThrowsError(try edit()) { XCTAssertEqual($0 as? FinanceDataManagementError, .busy) }
        }
        XCTAssertThrowsError(try CategoryCatalogService.commit(
            catalogPreview, selected: ["expense.vehicle"], in: context,
            sync: catalogSync, changes: catalogChanges
        ))
        XCTAssertEqual(catalogChanges.revision, 0)
        // Release only after the synchronous MainActor save returned: a blocking lock
        // cannot satisfy this handshake and will fail the import's bounded timeout.
        gate.deletionReachedBoundaryOrFinished.signal()
        let result = try await importing.value
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(draft.note, "保留输入")
        let saved = try TransactionLifecycleService.save(
            draft: draft, accounts: [account], categories: [category], in: context
        )
        XCTAssertEqual(saved.amountMinorUnits, 2345)
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(container))
        XCTAssertEqual(package.transactions.count, 2)
        XCTAssertNoThrow(try NativeBackupService.validate(package))
    }

    func testRestoreRechecksPristineEligibilityAfterConcurrentImportCommits() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        try DefaultFinanceDataService.ensureDefaults(in: context)
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let account = try XCTUnwrap(accounts.first)
        let data = try await NativeBackupActor(modelContainer: container).exportData()
        let csv = "type,amount,date_time,category,account\nexpense,12.34,2026-01-01 10:00,餐饮 / 早餐,\(account.name)"
        let document = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: "restore-race.csv")
        let plan = try FinanceCSVService.makePlan(document: document, mapping: FinanceCSVService.autoMapping(headers: document.headers), fileName: "restore-race.csv", existingTransactions: [])
        let model = FinanceCSVService.makeImportModelSnapshot(accounts: accounts, categories: categories, tags: [])
        let request = try FinanceCSVService.makeBackgroundCommitRequest(plan: plan, modelSnapshot: model, createMissingCategories: false, rememberedCategoryMappings: [:])
        let gate = MetadataBoundaryGate()
        let importer = ImportCommitActor(modelContainer: container)
        let importing = Task {
            try await importer.commit(request, afterDependencyValidation: {
                XCTAssertFalse(Thread.isMainThread)
                gate.validated.signal()
                guard gate.deletionReachedBoundaryOrFinished.wait(timeout: .now() + 10) == .success else {
                    throw CocoaError(.userCancelled)
                }
            })
        }
        let reached = await Task.detached { gate.waitForValidation() }.value
        XCTAssertTrue(reached)
        let restoring = Task { () -> Bool in
            defer { gate.deletionReachedBoundaryOrFinished.signal() }
            do {
                _ = try await NativeBackupActor(modelContainer: container).restore(data: data, admission: offlineRestoreTicket(for: container), onBoundaryContention: {
                    XCTAssertFalse(Thread.isMainThread)
                    gate.contention.signal()
                    gate.deletionReachedBoundaryOrFinished.signal()
                })
                return false
            } catch NativeBackupError.destinationContainsUserLedger {
                return true
            }
        }
        let rejected = try await restoring.value
        let imported = try await importing.value
        XCTAssertTrue(gate.didContend())
        XCTAssertTrue(rejected)
        XCTAssertEqual(imported.importedCount, 1)
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(container))
        XCTAssertEqual(package.transactions.map(\.id), request.transactions.map(\.id))
        XCTAssertEqual(package.transactions.first?.amountMinorUnits, 1234)
        XCTAssertEqual(package.transactions.first?.importBatchID, request.batchID)
        XCTAssertEqual(package.importBatches.first?.status, .completed)
        XCTAssertNoThrow(try NativeBackupService.validate(package))
    }

    func testBatchCategoryWaitsForImportAndReadsCommittedSelection() async throws {
        try await assertWriterWaitsForImport(rollback: false)
    }

    func testRollbackWaitsForImportAndReadsCommittedBatch() async throws {
        try await assertWriterWaitsForImport(rollback: true)
    }

    private func assertWriterWaitsForImport(rollback: Bool) async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.insert(AppMetadata())
        context.insert(Account(name: "Review account", type: .cash, isDefault: true))
        let root = PersonalFinanceOS.Category(kind: .expense, name: "餐饮", symbolName: "fork.knife", colorToken: "orange")
        let target = PersonalFinanceOS.Category(kind: .expense, name: "Other", symbolName: "folder", colorToken: "blue")
        context.insert(root)
        context.insert(target)
        try context.save()
        let targetID = target.id
        let csv = "type,amount,date_time,category,account\nexpense,12.34,2026-01-01 10:00,餐饮 / Child,Review account"
        let document = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: "boundary.csv")
        let plan = try FinanceCSVService.makePlan(document: document, mapping: FinanceCSVService.autoMapping(headers: document.headers), fileName: "boundary.csv", existingTransactions: [])
        let model = FinanceCSVService.makeImportModelSnapshot(accounts: try context.fetch(FetchDescriptor<Account>()), categories: try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), tags: [])
        let request = try FinanceCSVService.makeBackgroundCommitRequest(plan: plan, modelSnapshot: model, createMissingCategories: true, rememberedCategoryMappings: [:])
        let transactionID = try XCTUnwrap(request.transactions.first?.id)
        let gate = MetadataBoundaryGate()
        let importer = ImportCommitActor(modelContainer: container)
        let importing = Task {
            try await importer.commit(request, afterDependencyValidation: {
                XCTAssertFalse(Thread.isMainThread)
                gate.validated.signal()
                guard gate.deletionReachedBoundaryOrFinished.wait(timeout: .now() + 10) == .success else {
                    throw CocoaError(.userCancelled)
                }
            })
        }
        let reachedValidation = await Task.detached { gate.waitForValidation() }.value
        XCTAssertTrue(reachedValidation)
        let mutation = Task {
            defer { gate.deletionReachedBoundaryOrFinished.signal() }
            let contention: @Sendable () -> Void = {
                XCTAssertFalse(Thread.isMainThread)
                gate.contention.signal()
                gate.deletionReachedBoundaryOrFinished.signal()
            }
            if rollback {
                let result = try await ImportRollbackActor(modelContainer: container).rollback(
                    batchID: request.batchID, preserveEdited: true, onBoundaryContention: contention
                )
                XCTAssertEqual(result.deletedCount, 0)
                XCTAssertEqual(result.preservedEditedCount, 0)
                XCTAssertEqual(result.preservedUncertainCount, 1)
            } else {
                _ = try await LedgerBatchOperationActor(modelContainer: container).migrateCategory(
                    selectedIDs: [transactionID], targetID: targetID, onBoundaryContention: contention
                )
            }
        }
        try await mutation.value
        let imported = try await importing.value
        XCTAssertEqual(imported.importedCount, 1)
        XCTAssertTrue(gate.didContend())
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(container))
        let transaction = try XCTUnwrap(package.transactions.first)
        XCTAssertEqual(package.transactions.count, 1)
        XCTAssertEqual(transaction.id, transactionID)
        XCTAssertEqual(transaction.amountMinorUnits, 1234)
        XCTAssertEqual(transaction.importBatchID, request.batchID)
        if rollback {
            XCTAssertNil(transaction.deletedAt)
            XCTAssertEqual(package.importBatches.first?.status, .completed)
        } else {
            XCTAssertNil(transaction.deletedAt)
            XCTAssertEqual(transaction.categoryID, targetID)
        }
        XCTAssertNoThrow(try NativeBackupService.validate(package))
    }

    func testParentDeletionAfterImportValidationMustRecheckChildrenInsideBoundary() async throws {
        let container = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.insert(AppMetadata())
        context.insert(Account(name: "Review account", type: .cash, isDefault: true))
        let root = PersonalFinanceOS.Category(kind: .expense, name: "餐饮", symbolName: "fork.knife", colorToken: "orange")
        context.insert(root)
        context.insert(PersonalFinanceOS.Category(kind: .expense, name: "Other", symbolName: "folder", colorToken: "blue"))
        try context.save()
        let rootID = root.id
        let csv = "type,amount,date_time,category,account\nexpense,12.34,2026-01-01 10:00,餐饮 / Child,Review account"
        let document = try FinanceCSVService.readImportDocument(data: Data(csv.utf8), fileName: "boundary.csv")
        let plan = try FinanceCSVService.makePlan(document: document, mapping: FinanceCSVService.autoMapping(headers: document.headers), fileName: "boundary.csv", existingTransactions: [])
        let model = FinanceCSVService.makeImportModelSnapshot(accounts: try context.fetch(FetchDescriptor<Account>()), categories: try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()), tags: [])
        let request = try FinanceCSVService.makeBackgroundCommitRequest(plan: plan, modelSnapshot: model, createMissingCategories: true, rememberedCategoryMappings: [:])
        XCTAssertEqual(request.categoriesToCreate.first?.parentID, rootID)
        let gate = MetadataBoundaryGate()
        let importer = ImportCommitActor(modelContainer: container)
        let importing = Task {
            try await importer.commit(request, afterDependencyValidation: {
                XCTAssertFalse(Thread.isMainThread)
                gate.validated.signal()
                guard gate.deletionReachedBoundaryOrFinished.wait(timeout: .now() + 10) == .success else {
                    throw CocoaError(.userCancelled)
                }
            })
        }
        let reachedValidation = await Task.detached { gate.waitForValidation() }.value
        XCTAssertTrue(reachedValidation)
        let deleting = Task { () -> Bool in
            defer { gate.deletionReachedBoundaryOrFinished.signal() }
            let writer = MetadataMutationActor(modelContainer: container)
            // Cache the old "no children" view before trying the actual mutation.
            let analysis = try await writer.analyzeCategory(id: rootID)
            XCTAssertEqual(analysis.analysis.childObjectCount, 0)
            do {
                _ = try await writer.deleteCategory(id: rootID, targetID: nil, onBoundaryContention: {
                    XCTAssertFalse(Thread.isMainThread)
                    gate.contention.signal()
                    gate.deletionReachedBoundaryOrFinished.signal()
                })
                return false
            } catch FinanceDataManagementError.categoryHasChildren {
                return true
            }
        }
        let deletionWasRejectedAfterRecheck = try await deleting.value
        let result = try await importing.value
        XCTAssertTrue(gate.didContend())
        XCTAssertTrue(deletionWasRejectedAfterRecheck)
        XCTAssertEqual(result.importedCount, 1)
        let package = try LedgerSnapshotCodec.capture(in: ModelContext(container))
        XCTAssertEqual(package.transactions.count, 1)
        XCTAssertEqual(package.importBatches.count, 1)
        XCTAssertEqual(package.importBatches.first?.importedRowCount, 1)
        XCTAssertEqual(package.transactions.first?.importBatchID, request.batchID)
        XCTAssertEqual(package.transactions.first?.amountMinorUnits, 1234)
        XCTAssertTrue(package.categories.contains { $0.id == rootID })
        XCTAssertEqual(package.categories.first { $0.id == request.categoriesToCreate.first?.id }?.parentID, rootID)
        XCTAssertNoThrow(try NativeBackupService.validate(package))
    }
}
