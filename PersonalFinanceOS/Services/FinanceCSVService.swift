import Foundation
import SwiftData

enum FinanceCSVService {
    static let importCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hans_CN")
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    static let exportHeaders = [
        "transaction_id", "type", "amount", "currency", "category",
        "category_icon", "account", "date_time", "time_zone_identifier",
        "local_day_key", "merchant", "note", "tags", "created_at", "updated_at"
    ]

    static let legacyPersonalFinanceOSHeaders = [
        "transaction_id", "type", "amount", "currency", "category",
        "category_icon", "account", "date_time", "note", "tags",
        "created_at", "updated_at"
    ]

    static func isLegacyPersonalFinanceOSCSV(headers: [String]) -> Bool {
        headers.map(BillTextNormalization.header) ==
            legacyPersonalFinanceOSHeaders.map(BillTextNormalization.header)
    }

    static func readImportDocument(data: Data, fileName: String) throws -> BillImportDocument {
        try TabularBillFileReader.read(data: data, fileName: fileName)
    }

    static func parseDocument(data: Data) throws -> CSVDocument {
        try TabularBillFileReader.readCSV(data: data)
    }

    static func autoMapping(headers: [String]) -> CSVColumnMapping {
        let normalizedHeaders = headers.map(BillTextNormalization.header)
        func index(_ aliases: [String], exactOnly: Bool = false) -> Int? {
            let normalized = aliases.map(BillTextNormalization.header)
            for alias in normalized {
                if let index = normalizedHeaders.firstIndex(of: alias) { return index }
            }
            guard !exactOnly else { return nil }
            return normalizedHeaders.firstIndex { header in normalized.contains { header.contains($0) } }
        }
        return CSVColumnMapping(
            type: index(["type", "收/支", "收支", "收支类型", "交易类型", "类型"]),
            amount: index(["amount", "金额", "交易金额", "金额(元)"]),
            dateTime: index(["date_time", "datetime", "交易时间", "日期时间", "日期", "时间"]),
            category: index(["category", "分类", "一级分类", "交易分类", "类别"]),
            account: index(["account", "账户", "支付账户", "支付方式", "收/付款方式", "收付账户"]),
            note: index(["note", "备注", "商品说明", "交易说明", "项目", "交易对方"]),
            tags: index(["tags", "标签"]),
            transactionID: index(["transaction_id", "交易单号", "交易订单号", "流水号", "id"], exactOnly: true)
        )
    }

    static func makePlan(
        document: CSVDocument,
        mapping: CSVColumnMapping,
        fileName: String,
        existingTransactions: [FinanceTransaction],
        parserMode: BillImportParserMode = .automatic,
        calendar: Calendar = importCalendar
    ) throws -> ImportPlan {
        let headers = document.headers
        let detection = BillSourceDetector.detect(headers: headers, preambleRows: [], sheetName: nil)
        let rows = document.rows.enumerated().map { offset, cells in
            TabularRow(number: offset + 2, cells: cells.map { TabularCell(text: $0) })
        }
        let imported = BillImportDocument(
            format: .csv,
            encodingName: document.encodingName,
            sheetName: nil,
            excelDateSystem: nil,
            rawRowCount: rows.count + 1,
            headerRowNumber: 1,
            headers: headers,
            rows: rows,
            nonTransactionRowCount: 1,
            detection: detection,
            formatMismatchMessage: nil
        )
        return try makePlan(
            document: imported,
            mapping: mapping,
            fileName: fileName,
            existingTransactions: existingTransactions,
            parserMode: parserMode,
            calendar: calendar
        )
    }

    static func makePlan(
        document: BillImportDocument,
        mapping: CSVColumnMapping,
        fileName: String,
        existingTransactions: [FinanceTransaction],
        parserMode: BillImportParserMode = .automatic,
        calendar: Calendar = importCalendar
    ) throws -> ImportPlan {
        try makePlan(
            document: document,
            mapping: mapping,
            fileName: fileName,
            existingRecords: try existingTransactions.first?.modelContext.map {
                try ImportDuplicateRecord.snapshot(existingTransactions, in: $0)
            } ?? existingTransactions.map(ImportDuplicateRecord.init),
            parserMode: parserMode,
            calendar: calendar
        )
    }

    static func makePlan(
        document: BillImportDocument,
        mapping: CSVColumnMapping,
        fileName: String,
        existingRecords: [ImportDuplicateRecord],
        parserMode: BillImportParserMode = .automatic,
        calendar: Calendar = importCalendar
    ) throws -> ImportPlan {
        let parsed = try parsePlan(
            document: document,
            mapping: mapping,
            fileName: fileName,
            parserMode: parserMode,
            calendar: calendar
        )
        return assessDuplicates(parsed, existingRecords: existingRecords)
    }

