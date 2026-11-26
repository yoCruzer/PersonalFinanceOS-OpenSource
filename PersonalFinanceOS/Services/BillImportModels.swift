import Foundation

enum BillFileFormat: String, Equatable, Sendable {
    case csv = "CSV"
    case xlsx = "XLSX"
}

enum BillImportError: LocalizedError, Equatable, Sendable {
    case emptyFile
    case unsupportedFileType
    case unsupportedEncoding
    case malformedCSV
    case invalidXLSX
    case unsupportedExcelDateSystem
    case noRecognizableWorksheet
    case missingRequiredColumns([String])
    case missingGenericMapping
    case noValidRows

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            "文件为空。"
        case .unsupportedFileType:
            "不支持此文件类型。请选择 CSV 或 XLSX 账单。"
        case .unsupportedEncoding:
            "无法可靠识别 CSV 编码。支持 UTF-8、GB18030/GBK 和带 BOM 的 UTF-16。"
        case .malformedCSV:
            "CSV 结构损坏，请检查引号、分隔符或列结构。"
        case .invalidXLSX:
            "XLSX 无法打开或工作簿结构损坏。"
        case .unsupportedExcelDateSystem:
            "XLSX 使用了无法确认的日期系统，未进行静默日期转换。"
        case .noRecognizableWorksheet:
            "XLSX 中没有可识别的账单工作表。"
        case let .missingRequiredColumns(columns):
            "专用解析缺少必要字段：\(columns.joined(separator: "、"))。可改用通用映射。"
        case .missingGenericMapping:
            "通用映射需要指定金额和日期时间字段。"
        case .noValidRows:
            "没有可导入的有效交易。"
        }
    }
}

typealias FinanceCSVError = BillImportError

enum ExcelDateSystem: String, Equatable, Sendable {
    case excel1900
    case excel1904
}

struct TabularCell: Equatable, Sendable {
    let text: String
    let excelSerial: Double?

    init(text: String = "", excelSerial: Double? = nil) {
        self.text = text
        self.excelSerial = excelSerial
    }
}

struct TabularRow: Equatable, Sendable {
    let number: Int
    let cells: [TabularCell]

