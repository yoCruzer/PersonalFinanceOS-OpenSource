import Foundation

struct ParsedBillRows {
    let candidates: [ImportCandidate]
    let issues: [ImportRowIssue]
}

protocol BillSourceParsing {
    var source: ImportSourceType { get }
    func parse(document: BillImportDocument, calendar: Calendar) throws -> ParsedBillRows
}

struct WeChatBillParser: BillSourceParsing {
    let source = ImportSourceType.wechat

    func parse(document: BillImportDocument, calendar: Calendar) throws -> ParsedBillRows {
        let columns = try BillColumns(headers: document.headers, required: [
            ("交易时间", ["交易时间"]),
            ("交易类型", ["交易类型"]),
            ("收支方向", ["收/支", "收支"]),
            ("金额", ["金额(元)", "金额"])
        ])
        return BillParserSupport.parseRows(document.rows) { row in
            let values = BillRow(row: row, columns: columns)
            let direction = values.text(["收/支", "收支"])
            let transactionType = values.text(["交易类型"])
            let status = values.text(["当前状态", "交易状态"])
            try BillParserSupport.requireSupportedStatus(status)
            let type: TransactionType
            if transactionType.contains("退款") || (direction.contains("收入") && status.contains("退款")) {
                type = .refund
            } else if direction.contains("收入") {
                type = .income
            } else if direction.contains("支出") {
                type = .expense
            } else {
                throw RowParsingError.skipped(.unsupportedDirection, "收支方向“\(direction)”需要人工确认")
            }
            return try BillParserSupport.makeCandidate(
                row: row,
                source: source,
                type: type,
                amount: values.text(["金额(元)", "金额"]),
                dateCell: values.cell(["交易时间"]),
                category: transactionType,
                account: values.text(["支付方式"]),
                merchant: values.text(["交易对方"]),
                description: values.text(["商品"]),
                note: values.text(["备注"]),
                paymentMethod: values.text(["支付方式"]),
                status: status,
                tags: "",
                externalID: values.text(["交易单号"]),
                excelDateSystem: document.excelDateSystem,
                calendar: calendar
            )
        }
    }
}

struct WacaiBillParser: BillSourceParsing {
    let source = ImportSourceType.wacai

    func parse(document: BillImportDocument, calendar: Calendar) throws -> ParsedBillRows {
        let columns = try BillColumns(headers: document.headers, required: [
            ("日期时间", ["日期时间"]),
            ("类型", ["类型", "收支类型"]),
            ("金额", ["金额"])
        ])
        return BillParserSupport.parseRows(document.rows) { row in
            let values = BillRow(row: row, columns: columns)
            try BillParserSupport.validateCurrency(values.text(["币种", "货币", "currency", "currency_code"]))
            let rawType = values.text(["类型", "收支类型"])
            let type: TransactionType
            if rawType.contains("退款") {
                type = .refund
            } else if rawType.contains("收入") {
                type = .income
            } else if rawType.contains("支出") {
                type = .expense
            } else if rawType.contains("转账") {
                throw RowParsingError.skipped(.unsupportedDirection, "账户间转账需要确认转入账户")
            } else {
                throw RowParsingError.skipped(.unsupportedDirection, "类型“\(rawType)”需要人工确认")
            }
            return try BillParserSupport.makeCandidate(
                row: row,
                source: source,
                type: type,
                amount: values.text(["金额"]),
                dateCell: values.cell(["日期时间"]),
                category: values.text(["类别", "分类"]),
                account: values.text(["收付账户", "账户"]),
                merchant: BillParserSupport.firstNonempty([
                    values.text(["商家"]), values.text(["收付款人"])
                ]),
                description: values.text(["收付款人"]),
                note: values.text(["备注"]),
                paymentMethod: values.text(["收付账户", "账户"]),
                status: "",
                tags: values.text(["标签"]),
                externalID: "",
                excelDateSystem: document.excelDateSystem,
                calendar: calendar
            )
        }
    }
}

struct AlipayBillParser: BillSourceParsing {
    let source = ImportSourceType.alipay