    static func parsePlan(
        document: BillImportDocument,
        mapping: CSVColumnMapping,
        fileName: String,
        parserMode: BillImportParserMode = .automatic,
        calendar: Calendar = importCalendar
    ) throws -> ParsedImportPlan {
        try Task.checkCancellation()
        let sourceIdentity = document.detection.source
        let parser: any BillSourceParsing = switch parserMode {
        case .generic:
            GenericTabularBillParser(source: sourceIdentity, mapping: mapping)
        case .automatic:
            specializedParser(for: document.detection.source, mapping: mapping)
        }
        let parsed: ParsedBillRows
        let parsingMethod: BillImportParsingMethod
        do {
            parsed = try parser.parse(document: document, calendar: calendar)
            parsingMethod = parser is GenericTabularBillParser ? .genericMapping : .specialized
        } catch BillImportError.missingRequiredColumns where parserMode == .automatic
            && mapping.amount != nil && mapping.dateTime != nil {
            let generic = GenericTabularBillParser(source: sourceIdentity, mapping: mapping)
            parsed = try generic.parse(document: document, calendar: calendar)
            parsingMethod = .genericMapping
        }
        try Task.checkCancellation()
        let fallbackReasons: [String]
        if parserMode == .generic {
            fallbackReasons = ["用户选择通用字段映射"]
        } else if parsingMethod == .genericMapping && sourceIdentity != .genericCSV {
            fallbackReasons = ["专用解析缺少核心字段，已自动降级为通用字段映射"]
        } else {
            fallbackReasons = []
        }
        return ParsedImportPlan(
            source: sourceIdentity,
            parsingMethod: parsingMethod,
            sourceDisplayName: fileName,
            fileFormat: document.format,
            encodingName: document.encodingName,
            sheetName: document.sheetName,
            sourceDetectionReasons: document.detection.reasons + fallbackReasons,
            rawRowCount: document.rawRowCount,
            nonTransactionRowCount: document.nonTransactionRowCount,
            totalRows: document.rows.count,
            candidates: parsed.candidates,
            rowIssues: parsed.issues
        )
    }

    static func assessDuplicates(
        _ parsed: ParsedImportPlan,
        existingRecords: [ImportDuplicateRecord]
    ) -> ImportPlan {
        let candidates = markDuplicates(
            parsed.candidates,
            source: parsed.source,
            existingRecords: existingRecords
        )
        return ImportPlan(
            source: parsed.source,
            parsingMethod: parsed.parsingMethod,
            sourceDisplayName: parsed.sourceDisplayName,
            fileFormat: parsed.fileFormat,
            encodingName: parsed.encodingName,
            sheetName: parsed.sheetName,
            sourceDetectionReasons: parsed.sourceDetectionReasons,
            rawRowCount: parsed.rawRowCount,
            nonTransactionRowCount: parsed.nonTransactionRowCount,
            totalRows: parsed.totalRows,
            candidates: candidates,
            rowIssues: parsed.rowIssues
        )
    }

    @MainActor
    static func commit(
        plan: ImportPlan,
        accounts: [Account],
        categories: [Category],
        tags: [Tag],
        in context: ModelContext,
        createMissingCategories: Bool = false,
        createMissingAccounts: Bool = false,
        createMissingTags: Bool = false,
        includeSuspectedDuplicates: Bool = true,
        includeConfirmedDuplicates: Bool = false,
        rememberedCategoryMappings: [String: UUID]? = nil,
        rowCategoryOverrides: [Int: UUID] = [:],
        now: Date = Date()
    ) throws -> ImportResult {
        let snapshot = makeImportModelSnapshot(accounts: accounts, categories: categories, tags: tags)
        let request = try makeBackgroundCommitRequest(
            plan: plan, modelSnapshot: snapshot,
            createMissingCategories: createMissingCategories, createMissingAccounts: createMissingAccounts,
            createMissingTags: createMissingTags, includeSuspectedDuplicates: includeSuspectedDuplicates,
            includeConfirmedDuplicates: includeConfirmedDuplicates,
            rememberedCategoryMappings: rememberedCategoryMappings ?? ImportCategoryMappingStore.mappings(categories: snapshot.categories),
            rowCategoryOverrides: rowCategoryOverrides, now: now
        )
        return try ImportCommitWriter(modelContext: context).commit(request)
    }