    var isEmpty: Bool {
        cells.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct TabularSheet: Equatable, Sendable {
    let name: String
    let rows: [TabularRow]
    let excelDateSystem: ExcelDateSystem?

    init(name: String, rows: [TabularRow], excelDateSystem: ExcelDateSystem? = nil) {
        self.name = name
        self.rows = rows
        self.excelDateSystem = excelDateSystem
    }
}

struct BillSourceDetection: Equatable, Sendable {
    let source: ImportSourceType
    let confidence: Double
    let reasons: [String]

    var isSpecialized: Bool { source != .genericCSV }
}

struct BillImportDocument: Equatable, Sendable {
    let format: BillFileFormat
    let encodingName: String?
    let sheetName: String?
    let excelDateSystem: ExcelDateSystem?
    let rawRowCount: Int
    let headerRowNumber: Int
    let headers: [String]
    let rows: [TabularRow]
    let nonTransactionRowCount: Int
    let detection: BillSourceDetection
    let formatMismatchMessage: String?

    var formatDescription: String { format.rawValue }
}

enum BillImportParserMode: Equatable, Sendable {
    case automatic
    case generic
}

enum BillImportParsingMethod: Equatable, Sendable {
    case specialized
    case genericMapping
}

struct CSVDocument: Sendable {
    let headers: [String]
    let rows: [[String]]
    let delimiter: Character
    let encodingName: String
}

struct CSVColumnMapping: Equatable, Sendable {
    var type: Int?
    var amount: Int?
    var dateTime: Int?
    var category: Int?
    var account: Int?
    var note: Int?
    var tags: Int?
    var transactionID: Int?
}

enum ImportRowIssueDisposition: String, Equatable, Sendable {
    case skipped
    case failed
}

enum ImportRowIssueReason: String, Equatable, Sendable {
    case notATransaction = "不属于交易行"
    case unsupportedStatus = "交易状态不支持"
    case unsupportedDirection = "收支方向需确认"
    case unsupportedCurrency = "币种不支持"
    case invalidDate = "日期无法解析"
    case missingAmount = "金额缺失"
    case zeroAmount = "金额为零"
    case invalidAmount = "金额格式无效"
    case partialRefundNeedsConfirmation = "部分退款关系需确认"
    case amountAnnotationNeedsConfirmation = "金额注释需确认"
    case missingRequiredField = "必要字段缺失"
    case damagedColumns = "列结构损坏"
}

struct ImportRowIssue: Equatable, Sendable {
    let rowNumber: Int
    let disposition: ImportRowIssueDisposition
    let reason: ImportRowIssueReason
    let detail: String
}

struct ImportCandidate: Identifiable, Sendable {
    let id = UUID()
    let rowNumber: Int
    let type: TransactionType
    let amountMinorUnits: Int64
    let occurredAt: Date
    let timeZoneIdentifier: String
    let categoryName: String
    let accountName: String
    let merchantName: String
    let description: String
    let note: String
    let paymentMethod: String
    let statusText: String
    let tagNames: [String]
    let externalTransactionID: String
    let stableEventIdentity: String
    let fingerprint: String
    var isDuplicate: Bool
    var isSuspectedDuplicate: Bool
    var duplicateAssessment: ImportDuplicateAssessment = .normal

    var persistedNote: String {
        [description, note]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { values, value in
                if !values.contains(value) { values.append(value) }
            }
            .joined(separator: " · ")
    }
}

enum ImportDuplicateAssessment: String, Equatable, Sendable {
    case normal
    case authoritativeExisting
    case exactFingerprintExisting
    case suspectedExisting
    case withinFile

    var title: String {
        switch self {
        case .normal: "普通记录"
        case .authoritativeExisting: "来源唯一标识已存在"
        case .exactFingerprintExisting: "精确导入指纹已存在"
        case .suspectedExisting: "疑似与现有记录相同"
        case .withinFile: "文件内相似记录"
        }
    }
}

struct ImportPlan: Sendable {
    let source: ImportSourceType
    let parsingMethod: BillImportParsingMethod
    let sourceDisplayName: String
    let fileFormat: BillFileFormat
    let encodingName: String?
    let sheetName: String?
    let sourceDetectionReasons: [String]
    let rawRowCount: Int
    let nonTransactionRowCount: Int
    let totalRows: Int
    let candidates: [ImportCandidate]
    let rowIssues: [ImportRowIssue]

    var rowsToImport: [ImportCandidate] { candidates.filter { !$0.isDuplicate } }
    func effectiveRowsToImport(
        includeSuspectedDuplicates: Bool,
        includeConfirmedDuplicates: Bool = false
    ) -> [ImportCandidate] {
        candidates.filter {
            (includeConfirmedDuplicates || !$0.isDuplicate) &&
            (includeSuspectedDuplicates || !$0.isSuspectedDuplicate)
        }
    }
    var duplicateCount: Int { candidates.filter(\.isDuplicate).count }
    var suspectedDuplicateCount: Int {
        candidates.filter { !$0.isDuplicate && $0.isSuspectedDuplicate }.count
    }
    var withinFileDuplicateCount: Int {
        candidates.filter { $0.duplicateAssessment == .withinFile }.count
    }
    var skippedRows: [ImportRowIssue] { rowIssues.filter { $0.disposition == .skipped } }
    var failedRows: [ImportRowIssue] { rowIssues.filter { $0.disposition == .failed } }
    var invalidRows: [(Int, String)] {
        rowIssues.map { ($0.rowNumber, $0.detail) }
    }
    var incomeMinorUnits: Int64 {
        incomeMinorUnits(includeSuspectedDuplicates: true)
    }
    var expenseMinorUnits: Int64 {
        expenseMinorUnits(includeSuspectedDuplicates: true)
    }
    var refundMinorUnits: Int64 {
        refundMinorUnits(includeSuspectedDuplicates: true)
    }
    var localDayRange: ClosedRange<String>? {
        localDayRange(includeSuspectedDuplicates: true)
    }
    func incomeMinorUnits(
        includeSuspectedDuplicates: Bool,
        includeConfirmedDuplicates: Bool = false
    ) -> Int64 {
        effectiveRowsToImport(
            includeSuspectedDuplicates: includeSuspectedDuplicates,
            includeConfirmedDuplicates: includeConfirmedDuplicates
        )
            .filter { $0.type == .income }
            .reduce(0) { $0 + $1.amountMinorUnits }
    }
    func expenseMinorUnits(
        includeSuspectedDuplicates: Bool,
        includeConfirmedDuplicates: Bool = false
    ) -> Int64 {
        effectiveRowsToImport(
            includeSuspectedDuplicates: includeSuspectedDuplicates,
            includeConfirmedDuplicates: includeConfirmedDuplicates
        )
            .filter { $0.type == .expense }
            .reduce(0) { $0 + $1.amountMinorUnits }
    }
    func refundMinorUnits(
        includeSuspectedDuplicates: Bool,
        includeConfirmedDuplicates: Bool = false
    ) -> Int64 {
        effectiveRowsToImport(
            includeSuspectedDuplicates: includeSuspectedDuplicates,
            includeConfirmedDuplicates: includeConfirmedDuplicates
        )
            .filter { $0.type == .refund }
            .reduce(0) { $0 + $1.amountMinorUnits }
    }
    func localDayRange(
        includeSuspectedDuplicates: Bool,
        includeConfirmedDuplicates: Bool = false
    ) -> ClosedRange<String>? {
        let days = effectiveRowsToImport(
            includeSuspectedDuplicates: includeSuspectedDuplicates,
            includeConfirmedDuplicates: includeConfirmedDuplicates
        )
            .compactMap { candidate -> String? in
                guard let timeZone = TimeZone(identifier: candidate.timeZoneIdentifier) else {
                    return nil
                }
                return LocalDayKey.make(for: candidate.occurredAt, timeZone: timeZone)
            }
        guard let first = days.min(), let last = days.max() else { return nil }
        return first...last
    }
    var issueSummary: [(String, Int)] {
        Dictionary(grouping: rowIssues, by: { $0.detail })
            .map { ($0.key, $0.value.count) }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1
            }
    }
}

struct ParsedImportPlan: Sendable {
    let source: ImportSourceType
    let parsingMethod: BillImportParsingMethod
    let sourceDisplayName: String
    let fileFormat: BillFileFormat
    let encodingName: String?
    let sheetName: String?
    let sourceDetectionReasons: [String]
    let rawRowCount: Int
    let nonTransactionRowCount: Int
    let totalRows: Int
    let candidates: [ImportCandidate]
    let rowIssues: [ImportRowIssue]

