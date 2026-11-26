import Foundation

enum BillTextNormalization {
    static func value(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "zh_Hans_CN")
            )
    }

    static func header(_ value: String) -> String {
        self.value(value)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
    }
}

enum BillSourceDetector {
    private static let recognizedHeaderAliases = [
        "交易时间", "日期时间", "时间", "交易类型", "收支类型", "类型", "交易分类", "类别", "分类",
        "交易对方", "收付款人", "商户名称", "商家", "商品", "商品说明", "交易说明",
        "收/支", "收支", "金额", "金额(元)", "支付方式", "收/付款方式", "收付账户", "账户",
        "当前状态", "交易状态", "交易单号", "交易订单号", "商户单号", "商家订单号", "备注",
        "date_time", "datetime", "amount", "type", "category", "account", "note", "tags",
        "transaction_id"
    ].map(BillTextNormalization.header)

    static func headerScore(_ row: TabularRow) -> Int {
        let values = Set(row.cells.map { BillTextNormalization.header($0.text) })
        return recognizedHeaderAliases.reduce(0) { score, alias in
            score + (values.contains(alias) ? 1 : 0)
        }
    }

    static func headerRowIndex(in rows: [TabularRow]) -> Int? {
        let candidates = rows.prefix(80).enumerated().map { index, row in
            (index: index, score: headerScore(row), columns: row.cells.filter { !$0.text.isEmpty }.count)
        }
        if let best = candidates.max(by: { lhs, rhs in
            lhs.score == rhs.score ? lhs.columns < rhs.columns : lhs.score < rhs.score
        }), best.score >= 2 {
            return best.index
        }
        return candidates.first(where: { $0.columns >= 2 })?.index
    }

    static func detect(
        headers: [String],
        preambleRows: [TabularRow],
        sheetName: String?
    ) -> BillSourceDetection {
        let normalizedHeaders = Set(headers.map(BillTextNormalization.header))
        let preamble = preambleRows
            .flatMap(\.cells)
            .map { BillTextNormalization.value($0.text) }
            .joined(separator: "|")
        let sheet = BillTextNormalization.value(sheetName ?? "")

        func matches(_ aliases: [String]) -> Int {
            aliases.map(BillTextNormalization.header).filter(normalizedHeaders.contains).count
        }

        let wechatFields = matches([
            "交易时间", "交易类型", "交易对方", "商品", "收/支", "金额(元)",
            "支付方式", "当前状态", "交易单号", "商户单号"
        ])
        let wechatTitle = preamble.contains("微信支付账单") || sheet.contains("微信支付")
        let wechatCore = matches(["交易时间", "交易类型", "收/支", "金额(元)"])
        if (wechatTitle && wechatCore >= 3) || (!wechatTitle && wechatFields >= 9) {
            return BillSourceDetection(
                source: .wechat,
                confidence: wechatTitle ? 1 : 0.94,
                reasons: [
                    "匹配微信交易字段 \(wechatFields) 项",
                    wechatTitle ? "说明文字包含“微信支付账单”" : "字段组合具有微信账单唯一性"
                ]
            )
        }

        let wacaiFields = matches([
            "日期时间", "类型", "类别", "金额", "币种", "收付款人", "收付账户",
            "参与人", "标签", "商家", "属性", "备注"
        ])
        let wacaiTitle = preamble.contains("挖财") || sheet.contains("挖财")
        let wacaiCore = matches(["日期时间", "类型", "收支类型", "金额"])
        let wacaiDistinctive = matches(["币种", "收付款人", "收付账户", "参与人", "属性", "商家"])
        if (wacaiTitle && wacaiCore >= 3)
            || (!wacaiTitle && wacaiFields >= 7 && wacaiDistinctive >= 3) {
            return BillSourceDetection(
                source: .wacai,
                confidence: wacaiTitle ? 1 : (wacaiFields >= 10 ? 0.94 : 0.85),
                reasons: [
                    "匹配挖财交易字段 \(wacaiFields) 项",
                    wacaiTitle ? "说明文字包含“挖财”" : "匹配币种、收付款人、收付账户等挖财特征字段"
                ]
            )
        }

        let alipayFields = matches([
            "交易时间", "交易分类", "交易对方", "对方账号", "商品说明", "收/支",
            "金额", "收/付款方式", "交易状态", "交易订单号", "商家订单号"
        ])
        let alipayTitle = preamble.contains("支付宝") || sheet.contains("支付宝")
        let alipayCore = matches(["交易时间", "收/支", "金额"])
        if (alipayTitle && alipayCore == 3)
            || (!alipayTitle && alipayFields >= 8
                && normalizedHeaders.contains(BillTextNormalization.header("对方账号"))) {
            return BillSourceDetection(
                source: .alipay,
                confidence: alipayTitle ? 1 : 0.96,
                reasons: [
                    "匹配支付宝交易字段 \(alipayFields) 项",
                    alipayTitle ? "说明文字包含“支付宝”" : "同时包含对方账号与支付宝订单字段组合"
                ]
            )
        }

        let jdFields = matches([
            "交易时间", "商户名称", "交易说明", "金额", "收/付款方式", "交易状态",
            "收/支", "交易分类", "交易订单号", "商家订单号", "备注"
        ])
        let jdTitle = preamble.contains("京东") || sheet.contains("京东")
        let jdCore = matches(["交易时间", "金额", "交易状态", "收/支"])
        if (jdTitle && jdCore == 4)
            || (!jdTitle && jdFields >= 8
                && normalizedHeaders.contains(BillTextNormalization.header("商户名称"))
                && normalizedHeaders.contains(BillTextNormalization.header("交易说明"))) {
            return BillSourceDetection(
                source: .jd,
                confidence: jdTitle ? 1 : 0.96,
                reasons: [
                    "匹配京东交易字段 \(jdFields) 项",
                    jdTitle ? "说明文字包含“京东”" : "同时包含商户名称与交易说明字段"
                ]
            )
        }

        return BillSourceDetection(
            source: .genericCSV,
            confidence: 0,
            reasons: ["未满足任一平台的多字段识别规则，使用通用字段映射"]
        )
    }
}