    @MainActor
    static func makeImportModelSnapshot(
        accounts: [Account],
        categories: [Category],
        tags: [Tag]
    ) -> ImportModelSnapshot {
        ImportModelSnapshot(
            accounts: accounts.filter { $0.currencyCode == Money.cnyCode }.map {
                ImportAccountSnapshot(
                    id: $0.id,
                    name: $0.name,
                    isDefault: $0.isDefault,
                    sortOrder: $0.sortOrder,
                    archivedAt: $0.archivedAt,
                    createdAt: $0.createdAt
                )
            },
            categories: categories.map {
                ImportCategorySnapshot(
                    id: $0.id,
                    kind: $0.kind,
                    name: $0.name,
                    parentID: $0.parentID,
                    symbolName: $0.symbolName,
                    colorToken: $0.colorToken,
                    sortOrder: $0.sortOrder,
                    isHidden: $0.isHidden,
                    archivedAt: $0.archivedAt,
                    createdAt: $0.createdAt,
                    defaultDefinitionKey: $0.defaultDefinitionKey
                )
            },
            tags: tags.map {
                ImportTagSnapshot(
                    id: $0.id,
                    name: $0.name,
                    sortOrder: $0.sortOrder,
                    archivedAt: $0.archivedAt,
                    createdAt: $0.createdAt
                )
            }
        )
    }

    static func makePreviewSnapshot(
        plan: ImportPlan,
        modelSnapshot: ImportModelSnapshot,
        includeSuspectedDuplicates: Bool,
        includeConfirmedDuplicates: Bool,
        rememberedCategoryMappings: [String: UUID],
        rowCategoryOverrides: [Int: UUID]
    ) throws -> ImportPreviewSnapshot {
        try Task.checkCancellation()
        let effectiveRows = plan.effectiveRowsToImport(
            includeSuspectedDuplicates: includeSuspectedDuplicates,
            includeConfirmedDuplicates: includeConfirmedDuplicates
        )
        let accountNames = Set(modelSnapshot.accounts.map { $0.name.lowercased() })
        let tagNames = Set(modelSnapshot.tags.map { $0.name.lowercased() })
        var resolutionsByRowNumber: [Int: ImportCategoryResolution] = [:]
        resolutionsByRowNumber.reserveCapacity(effectiveRows.count)
        var unresolvedRows: [ImportCandidate] = []
        var unresolvedGroups = Set<ImportCategoryGroupSnapshot>()
        var proposedChildren = Set<String>()
        var unknownAccounts = Set<String>()
        var unknownTags = Set<String>()
        var incomeMinorUnits: Int64 = 0
        var expenseMinorUnits: Int64 = 0
        var refundMinorUnits: Int64 = 0
        var localDays: [String] = []
        localDays.reserveCapacity(effectiveRows.count)

        for (index, row) in effectiveRows.enumerated() {
            if index.isMultiple(of: 250) { try Task.checkCancellation() }
            let kind: CategoryKind = row.type == .income ? .income : .expense
            let mappingKey = ImportCategoryMappingStore.stableKey(
                source: plan.source,
                rawCategory: row.categoryName,
                kind: kind
            )
            let resolution = ImportCategoryResolutionService.resolve(
                source: plan.source,
                rawCategory: row.categoryName,
                note: row.persistedNote,
                merchant: row.merchantName,
                type: row.type,
                kind: kind,
                categories: modelSnapshot.categories,
                rememberedCategoryID: rowCategoryOverrides[row.rowNumber]
                    ?? rememberedCategoryMappings[mappingKey]
            )
            resolutionsByRowNumber[row.rowNumber] = resolution
            if resolution.resolvedCategoryID == nil {
                unresolvedRows.append(row)
                if !row.categoryName.isEmpty {
                    unresolvedGroups.insert(ImportCategoryGroupSnapshot(
                        rawCategory: row.categoryName,
                        kind: kind
                    ))
                }
                if let rootID = resolution.proposedRootID,
                   let childName = resolution.proposedChildName {
                    proposedChildren.insert(
                        "\(rootID.uuidString)|\(ImportCategoryResolutionService.normalize(childName))"
                    )
                }
            }
            if !row.accountName.isEmpty,
               !accountNames.contains(row.accountName.lowercased()) {
                unknownAccounts.insert(row.accountName)
            }
            for name in row.tagNames where !tagNames.contains(name.lowercased()) {
                unknownTags.insert(name)
            }
            switch row.type {
            case .income:
                incomeMinorUnits = saturatingAdd(incomeMinorUnits, row.amountMinorUnits)
            case .expense:
                expenseMinorUnits = saturatingAdd(expenseMinorUnits, row.amountMinorUnits)
            case .refund:
                refundMinorUnits = saturatingAdd(refundMinorUnits, row.amountMinorUnits)
            case .transfer:
                break
            }
            if let timeZone = TimeZone(identifier: row.timeZoneIdentifier) {
                localDays.append(LocalDayKey.make(for: row.occurredAt, timeZone: timeZone))
            }
        }
        let localDayRange = localDays.min().flatMap { first in
            localDays.max().map { first...$0 }
        }

        return ImportPreviewSnapshot(
            effectiveRows: effectiveRows,
            incomeMinorUnits: incomeMinorUnits,
            expenseMinorUnits: expenseMinorUnits,
            refundMinorUnits: refundMinorUnits,
            localDayRange: localDayRange,
            duplicateCount: plan.duplicateCount,
            suspectedDuplicateCount: plan.suspectedDuplicateCount,
            withinFileDuplicateCount: plan.withinFileDuplicateCount,
            skippedCount: plan.skippedRows.count,
            failedCount: plan.failedRows.count,
            issueSummary: plan.issueSummary,
            unresolvedRows: unresolvedRows,
            unresolvedCategoryGroups: unresolvedGroups.sorted {
                if $0.rawCategory != $1.rawCategory { return $0.rawCategory < $1.rawCategory }
                return $0.kind.rawValue < $1.kind.rawValue
            },
            resolutionsByRowNumber: resolutionsByRowNumber,
            proposedChildCount: proposedChildren.count,
            unknownAccounts: unknownAccounts.sorted(),
            unknownTags: unknownTags.sorted()
        )
    }