    var localDayRange: ClosedRange<String>? {
        let days = candidates.compactMap { candidate -> String? in
            guard let timeZone = TimeZone(identifier: candidate.timeZoneIdentifier) else {
                return nil
            }
            return LocalDayKey.make(for: candidate.occurredAt, timeZone: timeZone)
        }
        guard let first = days.min(), let last = days.max() else { return nil }
        return first...last
    }
}

struct ImportAccountSnapshot: Sendable {
    let id: UUID
    let name: String
    let isDefault: Bool
    let sortOrder: Int
    let archivedAt: Date?
    let createdAt: Date
}

struct ImportCategorySnapshot: Codable, Sendable {
    let id: UUID
    let kind: CategoryKind
    let name: String
    let parentID: UUID?
    let symbolName: String
    let colorToken: String
    let sortOrder: Int
    let isHidden: Bool
    let archivedAt: Date?
    let createdAt: Date
    var defaultDefinitionKey: String = ""

    var isActiveForSelection: Bool { archivedAt == nil && !isHidden }
}

struct ImportTagSnapshot: Sendable {
    let id: UUID
    let name: String
    let sortOrder: Int
    let archivedAt: Date?
    let createdAt: Date
}

struct ImportModelSnapshot: Sendable {
    let accounts: [ImportAccountSnapshot]
    let categories: [ImportCategorySnapshot]
    let tags: [ImportTagSnapshot]
    var ledgerGeneration: UUID = LedgerSaveRevision.shared.restoreGeneration
}

struct ImportCategoryGroupSnapshot: Hashable, Identifiable, Sendable {
    let rawCategory: String
    let kind: CategoryKind

    var id: String {
        "\(kind.rawValue)|\(ImportCategoryResolutionService.normalize(rawCategory))"
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind &&
            ImportCategoryResolutionService.normalize(lhs.rawCategory) ==
            ImportCategoryResolutionService.normalize(rhs.rawCategory)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(ImportCategoryResolutionService.normalize(rawCategory))
    }
}

struct ImportPreviewSnapshot: Sendable {
    let effectiveRows: [ImportCandidate]
    let incomeMinorUnits: Int64
    let expenseMinorUnits: Int64
    let refundMinorUnits: Int64
    let localDayRange: ClosedRange<String>?
    let duplicateCount: Int
    let suspectedDuplicateCount: Int
    let withinFileDuplicateCount: Int
    let skippedCount: Int
    let failedCount: Int
    let issueSummary: [(String, Int)]
    let unresolvedRows: [ImportCandidate]
    let unresolvedCategoryGroups: [ImportCategoryGroupSnapshot]
    let resolutionsByRowNumber: [Int: ImportCategoryResolution]
    let proposedChildCount: Int
    let unknownAccounts: [String]
    let unknownTags: [String]
}

struct ImportResult: Sendable {
    let importedCount: Int
    let duplicateCount: Int
    let skippedCount: Int
    let failedCount: Int
    let invalidCount: Int
    let createdCategoryCount: Int
    let createdAccountCount: Int
    let createdTagCount: Int
    let incomeMinorUnits: Int64
    let expenseMinorUnits: Int64
    var confirmedDuplicateSkippedCount: Int = 0
    var staleDuplicateCount: Int = 0
}

struct ImportDuplicateRecord: Sendable {
    var importSemanticOrigin: String? = nil
    var merchantName = ""
    let externalSource: ImportSourceType?
    let type: TransactionType
    let externalTransactionID: String
    let importFingerprint: String
    let amountMinorUnits: Int64
    let occurredAt: Date
    let note: String
    let deletedAt: Date?

