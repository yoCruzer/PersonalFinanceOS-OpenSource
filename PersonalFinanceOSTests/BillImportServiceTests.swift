import SwiftData
import XCTest
@testable import PersonalFinanceOS

final class BillImportServiceTests: XCTestCase {
    func testCSVDecodesSupportedEncodingsAndRejectsInvalidBytes() throws {
        let utf8 = Data("date_time,amount\n2026-01-01,1.00".utf8)
        XCTAssertEqual(try FinanceCSVService.parseDocument(data: utf8).encodingName, "UTF-8")

        let bom = Data([0xEF, 0xBB, 0xBF]) + utf8
        XCTAssertEqual(try FinanceCSVService.parseDocument(data: bom).encodingName, "UTF-8 BOM")

        let utf16Text = "日期时间,金额\r\n2026-01-01,1.00"
        let utf16Payload = try XCTUnwrap(utf16Text.data(using: .utf16LittleEndian))
        let utf16 = Data([0xFF, 0xFE]) + utf16Payload
        XCTAssertEqual(try FinanceCSVService.parseDocument(data: utf16).encodingName, "UTF-16 LE BOM")

        let utf16BEPayload = try XCTUnwrap(utf16Text.data(using: .utf16BigEndian))
        let utf16BE = Data([0xFE, 0xFF]) + utf16BEPayload
        XCTAssertEqual(try FinanceCSVService.parseDocument(data: utf16BE).encodingName, "UTF-16 BE BOM")

        let cp936 = String.Encoding(rawValue: 0x8000_0421)
        let cp936Payload = try XCTUnwrap(utf16Text.data(using: cp936))
        let compatible = try FinanceCSVService.parseDocument(data: cp936Payload)
        XCTAssertTrue(["GB18030", "GBK/CP936"].contains(compatible.encodingName))
        XCTAssertEqual(compatible.headers, ["日期时间", "金额"])

        XCTAssertThrowsError(try FinanceCSVService.parseDocument(data: Data([0x81]))) { error in
            XCTAssertEqual(error as? BillImportError, .unsupportedEncoding)
        }
    }

    func testCSVHandlesTabsQuotesCommasEscapedQuotesAndMultilineFields() throws {
        let tab = "日期时间\t金额\t备注\n2026-01-01 10:00\t1.00\t测试"
        let tabDocument = try FinanceCSVService.parseDocument(data: Data(tab.utf8))
        XCTAssertEqual(tabDocument.delimiter, "\t")
        XCTAssertEqual(tabDocument.rows.first?[2], "测试")

        let csv = """
        date_time,amount,note
        2026-01-01 10:00,"1,234.56","第一行,""引用""
        第二行"
        """
        let document = try FinanceCSVService.parseDocument(data: Data(csv.utf8))
        XCTAssertEqual(document.rows.count, 1)
        XCTAssertEqual(document.rows[0][1], "1,234.56")
        XCTAssertEqual(document.rows[0][2], "第一行,\"引用\"\n第二行")
    }

    func testAlipayGB18030FindsHeaderAndClassifiesNonTransactionRows() throws {
        let data = try fixture("alipay_bill_gb18030", extension: "csv")
        let document = try FinanceCSVService.readImportDocument(data: data, fileName: "unrelated.csv")
        XCTAssertEqual(document.format, .csv)
        XCTAssertEqual(document.encodingName, "GB18030")
        XCTAssertEqual(document.headerRowNumber, 24)
        XCTAssertEqual(document.nonTransactionRowCount, 24)
        XCTAssertEqual(document.detection.source, .alipay)

        let plan = try plan(document)
        XCTAssertEqual(plan.candidates.count, 2)
        XCTAssertEqual(Set(plan.candidates.map(\.type)), [.expense, .refund])
        XCTAssertEqual(plan.skippedRows.count, 1)
        XCTAssertEqual(plan.skippedRows.first?.reason, .unsupportedStatus)
        XCTAssertEqual(plan.failedRows.count, 0)
    }

    func testJDBOMCSVParsesPaymentRefundAndConservativelySkipsRepayment() throws {
        let data = try fixture("jd_bill_utf8_bom", extension: "csv")
        let document = try FinanceCSVService.readImportDocument(data: data, fileName: "neutral.csv")
        XCTAssertEqual(document.encodingName, "UTF-8 BOM")
        XCTAssertEqual(document.headerRowNumber, 22)
        XCTAssertEqual(document.nonTransactionRowCount, 22)
        XCTAssertEqual(document.detection.source, .jd)

        let plan = try plan(document)
        XCTAssertEqual(plan.candidates.count, 2)
        XCTAssertEqual(Set(plan.candidates.map(\.type)), [.expense, .refund])
        XCTAssertEqual(plan.skippedRows.map(\.detail), ["信用卡还款需要确认账户间资金流转"])
        XCTAssertTrue(plan.failedRows.isEmpty)
    }