    func parse(document: BillImportDocument, calendar: Calendar) throws -> ParsedBillRows {
        let columns = try BillColumns(headers: document.headers, required: [
            ("交易时间", ["交易时间"]),
            ("收支方向", ["收/支", "收支"]),
            ("金额", ["金额"])
        ])
        return BillParserSupport.parseRows(document.rows) { row in
            let values = BillRow(row: row, columns: columns)
            let direction = values.text(["收/支", "收支"])
            let status = values.text(["交易状态"])
            try BillParserSupport.requireSupportedStatus(status)
            let type: TransactionType
            if status.contains("退款成功") {
                type = .refund
            } else if direction.contains("支出") {
                type = .expense
            } else if direction.contains("收入") {
                type = .income
            } else {
                throw RowParsingError.skipped(.unsupportedDirection, "不计收支项目需要人工确认资金流转语义")
            }
            return try BillParserSupport.makeCandidate(
                row: row,
                source: source,
                type: type,
                amount: values.text(["金额"]),
                dateCell: values.cell(["交易时间"]),
                category: values.text(["交易分类"]),
                account: values.text(["收/付款方式", "支付方式"]),
                merchant: values.text(["交易对方"]),
                description: values.text(["商品说明"]),
                note: values.text(["备注"]),
                paymentMethod: values.text(["收/付款方式", "支付方式"]),
                status: status,
                tags: "",
                externalID: values.text(["交易订单号", "交易单号"]),
                excelDateSystem: document.excelDateSystem,
                calendar: calendar
            )
        }
    }
}

struct JDBillParser: BillSourceParsing {
    let source = ImportSourceType.jd

    func parse(document: BillImportDocument, calendar: Calendar) throws -> ParsedBillRows {
        let columns = try BillColumns(headers: document.headers, required: [
            ("交易时间", ["交易时间"]),
            ("金额", ["金额"]),
            ("交易状态", ["交易状态"]),
            ("收支方向", ["收/支", "收支"])
        ])
        var validRefundCandidates: [Int: ImportCandidate] = [:]
        var refundCandidatesByEventIdentity: [String: ImportCandidate] = [:]
        var conflictingRefundEventIdentities: Set<String> = []
        for row in document.rows {
            let values = BillRow(row: row, columns: columns)
            let status = values.text(["交易状态"])
            let orderID = values.text(["交易订单号", "交易单号"])
            let refundEventID = values.text(["商家订单号", "退款流水号", "退款交易号", "流水号"])
            guard status.contains("退款成功"), !orderID.isEmpty else { continue }
            guard let candidate = try? BillParserSupport.makeCandidate(
                row: row,
                source: source,
                type: .refund,
                amount: values.text(["金额"]),
                dateCell: values.cell(["交易时间"]),
                category: values.text(["交易分类"]),
                account: values.text(["收/付款方式", "支付方式"]),
                merchant: values.text(["商户名称"]),
                description: values.text(["交易说明"]),
                note: values.text(["备注"]),
                paymentMethod: values.text(["收/付款方式", "支付方式"]),
                status: status,
                tags: "",
                externalID: orderID,
                eventID: refundEventID,
                excelDateSystem: document.excelDateSystem,
                calendar: calendar
            ) else { continue }
            validRefundCandidates[row.number] = candidate
            if let existing = refundCandidatesByEventIdentity[candidate.stableEventIdentity] {
                if existing.externalTransactionID != candidate.externalTransactionID
                    || existing.amountMinorUnits != candidate.amountMinorUnits
                    || existing.occurredAt != candidate.occurredAt
                    || existing.timeZoneIdentifier != candidate.timeZoneIdentifier {
                    conflictingRefundEventIdentities.insert(candidate.stableEventIdentity)
                }
            } else {
                refundCandidatesByEventIdentity[candidate.stableEventIdentity] = candidate
            }
        }
        var refundMinorUnitsByOrder: [String: Int64] = [:]
        var overflowingOrders = Set<String>()
        for (eventIdentity, candidate) in refundCandidatesByEventIdentity
        where !conflictingRefundEventIdentities.contains(eventIdentity) {
            let orderID = candidate.externalTransactionID
            let (sum, overflow) = refundMinorUnitsByOrder[orderID, default: 0].addingReportingOverflow(candidate.amountMinorUnits)
            if overflow { overflowingOrders.insert(orderID) }
            else { refundMinorUnitsByOrder[orderID] = sum }
        }
        return BillParserSupport.parseRows(document.rows) { row in
            let values = BillRow(row: row, columns: columns)
            let direction = values.text(["收/支", "收支"])
            let status = values.text(["交易状态"])
            try BillParserSupport.requireSupportedStatus(status)
            let type: TransactionType
            if overflowingOrders.contains(values.text(["交易订单号", "交易单号"])) {
                throw RowParsingError.failed(.invalidAmount, "该订单的退款合计超出支持范围")
            }
            if status.contains("退款成功") {
                if let candidate = validRefundCandidates[row.number] {
                    return candidate
                }
                type = .refund
            } else if status.contains("还款") {
                throw RowParsingError.skipped(.unsupportedDirection, "信用卡还款需要确认账户间资金流转")
            } else if direction.contains("支出") {
                type = .expense
            } else if direction.contains("收入") {
                type = .income
            } else {
                throw RowParsingError.skipped(.unsupportedDirection, "不计收支项目需要人工确认资金流转语义")
            }
            let orderID = values.text(["交易订单号", "交易单号"])
            let refundEventID = values.text(["商家订单号", "退款流水号", "退款交易号", "流水号"])
            let amount = try BillParserSupport.jdAmount(
                values.text(["金额"]),
                transactionType: type,
                orderID: orderID,
                refundMinorUnitsByOrder: refundMinorUnitsByOrder
            )
            return try BillParserSupport.makeCandidate(
                row: row,
                source: source,
                type: type,
                amount: amount,
                dateCell: values.cell(["交易时间"]),
                category: values.text(["交易分类"]),
                account: values.text(["收/付款方式", "支付方式"]),
                merchant: values.text(["商户名称"]),
                description: values.text(["交易说明"]),
                note: values.text(["备注"]),
                paymentMethod: values.text(["收/付款方式", "支付方式"]),
                status: status,
                tags: "",
                externalID: orderID,
                eventID: type == .refund ? refundEventID : "",
                excelDateSystem: document.excelDateSystem,
                calendar: calendar
            )
        }
    }
}