    init(
        externalSource: ImportSourceType?,
        type: TransactionType,
        externalTransactionID: String,
        importFingerprint: String,
        amountMinorUnits: Int64,
        occurredAt: Date,
        note: String,
        deletedAt: Date?
    ) {
        self.externalSource = externalSource
        self.type = type
        self.externalTransactionID = externalTransactionID
        self.importFingerprint = importFingerprint
        self.amountMinorUnits = amountMinorUnits
        self.occurredAt = occurredAt
        self.note = note
        self.deletedAt = deletedAt
    }

    init(transaction: FinanceTransaction) {
        merchantName = transaction.rawMerchantText
        externalSource = transaction.externalSource
        type = transaction.type
        externalTransactionID = transaction.externalTransactionID
        importFingerprint = transaction.importFingerprint
        amountMinorUnits = transaction.amountMinorUnits
        occurredAt = transaction.occurredAt
        note = transaction.note
        deletedAt = transaction.deletedAt
    }
}

/// Shared by preview assessment and final commit. Missing legacy provenance reserves
/// only the base occurrence; never infer ordinals from local UUIDs or row count.
struct ImportOccurrenceIndex {
    private var bases = Set<UUID>()
    private var origins = Set<String>()
    private struct SourceOccurrence: Hashable {
        let source: ImportSourceType
        let externalID: String
        let fingerprint: String
        let ordinal: Int
    }

    private var sourceOccurrences = Set<SourceOccurrence>()

    private static func ordinal(_ origin: String?) -> Int? {
        guard let origin else { return 0 }
        if origin.hasPrefix("import-base-v1:") { return 0 }
        let parts = origin.split(separator: ":")
        guard parts.count == 3, parts[0] == "occurrence-v1", UUID(uuidString: String(parts[1])) != nil,
              let ordinal = Int(parts[2]), ordinal > 0 else { return nil }
        return ordinal
    }

    private(set) var ambiguousLegacyBases = Set<UUID>()

    init(records: [ImportDuplicateRecord]) {
        var baseCounts: [UUID: Int] = [:]
        for record in records {
            if let source = record.externalSource, !record.importFingerprint.isEmpty,
               let ordinal = Self.ordinal(record.importSemanticOrigin) {
                let fingerprint = BillParserSupport.merchantFingerprint(source: source, legacy: record.importFingerprint,
                    merchant: record.merchantName, externalID: record.externalTransactionID)
                sourceOccurrences.insert(SourceOccurrence(source: source, externalID: record.externalTransactionID,
                    fingerprint: fingerprint, ordinal: ordinal))
            }
            if let origin = record.importSemanticOrigin {
                origins.insert(origin)
                if origin.hasPrefix("import-base-v1:"),
                   let base = UUID(uuidString: String(origin.dropFirst("import-base-v1:".count))) {
                    bases.insert(base)
                    baseCounts[base, default: 0] += 1
                }
                // Explicit instances and later occurrences do not consume occurrence zero.
            } else if let base = LedgerSyncIdentity.importIdentity(source: record.externalSource,
                type: record.type, externalID: record.externalTransactionID, fingerprint: record.importFingerprint) {
                bases.insert(base)
                baseCounts[base, default: 0] += 1
            }
        }
        ambiguousLegacyBases = Set(baseCounts.filter { $0.value > 1 }.map(\.key))
    }

    func contains(source: ImportSourceType, type: TransactionType, externalID: String,
                  fingerprint: String, occurrenceOrigin: String?) -> Bool {
        if let ordinal = Self.ordinal(occurrenceOrigin),
           sourceOccurrences.contains(SourceOccurrence(source: source, externalID: externalID, fingerprint: fingerprint, ordinal: ordinal)) {
            return true
        }
        if let occurrenceOrigin { return origins.contains(occurrenceOrigin) }
        guard let base = LedgerSyncIdentity.importIdentity(source: source, type: type,
            externalID: externalID, fingerprint: fingerprint) else { return false }
        return bases.contains(base)
    }
}