    static func makeBackgroundCommitRequest(
        plan: ImportPlan,
        modelSnapshot: ImportModelSnapshot,
        createMissingCategories: Bool = false,
        createMissingAccounts: Bool = false,
        createMissingTags: Bool = false,
        includeSuspectedDuplicates: Bool = true,
        includeConfirmedDuplicates: Bool = false,
        rememberedCategoryMappings: [String: UUID],
        rowCategoryOverrides: [Int: UUID] = [:],
        now: Date = Date()
    ) throws -> ImportCommitRequest {
        let rowsToCommit = plan.effectiveRowsToImport(
            includeSuspectedDuplicates: includeSuspectedDuplicates,
            includeConfirmedDuplicates: includeConfirmedDuplicates
        )
        guard !rowsToCommit.isEmpty else { throw BillImportError.noValidRows }
        let retainedIntents = occurrenceIntents(for: plan.candidates, source: plan.source)
        let sortedAccounts = modelSnapshot.accounts.sorted(by: preferredAccountSnapshot)
        var workingCategories = modelSnapshot.categories.sorted(by: preferredCategorySnapshot)
        let sortedTags = modelSnapshot.tags.sorted(by: preferredTagSnapshot)
        guard let defaultAccount = sortedAccounts.first(where: { $0.archivedAt == nil }) else {
            throw TransactionDraftError.missingAccount
        }

        var accountByName: [String: UUID] = [:]
        for account in sortedAccounts where accountByName[normalize(account.name)] == nil {
            accountByName[normalize(account.name)] = account.id
        }
        var tagByName: [String: UUID] = [:]
        for tag in sortedTags where tagByName[normalize(tag.name)] == nil {
            tagByName[normalize(tag.name)] = tag.id
        }

        var accountsToCreate: [ImportCommitRequest.AccountPayload] = []
        var categoriesToCreate: [ImportCommitRequest.CategoryPayload] = []
        var tagsToCreate: [ImportCommitRequest.TagPayload] = []
        var transactions: [ImportCommitRequest.TransactionPayload] = []
        transactions.reserveCapacity(rowsToCommit.count)

        for (index, row) in rowsToCommit.enumerated() {
            if index.isMultiple(of: 250) { try Task.checkCancellation() }
            let kind: CategoryKind = row.type == .income ? .income : .expense
            let mappingKey = ImportCategoryMappingStore.stableKey(
                source: plan.source,
                rawCategory: row.categoryName,
                kind: kind
            )
            let resolution = ImportCategoryResolutionService.resolve(
                source: plan.source,
                rawCategory: row.categoryName,
                note: row.persistedNote,
                merchant: row.merchantName,
                type: row.type,
                kind: kind,
                categories: workingCategories,
                rememberedCategoryID: rowCategoryOverrides[row.rowNumber]
                    ?? rememberedCategoryMappings[mappingKey]
            )
            var categoryID = resolution.resolvedCategoryID
            if categoryID == nil,
               createMissingCategories,
               resolution.confidence == .high,
               let parentID = resolution.proposedRootID,
               let parent = workingCategories.first(where: {
                   $0.id == parentID && $0.kind == kind && $0.parentID == nil && $0.isActiveForSelection
               }),
               let leafName = resolution.proposedChildName,
               !leafName.isEmpty {
                let id = UUID()
                let sortOrder = workingCategories.filter {
                    $0.kind == kind && $0.parentID == parent.id
                }.count
                categoriesToCreate.append(.init(
                    id: id,
                    kind: kind,
                    name: leafName,
                    parentID: parent.id,
                    symbolName: CategoryIconLibrary.suggestedSymbol(for: leafName, kind: kind),
                    colorToken: parent.colorToken,
                    sortOrder: sortOrder
                ))
                workingCategories.append(ImportCategorySnapshot(
                    id: id,
                    kind: kind,
                    name: leafName,
                    parentID: parent.id,
                    symbolName: CategoryIconLibrary.suggestedSymbol(for: leafName, kind: kind),
                    colorToken: parent.colorToken,
                    sortOrder: sortOrder,
                    isHidden: false,
                    archivedAt: nil,
                    createdAt: now,
                ))
                categoryID = id
            }

            let accountKey = normalize(row.accountName)
            var accountID = accountByName[accountKey]
            if accountID == nil, createMissingAccounts, !row.accountName.isEmpty {
                let id = UUID()
                accountsToCreate.append(.init(id: id, name: row.accountName, sortOrder: accountByName.count))
                accountByName[accountKey] = id
                accountID = id
            }

            var tagIDs: [UUID] = []
            for name in row.tagNames {
                let key = normalize(name)
                if let id = tagByName[key] {
                    tagIDs.append(id)
                } else if createMissingTags {
                    let id = UUID()
                    tagsToCreate.append(.init(id: id, name: name, sortOrder: tagByName.count))
                    tagByName[key] = id
                    tagIDs.append(id)
                }
            }

            let timeZone = TimeZone(identifier: row.timeZoneIdentifier) ?? .current
            transactions.append(.init(
                id: UUID(),
                type: row.type,
                amountMinorUnits: row.amountMinorUnits,
                occurredAt: row.occurredAt,
                localDayKey: LocalDayKey.make(for: row.occurredAt, timeZone: timeZone),
                timeZoneIdentifier: row.timeZoneIdentifier,
                accountID: accountID ?? defaultAccount.id,
                categoryID: categoryID,
                merchantName: row.merchantName,
                note: row.persistedNote,
                reviewStatus: categoryID == nil ? .needsReview : .complete,
                reviewReasons: categoryID == nil ? [.uncategorized, .importUncertain] : [],
                externalTransactionID: row.externalTransactionID,
                fingerprint: row.fingerprint,
                tagIDs: tagIDs,
                intent: includeConfirmedDuplicates && row.isDuplicate
                    ? .confirmedExistingRetained(instance: UUID()) : retainedIntents[row.rowNumber] ?? .normal,
                duplicateCheckID: row.stableEventIdentity
            ))
        }

        let totals = importTotals(rowsToCommit)
        let skippedDuplicates = (includeConfirmedDuplicates ? 0 : plan.duplicateCount)
            + (includeSuspectedDuplicates ? 0 : plan.suspectedDuplicateCount)
        let result = ImportResult(
            importedCount: rowsToCommit.count,
            duplicateCount: skippedDuplicates,
            skippedCount: plan.skippedRows.count,
            failedCount: plan.failedRows.count,
            invalidCount: plan.rowIssues.count,
            createdCategoryCount: categoriesToCreate.count,
            createdAccountCount: accountsToCreate.count,
            createdTagCount: tagsToCreate.count,
            incomeMinorUnits: totals.income,
            expenseMinorUnits: totals.expense,
            confirmedDuplicateSkippedCount: includeConfirmedDuplicates ? 0 : plan.duplicateCount
        )
        return ImportCommitRequest(
            batchID: UUID(),
            source: plan.source,
            sourceDisplayName: plan.sourceDisplayName,
            sourceFormatVersion: "\(plan.fileFormat.rawValue.lowercased())-v2",
            startedAt: now,
            totalRowCount: plan.totalRows,
            skippedRowCount: plan.skippedRows.count,
            duplicateRowCount: skippedDuplicates,
            errorRowCount: plan.failedRows.count,
            accountsToCreate: accountsToCreate,
            categoriesToCreate: categoriesToCreate,
            tagsToCreate: tagsToCreate,
            transactions: transactions,
            result: result,
            categoryBaselines: modelSnapshot.categories,
            ledgerGeneration: modelSnapshot.ledgerGeneration
        )
    }