struct GenericTabularBillParser: BillSourceParsing {
    let source: ImportSourceType
    let mapping: CSVColumnMapping

    func parse(document: BillImportDocument, calendar: Calendar) throws -> ParsedBillRows {
        guard mapping.amount != nil, mapping.dateTime != nil else {
            throw BillImportError.missingGenericMapping
        }
        let refundEventIDIndex = document.headers.firstIndex {
            ["商家订单号", "退款流水号", "退款交易号", "流水号"]
                .map(BillTextNormalization.header)
                .contains(BillTextNormalization.header($0))
        }
        let columns = try BillColumns(headers: document.headers, required: [])
        let currencyIndex = columns.index(["币种", "货币", "currency", "currency_code"])
        let merchantIndex = columns.index(["商家", "商户名称", "merchant", "merchant_name"])
        let timeZoneIndex = document.headers.firstIndex {
            BillTextNormalization.header($0) == BillTextNormalization.header("time_zone_identifier")
        }
        let isLegacyPersonalFinanceOSCSV = FinanceCSVService.isLegacyPersonalFinanceOSCSV(
            headers: document.headers
        )
        return BillParserSupport.parseRows(document.rows) { row in
            func cell(_ index: Int?) -> TabularCell {
                guard let index, row.cells.indices.contains(index) else { return TabularCell() }
                return row.cells[index]
            }
            func text(_ index: Int?) -> String {
                cell(index).text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try BillParserSupport.validateCurrency(text(currencyIndex))
            let rawType = text(mapping.type).lowercased()
            let amount = text(mapping.amount)
            let negative = BillParserSupport.cleanedAmount(amount).hasPrefix("-")
            let type: TransactionType
            if ["退款", "退款成功", "refund"].contains(rawType) {
                type = .refund
            } else if rawType.contains("转账") || rawType == "transfer" {
                throw RowParsingError.skipped(.unsupportedDirection, "通用转账行需要确认转入账户")
            } else if rawType == "收入" || rawType == "income" {
                type = negative ? .expense : .income
            } else if rawType.isEmpty || rawType == "支出" || rawType == "expense" {
                type = .expense
            } else {
                throw RowParsingError.skipped(.unsupportedDirection, "收支方向“\(rawType)”需要人工确认")
            }
            return try BillParserSupport.makeCandidate(
                row: row,
                source: source,
                type: type,
                amount: amount,
                dateCell: cell(mapping.dateTime),
                category: text(mapping.category),
                account: text(mapping.account),
                merchant: text(merchantIndex),
                description: "",
                note: text(mapping.note),
                paymentMethod: text(mapping.account),
                status: "",
                tags: text(mapping.tags),
                externalID: text(mapping.transactionID),
                eventID: source == .jd && type == .refund ? text(refundEventIDIndex) : "",
                excelDateSystem: document.excelDateSystem,
                calendar: calendar,
                preservesExplicitTimeZone: !isLegacyPersonalFinanceOSCSV,
                preferredTimeZoneIdentifier: text(timeZoneIndex)
            )
        }
    }
}

private struct BillColumns {
    let indices: [String: Int]