    func testWeChatXLSXReadsNumericDatesAndDedicatedSemantics() throws {
        let data = try fixture("wechat_bill", extension: "xlsx")
        let document = try FinanceCSVService.readImportDocument(data: data, fileName: "neutral.bin")
        XCTAssertEqual(document.format, .xlsx)
        XCTAssertEqual(document.sheetName, "Sheet1")
        XCTAssertEqual(document.headerRowNumber, 18)
        XCTAssertEqual(document.nonTransactionRowCount, 18)
        XCTAssertEqual(document.detection.source, .wechat)
        XCTAssertEqual(document.excelDateSystem, .excel1900)

        let plan = try plan(document)
        XCTAssertEqual(plan.candidates.count, 3)
        XCTAssertEqual(Set(plan.candidates.map(\.type)), [.expense, .income, .refund])
        XCTAssertTrue(plan.failedRows.isEmpty)
        XCTAssertTrue(plan.skippedRows.isEmpty)
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: try XCTUnwrap(plan.candidates.first?.occurredAt)
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 2)
        XCTAssertEqual(components.hour, 4)
        XCTAssertEqual(components.minute, 30)
    }

    func testWacaiXLSXSelectsSheetAndParsesTypedAmounts() throws {
        let data = try fixture("wacai_bill", extension: "xlsx")
        let document = try FinanceCSVService.readImportDocument(data: data, fileName: "neutral.xlsx")
        XCTAssertEqual(document.sheetName, "Sheet0")
        XCTAssertEqual(document.headerRowNumber, 7)
        XCTAssertEqual(document.nonTransactionRowCount, 7)
        XCTAssertEqual(document.detection.source, .wacai)

        let plan = try plan(document)
        XCTAssertEqual(plan.candidates.map(\.amountMinorUnits), [2_345, 10_000])
        XCTAssertEqual(plan.candidates.map(\.type), [.expense, .income])
    }

    func testContentSignatureWinsAndReportsExtensionMismatch() throws {
        let xlsx = try fixture("wechat_bill", extension: "xlsx")
        let workbook = try FinanceCSVService.readImportDocument(data: xlsx, fileName: "fake.csv")
        XCTAssertEqual(workbook.format, .xlsx)
        XCTAssertNotNil(workbook.formatMismatchMessage)

        let csv = Data("date_time,amount\n2026-01-01,1.00".utf8)
        let text = try FinanceCSVService.readImportDocument(data: csv, fileName: "fake.xlsx")
        XCTAssertEqual(text.format, .csv)
        XCTAssertNotNil(text.formatMismatchMessage)
    }

    func testUnknownCSVAndXLSXRetainGenericMappingFallback() throws {
        let csv = try fixture("generic", extension: "csv")
        let csvDocument = try FinanceCSVService.readImportDocument(data: csv, fileName: "unknown.csv")
        XCTAssertEqual(csvDocument.detection.source, .genericCSV)
        let csvPlan = try plan(csvDocument)
        XCTAssertEqual(csvPlan.source, .genericCSV)
        XCTAssertEqual(csvPlan.parsingMethod, .genericMapping)
        XCTAssertEqual(csvPlan.candidates.count, 2)

        let xlsx = try fixture("generic_bill", extension: "xlsx")
        let xlsxDocument = try FinanceCSVService.readImportDocument(data: xlsx, fileName: "unknown.xlsx")
        XCTAssertEqual(xlsxDocument.detection.source, .genericCSV)
        let xlsxPlan = try plan(xlsxDocument)
        XCTAssertEqual(xlsxPlan.source, .genericCSV)
        XCTAssertEqual(xlsxPlan.parsingMethod, .genericMapping)
        XCTAssertEqual(xlsxPlan.candidates.count, 1)
    }

    func testInvalidTransactionRowDoesNotBlockValidPreview() throws {
        let csv = """
        date_time,type,amount,note
        2026-01-01 10:00,expense,1.00,有效
        invalid,expense,abc,损坏
        2026-01-02 10:00,expense,0.00,零金额
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8),
            fileName: "generic.csv"
        )
        let plan = try plan(document)
        XCTAssertEqual(plan.candidates.count, 1)
        XCTAssertEqual(plan.failedRows.count, 1)
        XCTAssertEqual(plan.failedRows.first?.reason, .invalidAmount)
        XCTAssertEqual(plan.skippedRows.count, 1)
        XCTAssertEqual(plan.skippedRows.first?.reason, .zeroAmount)
    }

    func testJDRefundAnnotationRequiresAndPreservesIndependentRefundRow() throws {
        let csv = """
        交易时间,商户名称,交易说明,金额,收/付款方式,交易状态,收/支,交易分类,交易订单号
        2026-01-11 14:00:00,示例商户,普通支付,30.00(已退款5.00),银行卡,交易成功,支出,购物,JD-ANNOTATED
        2026-01-12 14:00:00,示例商户,退款,5.00,银行卡,退款成功,收入,退款,JD-ANNOTATED
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8),
            fileName: "neutral.csv"
        )
        let parsed = try plan(document)
        XCTAssertEqual(parsed.source, .jd)
        XCTAssertEqual(parsed.candidates.map(\.amountMinorUnits), [3_000, 500])
        XCTAssertEqual(parsed.candidates.map(\.type), [.expense, .refund])
        XCTAssertEqual(Set(parsed.candidates.map(\.externalTransactionID)), ["JD-ANNOTATED"])
        XCTAssertEqual(Set(parsed.candidates.map(\.fingerprint)).count, 2)
        XCTAssertEqual(parsed.duplicateCount, 0)
        XCTAssertEqual(parsed.effectiveRowsToImport(includeSuspectedDuplicates: false).count, 2)
        XCTAssertEqual(Set(parsed.candidates.map(\.stableEventIdentity)).count, 2)
    }

    func testJDRefundAnnotationRejectsMismatchedRefundTotal() throws {
        let parsed = try jdPlan(rows: [
            "2026-01-11 14:00:00,示例商户,普通支付,30.00(已退款5.00),银行卡,交易成功,支出,购物,JD-MISMATCH",
            "2026-01-12 14:00:00,示例商户,退款,3.00,银行卡,退款成功,收入,退款,JD-MISMATCH"
        ])
        XCTAssertEqual(parsed.candidates.map(\.type), [.refund])
        XCTAssertEqual(parsed.candidates.map(\.amountMinorUnits), [300])
        XCTAssertEqual(parsed.skippedRows.map(\.reason), [.partialRefundNeedsConfirmation])
    }

    func testJDZeroRefundCannotProveAnnotatedOriginal() throws {
        let parsed = try jdPlan(rows: [
            "2026-01-11 14:00:00,示例商户,普通支付,30.00(已退款5.00),银行卡,交易成功,支出,购物,JD-ZERO",
            "2026-01-12 14:00:00,示例商户,退款,0.00,银行卡,退款成功,收入,退款,JD-ZERO"
        ])
        XCTAssertTrue(parsed.candidates.isEmpty)
        XCTAssertEqual(Set(parsed.skippedRows.map(\.reason)), [.partialRefundNeedsConfirmation, .zeroAmount])
    }

    func testJDInvalidDateRefundCannotProveAnnotatedOriginal() throws {
        let parsed = try jdPlan(rows: [
            "2026-01-11 14:00:00,示例商户,普通支付,30.00(已退款5.00),银行卡,交易成功,支出,购物,JD-DATE",
            "not-a-date,示例商户,退款,5.00,银行卡,退款成功,收入,退款,JD-DATE"
        ])
        XCTAssertTrue(parsed.candidates.isEmpty)
        XCTAssertEqual(parsed.skippedRows.map(\.reason), [.partialRefundNeedsConfirmation])
        XCTAssertEqual(parsed.failedRows.map(\.reason), [.invalidDate])
    }

    func testJDFileInternalDuplicateIsReportedButPreservedByDefault() throws {
        let refund = "2026-01-12 14:00:00,示例商户,退款,5.00,银行卡,退款成功,收入,退款,JD-DUPLICATE-MATCH,M-DUPLICATE-MATCH"
        let parsed = try jdPlan(rows: [
            "2026-01-11 14:00:00,示例商户,普通支付,30.00(已退款5.00),银行卡,交易成功,支出,购物,JD-DUPLICATE-MATCH,M-DUPLICATE-ORIGINAL",
            refund,
            refund
        ])

        XCTAssertEqual(parsed.candidates.count, 3)
        XCTAssertEqual(parsed.candidates.map(\.type), [.expense, .refund, .refund])
        XCTAssertEqual(parsed.duplicateCount, 0)
        XCTAssertEqual(parsed.withinFileDuplicateCount, 1)
        XCTAssertEqual(parsed.effectiveRowsToImport(includeSuspectedDuplicates: true).count, 3)
        XCTAssertEqual(parsed.expenseMinorUnits(includeSuspectedDuplicates: true), 3_000)
        XCTAssertEqual(parsed.refundMinorUnits(includeSuspectedDuplicates: true), 1_000)
        XCTAssertTrue(parsed.rowIssues.isEmpty)
    }

    func testJDConflictingRefundIdentityCannotFakeRelationshipOrDropRows() throws {
        let refund = "2026-01-12 14:00:00,示例商户,退款,5.00,银行卡,退款成功,收入,退款,JD-DUPLICATE-MISMATCH,M-DUPLICATE-MISMATCH"
        let parsed = try jdPlan(rows: [
            "2026-01-11 14:00:00,示例商户,普通支付,30.00(已退款10.00),银行卡,交易成功,支出,购物,JD-DUPLICATE-MISMATCH,M-DUPLICATE-ORIGINAL",
            refund,
            refund
        ])

        XCTAssertEqual(parsed.candidates.count, 2)
        XCTAssertTrue(parsed.candidates.allSatisfy { $0.type == .refund })
        XCTAssertEqual(parsed.duplicateCount, 0)
        XCTAssertEqual(parsed.withinFileDuplicateCount, 1)
        XCTAssertEqual(parsed.skippedRows.map(\.reason), [.partialRefundNeedsConfirmation])
        XCTAssertEqual(parsed.effectiveRowsToImport(includeSuspectedDuplicates: true).count, 2)
        XCTAssertEqual(parsed.refundMinorUnits(includeSuspectedDuplicates: true), 1_000)

        let conflicting = try jdPlan(rows: [
            "2026-01-11 14:00:00,示例商户,普通支付,30.00(已退款8.00),银行卡,交易成功,支出,购物,JD-CONFLICT,M-CONFLICT-ORIGINAL",
            "2026-01-12 14:00:00,示例商户,退款,5.00,银行卡,退款成功,收入,退款,JD-CONFLICT,M-CONFLICT",
            "2026-01-13 14:00:00,示例商户,退款,3.00,银行卡,退款成功,收入,退款,JD-CONFLICT,M-CONFLICT"
        ])
        XCTAssertEqual(conflicting.candidates.count, 2)
        XCTAssertTrue(conflicting.candidates.allSatisfy { $0.type == .refund })
        XCTAssertEqual(conflicting.duplicateCount, 0)
        XCTAssertEqual(conflicting.withinFileDuplicateCount, 1)
        XCTAssertEqual(
            conflicting.effectiveRowsToImport(includeSuspectedDuplicates: true).count,
            2
        )
        XCTAssertEqual(conflicting.skippedRows.map(\.reason), [.partialRefundNeedsConfirmation])
    }

    func testJDMultipleRefundsCanMatchAnnotatedTotal() throws {
        let parsed = try jdPlan(rows: [
            "2026-01-11 14:00:00,示例商户,普通支付,30.00(已退款5.00),银行卡,交易成功,支出,购物,JD-MULTI,M-ORIGINAL",
            "2026-01-12 14:00:00,示例商户,退款,2.00,银行卡,退款成功,收入,退款,JD-MULTI,M-REFUND-1",
            "2026-01-13 14:00:00,示例商户,退款,3.00,银行卡,退款成功,收入,退款,JD-MULTI,M-REFUND-2"
        ])
        XCTAssertEqual(parsed.candidates.map(\.type), [.expense, .refund, .refund])
        XCTAssertEqual(parsed.duplicateCount, 0)
        XCTAssertEqual(parsed.effectiveRowsToImport(includeSuspectedDuplicates: false).count, 3)
        XCTAssertEqual(parsed.expenseMinorUnits(includeSuspectedDuplicates: false), 3_000)
        XCTAssertEqual(parsed.refundMinorUnits(includeSuspectedDuplicates: false), 500)
        XCTAssertEqual(
            Set(parsed.candidates.filter { $0.type == .refund }.map(\.stableEventIdentity)).count,
            2
        )
        XCTAssertTrue(parsed.rowIssues.isEmpty)
    }

    func testRefundAggregateOverflowRejectsOnlyTheAffectedOrder() throws {
        let parsed = try jdPlan(rows: [
            "2026-01-11 14:00:00,甲,支付,2.00(已全额退款),银行卡,交易成功,支出,购物,A",
            "2026-01-12 14:00:00,甲,退款,92233720368547758.07,银行卡,退款成功,收入,退款,A",
            "2026-01-13 14:00:00,甲,退款,0.01,银行卡,退款成功,收入,退款,A",
            "2026-01-14 14:00:00,乙,支付,1.00,银行卡,交易成功,支出,购物,B"
        ])
        XCTAssertEqual(parsed.failedRows.map(\.reason), [.invalidAmount, .invalidAmount, .invalidAmount])
        XCTAssertEqual(parsed.candidates.map(\.externalTransactionID), ["B"])
    }

    func testExcelDatesStayWithinEachSystemsSupportedCalendar() {
        for (system, lastDay) in [(ExcelDateSystem.excel1900, 2_958_465.0), (.excel1904, 2_957_003.0)] {
            XCTAssertNotNil(BillParserSupport.excelDate(serial: lastDay + 0.5, system: system, calendar: calendar))
            for serial in [lastDay + 1, (lastDay + 1).nextDown, Double.greatestFiniteMagnitude, .infinity, -1] {
                XCTAssertNil(BillParserSupport.excelDate(serial: serial, system: system, calendar: calendar))
            }
        }
    }

    func testJDMultipleRefundsRejectMismatchedAnnotatedTotal() throws {
        let parsed = try jdPlan(rows: [
            "2026-01-11 14:00:00,示例商户,普通支付,30.00(已退款5.00),银行卡,交易成功,支出,购物,JD-MULTI-WRONG",
            "2026-01-12 14:00:00,示例商户,退款,2.00,银行卡,退款成功,收入,退款,JD-MULTI-WRONG",
            "2026-01-13 14:00:00,示例商户,退款,2.00,银行卡,退款成功,收入,退款,JD-MULTI-WRONG"
        ])
        XCTAssertEqual(parsed.candidates.map(\.type), [.refund, .refund])
        XCTAssertEqual(parsed.skippedRows.map(\.reason), [.partialRefundNeedsConfirmation])
    }

    @MainActor
    func testJDFullRefundRequiresTotalEqualToOriginalAmount() throws {
        let matched = try jdPlan(rows: [
            "2026-01-11 14:00:00,示例商户,普通支付,30.00(已全额退款),银行卡,交易成功,支出,购物,JD-FULL,M-FULL-ORIGINAL",
            "2026-01-12 14:00:00,示例商户,退款,10.00,银行卡,退款成功,收入,退款,JD-FULL,M-FULL-1",
            "2026-01-13 14:00:00,示例商户,退款,20.00,银行卡,退款成功,收入,退款,JD-FULL,M-FULL-2"
        ])
        XCTAssertEqual(matched.candidates.map(\.type), [.expense, .refund, .refund])
        XCTAssertEqual(matched.duplicateCount, 0)
        XCTAssertEqual(matched.effectiveRowsToImport(includeSuspectedDuplicates: false).count, 3)
        XCTAssertEqual(matched.refundMinorUnits(includeSuspectedDuplicates: false), 3_000)
        XCTAssertTrue(matched.rowIssues.isEmpty)

        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(name: "默认账户", type: .cash, isDefault: true)
        let category = Category(
            kind: .expense,
            name: "其他",
            symbolName: "ellipsis.circle",
            colorToken: "teal",
            isSystemCategory: true
        )
        context.insert(account)
        context.insert(category)
        try context.save()
        let result = try FinanceCSVService.commit(
            plan: matched,
            accounts: [account],
            categories: [category],
            tags: [],
            in: context
        )
        let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(result.importedCount, 3)
        XCTAssertEqual(transactions.count, 3)
        XCTAssertEqual(
            transactions.filter { $0.type == .expense }.reduce(0) { $0 + $1.amountMinorUnits },
            3_000
        )
        XCTAssertEqual(
            transactions.filter { $0.type == .refund }.reduce(0) { $0 + $1.amountMinorUnits },
            3_000
        )

        let mismatched = try jdPlan(rows: [
            "2026-01-11 14:00:00,示例商户,普通支付,30.00(已全额退款),银行卡,交易成功,支出,购物,JD-FULL-WRONG",
            "2026-01-12 14:00:00,示例商户,退款,29.00,银行卡,退款成功,收入,退款,JD-FULL-WRONG"
        ])
        XCTAssertEqual(mismatched.candidates.map(\.type), [.refund])
        XCTAssertEqual(mismatched.skippedRows.map(\.reason), [.partialRefundNeedsConfirmation])
    }

    @MainActor
    func testJDOriginalAndRefundDeduplicateIndependentlyOnRepeatImport() throws {
        let first = try jdPlan(rows: [
            "2026-01-11 14:00:00,示例商户,普通支付,30.00(已退款5.00),银行卡,交易成功,支出,购物,JD-REPEAT,M-REPEAT-ORIGINAL",
            "2026-01-12 14:00:00,示例商户,退款,2.00,银行卡,退款成功,收入,退款,JD-REPEAT,M-REPEAT-1",
            "2026-01-13 14:00:00,示例商户,退款,3.00,银行卡,退款成功,收入,退款,JD-REPEAT,M-REPEAT-2"
        ])
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(name: "默认账户", type: .cash, isDefault: true)
        let category = Category(
            kind: .expense,
            name: "其他",
            symbolName: "ellipsis.circle",
            colorToken: "teal",
            isSystemCategory: true
        )
        context.insert(account)
        context.insert(category)
        try context.save()
        _ = try FinanceCSVService.commit(
            plan: first,
            accounts: [account],
            categories: [category],
            tags: [],
            in: context
        )
        let existing = try context.fetch(FetchDescriptor<FinanceTransaction>())
        let second = try jdPlan(rows: [
            "2026-01-11 14:00:00,示例商户,普通支付,30.00(已退款5.00),银行卡,交易成功,支出,购物,JD-REPEAT,M-REPEAT-ORIGINAL",
            "2026-01-12 14:00:00,示例商户,退款,2.00,银行卡,退款成功,收入,退款,JD-REPEAT,M-REPEAT-1",
            "2026-01-13 14:00:00,示例商户,退款,3.00,银行卡,退款成功,收入,退款,JD-REPEAT,M-REPEAT-2"
        ], existingTransactions: existing)
        XCTAssertEqual(first.duplicateCount, 0)
        XCTAssertEqual(first.effectiveRowsToImport(includeSuspectedDuplicates: false).count, 3)
        XCTAssertEqual(second.duplicateCount, 3)
        XCTAssertTrue(second.candidates.allSatisfy(\.isDuplicate))
        XCTAssertTrue(second.effectiveRowsToImport(includeSuspectedDuplicates: false).isEmpty)
        XCTAssertEqual(Set(second.candidates.map(\.type)), [.expense, .refund])
    }

    func testJDIdenticalRefundRowsAreReportedAsWithinFileDuplicates() throws {
        let row = "2026-01-12 14:00:00,示例商户,退款,5.00,银行卡,退款成功,收入,退款,JD-EXACT,M-EXACT"
        let parsed = try jdPlan(rows: [row, row])
        XCTAssertEqual(parsed.candidates.count, 2)
        XCTAssertEqual(parsed.duplicateCount, 0)
        XCTAssertEqual(parsed.withinFileDuplicateCount, 1)
        XCTAssertEqual(parsed.effectiveRowsToImport(includeSuspectedDuplicates: true).count, 2)
        XCTAssertEqual(parsed.refundMinorUnits(includeSuspectedDuplicates: true), 1_000)
    }

    func testJDRefundsWithSameOrderAndAmountButDifferentTimesStayDistinct() throws {
        let parsed = try jdPlan(rows: [
            "2026-01-12 14:00:00,示例商户,退款,5.00,银行卡,退款成功,收入,退款,JD-SAME-AMOUNT",
            "2026-01-13 14:00:00,示例商户,退款,5.00,银行卡,退款成功,收入,退款,JD-SAME-AMOUNT"
        ])
        XCTAssertEqual(parsed.duplicateCount, 0)
        XCTAssertEqual(parsed.effectiveRowsToImport(includeSuspectedDuplicates: false).count, 2)
        XCTAssertEqual(Set(parsed.candidates.map(\.stableEventIdentity)).count, 2)
    }

    func testJDRefundsWithSameOrderAndTimeButDifferentAmountsStayDistinct() throws {
        let parsed = try jdPlan(rows: [
            "2026-01-12 14:00:00,示例商户,退款,2.00,银行卡,退款成功,收入,退款,JD-SAME-TIME",
            "2026-01-12 14:00:00,示例商户,退款,3.00,银行卡,退款成功,收入,退款,JD-SAME-TIME"
        ])
        XCTAssertEqual(parsed.duplicateCount, 0)
        XCTAssertEqual(parsed.effectiveRowsToImport(includeSuspectedDuplicates: false).count, 2)
        XCTAssertEqual(Set(parsed.candidates.map(\.stableEventIdentity)).count, 2)
    }

    func testJDDedicatedAndGenericParsingShareRefundEventIdentity() throws {
        let document = try jdDocument(rows: [
            "2026-01-12 14:00:00,示例商户,退款,5.00,银行卡,退款成功,收入,退款,JD-CROSS-MODE,M-CROSS-MODE"
        ])
        let dedicated = try plan(document)
        var mapping = FinanceCSVService.autoMapping(headers: document.headers)
        mapping.type = document.headers.firstIndex(of: "交易状态")
        let generic = try FinanceCSVService.makePlan(
            document: document,
            mapping: mapping,
            fileName: "jd.csv",
            existingTransactions: [],
            parserMode: .generic,
            calendar: calendar
        )
        let dedicatedRefund = try XCTUnwrap(dedicated.candidates.first)
        let genericRefund = try XCTUnwrap(generic.candidates.first)
        XCTAssertEqual(dedicatedRefund.type, .refund)
        XCTAssertEqual(genericRefund.type, .refund)
        XCTAssertEqual(dedicatedRefund.stableEventIdentity, genericRefund.stableEventIdentity)
        XCTAssertEqual(dedicatedRefund.fingerprint, genericRefund.fingerprint)
    }

    func testJDRefundAnnotationWithoutExactlyLinkedRefundNeedsConfirmation() throws {
        let csv = """
        交易时间,商户名称,交易说明,金额,收/付款方式,交易状态,收/支,交易分类,交易订单号
        2026-01-11 14:00:00,示例商户,普通支付,30.00(已退款5.00),银行卡,交易成功,支出,购物,JD-ORIGINAL
        2026-01-12 14:00:00,示例商户,退款,5.00,银行卡,退款成功,收入,退款,JD-SIMILAR
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8), fileName: "neutral.csv"
        )
        let parsed = try plan(document)
        XCTAssertEqual(parsed.candidates.map(\.type), [.refund])
        XCTAssertEqual(parsed.skippedRows.map(\.reason), [.partialRefundNeedsConfirmation])
    }

    func testJDUnknownAmountAnnotationNeedsConfirmation() throws {
        let csv = """
        交易时间,商户名称,交易说明,金额,收/付款方式,交易状态,收/支,交易分类,交易订单号
        2026-01-11 14:00:00,示例商户,普通支付,30.00(含优惠),银行卡,交易成功,支出,购物,JD-UNKNOWN
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8), fileName: "neutral.csv"
        )
        let parsed = try plan(document)
        XCTAssertTrue(parsed.candidates.isEmpty)
        XCTAssertEqual(parsed.skippedRows.map(\.reason), [.amountAnnotationNeedsConfirmation])
    }

    func testCommonChineseHeadersDoNotImpersonateWacai() throws {
        let csv = """
        收支类型,金额,日期时间,分类,账户,备注,标签
        支出,1.00,2026-01-01 10:00,餐饮,现金,早餐,日常
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8), fileName: "挖财.csv"
        )
        XCTAssertEqual(document.detection.source, .genericCSV)
        XCTAssertEqual(try plan(document).source, .genericCSV)
    }

    func testDedicatedSourcesAcceptMissingOptionalColumns() throws {
        let samples: [(String, ImportSourceType)] = [
            ("""
            微信支付账单
            交易时间,交易类型,收/支,金额(元)
            2026-01-01 10:00,商户消费,支出,1.00
            """, .wechat),
            ("""
            支付宝交易明细
            交易时间,收/支,金额
            2026-01-01 10:00,支出,2.00
            """, .alipay),
            ("""
            京东交易明细
            交易时间,金额,交易状态,收/支
            2026-01-01 10:00,3.00,交易成功,支出
            """, .jd)
        ]
        for (csv, expectedSource) in samples {
            let document = try FinanceCSVService.readImportDocument(
                data: Data(csv.utf8), fileName: "neutral.csv"
            )
            XCTAssertEqual(document.detection.source, expectedSource)
            let parsed = try plan(document)
            XCTAssertEqual(parsed.source, expectedSource)
            XCTAssertEqual(parsed.candidates.count, 1)
        }
    }

    func testMissingDedicatedCoreColumnFallsBackAndCanBeForcedGeneric() throws {
        let csv = """
        微信支付账单
        交易时间,交易类型,金额(元)
        2026-01-01 10:00,支出,1.00
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8), fileName: "neutral.csv"
        )
        XCTAssertEqual(document.detection.source, .wechat)
        let automatic = try plan(document)
        XCTAssertEqual(automatic.source, .wechat)
        XCTAssertEqual(automatic.parsingMethod, .genericMapping)
        XCTAssertEqual(automatic.candidates.count, 1)
        XCTAssertTrue(automatic.sourceDetectionReasons.contains {
            $0.contains("已自动降级为通用字段映射")
        })

        let generic = try FinanceCSVService.makePlan(
            document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "neutral",
            existingTransactions: [],
            parserMode: .generic,
            calendar: calendar
        )
        XCTAssertEqual(generic.source, .wechat)
        XCTAssertEqual(generic.parsingMethod, .genericMapping)
        XCTAssertTrue(generic.sourceDetectionReasons.contains("用户选择通用字段映射"))
    }

    func testDetectedAlipayRetainsSourceWhenUserSelectsGenericMapping() throws {
        let csv = """
        支付宝交易明细
        交易时间,收/支,金额,交易订单号
        2026-01-01 10:00,支出,2.00,SAME-ORDER
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8), fileName: "neutral.csv"
        )
        let generic = try plan(document, parserMode: .generic)
        XCTAssertEqual(generic.source, .alipay)
        XCTAssertEqual(generic.parsingMethod, .genericMapping)
        XCTAssertTrue(generic.sourceDetectionReasons.contains("用户选择通用字段映射"))
    }

    func testGenericMappingIsolatesSameOrderIDAcrossDetectedPlatforms() throws {
        let wechat = try FinanceCSVService.readImportDocument(data: Data("""
        微信支付账单
        交易时间,交易类型,收/支,金额(元),交易单号
        2026-01-01 10:00,商户消费,支出,2.00,SAME-ORDER
        """.utf8), fileName: "wechat.csv")
        let alipay = try FinanceCSVService.readImportDocument(data: Data("""
        支付宝交易明细
        交易时间,收/支,金额,交易订单号
        2026-01-01 10:00,支出,2.00,SAME-ORDER
        """.utf8), fileName: "alipay.csv")
        let wechatPlan = try plan(wechat, parserMode: .generic)
        let existing = try XCTUnwrap(wechatPlan.candidates.first)
        let alipayPlan = try plan(
            alipay,
            existingTransactions: [existingTransaction(from: existing, source: .wechat)],
            parserMode: .generic
        )
        XCTAssertEqual(wechatPlan.source, .wechat)
        XCTAssertEqual(alipayPlan.source, .alipay)
        XCTAssertEqual(alipayPlan.duplicateCount, 0)
        XCTAssertEqual(alipayPlan.suspectedDuplicateCount, 0)
    }

    func testSamePlatformDeduplicatesAcrossDedicatedAndGenericParsingBothDirections() throws {
        let document = try FinanceCSVService.readImportDocument(data: Data("""
        支付宝交易明细
        交易时间,收/支,金额,交易订单号
        2026-01-01 10:00,支出,2.00,ALIPAY-CROSS-MODE
        """.utf8), fileName: "alipay.csv")
        let dedicated = try plan(document)
        let generic = try plan(document, parserMode: .generic)
        let dedicatedCandidate = try XCTUnwrap(dedicated.candidates.first)
        let genericCandidate = try XCTUnwrap(generic.candidates.first)

        let genericAfterDedicated = try plan(
            document,
            existingTransactions: [existingTransaction(from: dedicatedCandidate, source: .alipay)],
            parserMode: .generic
        )
        let dedicatedAfterGeneric = try plan(
            document,
            existingTransactions: [existingTransaction(from: genericCandidate, source: .alipay)]
        )
        XCTAssertEqual(genericAfterDedicated.duplicateCount, 1)
        XCTAssertEqual(dedicatedAfterGeneric.duplicateCount, 1)
        XCTAssertEqual(dedicatedCandidate.fingerprint, genericCandidate.fingerprint)
    }

    func testMissingCoreColumnReportsExactDedicatedAndGenericErrors() throws {
        let csv = """
        微信支付账单
        交易时间,交易类型,收/支
        2026-01-01 10:00,商户消费,支出
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8), fileName: "neutral.csv"
        )
        let mapping = FinanceCSVService.autoMapping(headers: document.headers)
        XCTAssertThrowsError(try FinanceCSVService.makePlan(
            document: document,
            mapping: mapping,
            fileName: "neutral",
            existingTransactions: [],
            calendar: calendar
        )) { error in
            XCTAssertEqual(error as? BillImportError, .missingRequiredColumns(["金额"]))
        }
        XCTAssertThrowsError(try FinanceCSVService.makePlan(
            document: document,
            mapping: mapping,
            fileName: "neutral",
            existingTransactions: [],
            parserMode: .generic,
            calendar: calendar
        )) { error in
            XCTAssertEqual(error as? BillImportError, .missingGenericMapping)
        }
    }

    func testEffectiveRowsUseOneToggleSensitiveCollection() throws {
        let rows = (0..<10).map { index in
            "expense,\(index + 1).00,2026-01-01 \(String(format: "%02d", index)):00,餐饮,现金,row-\(index)"
        }.joined(separator: "\n")
        let csv = "type,amount,date_time,category,account,note\n" + rows
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8), fileName: "generic.csv"
        )
        let initial = try plan(document)
        let existing = initial.candidates.prefix(3).map(manualTransaction)
        let reviewed = try plan(document, existingTransactions: existing)
        XCTAssertEqual(reviewed.suspectedDuplicateCount, 3)
        XCTAssertEqual(reviewed.effectiveRowsToImport(includeSuspectedDuplicates: false).count, 7)
        XCTAssertEqual(reviewed.effectiveRowsToImport(includeSuspectedDuplicates: true).count, 10)
        XCTAssertEqual(reviewed.expenseMinorUnits(includeSuspectedDuplicates: false), 4_900)
        XCTAssertEqual(reviewed.expenseMinorUnits(includeSuspectedDuplicates: true), 5_500)

        let allExisting = initial.candidates.map(manualTransaction)
        let allSuspected = try plan(document, existingTransactions: allExisting)
        XCTAssertTrue(allSuspected.effectiveRowsToImport(includeSuspectedDuplicates: false).isEmpty)
        XCTAssertEqual(allSuspected.effectiveRowsToImport(includeSuspectedDuplicates: true).count, 10)
    }

    func testConfirmedDuplicatePreviewMetricsMatchEffectiveRows() throws {
        let csv = """
        type,amount,date_time,category,account,note,transaction_id
        income,10.00,2026-01-01 10:00,工资,现金,income-row,income-id
        expense,20.00,2026-01-02 10:00,餐饮,现金,expense-row,expense-id
        refund,5.00,2026-01-03 10:00,退款,现金,refund-row,refund-id
        expense,40.00,2026-01-04 10:00,购物,现金,kept-row,kept-id
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8),
            fileName: "confirmed-duplicates.csv"
        )
        let initial = try plan(document)
        let existing = initial.candidates.prefix(3).map {
            existingTransaction(from: $0, source: initial.source)
        }
        let reviewed = try plan(document, existingTransactions: existing)

        for includeConfirmed in [false, true] {
            let effective = reviewed.effectiveRowsToImport(
                includeSuspectedDuplicates: true,
                includeConfirmedDuplicates: includeConfirmed
            )
            let preview = try FinanceCSVService.makePreviewSnapshot(
                plan: reviewed,
                modelSnapshot: ImportModelSnapshot(accounts: [], categories: [], tags: []),
                includeSuspectedDuplicates: true,
                includeConfirmedDuplicates: includeConfirmed,
                rememberedCategoryMappings: [:],
                rowCategoryOverrides: [:]
            )
            XCTAssertEqual(preview.effectiveRows.map(\.rowNumber), effective.map(\.rowNumber))
            XCTAssertEqual(
                reviewed.incomeMinorUnits(
                    includeSuspectedDuplicates: true,
                    includeConfirmedDuplicates: includeConfirmed
                ),
                effective.filter { $0.type == .income }.reduce(0) { $0 + $1.amountMinorUnits }
            )
            XCTAssertEqual(preview.incomeMinorUnits, reviewed.incomeMinorUnits(
                includeSuspectedDuplicates: true,
                includeConfirmedDuplicates: includeConfirmed
            ))
            XCTAssertEqual(
                reviewed.expenseMinorUnits(
                    includeSuspectedDuplicates: true,
                    includeConfirmedDuplicates: includeConfirmed
                ),
                effective.filter { $0.type == .expense }.reduce(0) { $0 + $1.amountMinorUnits }
            )
            XCTAssertEqual(preview.expenseMinorUnits, reviewed.expenseMinorUnits(
                includeSuspectedDuplicates: true,
                includeConfirmedDuplicates: includeConfirmed
            ))
            XCTAssertEqual(
                reviewed.refundMinorUnits(
                    includeSuspectedDuplicates: true,
                    includeConfirmedDuplicates: includeConfirmed
                ),
                effective.filter { $0.type == .refund }.reduce(0) { $0 + $1.amountMinorUnits }
            )
            XCTAssertEqual(preview.refundMinorUnits, reviewed.refundMinorUnits(
                includeSuspectedDuplicates: true,
                includeConfirmedDuplicates: includeConfirmed
            ))
            XCTAssertEqual(
                reviewed.localDayRange(
                    includeSuspectedDuplicates: true,
                    includeConfirmedDuplicates: includeConfirmed
                ),
                expectedLocalDayRange(effective)
            )
            XCTAssertEqual(preview.localDayRange, expectedLocalDayRange(effective))
        }
    }

    func testParsedPlanIsReusedForDuplicateAssessment() throws {
        let csv = """
        type,amount,date_time,category,account,note,transaction_id
        expense,1.00,2026-01-01 10:00,餐饮,现金,row-1,id-1
        expense,2.00,2026-01-02 10:00,餐饮,现金,row-2,id-2
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8),
            fileName: "single-parse.csv"
        )
        let mapping = FinanceCSVService.autoMapping(headers: document.headers)
        let parsed = try FinanceCSVService.parsePlan(
            document: document,
            mapping: mapping,
            fileName: "single-parse.csv",
            calendar: calendar
        )
        let existing = [ImportDuplicateRecord(
            externalSource: parsed.source,
            type: parsed.candidates[0].type,
            externalTransactionID: parsed.candidates[0].externalTransactionID,
            importFingerprint: parsed.candidates[0].fingerprint,
            amountMinorUnits: parsed.candidates[0].amountMinorUnits,
            occurredAt: parsed.candidates[0].occurredAt,
            note: parsed.candidates[0].persistedNote,
            deletedAt: nil
        )]

        let assessed = FinanceCSVService.assessDuplicates(parsed, existingRecords: existing)

        XCTAssertEqual(assessed.candidates.count, 2)
        XCTAssertEqual(assessed.duplicateCount, 1)
        XCTAssertEqual(assessed.sourceDisplayName, "single-parse.csv")
        XCTAssertEqual(parsed.localDayRange, "2026-01-01"..."2026-01-02")
    }

    func testExcelDatesUseSpecifiedCalendarAcrossDeviceTimeZonesAndStableFingerprint() throws {
        let data = try fixture("wechat_bill", extension: "xlsx")
        let document = try FinanceCSVService.readImportDocument(data: data, fileName: "neutral.xlsx")
        let originalDefault = NSTimeZone.default
        defer { NSTimeZone.default = originalDefault }

        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        let first = try plan(document)
        NSTimeZone.default = TimeZone(identifier: "Europe/London")!
        let second = try plan(document)
        XCTAssertEqual(first.candidates.first?.occurredAt, second.candidates.first?.occurredAt)
        XCTAssertEqual(first.candidates.first?.fingerprint, second.candidates.first?.fingerprint)
        XCTAssertEqual(first.candidates.first?.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(second.candidates.first?.timeZoneIdentifier, "Asia/Shanghai")
    }

    @MainActor
    func testCommitPersistsPlatformTimeZoneAndLocalDayAcrossDeviceTimeZones() throws {
        let originalDefault = NSTimeZone.default
        defer { NSTimeZone.default = originalDefault }
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!

        let document = try FinanceCSVService.readImportDocument(data: Data("""
        微信支付账单
        交易时间,交易类型,收/支,金额(元),交易单号
        2026-01-02 00:30:00,商户消费,支出,30.00,WECHAT-TIME-ZONE
        """.utf8), fileName: "wechat.csv")
        let firstPlan = try plan(document)
        let firstCandidate = try XCTUnwrap(firstPlan.candidates.first)
        XCTAssertEqual(firstCandidate.timeZoneIdentifier, "Asia/Shanghai")

        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(name: "默认账户", type: .cash, isDefault: true)
        let category = Category(
            kind: .expense,
            name: "其他",
            symbolName: "ellipsis.circle",
            colorToken: "teal",
            isSystemCategory: true
        )
        context.insert(account)
        context.insert(category)
        try context.save()
        _ = try FinanceCSVService.commit(
            plan: firstPlan,
            accounts: [account],
            categories: [category],
            tags: [],
            in: context
        )
        let transaction = try XCTUnwrap(
            context.fetch(FetchDescriptor<FinanceTransaction>()).first
        )
        XCTAssertEqual(transaction.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(transaction.localDayKey, "2026-01-02")
        XCTAssertNotEqual(transaction.localDayKey, "2026-01-01")

        NSTimeZone.default = TimeZone(identifier: "Pacific/Honolulu")!
        let repeatPlan = try plan(document, existingTransactions: [transaction])
        XCTAssertEqual(repeatPlan.candidates.first?.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(repeatPlan.candidates.first?.fingerprint, firstCandidate.fingerprint)
        XCTAssertEqual(repeatPlan.duplicateCount, 1)
    }

    func testUnknownGenericISOTimestampPreservesExplicitOffset() throws {
        let document = try FinanceCSVService.readImportDocument(
            data: Data("date_time,amount,transaction_id\n2026-01-02T00:30:00-08:00,1.00,ISO-OFFSET".utf8),
            fileName: "generic.csv"
        )
        let parsed = try plan(document)
        let candidate = try XCTUnwrap(parsed.candidates.first)
        let timeZone = try XCTUnwrap(TimeZone(identifier: candidate.timeZoneIdentifier))
        XCTAssertEqual(timeZone.secondsFromGMT(for: candidate.occurredAt), -8 * 60 * 60)
        XCTAssertEqual(LocalDayKey.make(for: candidate.occurredAt, timeZone: timeZone), "2026-01-02")
    }

    func testExcel1904SystemAndInvalidDeclarationAreExplicit() throws {
        XCTAssertEqual(
            try TabularBillFileReader.excelDateSystem(
                workbookXML: Data("<workbook><workbookPr date1904=\"1\"/></workbook>".utf8)
            ),
            .excel1904
        )
        XCTAssertEqual(
            try TabularBillFileReader.excelDateSystem(
                workbookXML: Data("<workbook><workbookPr/></workbook>".utf8)
            ),
            .excel1900
        )
        XCTAssertThrowsError(try TabularBillFileReader.excelDateSystem(
            workbookXML: Data("<workbook><workbookPr date1904=\"maybe\"/></workbook>".utf8)
        )) { error in
            XCTAssertEqual(error as? BillImportError, .unsupportedExcelDateSystem)
        }

        let date = try XCTUnwrap(BillParserSupport.excelDate(
            serial: 1.5,
            system: .excel1904,
            calendar: calendar
        ))
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(components.year, 1904)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 2)
        XCTAssertEqual(components.hour, 12)
        XCTAssertEqual(components.minute, 0)
    }

    @MainActor
    func testCommitDeterministicallyResolvesNormalizedDuplicateNames() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let preferredAccount = Account(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            name: "cash", type: .cash, isDefault: true, sortOrder: 4, createdAt: late
        )
        let otherAccount = Account(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            name: "CASH", type: .cash, isDefault: false, sortOrder: 0, createdAt: early
        )
        let preferredCategory = Category(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            kind: .expense, name: "餐饮", symbolName: "fork.knife", colorToken: "orange",
            sortOrder: 8, isHidden: false, createdAt: late
        )
        let hiddenCategory = Category(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            kind: .expense, name: " 餐饮 ", symbolName: "fork.knife", colorToken: "orange",
            sortOrder: 0, isHidden: true, createdAt: early
        )
        let preferredTag = Tag(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
            name: " 工作 ", sortOrder: 9, createdAt: late
        )
        let archivedTag = Tag(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
            name: "工作", sortOrder: 0, archivedAt: late, createdAt: early
        )
        [preferredAccount, otherAccount].forEach(context.insert)
        [preferredCategory, hiddenCategory].forEach(context.insert)
        [preferredTag, archivedTag].forEach(context.insert)
        try context.save()

        func importOne(id: String, reversed: Bool) throws {
            let csv = "transaction_id,type,amount,date_time,category,account,tags\n\(id),expense,1.00,2026-01-01 10:00,餐饮,Cash,工作"
            let document = try FinanceCSVService.readImportDocument(
                data: Data(csv.utf8), fileName: "generic.csv"
            )
            let importPlan = try plan(document)
            _ = try FinanceCSVService.commit(
                plan: importPlan,
                accounts: reversed ? [otherAccount, preferredAccount] : [preferredAccount, otherAccount],
                categories: reversed ? [hiddenCategory, preferredCategory] : [preferredCategory, hiddenCategory],
                tags: reversed ? [archivedTag, preferredTag] : [preferredTag, archivedTag],
                in: context
            )
        }
        try importOne(id: "one", reversed: false)
        try importOne(id: "two", reversed: true)

        let imported = try context.fetch(FetchDescriptor<FinanceTransaction>())
            .filter { $0.externalTransactionID == "one" || $0.externalTransactionID == "two" }
        XCTAssertEqual(imported.count, 2)
        XCTAssertTrue(imported.allSatisfy { $0.accountID == preferredAccount.id })
        XCTAssertTrue(imported.allSatisfy { $0.categoryID == preferredCategory.id })
        XCTAssertTrue(imported.allSatisfy { $0.tags.map(\.id) == [preferredTag.id] })
    }

    @MainActor
    func testImportResolvesFullCategoryPathWhenLeafNamesRepeat() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(name: "现金", type: .cash, isDefault: true)
        let dining = Category(kind: .expense, name: "餐饮", symbolName: "fork.knife", colorToken: "orange")
        let shopping = Category(kind: .expense, name: "购物", symbolName: "bag", colorToken: "purple")
        let diningOther = Category(
            kind: .expense,
            name: "其他",
            parentID: dining.id,
            symbolName: "ellipsis.circle",
            colorToken: "orange"
        )
        let shoppingOther = Category(
            kind: .expense,
            name: "其他",
            parentID: shopping.id,
            symbolName: "ellipsis.circle",
            colorToken: "purple"
        )
        context.insert(account)
        [dining, shopping, diningOther, shoppingOther].forEach(context.insert)
        try context.save()

        let csv = "transaction_id,type,amount,date_time,category,account\npath-1,expense,12.00,2026-01-01 10:00,购物 / 其他,现金"
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8),
            fileName: "path.csv"
        )
        _ = try FinanceCSVService.commit(
            plan: try plan(document),
            accounts: [account],
            categories: [dining, shopping, diningOther, shoppingOther],
            tags: [],
            in: context
        )

        let imported = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>())
            .first { $0.externalTransactionID == "path-1" })
        XCTAssertEqual(imported.categoryID, shoppingOther.id)
        let exported = try XCTUnwrap(String(data: FinanceCSVService.exportData(
            transactions: [imported],
            categories: [dining, shopping, diningOther, shoppingOther],
            accounts: [account]
        ), encoding: .utf8))
        XCTAssertTrue(exported.contains("购物 / 其他"))
    }

    @MainActor
    func testImportAfterDeletingDefaultOtherDoesNotResurrectIt() throws {
        let container = try makeContainer()
        let context = container.mainContext
        // This regression targets the legacy generic "其他" child, which is
        // retained on upgrade but is not installed in a fresh V4 catalog.
        try seedFrozenV3Ledger(in: context)
        try DefaultFinanceDataService.ensureDefaults(in: context)
        var categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let deletedOther = try XCTUnwrap(categories.first {
            $0.kind == .expense && $0.name == "其他" && $0.parentID != nil
        })
        try FinanceDataManagementService.permanentlyDelete(category: deletedOther, in: context)
        try DefaultFinanceDataService.ensureDefaults(in: context)

        categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        XCTAssertFalse(categories.contains { $0.id == deletedOther.id })
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<Account>())
            .first { $0.archivedAt == nil })
        let categoryCount = categories.count
        let csv = "transaction_id,type,amount,date_time,category,account\nno-other,expense,5.00,2026-01-01 10:00,未知分类,\(account.name)"
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8),
            fileName: "no-other.csv"
        )
        let result = try FinanceCSVService.commit(
            plan: try plan(document),
            accounts: [account],
            categories: categories,
            tags: [],
            in: context
        )
        let imported = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>())
            .first { $0.externalTransactionID == "no-other" })
        XCTAssertNil(imported.categoryID)
        XCTAssertEqual(imported.reviewStatus, .needsReview)
        XCTAssertEqual(imported.reviewReasons, [.uncategorized, .importUncertain])
        XCTAssertEqual(result.createdCategoryCount, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>()).count, categoryCount)
    }

    @MainActor
    func testHighConfidenceImportMayCreateChildButNeverCreatesANewRoot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(name: "现金", type: .cash, isDefault: true)
        let dining = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        context.insert(account)
        context.insert(dining)
        try context.save()

        let csv = "transaction_id,type,amount,date_time,category,account\nnew-child,expense,18.00,2026-01-01 10:00,餐饮 / 早午餐,现金"
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8),
            fileName: "new-child.csv"
        )
        let result = try FinanceCSVService.commit(
            plan: try plan(document),
            accounts: [account],
            categories: [dining],
            tags: [],
            in: context,
            createMissingCategories: true
        )

        let categories = try context.fetch(FetchDescriptor<PersonalFinanceOS.Category>())
        let created = try XCTUnwrap(categories.first { $0.name == "早午餐" })
        let imported = try XCTUnwrap(context.fetch(FetchDescriptor<FinanceTransaction>())
            .first { $0.externalTransactionID == "new-child" })
        XCTAssertEqual(result.createdCategoryCount, 1)
        XCTAssertEqual(created.parentID, dining.id)
        XCTAssertEqual(categories.filter { $0.parentID == nil }.map(\.id), [dining.id])
        XCTAssertEqual(imported.categoryID, created.id)
        XCTAssertEqual(imported.reviewStatus, .complete)
    }

    @MainActor
    func testRememberedMappingsSeparateSameRawCategoryByIncomeAndExpense() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(name: "现金", type: .cash, isDefault: true)
        let expense = Category(
            kind: .expense,
            name: "日常支出",
            symbolName: "cart",
            colorToken: "orange"
        )
        let income = Category(
            kind: .income,
            name: "其他收入",
            symbolName: "banknote",
            colorToken: "green"
        )
        context.insert(account)
        context.insert(expense)
        context.insert(income)
        try context.save()

        let csv = """
        transaction_id,type,amount,date_time,category,account
        shared-expense,expense,12.00,2026-01-01 10:00,共同分类,现金
        shared-income,income,20.00,2026-01-02 10:00,共同分类,现金
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8),
            fileName: "kind-mapping.csv"
        )
        let mappings = [
            ImportCategoryMappingStore.stableKey(
                source: .genericCSV,
                rawCategory: "共同分类",
                kind: .expense
            ): expense.id,
            ImportCategoryMappingStore.stableKey(
                source: .genericCSV,
                rawCategory: "共同分类",
                kind: .income
            ): income.id
        ]

        _ = try FinanceCSVService.commit(
            plan: try plan(document),
            accounts: [account],
            categories: [expense, income],
            tags: [],
            in: context,
            rememberedCategoryMappings: mappings
        )

        let imported = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertEqual(
            imported.first { $0.externalTransactionID == "shared-expense" }?.categoryID,
            expense.id
        )
        XCTAssertEqual(
            imported.first { $0.externalTransactionID == "shared-income" }?.categoryID,
            income.id
        )
    }

    @MainActor
    func testImportHistoryTotalsUseNetExpenseSemantics() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(name: "现金", type: .cash, isDefault: true)
        let expense = Category(
            kind: .expense,
            name: "餐饮",
            symbolName: "fork.knife",
            colorToken: "orange"
        )
        context.insert(account)
        context.insert(expense)
        try context.save()

        let csv = """
        transaction_id,type,amount,date_time,category,account
        expense-total,expense,100.00,2026-01-01 10:00,餐饮,现金
        refund-total,refund,40.00,2026-01-02 10:00,餐饮,现金
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8),
            fileName: "net-total.csv"
        )
        let result = try FinanceCSVService.commit(
            plan: try plan(document),
            accounts: [account],
            categories: [expense],
            tags: [],
            in: context
        )

        let batch = try XCTUnwrap(context.fetch(FetchDescriptor<ImportBatch>()).first)
        XCTAssertEqual(result.expenseMinorUnits, 6_000)
        XCTAssertEqual(batch.expenseMinorUnits, 6_000)
    }

    func testRepeatedHeadersAndFooterSummariesAreNonTransactionRows() throws {
        let csv = """
        date_time,amount,note
        2026-01-01 10:00,1.00,有效
        date_time,amount,note
        合计,1.00,
        温馨提示：请妥善保管文件
        """
        let document = try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8),
            fileName: "neutral.csv"
        )
        XCTAssertEqual(document.rawRowCount, 5)
        XCTAssertEqual(document.nonTransactionRowCount, 4)
        XCTAssertEqual(document.rows.count, 1)
        XCTAssertEqual(try plan(document).candidates.count, 1)
    }

    func testStableIDsDeduplicateWithinSourceButNotAcrossPlatforms() throws {
        let data = try fixture("alipay_bill_gb18030", extension: "csv")
        let document = try FinanceCSVService.readImportDocument(data: data, fileName: "anything.csv")
        let initial = try plan(document)
        let candidate = try XCTUnwrap(initial.candidates.first)
        let sameSource = existingTransaction(from: candidate, source: .alipay)
        let samePlan = try plan(document, existingTransactions: [sameSource])
        XCTAssertEqual(samePlan.duplicateCount, 1)

        let otherSource = existingTransaction(from: candidate, source: .wechat)
        let crossSourcePlan = try plan(document, existingTransactions: [otherSource])
        XCTAssertEqual(crossSourcePlan.duplicateCount, 0)
        XCTAssertEqual(crossSourcePlan.suspectedDuplicateCount, 0)
    }

    @MainActor
    func testCommitAndRepeatPlanPreservePersistenceAndDeduplication() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(name: "默认账户", type: .cash, isDefault: true)
        let expense = Category(
            kind: .expense,
            name: "其他",
            symbolName: "ellipsis.circle",
            colorToken: "teal",
            isSystemCategory: true
        )
        let income = Category(
            kind: .income,
            name: "其他收入",
            symbolName: "plus.circle",
            colorToken: "green",
            isSystemCategory: true
        )
        context.insert(account)
        context.insert(expense)
        context.insert(income)
        try context.save()

        let data = try fixture("wechat_bill", extension: "xlsx")
        let document = try FinanceCSVService.readImportDocument(data: data, fileName: "bill.xlsx")
        let firstPlan = try plan(document)
        let result = try FinanceCSVService.commit(
            plan: firstPlan,
            accounts: [account],
            categories: [expense, income],
            tags: [],
            in: context
        )
        XCTAssertEqual(result.importedCount, 3)

        let persisted = try context.fetch(FetchDescriptor<FinanceTransaction>())
        let secondPlan = try plan(document, existingTransactions: persisted)
        XCTAssertEqual(secondPlan.duplicateCount, 3)
        let batches = try context.fetch(FetchDescriptor<ImportBatch>())
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.duplicateRowCount, 0)

        _ = try ImportBatchHistoryService.rollback(
            batch: try XCTUnwrap(batches.first),
            transactions: persisted,
            preserveEdited: false,
            includeUncertain: true,
            reviewedRevision: LedgerSaveRevision.shared.contentRevision,
            in: context
        )
        let rolledBackTransactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
        XCTAssertTrue(rolledBackTransactions.allSatisfy { $0.deletedAt != nil })
        let afterRollbackPlan = try plan(document, existingTransactions: rolledBackTransactions)
        XCTAssertEqual(afterRollbackPlan.duplicateCount, 3)
    }

    private func plan(
        _ document: BillImportDocument,
        existingTransactions: [FinanceTransaction] = [],
        parserMode: BillImportParserMode = .automatic
    ) throws -> ImportPlan {
        try FinanceCSVService.makePlan(
            document: document,
            mapping: FinanceCSVService.autoMapping(headers: document.headers),
            fileName: "neutral-file",
            existingTransactions: existingTransactions,
            parserMode: parserMode,
            calendar: calendar
        )
    }

    private func jdPlan(
        rows: [String],
        existingTransactions: [FinanceTransaction] = []
    ) throws -> ImportPlan {
        let document = try jdDocument(rows: rows)
        return try plan(document, existingTransactions: existingTransactions)
    }

    private func jdDocument(rows: [String]) throws -> BillImportDocument {
        let csv = ([
            "交易时间,商户名称,交易说明,金额,收/付款方式,交易状态,收/支,交易分类,交易订单号,商家订单号"
        ] + rows).joined(separator: "\n")
        return try FinanceCSVService.readImportDocument(
            data: Data(csv.utf8), fileName: "jd.csv"
        )
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }

    private func existingTransaction(
        from candidate: ImportCandidate,
        source: ImportSourceType
    ) -> FinanceTransaction {
        let timeZone = TimeZone(identifier: candidate.timeZoneIdentifier)!
        return FinanceTransaction(
            type: candidate.type,
            amountMinorUnits: candidate.amountMinorUnits,
            occurredAt: candidate.occurredAt,
            localDayKey: LocalDayKey.make(for: candidate.occurredAt, timeZone: timeZone),
            timeZoneIdentifier: candidate.timeZoneIdentifier,
            note: candidate.persistedNote,
            externalSource: source,
            externalTransactionID: candidate.externalTransactionID,
            importFingerprint: candidate.fingerprint
        )
    }

    private func manualTransaction(from candidate: ImportCandidate) -> FinanceTransaction {
        let timeZone = TimeZone(identifier: candidate.timeZoneIdentifier)!
        return FinanceTransaction(
            type: candidate.type,
            amountMinorUnits: candidate.amountMinorUnits,
            occurredAt: candidate.occurredAt,
            localDayKey: LocalDayKey.make(for: candidate.occurredAt, timeZone: timeZone),
            timeZoneIdentifier: candidate.timeZoneIdentifier,
            note: candidate.persistedNote
        )
    }

    @MainActor
    func testBackgroundCommitPersistsValuePayloadWithoutCrossingModels() async throws {
        let document = try jdDocument(rows: [
            "2026-01-11 14:00:00,示例商户,普通支付,30.00,银行卡,交易成功,支出,购物,JD-BACKGROUND,M-BACKGROUND"
        ])
        let importPlan = try plan(document)
        let container = try makeContainer()
        let context = container.mainContext
        let account = Account(name: "默认账户", type: .cash, isDefault: true)
        let category = Category(
            kind: .expense,
            name: "购物",
            symbolName: "bag",
            colorToken: "teal"
        )
        context.insert(account)
        context.insert(category)
        try context.save()

        let modelSnapshot = FinanceCSVService.makeImportModelSnapshot(
            accounts: [account],
            categories: [category],
            tags: []
        )
        let request = try await Task.detached {
            try FinanceCSVService.makeBackgroundCommitRequest(
                plan: importPlan,
                modelSnapshot: modelSnapshot,
                rememberedCategoryMappings: [:]
            )
        }.value
        let importer = ImportCommitActor(modelContainer: container)
        let importResult = try await importer.commit(request)

        XCTAssertEqual(importResult.importedCount, 1)
        let transactions = try context.fetch(FetchDescriptor<FinanceTransaction>())
        let batches = try context.fetch(FetchDescriptor<ImportBatch>())
        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions.first?.importBatchID, batches.first?.id)
        XCTAssertEqual(batches.first?.status, .completed)
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: AppSchema.schema, configurations: [configuration])
    }

    private func fixture(_ name: String, extension extensionName: String) throws -> Data {
        let bundle = Bundle(for: BillImportServiceTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: extensionName, subdirectory: "Fixtures")
                ?? bundle.url(forResource: name, withExtension: extensionName)
        )
        return try Data(contentsOf: url)
    }

    private func expectedLocalDayRange(
        _ candidates: [ImportCandidate]
    ) -> ClosedRange<String>? {
        let days = candidates.map {
            LocalDayKey.make(
                for: $0.occurredAt,
                timeZone: TimeZone(identifier: $0.timeZoneIdentifier)!
            )
        }
        guard let first = days.min(), let last = days.max() else { return nil }
        return first...last
    }
}
