import CoreXLSX
import Foundation
import ZIPFoundation

enum TabularBillFileReader {
    static func read(data: Data, fileName: String) throws -> BillImportDocument {
        guard !data.isEmpty else { throw BillImportError.emptyFile }

        let format: BillFileFormat
        let encodingName: String?
        let delimiter: Character?
        let sheets: [TabularSheet]
        if isZIP(data) {
            format = .xlsx
            encodingName = nil
            delimiter = nil
            sheets = try readXLSX(data)
        } else {
            let decoded = try decodeCSV(data)
            let parsed = try parseBestCSV(decoded.text)
            format = .csv
            encodingName = decoded.name
            delimiter = parsed.delimiter
            sheets = [TabularSheet(name: "CSV", rows: parsed.rows)]
        }

        guard !sheets.isEmpty else { throw BillImportError.noRecognizableWorksheet }
        let choices = sheets.compactMap { sheet -> SheetChoice? in
            guard let headerIndex = BillSourceDetector.headerRowIndex(in: sheet.rows) else { return nil }
            let headers = sheet.rows[headerIndex].cells.map { cleanHeader($0.text) }
            let detection = BillSourceDetector.detect(
                headers: headers,
                preambleRows: Array(sheet.rows[..<headerIndex]),
                sheetName: format == .xlsx ? sheet.name : nil
            )
            return SheetChoice(
                sheet: sheet,
                headerIndex: headerIndex,
                headers: headers,
                detection: detection,
                score: BillSourceDetector.headerScore(sheet.rows[headerIndex])
            )
        }
        guard let selected = choices.max(by: { lhs, rhs in
            if lhs.detection.confidence != rhs.detection.confidence {
                return lhs.detection.confidence < rhs.detection.confidence
            }
            return lhs.score < rhs.score
        }) else {
            throw format == .xlsx ? BillImportError.noRecognizableWorksheet : BillImportError.malformedCSV
        }

        let bodyRows = selected.sheet.rows[(selected.headerIndex + 1)...]
            .filter { !isNonTransactionRow($0) }
        let rawRowCount = selected.sheet.rows.map(\.number).max() ?? selected.sheet.rows.count
        let mismatch = formatMismatchMessage(fileName: fileName, actual: format)
        _ = delimiter
        return BillImportDocument(
            format: format,
            encodingName: encodingName,
            sheetName: format == .xlsx ? selected.sheet.name : nil,
            excelDateSystem: selected.sheet.excelDateSystem,
            rawRowCount: rawRowCount,
            headerRowNumber: selected.sheet.rows[selected.headerIndex].number,
            headers: selected.headers,
            rows: Array(bodyRows),
            nonTransactionRowCount: rawRowCount - bodyRows.count,
            detection: selected.detection,
            formatMismatchMessage: mismatch
        )
    }

    static func readCSV(data: Data) throws -> CSVDocument {
        guard !data.isEmpty else { throw BillImportError.emptyFile }
        guard !isZIP(data) else { throw BillImportError.unsupportedFileType }
        let decoded = try decodeCSV(data)
        let parsed = try parseBestCSV(decoded.text)
        guard let headerIndex = BillSourceDetector.headerRowIndex(in: parsed.rows) else {
            throw BillImportError.malformedCSV
        }
        let headers = parsed.rows[headerIndex].cells.map { cleanHeader($0.text) }
        let body = parsed.rows[(headerIndex + 1)...]
            .filter { !$0.isEmpty }
            .map { $0.cells.map(\.text) }
        return CSVDocument(
            headers: headers,
            rows: Array(body),
            delimiter: parsed.delimiter,
            encodingName: decoded.name
        )
    }

    private struct SheetChoice {
        let sheet: TabularSheet
        let headerIndex: Int
        let headers: [String]
        let detection: BillSourceDetection
        let score: Int
    }

    private struct ParsedCSV {
        let rows: [TabularRow]
        let delimiter: Character
        let headerScore: Int
        let widestRow: Int
    }

    private static func isZIP(_ data: Data) -> Bool {
        data.starts(with: [0x50, 0x4B, 0x03, 0x04])
            || data.starts(with: [0x50, 0x4B, 0x05, 0x06])
            || data.starts(with: [0x50, 0x4B, 0x07, 0x08])
    }