    /// Equivalent source events form a multiset: occurrence zero keeps the existing
    /// semantic identity; subsequent occurrences are stable across filenames/devices/imports.
    /// Sort business fields first; row number only breaks ties between identical payloads.
    private static func occurrenceIntents(for candidates: [ImportCandidate], source: ImportSourceType) -> [Int: ImportCommitRequest.RowIntent] {
        var intents: [Int: ImportCommitRequest.RowIntent] = [:]
        let groups = Dictionary(grouping: candidates) { row in
            LedgerSyncIdentity.importIdentity(source: source, type: row.type,
                externalID: row.externalTransactionID, fingerprint: row.fingerprint)
        }
        func orderKey(_ row: ImportCandidate) -> [String] {
            [row.type.rawValue, row.externalTransactionID, row.fingerprint, String(row.amountMinorUnits),
             String(row.occurredAt.timeIntervalSince1970), row.timeZoneIdentifier, row.categoryName,
             row.accountName, row.merchantName, row.persistedNote] + row.tagNames.sorted()
        }
        for (base, rows) in groups {
            let ordered = rows.sorted {
                let lhs = orderKey($0), rhs = orderKey($1)
                return lhs == rhs ? $0.rowNumber < $1.rowNumber : lhs.lexicographicallyPrecedes(rhs)
            }
            for (ordinal, row) in ordered.enumerated() {
                if let base, ordinal > 0 {
                    intents[row.rowNumber] = .withinFileRetained(
                        semanticOrigin: "occurrence-v1:" + base.uuidString + ":" + String(ordinal))
                } else if row.duplicateAssessment == .withinFile {
                    intents[row.rowNumber] = .withinFileRetained(semanticOrigin: nil)
                }
            }
        }
        return intents
    }