    init(headers: [String], required: [(name: String, aliases: [String])]) throws {
        var result: [String: Int] = [:]
        for (index, header) in headers.enumerated() {
            result[BillTextNormalization.header(header)] = index
        }
        let missing = required.compactMap { group in
            group.aliases.allSatisfy { result[BillTextNormalization.header($0)] == nil }
                ? group.name : nil
        }
        if !missing.isEmpty {
            throw BillImportError.missingRequiredColumns(missing)
        }
        indices = result
    }

    func index(_ aliases: [String]) -> Int? {
        aliases.lazy.compactMap { indices[BillTextNormalization.header($0)] }.first
    }
}

private struct BillRow {
    let row: TabularRow
    let columns: BillColumns

    func cell(_ aliases: [String]) -> TabularCell {
        guard let index = columns.index(aliases), row.cells.indices.contains(index) else {
            return TabularCell()
        }
        return row.cells[index]
    }

    func text(_ aliases: [String]) -> String {
        cell(aliases).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum RowParsingError: Error {
    case issue(ImportRowIssueDisposition, ImportRowIssueReason, String)

    static func skipped(_ reason: ImportRowIssueReason, _ detail: String) -> Self {
        .issue(.skipped, reason, detail)
    }

    static func failed(_ reason: ImportRowIssueReason, _ detail: String) -> Self {
        .issue(.failed, reason, detail)
    }
}

enum BillParserSupport {
    static func parseRows(
        _ rows: [TabularRow],
        transform: (TabularRow) throws -> ImportCandidate
    ) -> ParsedBillRows {
        var candidates: [ImportCandidate] = []
        var issues: [ImportRowIssue] = []
        for row in rows {
            do {
                candidates.append(try transform(row))
            } catch let RowParsingError.issue(disposition, reason, detail) {
                issues.append(ImportRowIssue(
                    rowNumber: row.number,
                    disposition: disposition,
                    reason: reason,
                    detail: detail
                ))
            } catch {
                issues.append(ImportRowIssue(
                    rowNumber: row.number,
                    disposition: .failed,
                    reason: .missingRequiredField,
                    detail: "必要字段无法解析"
                ))
            }
        }
        return ParsedBillRows(candidates: candidates, issues: issues)
    }

    static func makeCandidate(
        row: TabularRow,
        source: ImportSourceType,
        type: TransactionType,
        amount: String,
        dateCell: TabularCell,
        category: String,
        account: String,
        merchant: String,
        description: String,
        note: String,
        paymentMethod: String,
        status: String,
        tags: String,
        externalID: String,
        eventID: String = "",
        excelDateSystem: ExcelDateSystem?,
        calendar: Calendar,
        preservesExplicitTimeZone: Bool? = nil,
        preferredTimeZoneIdentifier: String = ""
    ) throws -> ImportCandidate {
        let normalizedAmount = cleanedAmount(amount)
        guard !normalizedAmount.isEmpty else {
            throw RowParsingError.failed(.missingAmount, "金额缺失")
        }
        let unsigned = normalizedAmount.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard let money = try? Money(decimalString: unsigned) else {
            throw RowParsingError.failed(.invalidAmount, "金额格式无效")
        }
        guard money.minorUnits > 0 else {
            throw RowParsingError.skipped(.zeroAmount, "金额为零，不导入")
        }
        let preferredTimeZone = TimeZone(identifier: preferredTimeZoneIdentifier)
        let defaultTimeZone = preferredTimeZone ?? (source == .genericCSV
            ? calendar.timeZone
            : TimeZone(identifier: "Asia/Shanghai")!)
        guard let importedDate = parseDate(
            dateCell,
            excelDateSystem: excelDateSystem,
            calendar: calendar,
            defaultTimeZone: defaultTimeZone,
            preservesExplicitTimeZone: preservesExplicitTimeZone ?? (source == .genericCSV)
        ) else {
            throw RowParsingError.failed(.invalidDate, "日期无法解析")
        }
        let date = importedDate.date
        let tagNames = tags
            .components(separatedBy: CharacterSet(charactersIn: "|;；、"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmedExternalID = externalID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEventID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableEventIdentity: String
        if !trimmedEventID.isEmpty {
            stableEventIdentity = trimmedEventID
        } else if source == .jd, type == .refund, !trimmedExternalID.isEmpty {
            stableEventIdentity = [
                trimmedExternalID,
                String(money.minorUnits),
                ISO8601DateFormatter().string(from: date)
            ].joined(separator: "\u{1F}")
        } else {
            stableEventIdentity = trimmedExternalID
        }
        let fingerprint: String
        if !stableEventIdentity.isEmpty {
            fingerprint = eventFingerprint(source: source, type: type, eventID: stableEventIdentity)
        } else {
            let legacy = fnv1a([
                source.rawValue, "", type.rawValue, String(money.minorUnits),
                ISO8601DateFormatter().string(from: date), category, account,
                [description, note].filter { !$0.isEmpty }.joined(separator: " · "),
                tagNames.sorted().joined(separator: "|")
            ].joined(separator: "\u{1F}"))
            fingerprint = merchantFingerprint(source: source, legacy: legacy, merchant: merchant, externalID: trimmedExternalID)
        }
        return ImportCandidate(
            rowNumber: row.number,
            type: type,
            amountMinorUnits: money.minorUnits,
            occurredAt: date,
            timeZoneIdentifier: preferredTimeZone?.identifier ?? importedDate.timeZone.identifier,
            categoryName: category.trimmingCharacters(in: .whitespacesAndNewlines),
            accountName: account.trimmingCharacters(in: .whitespacesAndNewlines),
            merchantName: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            paymentMethod: paymentMethod.trimmingCharacters(in: .whitespacesAndNewlines),
            statusText: status.trimmingCharacters(in: .whitespacesAndNewlines),
            tagNames: tagNames,
            externalTransactionID: trimmedExternalID,
            stableEventIdentity: stableEventIdentity,
            fingerprint: fingerprint,
            isDuplicate: false,
            isSuspectedDuplicate: false
        )
    }

    static func validateCurrency(_ value: String) throws {
        guard ["", "CNY", "RMB", "人民币", "人民币元", "元", "¥", "￥"].contains(value.uppercased()) else {
            throw RowParsingError.skipped(.unsupportedCurrency, "当前仅支持人民币，来源币种为“\(value)”")
        }
    }

    // Retain the Build 33 digest for indexed lookups in existing stores. Upgrade
    // legacy evidence with the merchant recorded on that row, never the new input.
    static func merchantFingerprint(source: ImportSourceType, legacy: String, merchant: String, externalID: String) -> String {
        guard externalID.isEmpty, source != .genericCSV || !merchant.isEmpty,
              !legacy.hasPrefix("v2:") else { return legacy }
        return "v2:" + legacy + ":" + fnv1a(merchant.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func eventFingerprint(source: ImportSourceType, type: TransactionType, eventID: String) -> String {
        fnv1a([source.rawValue, type.rawValue, eventID].joined(separator: "\u{1F}"))
    }

    static func legacyFingerprint(_ fingerprint: String) -> String {
        let parts = fingerprint.split(separator: ":")
        return parts.count == 3 && parts[0] == "v2" ? String(parts[1]) : fingerprint
    }

    static func cleanedAmount(_ value: String) -> String {
        value
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "￥", with: "")
            .replacingOccurrences(of: "元", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func jdAmount(
        _ value: String,
        transactionType: TransactionType,
        orderID: String,
        refundMinorUnitsByOrder: [String: Int64]
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("(") || trimmed.contains("（") else { return trimmed }

        let normalized = trimmed
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
        let partialPattern = #"^(.+)\(已退款[¥￥]?\s*([+-]?\d[\d,]*(?:\.\d+)?)\s*元?\)$"#
        let fullPattern = #"^(.+)\(已全额退款\)$"#
        let baseAmount: String
        let expectedRefundMinorUnits: Int64
        if let values = captureGroups(partialPattern, in: normalized, count: 2),
           let refund = try? Money(decimalString: cleanedAmount(values[1])),
           refund.minorUnits > 0 {
            baseAmount = values[0]
            expectedRefundMinorUnits = refund.minorUnits
        } else if let values = captureGroups(fullPattern, in: normalized, count: 1),
                  let original = try? Money(decimalString: cleanedAmount(values[0])),
                  original.minorUnits > 0 {
            baseAmount = values[0]
            expectedRefundMinorUnits = original.minorUnits
        } else {
            throw RowParsingError.skipped(.amountAnnotationNeedsConfirmation, "金额括号注释无法可靠解释")
        }
        guard transactionType != .refund,
              !orderID.isEmpty,
              let actualRefundMinorUnits = refundMinorUnitsByOrder[orderID],
              actualRefundMinorUnits == expectedRefundMinorUnits else {
            throw RowParsingError.skipped(
                .partialRefundNeedsConfirmation,
                "同订单号有效退款合计与金额注释不一致"
            )
        }
        return baseAmount
    }

    static func firstNonempty(_ values: [String]) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    static func requireSupportedStatus(_ value: String) throws {
        let normalized = BillTextNormalization.value(value)
        let unsupported = ["已关闭", "交易关闭", "失败", "已取消", "待支付", "等待付款", "未完成"]
        if let status = unsupported.first(where: normalized.contains) {
            throw RowParsingError.skipped(.unsupportedStatus, "交易状态“\(status)”不导入")
        }
    }

    static func parseDate(
        _ cell: TabularCell,
        excelDateSystem: ExcelDateSystem?,
        calendar: Calendar,
        defaultTimeZone: TimeZone,
        preservesExplicitTimeZone: Bool
    ) -> ImportedBillDate? {
        var parsingCalendar = calendar
        parsingCalendar.timeZone = defaultTimeZone
        if let serial = cell.excelSerial {
            return excelDate(
                serial: serial,
                system: excelDateSystem ?? .excel1900,
                calendar: parsingCalendar
            ).map { ImportedBillDate(date: $0, timeZone: defaultTimeZone) }
        }
        let value = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitTimeZone = explicitISOTimeZone(in: value) {
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: value) {
                return ImportedBillDate(
                    date: date,
                    timeZone: preservesExplicitTimeZone ? explicitTimeZone : defaultTimeZone
                )
            }
        }
        for format in [
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm", "yyyy.MM.dd HH:mm:ss", "yyyy年M月d日 HH:mm",
            "yyyy-MM-dd", "yyyy/MM/dd"
        ] {
            let formatter = DateFormatter()
            formatter.calendar = parsingCalendar
            formatter.locale = Locale(identifier: "zh_Hans_CN")
            formatter.timeZone = defaultTimeZone
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: value) {
                return ImportedBillDate(date: date, timeZone: defaultTimeZone)
            }
        }
        return nil
    }

    static func excelDate(serial: Double, system: ExcelDateSystem, calendar: Calendar) -> Date? {
        let lastDay = system == .excel1900 ? 2_958_465 : 2_957_003
        guard serial.isFinite, serial >= 0, serial < Double(lastDay + 1) else { return nil }
        let wholeDays = Int(floor(serial))
        let fractionalSeconds = Int(((serial - floor(serial)) * 86_400).rounded())
        guard wholeDays < lastDay || fractionalSeconds < 86_400 else { return nil }
        let baseComponents: DateComponents
        let adjustedDays: Int
        switch system {
        case .excel1900:
            guard wholeDays != 60 else { return nil }
            baseComponents = DateComponents(year: 1899, month: 12, day: 31)
            adjustedDays = wholeDays > 60 ? wholeDays - 1 : wholeDays
        case .excel1904:
            baseComponents = DateComponents(year: 1904, month: 1, day: 1)
            adjustedDays = wholeDays
        }
        guard let base = calendar.date(from: baseComponents),
              let day = calendar.date(byAdding: .day, value: adjustedDays, to: base) else { return nil }
        return calendar.date(byAdding: .second, value: fractionalSeconds, to: day)
    }

    private static func fnv1a(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func captureGroups(
        _ pattern: String,
        in value: String,
        count: Int
    ) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ) else { return nil }
        var values: [String] = []
        for index in 1...count {
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            values.append(String(value[range]))
        }
        return values
    }

    private static func explicitISOTimeZone(in value: String) -> TimeZone? {
        if value.hasSuffix("Z") || value.hasSuffix("z") {
            return TimeZone(secondsFromGMT: 0)
        }
        let pattern = #"([+-])(\d{2}):?(\d{2})$"#
        guard let values = captureGroups(pattern, in: value, count: 3),
              let hours = Int(values[1]),
              let minutes = Int(values[2]),
              hours <= 18,
              minutes < 60 else { return nil }
        let direction = values[0] == "-" ? -1 : 1
        return TimeZone(secondsFromGMT: direction * ((hours * 60 + minutes) * 60))
    }
}

struct ImportedBillDate {
    let date: Date
    let timeZone: TimeZone
}