    private static func formatMismatchMessage(fileName: String, actual: BillFileFormat) -> String? {
        let extensionName = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard !extensionName.isEmpty else { return nil }
        if extensionName == "csv", actual == .xlsx {
            return "扩展名为 .csv，但文件内容是 XLSX；已按 XLSX 读取。"
        }
        if extensionName == "xlsx", actual == .csv {
            return "扩展名为 .xlsx，但文件内容是 CSV；已按 CSV 读取。"
        }
        if !["csv", "xlsx", "txt", "tsv"].contains(extensionName) {
            return "文件扩展名为 .\(extensionName)，实际内容按 \(actual.rawValue) 读取。"
        }
        return nil
    }

    private static func decodeCSV(_ data: Data) throws -> (text: String, name: String) {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return try decoded(data.dropFirst(3), encoding: .utf8, name: "UTF-8 BOM")
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return try decoded(data.dropFirst(2), encoding: .utf16LittleEndian, name: "UTF-16 LE BOM")
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return try decoded(data.dropFirst(2), encoding: .utf16BigEndian, name: "UTF-16 BE BOM")
        }
        if let text = String(data: data, encoding: .utf8), isPlausibleText(text) {
            return (text, "UTF-8")
        }
        let gb18030 = String.Encoding(rawValue: 0x8000_0632)
        if let text = String(data: data, encoding: gb18030), isPlausibleText(text) {
            return (text, "GB18030")
        }
        let cp936 = String.Encoding(rawValue: 0x8000_0421)
        if let text = String(data: data, encoding: cp936), isPlausibleText(text) {
            return (text, "GBK/CP936")
        }
        throw BillImportError.unsupportedEncoding
    }

    private static func decoded(
        _ bytes: Data.SubSequence,
        encoding: String.Encoding,
        name: String
    ) throws -> (text: String, name: String) {
        guard let text = String(data: Data(bytes), encoding: encoding), isPlausibleText(text) else {
            throw BillImportError.unsupportedEncoding
        }
        return (text, name)
    }

    private static func isPlausibleText(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains("\u{FFFD}") else { return false }
        let scalars = text.unicodeScalars
        let unacceptable = scalars.filter { scalar in
            scalar.value < 0x20 && ![0x09, 0x0A, 0x0D].contains(scalar.value)
        }.count
        return Double(unacceptable) / Double(max(1, scalars.count)) < 0.01
    }

    private static func parseBestCSV(_ text: String) throws -> ParsedCSV {
        let candidates = try [Character(","), Character("\t"), Character(";")].map { delimiter in
            let rows = try parseCSVRows(text, delimiter: delimiter)
            let headerScore = rows.prefix(80).map(BillSourceDetector.headerScore).max() ?? 0
            return ParsedCSV(
                rows: rows,
                delimiter: delimiter,
                headerScore: headerScore,
                widestRow: rows.map(\.cells.count).max() ?? 0
            )
        }
        guard let best = candidates.max(by: { lhs, rhs in
            lhs.headerScore == rhs.headerScore
                ? lhs.widestRow < rhs.widestRow
                : lhs.headerScore < rhs.headerScore
        }), best.widestRow >= 2 else {
            throw BillImportError.malformedCSV
        }
        return best
    }

    private static func parseCSVRows(_ text: String, delimiter: Character) throws -> [TabularRow] {
        var result: [TabularRow] = []
        var fields: [String] = []
        var field = ""
        var quoted = false
        var rowNumber = 1
        var index = text.startIndex

        func finishField() {
            fields.append(field)
            field = ""
        }
        func finishRow() {
            finishField()
            result.append(TabularRow(
                number: rowNumber,
                cells: fields.map { TabularCell(text: $0) }
            ))
            fields = []
            rowNumber += 1
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\"" {
                if quoted, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    quoted.toggle()
                }
            } else if character == delimiter, !quoted {
                finishField()
            } else if (character == "\n" || character == "\r" || character == "\r\n"), !quoted {
                if character == "\r", next < text.endIndex, text[next] == "\n" {
                    index = next
                }
                finishRow()
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        guard !quoted else { throw BillImportError.malformedCSV }
        if !field.isEmpty || !fields.isEmpty {
            finishRow()
        }
        return result
    }

    private static func readXLSX(_ data: Data) throws -> [TabularSheet] {
        do {
            let file = try XLSXFile(data: data)
            let sharedStrings = try file.parseSharedStrings()
            let workbookPaths = try file.parseDocumentPaths()
            let workbooks = try file.parseWorkbooks()
            var sheets: [TabularSheet] = []
            for (workbookIndex, workbook) in workbooks.enumerated() {
                guard workbookPaths.indices.contains(workbookIndex) else {
                    throw BillImportError.invalidXLSX
                }
                let dateSystem = try workbookDateSystem(
                    in: data,
                    workbookPath: workbookPaths[workbookIndex]
                )
                for (index, item) in try file.parseWorksheetPathsAndNames(workbook: workbook).enumerated() {
                    let worksheet = try file.parseWorksheet(at: item.path)
                    let rows = (worksheet.data?.rows ?? []).map { row in
                        let maxColumn = row.cells.map { columnIndex($0.reference.column) }.max() ?? 0
                        var cells = Array(repeating: TabularCell(), count: maxColumn + 1)
                        for cell in row.cells {
                            cells[columnIndex(cell.reference.column)] = tabularCell(
                                cell,
                                sharedStrings: sharedStrings
                            )
                        }
                        return TabularRow(number: Int(row.reference), cells: cells)
                    }
                    let workbookName = workbook.sheets.items.indices.contains(index)
                        ? workbook.sheets.items[index].name
                        : nil
                    sheets.append(TabularSheet(
                        name: item.name ?? workbookName ?? "工作表",
                        rows: rows,
                        excelDateSystem: dateSystem
                    ))
                }
            }
            guard !sheets.isEmpty else { throw BillImportError.noRecognizableWorksheet }
            return sheets
        } catch let error as BillImportError {
            throw error
        } catch {
            throw BillImportError.invalidXLSX
        }
    }

    private static func columnIndex(_ column: ColumnReference) -> Int {
        ColumnReference("A")!.distance(to: column)
    }

    private static func tabularCell(_ cell: Cell, sharedStrings: SharedStrings?) -> TabularCell {
        let text: String
        if let sharedStrings {
            if let string = cell.stringValue(sharedStrings) {
                text = string
            } else {
                let richText = cell.richStringValue(sharedStrings).compactMap(\.text).joined()
                text = richText.isEmpty ? (cell.inlineString?.text ?? cell.value ?? "") : richText
            }
        } else {
            text = cell.inlineString?.text ?? cell.value ?? ""
        }
        if cell.type == .bool {
            return TabularCell(text: text == "1" ? "TRUE" : "FALSE")
        }
        let excelSerial: Double?
        if cell.type == nil || cell.type == .number {
            excelSerial = cell.value.flatMap(Double.init)
        } else {
            excelSerial = nil
        }
        return TabularCell(text: text, excelSerial: excelSerial)
    }

    static func excelDateSystem(workbookXML: Data) throws -> ExcelDateSystem {
        guard let xml = String(data: workbookXML, encoding: .utf8) else {
            throw BillImportError.invalidXLSX
        }
        let attributePattern = #"date1904\s*=\s*[\"']([^\"']+)[\"']"#
        guard let expression = try? NSRegularExpression(
            pattern: attributePattern,
            options: [.caseInsensitive]
        ) else {
            throw BillImportError.invalidXLSX
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = expression.firstMatch(in: xml, range: range),
              let valueRange = Range(match.range(at: 1), in: xml) else {
            return .excel1900
        }
        switch xml[valueRange].lowercased() {
        case "1", "true":
            return .excel1904
        case "0", "false":
            return .excel1900
        default:
            throw BillImportError.unsupportedExcelDateSystem
        }
    }

    private static func workbookDateSystem(
        in data: Data,
        workbookPath: String
    ) throws -> ExcelDateSystem {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw BillImportError.invalidXLSX
        }
        let path = workbookPath.hasPrefix("/") ? String(workbookPath.dropFirst()) : workbookPath
        guard let entry = archive[path] else {
            throw BillImportError.invalidXLSX
        }
        var workbookXML = Data()
        _ = try archive.extract(entry) { workbookXML.append($0) }
        return try excelDateSystem(workbookXML: workbookXML)
    }

    private static func cleanHeader(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isNonTransactionRow(_ row: TabularRow) -> Bool {
        guard !row.isEmpty else { return true }
        if BillSourceDetector.headerScore(row) >= 2 { return true }

        let values = row.cells
            .map { BillTextNormalization.value($0.text) }
            .filter { !$0.isEmpty }
        guard values.count <= 3 else { return false }
        let text = values.joined(separator: "|")
        let markers = [
            "合计", "总计", "统计", "温馨提示", "友情提示", "导出时间",
            "账单结束", "明细结束", "以下内容", "数据说明", "文件说明"
        ]
        return markers.contains { text.contains($0) }
    }
}