    private static func importTotals(
        _ rows: [ImportCandidate]
    ) -> (income: Int64, expense: Int64) {
        var income: Int64 = 0
        var expense: Int64 = 0
        for row in rows {
            switch row.type {
            case .income:
                income = saturatingAdd(income, row.amountMinorUnits)
            case .expense:
                expense = saturatingAdd(expense, row.amountMinorUnits)
            case .refund:
                expense = saturatingSubtract(expense, row.amountMinorUnits)
            case .transfer:
                break
            }
        }
        return (income, expense)
    }

    static func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (result, overflow) = left.addingReportingOverflow(right)
        return overflow ? .max : result
    }

    static func saturatingSubtract(_ left: Int64, _ right: Int64) -> Int64 {
        let (result, overflow) = left.subtractingReportingOverflow(right)
        return overflow ? .min : result
    }

    static func exportData(
        transactions: [FinanceTransaction],
        categories: [Category],
        accounts: [Account]
    ) -> Data {
        let metadata = LedgerFilterMetadata(
            categories: Dictionary(uniqueKeysWithValues: categories.map {
                ($0.id, LedgerFilterMetadata.CategoryValue(id: $0.id, name: $0.name, parentID: $0.parentID,
                    symbolName: $0.symbolName, colorToken: $0.colorToken))
            }), accounts: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) }),
            tags: transactions.flatMap(\.tags).reduce(into: [:]) { $0[$1.id] = $1.name })
        return exportData(rows: TransactionLifecycleService.sortedActive(transactions).reversed().map(LedgerFilteredRow.init), metadata: metadata)
    }

    static func exportData(rows: [LedgerFilteredRow], metadata: LedgerFilterMetadata) -> Data {
        let formatter = ISO8601DateFormatter()
        var lines = [exportHeaders.map(escape).joined(separator: ",")]
        for row in rows {
            let category = row.categoryID.flatMap { metadata.categories[$0] }
            let amount = (try? Money(minorUnits: row.amountMinorUnits, currencyCode: row.currencyCode).decimalString) ?? ""
            formatter.timeZone = TimeZone(identifier: row.timeZoneIdentifier) ?? .gmt
            let values = [
                row.id.uuidString, row.type.rawValue, amount, row.currencyCode,
                category == nil ? "" : metadata.path(row.categoryID), category?.symbolName ?? "",
                row.accountID.flatMap { metadata.accounts[$0] } ?? "", formatter.string(from: row.occurredAt),
                row.timeZoneIdentifier, row.localDayKey, row.merchant, row.note,
                row.tagIDs.compactMap { metadata.tags[$0] }.sorted().joined(separator: "|"),
                formatter.string(from: row.createdAt), formatter.string(from: row.updatedAt)
            ]
            lines.append(values.map(escape).joined(separator: ","))
        }
        return Data([0xEF, 0xBB, 0xBF]) + Data(lines.joined(separator: "\r\n").utf8)
    }

    static func writeTemporaryExport(
        data: Data,
        fileName: String,
        directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let folder = directory.appendingPathComponent("PersonalFinanceOSExports", isDirectory: true)
        let manager = FileManager.default
        let requestFolder = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: requestFolder, withIntermediateDirectories: true)
        // Keep handed-off URLs readable for a day, including files from the old layout.
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        for entry in entries ?? [] where entry != requestFolder {
            if let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < cutoff {
                try? manager.removeItem(at: entry)
            }
        }
        let url = requestFolder.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func markDuplicates(
        _ candidates: [ImportCandidate],
        source: ImportSourceType,
        existingRecords: [ImportDuplicateRecord]
    ) -> [ImportCandidate] {
        let index = ImportOccurrenceIndex(records: existingRecords)
        let intents = occurrenceIntents(for: candidates, source: source)
        let existingSuspectedKeys = Set(existingRecords.compactMap { transaction -> String? in
            guard transaction.deletedAt == nil else { return nil }
            return suspectedKey(
                source: transaction.externalSource,
                type: transaction.type,
                amountMinorUnits: transaction.amountMinorUnits,
                occurredAt: transaction.occurredAt,
                note: transaction.note
            )
        })
        var seenFingerprints = Set<String>()
        var seenStableIDs = Set<String>()
        var seenSuspectedKeys = Set<String>()
        return candidates.map { original in
            var candidate = original
            let stableID = stableKey(
                source: source,
                type: candidate.type,
                externalID: candidate.stableEventIdentity
            )
            let fingerprint = fingerprintKey(source: source, fingerprint: candidate.fingerprint)
            let candidateSuspectedKey = suspectedKey(
                source: source,
                type: candidate.type,
                amountMinorUnits: candidate.amountMinorUnits,
                occurredAt: candidate.occurredAt,
                note: candidate.persistedNote
            )
            let origin: String?
            if case let .withinFileRetained(value) = intents[candidate.rowNumber] { origin = value }
            else { origin = nil }
            candidate.isDuplicate = false
            candidate.isSuspectedDuplicate = false
            candidate.duplicateAssessment = .normal
            if index.contains(source: source, type: candidate.type,
                externalID: candidate.externalTransactionID, fingerprint: candidate.fingerprint,
                occurrenceOrigin: origin) {
                candidate.isDuplicate = true
                candidate.duplicateAssessment = !candidate.externalTransactionID.isEmpty && !(source == .jd && candidate.type == .refund)
                    ? .authoritativeExisting : .exactFingerprintExisting
            } else if let base = LedgerSyncIdentity.importIdentity(source: source, type: candidate.type,
                externalID: candidate.externalTransactionID, fingerprint: candidate.fingerprint),
                index.ambiguousLegacyBases.contains(base) {
                candidate.isSuspectedDuplicate = true
                candidate.duplicateAssessment = .suspectedExisting
            } else if stableID.map(seenStableIDs.contains) == true
                || fingerprint.map(seenFingerprints.contains) == true
                || candidateSuspectedKey.map(seenSuspectedKeys.contains) == true {
                candidate.duplicateAssessment = .withinFile
            } else if candidateSuspectedKey.map(existingSuspectedKeys.contains) == true
                || suspectedKey(
                    source: nil,
                    type: candidate.type,
                    amountMinorUnits: candidate.amountMinorUnits,
                    occurredAt: candidate.occurredAt,
                    note: candidate.persistedNote
                ).map(existingSuspectedKeys.contains) == true {
                candidate.isSuspectedDuplicate = true
                candidate.duplicateAssessment = .suspectedExisting
            }
            if let fingerprint { seenFingerprints.insert(fingerprint) }
            if let stableID { seenStableIDs.insert(stableID) }
            if let candidateSuspectedKey { seenSuspectedKeys.insert(candidateSuspectedKey) }
            return candidate
        }
    }

    private static func suspectedKey(
        source: ImportSourceType?,
        type: TransactionType,
        amountMinorUnits: Int64,
        occurredAt: Date,
        note: String
    ) -> String? {
        let normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedNote.isEmpty else { return nil }
        let sourceKey = source?.rawValue ?? ""
        return [
            sourceKey,
            type.rawValue,
            String(amountMinorUnits),
            String(Int(occurredAt.timeIntervalSince1970)),
            normalizedNote
        ].joined(separator: "\u{1F}")
    }

    private static func fingerprintKey(
        source: ImportSourceType?,
        fingerprint: String
    ) -> String? {
        let trimmed = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source, !trimmed.isEmpty else { return nil }
        return "\(source.rawValue)|\(trimmed)"
    }

    private static func stableKey(
        source: ImportSourceType?,
        type: TransactionType,
        externalID: String
    ) -> String? {
        let trimmed = externalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source, !trimmed.isEmpty else { return nil }
        return "\(source.rawValue)|\(type.rawValue)|\(trimmed)"
    }

    private static func specializedParser(
        for source: ImportSourceType,
        mapping: CSVColumnMapping
    ) -> any BillSourceParsing {
        switch source {
        case .wechat: WeChatBillParser()
        case .wacai: WacaiBillParser()
        case .alipay: AlipayBillParser()
        case .jd: JDBillParser()
        case .genericCSV: GenericTabularBillParser(source: source, mapping: mapping)
        }
    }

    private static func preferredAccount(_ lhs: Account, _ rhs: Account) -> Bool {
        comparePreference(
            lhsArchived: lhs.archivedAt != nil,
            rhsArchived: rhs.archivedAt != nil,
            lhsPreferred: lhs.isDefault,
            rhsPreferred: rhs.isDefault,
            lhsSortOrder: lhs.sortOrder,
            rhsSortOrder: rhs.sortOrder,
            lhsCreatedAt: lhs.createdAt,
            rhsCreatedAt: rhs.createdAt,
            lhsID: lhs.id,
            rhsID: rhs.id
        )
    }

    private static func preferredCategory(_ lhs: Category, _ rhs: Category) -> Bool {
        comparePreference(
            lhsArchived: lhs.archivedAt != nil,
            rhsArchived: rhs.archivedAt != nil,
            lhsPreferred: !lhs.isHidden,
            rhsPreferred: !rhs.isHidden,
            lhsSortOrder: lhs.sortOrder,
            rhsSortOrder: rhs.sortOrder,
            lhsCreatedAt: lhs.createdAt,
            rhsCreatedAt: rhs.createdAt,
            lhsID: lhs.id,
            rhsID: rhs.id
        )
    }

    private static func preferredTag(_ lhs: Tag, _ rhs: Tag) -> Bool {
        comparePreference(
            lhsArchived: lhs.archivedAt != nil,
            rhsArchived: rhs.archivedAt != nil,
            lhsPreferred: false,
            rhsPreferred: false,
            lhsSortOrder: lhs.sortOrder,
            rhsSortOrder: rhs.sortOrder,
            lhsCreatedAt: lhs.createdAt,
            rhsCreatedAt: rhs.createdAt,
            lhsID: lhs.id,
            rhsID: rhs.id
        )
    }

    private static func preferredAccountSnapshot(
        _ lhs: ImportAccountSnapshot,
        _ rhs: ImportAccountSnapshot
    ) -> Bool {
        comparePreference(
            lhsArchived: lhs.archivedAt != nil,
            rhsArchived: rhs.archivedAt != nil,
            lhsPreferred: lhs.isDefault,
            rhsPreferred: rhs.isDefault,
            lhsSortOrder: lhs.sortOrder,
            rhsSortOrder: rhs.sortOrder,
            lhsCreatedAt: lhs.createdAt,
            rhsCreatedAt: rhs.createdAt,
            lhsID: lhs.id,
            rhsID: rhs.id
        )
    }

    private static func preferredCategorySnapshot(
        _ lhs: ImportCategorySnapshot,
        _ rhs: ImportCategorySnapshot
    ) -> Bool {
        comparePreference(
            lhsArchived: lhs.archivedAt != nil,
            rhsArchived: rhs.archivedAt != nil,
            lhsPreferred: !lhs.isHidden,
            rhsPreferred: !rhs.isHidden,
            lhsSortOrder: lhs.sortOrder,
            rhsSortOrder: rhs.sortOrder,
            lhsCreatedAt: lhs.createdAt,
            rhsCreatedAt: rhs.createdAt,
            lhsID: lhs.id,
            rhsID: rhs.id
        )
    }

    private static func preferredTagSnapshot(
        _ lhs: ImportTagSnapshot,
        _ rhs: ImportTagSnapshot
    ) -> Bool {
        comparePreference(
            lhsArchived: lhs.archivedAt != nil,
            rhsArchived: rhs.archivedAt != nil,
            lhsPreferred: false,
            rhsPreferred: false,
            lhsSortOrder: lhs.sortOrder,
            rhsSortOrder: rhs.sortOrder,
            lhsCreatedAt: lhs.createdAt,
            rhsCreatedAt: rhs.createdAt,
            lhsID: lhs.id,
            rhsID: rhs.id
        )
    }

    private static func comparePreference(
        lhsArchived: Bool,
        rhsArchived: Bool,
        lhsPreferred: Bool,
        rhsPreferred: Bool,
        lhsSortOrder: Int,
        rhsSortOrder: Int,
        lhsCreatedAt: Date,
        rhsCreatedAt: Date,
        lhsID: UUID,
        rhsID: UUID
    ) -> Bool {
        if lhsArchived != rhsArchived { return !lhsArchived }
        if lhsPreferred != rhsPreferred { return lhsPreferred }
        if lhsSortOrder != rhsSortOrder { return lhsSortOrder < rhsSortOrder }
        if lhsCreatedAt != rhsCreatedAt { return lhsCreatedAt < rhsCreatedAt }
        return lhsID.uuidString < rhsID.uuidString
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
        else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func normalize(_ value: String) -> String {
        BillTextNormalization.value(value)
    }
}
