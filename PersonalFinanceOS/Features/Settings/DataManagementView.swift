import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct DataManagementView: View {
    var body: some View {
        List {
            Section {
                NavigationLink {
                    BillImportView()
                } label: {
                    Label("导入账单", systemImage: "square.and.arrow.down")
                }
                NavigationLink {
                    BillExportView()
                } label: {
                    Label("导出账单", systemImage: "square.and.arrow.up")
                }
                NavigationLink {
                    NativeBackupView()
                } label: {
                    Label("完整备份与恢复", systemImage: "externaldrive")
                }
                NavigationLink {
                    ImportHistoryView()
                } label: {
                    Label("导入历史", systemImage: "clock.arrow.circlepath")
                }
            } footer: {
                Text("导入会先解析、映射和预览，确认前不会写入账本。导出文件仅在本机生成。")
            }
        }
        .navigationTitle("数据管理")
    }
}

private struct ImportRowReviewContext: Identifiable {
    let id = UUID()
    let rows: [ImportCandidate]
    let source: ImportSourceType
}

private struct ImportPlanningKey: Equatable {
    let documentID: UUID
    let mapping: CSVColumnMapping
    let parserMode: BillImportParserMode
}

private struct BillImportView: View {
    @Environment(\.locale) private var locale

    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @State private var showImporter = false
    @State private var document: BillImportDocument?
    @State private var fileName = ""
    @State private var mapping = CSVColumnMapping()
    @State private var parserMode = BillImportParserMode.automatic
    @State private var result: ImportResult?
    @State private var errorMessage: String?
    @State private var includeSuspectedDuplicates = true
    @State private var includeConfirmedDuplicates = false
    @State private var createMissingCategories = false
    @State private var createMissingAccounts = false
    @State private var createMissingTags = false
    @State private var categoryMappingSelections: [ImportCategoryGroupSnapshot: UUID] = [:]
    @State private var rowCategorySelections: [Int: UUID] = [:]
    @State private var rememberCategoryMappings = true
    @State private var rowReviewContext: ImportRowReviewContext?
    @State private var plan: ImportPlan?
    @State private var planErrorMessage: String?
    @State private var isPlanning = false
    @State private var isImporting = false
    @State private var importProgress = 0
    @State private var planGeneration = UUID()
    @State private var documentID = UUID()
    @State private var scheduledPlanningKey: ImportPlanningKey?
    @State private var previewGeneration = UUID()
    @State private var planningTask: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewSnapshot: ImportPreviewSnapshot?
    @State private var isPreparingPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PFSpacing.xLarge) {
                importHeader

                if let result {
                    resultView(result)
                } else if let document {
                    mappingView(document)
                    previewView
                } else {
                    PFEmptyState(
                        symbol: "doc.text",
                        title: "选择账单文件",
                        message: "支持微信、挖财、支付宝和京东账单，以及可手动映射的通用 CSV/XLSX。"
                    )
                    Button("选择文件") { showImporter = true }
                        .buttonStyle(PFPrimaryButtonStyle())
                        .accessibilityIdentifier("choose-import-file")
                }
            }
            .padding(PFSpacing.xLarge)
        }
        .background(PFColor.background)
        .navigationTitle("导入账单")
        .onChange(of: mapping) { rebuildPlan() }
        .onChange(of: parserMode) { rebuildPlan() }
        .onChange(of: includeSuspectedDuplicates) { rebuildPreviewSnapshot() }
        .onChange(of: includeConfirmedDuplicates) { rebuildPreviewSnapshot() }
        .onChange(of: categoryMappingSelections) { rebuildPreviewSnapshot() }
        .onChange(of: rowCategorySelections) { rebuildPreviewSnapshot() }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [
                .commaSeparatedText,
                .plainText,
                .tabSeparatedText,
                UTType(filenameExtension: "xlsx") ?? .spreadsheet
            ]
        ) { selection in
            do {
                let url = try selection.get()
                let scoped = url.startAccessingSecurityScopedResource()
                Task {
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let name = url.lastPathComponent
                        let parsed = try await Task.detached(priority: .userInitiated) {
                            let data = try Data(contentsOf: url)
                            return try FinanceCSVService.readImportDocument(data: data, fileName: name)
                        }.value
                        document = parsed
                        documentID = UUID()
                        fileName = name
                        mapping = FinanceCSVService.autoMapping(headers: parsed.headers)
                        parserMode = .automatic
                        rebuildPlan()
                        result = nil
                        categoryMappingSelections = [:]
                        rowCategorySelections = [:]
                        rowReviewContext = nil
                        previewSnapshot = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("无法导入", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $rowReviewContext) { context in
            ImportCategoryRowReviewView(
                rows: context.rows,
                source: context.source,
                categories: categories,
                rememberedCategoryMappings: effectiveCategoryMappings(source: context.source),
                rowCategorySelections: $rowCategorySelections
            )
        }
    }

    private var importHeader: some View {
        VStack(alignment: .leading, spacing: PFSpacing.small) {
            Text(result == nil ? (document == nil ? "1  选择文件" : "2  映射并预览") : "3  导入完成")
                .font(.headline)
            Text(result == nil ? "确认前不会写入数据库。" : "账本、日历与统计已使用同一份本地数据。")
                .font(.subheadline)
                .foregroundStyle(PFColor.secondaryText)
        }
        .padding(PFSpacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PFColor.card, in: RoundedRectangle(cornerRadius: PFRadius.medium))
    }

    private func mappingView(_ document: BillImportDocument) -> some View {
        VStack(alignment: .leading, spacing: PFSpacing.medium) {
            PFSectionHeader(title: document.detection.isSpecialized ? "自动识别" : "字段映射")
            Text(fileSummary(document))
                .font(.caption)
                .foregroundStyle(PFColor.secondaryText)
            if document.detection.isSpecialized && parserMode == .automatic {
                LabeledContent("来源", value: sourceName(document.detection.source))
                ForEach(document.detection.reasons, id: \.self) { reason in
                    Label(reason, systemImage: "checkmark.seal")
                        .font(.footnote)
                        .foregroundStyle(PFColor.secondaryText)
                }
                Button("改用通用映射") { parserMode = .generic }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("use-generic-mapping")
            } else {
                columnPicker("收支类型", selection: $mapping.type, headers: document.headers)
                columnPicker("金额（必填）", selection: $mapping.amount, headers: document.headers)
                columnPicker("日期时间（必填）", selection: $mapping.dateTime, headers: document.headers)
                columnPicker("分类", selection: $mapping.category, headers: document.headers)
                columnPicker("账户", selection: $mapping.account, headers: document.headers)
                columnPicker("备注", selection: $mapping.note, headers: document.headers)
                columnPicker("标签", selection: $mapping.tags, headers: document.headers)
                columnPicker("交易 ID", selection: $mapping.transactionID, headers: document.headers)
                if document.detection.isSpecialized {
                    Button("恢复自动识别") { parserMode = .automatic }
                        .buttonStyle(.bordered)
                }
            }
            if let mismatch = document.formatMismatchMessage {
                Label(mismatch, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(PFColor.expense)
            }
        }
        .padding(PFSpacing.large)
        .background(PFColor.card, in: RoundedRectangle(cornerRadius: PFRadius.medium))
    }

    private func columnPicker(
        _ title: String,
        selection: Binding<Int?>,
        headers: [String]
    ) -> some View {
        Picker(title, selection: selection) {
            Text("未映射").tag(Optional<Int>.none)
            ForEach(headers.indices, id: \.self) { index in
                Text(headers[index]).tag(Optional(index))
            }
        }
    }

    @ViewBuilder
    private var previewView: some View {
        if isPlanning {
            ProgressView("正在分析导入文件…")
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if let plan, let preparedPreview = previewSnapshot {
            let effectiveRows = preparedPreview.effectiveRows
            VStack(alignment: .leading, spacing: PFSpacing.medium) {
                PFSectionHeader(title: "导入预览")
                metric("来源", sourceName(plan.source))
                metric("解析方式", parsingMethodName(plan.parsingMethod))
                metric("文件格式", plan.fileFormat.rawValue)
                if let encoding = plan.encodingName {
                    metric("文本编码", encoding)
                }
                if let sheetName = plan.sheetName {
                    metric("工作表", sheetName)
                }
                metric("原始总行数", "\(plan.rawRowCount)")
                metric("非交易行", "\(plan.nonTransactionRowCount)")
                metric("识别出的交易行", "\(plan.totalRows)")
                metric("成功解析", "\(plan.candidates.count)")
                metric("将导入", "\(effectiveRows.count)")
                metric("确认现有重复", "\(preparedPreview.duplicateCount)")
                metric("疑似重复", "\(preparedPreview.suspectedDuplicateCount)")
                metric("文件内相似", "\(preparedPreview.withinFileDuplicateCount)")
                metric("跳过", "\(preparedPreview.skippedCount)")
                metric("失败", "\(preparedPreview.failedCount)")
                metric("收入", money(preparedPreview.incomeMinorUnits))
                metric("支出", money(preparedPreview.expenseMinorUnits))
                metric("退款", money(preparedPreview.refundMinorUnits))
                if let range = preparedPreview.localDayRange {
                    metric("日期范围", "\(range.lowerBound) – \(range.upperBound)")
                }

                let unresolved = preparedPreview.unresolvedRows
                let proposedChildCount = preparedPreview.proposedChildCount
                let unknownAccounts = preparedPreview.unknownAccounts
                let unknownTags = preparedPreview.unknownTags
                metric("未匹配分类", "\(unresolved.count)")
                metric("新建小类候选", "\(proposedChildCount)")
                metric("新建大类", "0")
                if !unresolved.isEmpty {
                    Text("无法可靠匹配的交易会保留金额、日期和账户，并标记为待复核；不会随机塞入“其他”或首个分类。")
                        .font(.footnote)
                        .foregroundStyle(PFColor.secondaryText)
                    if proposedChildCount > 0 {
                        Toggle("创建 \(proposedChildCount) 个高置信度小类", isOn: $createMissingCategories)
                    }
                    categoryResolutionEditors(
                        rows: unresolved,
                        groups: preparedPreview.unresolvedCategoryGroups,
                        source: plan.source,
                        resolutionsByRowNumber: preparedPreview.resolutionsByRowNumber
                    )
                }
                if !unknownAccounts.isEmpty {
                    Text("未匹配账户将映射到默认账户：\(unknownAccounts.joined(separator: "、"))")
                        .font(.footnote)
                        .foregroundStyle(PFColor.secondaryText)
                    Toggle("创建 \(unknownAccounts.count) 个新账户", isOn: $createMissingAccounts)
                }
                if !unknownTags.isEmpty {
                    Text("新标签候选：\(unknownTags.joined(separator: "、"))")
                        .font(.footnote)
                        .foregroundStyle(PFColor.secondaryText)
                    Toggle("创建 \(unknownTags.count) 个新标签", isOn: $createMissingTags)
                }
                if let example = effectiveRows.first {
                    Text("示例：\(formattedImportDate(example)) · \(example.note.isEmpty ? example.categoryName : example.note) · \(money(example.amountMinorUnits))")
                        .font(.footnote)
                        .foregroundStyle(PFColor.secondaryText)
                }
                Toggle("记住本次来源分类映射", isOn: $rememberCategoryMappings)
                if preparedPreview.suspectedDuplicateCount > 0 {
                    Toggle("导入疑似重复", isOn: $includeSuspectedDuplicates)
                    Text("疑似重复需同时匹配时间、金额、类型和备注；默认保留，方便你自行检查。")
                        .font(.caption)
                        .foregroundStyle(PFColor.secondaryText)
                }
                if preparedPreview.duplicateCount > 0 {
                    Toggle("仍导入确认现有重复", isOn: $includeConfirmedDuplicates)
                    Text("来源唯一标识或精确导入指纹已存在。默认建议跳过，但你始终可以保留导入。")
                        .font(.caption)
                        .foregroundStyle(PFColor.secondaryText)
                }
                if preparedPreview.withinFileDuplicateCount > 0 {
                    Text("文件内相似记录不会被静默删除；将按当前导入策略保留。")
                        .font(.caption)
                        .foregroundStyle(PFColor.secondaryText)
                }
                if !preparedPreview.issueSummary.isEmpty {
                    VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
                        Text("异常原因")
                            .font(.subheadline.weight(.semibold))
                        ForEach(preparedPreview.issueSummary, id: \.0) { item in
                            Text("• \(item.0)：\(item.1) 行")
                                .font(.caption)
                                .foregroundStyle(PFColor.secondaryText)
                        }
                    }
                }
            }
            .padding(PFSpacing.large)
            .background(PFColor.card, in: RoundedRectangle(cornerRadius: PFRadius.medium))

            HStack {
                Button("重新选择") {
                document = nil
                scheduledPlanningKey = nil
                categoryMappingSelections = [:]
                rowCategorySelections = [:]
                rowReviewContext = nil
                previewTask?.cancel()
                previewSnapshot = nil
                showImporter = true
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(isImporting ? "正在导入…" : "确认导入") { commit(plan) }
                    .buttonStyle(.borderedProminent)
                    .tint(PFColor.accent)
                    .disabled(effectiveRows.isEmpty || isImporting)
                    .accessibilityIdentifier("confirm-import")
            }
            if isImporting {
                ProgressView(
                    "正在导入 \(importProgress) / \(effectiveRows.count)",
                    value: Double(importProgress),
                    total: Double(effectiveRows.count)
                )
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } else if plan != nil || isPreparingPreview {
            ProgressView("正在准备导入预览…")
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(alignment: .leading, spacing: PFSpacing.medium) {
                PFEmptyState(
                    symbol: "exclamationmark.triangle",
                    title: "无法生成预览",
                    message: planErrorMessage ?? "无法解析当前字段。"
                )
                if document?.detection.isSpecialized == true && parserMode == .automatic {
                    Button("改用通用映射") { parserMode = .generic }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("use-generic-mapping-from-error")
                }
            }
        }
    }

    private func resultView(_ value: ImportResult) -> some View {
        VStack(alignment: .leading, spacing: PFSpacing.medium) {
            Label("导入完成", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(PFColor.income)
            metric("成功导入", "\(value.importedCount)")
            metric("跳过重复", "\(value.duplicateCount)")
            metric("规则跳过", "\(value.skippedCount)")
            metric("解析失败", "\(value.failedCount)")
            metric("创建分类", "\(value.createdCategoryCount)")
            metric("创建账户", "\(value.createdAccountCount)")
            metric("创建标签", "\(value.createdTagCount)")
            metric("收入", money(value.incomeMinorUnits))
            metric("支出", money(value.expenseMinorUnits))
            Button("继续导入") {
                result = nil
                document = nil
                parserMode = .automatic
                showImporter = true
            }
            .buttonStyle(.bordered)
        }
        .padding(PFSpacing.large)
        .background(PFColor.card, in: RoundedRectangle(cornerRadius: PFRadius.medium))
    }

    private func commit(_ plan: ImportPlan) {
        guard !isImporting else { return }
        let modelSnapshot = FinanceCSVService.makeImportModelSnapshot(
            accounts: accounts,
            categories: categories,
            tags: tags
        )
        let rememberedMappings = effectiveCategoryMappings(source: plan.source)
        let rowOverrides = rowCategorySelections
        let shouldCreateCategories = createMissingCategories
        let shouldCreateAccounts = createMissingAccounts
        let shouldCreateTags = createMissingTags
        let shouldIncludeSuspected = includeSuspectedDuplicates
        let shouldIncludeConfirmed = includeConfirmedDuplicates
        let modelContainer = modelContext.container
        let mappingsToRemember = categoryMappingSelections
        let mappingGeneration = ImportCategoryMappingStore.generation()
        let shouldRememberMappings = rememberCategoryMappings
        isImporting = true
        importProgress = 0
        let (progressStream, progressContinuation) = AsyncStream<Int>.makeStream()
        Task {
            for await completed in progressStream {
                importProgress = completed
            }
        }
        Task {
            do {
                let request = try await Task.detached(priority: .userInitiated) {
                    try FinanceCSVService.makeBackgroundCommitRequest(
                        plan: plan,
                        modelSnapshot: modelSnapshot,
                        createMissingCategories: shouldCreateCategories,
                        createMissingAccounts: shouldCreateAccounts,
                        createMissingTags: shouldCreateTags,
                        includeSuspectedDuplicates: shouldIncludeSuspected,
                        includeConfirmedDuplicates: shouldIncludeConfirmed,
                        rememberedCategoryMappings: rememberedMappings,
                        rowCategoryOverrides: rowOverrides
                    )
                }.value
                let importer = ImportCommitActor(modelContainer: modelContainer)
                let commitResult = try await importer.commit(
                    request,
                    progress: progressContinuation
                )
                result = commitResult
                if commitResult.importedCount > 0 { ledgerChangeCenter.recordMutation() }
                if shouldRememberMappings {
                    for (group, targetID) in mappingsToRemember {
                        ImportCategoryMappingStore.remember(
                            source: plan.source,
                            rawCategory: group.rawCategory,
                            kind: group.kind,
                            targetID: targetID,
                            categories: modelSnapshot.categories,
                            expectedGeneration: mappingGeneration
                        )
                    }
                }
            } catch {
                progressContinuation.finish()
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    private func money(_ value: Int64) -> String {
        let absolute = value == .min ? Int64.max : abs(value)
        let amount = (try? Money(minorUnits: absolute).formatted()) ?? "—"
        return value < 0 ? "−\(amount)" : amount
    }

    private func sourceName(_ source: ImportSourceType) -> String {
        switch source {
        case .wacai: "挖财"
        case .wechat: "微信"
        case .alipay: "支付宝"
        case .jd: "京东"
        case .genericCSV: "通用格式"
        }
    }

    private func parsingMethodName(_ method: BillImportParsingMethod) -> String {
        switch method {
        case .specialized: "专用解析"
        case .genericMapping: "通用字段映射"
        }
    }

    private func formattedImportDate(_ candidate: ImportCandidate) -> String {
        AppDateFormatter.shortDateTime(
            candidate.occurredAt,
            locale: locale,
            timeZone: TimeZone(identifier: candidate.timeZoneIdentifier) ?? .autoupdatingCurrent
        )
    }

    @ViewBuilder
    private func categoryResolutionEditors(
        rows: [ImportCandidate],
        groups: [ImportCategoryGroupSnapshot],
        source: ImportSourceType,
        resolutionsByRowNumber: [Int: ImportCategoryResolution]
    ) -> some View {
        VStack(alignment: .leading, spacing: PFSpacing.small) {
            Text("按来源分类批量修改")
                .font(.subheadline.weight(.semibold))
            ForEach(groups) { group in
                Picker(
                    "\(group.rawCategory) · \(categoryKindName(group.kind))",
                    selection: categoryMappingBinding(group)
                ) {
                    Text("自动解析").tag(nil as UUID?)
                    ForEach(activeCategoryTargets(kind: group.kind)) { category in
                        Text(category.displayPath(in: categories)).tag(category.id as UUID?)
                    }
                }
            }

            Text("逐条修改摘要（前 8 条）")
                .font(.subheadline.weight(.semibold))
                .padding(.top, PFSpacing.small)
            ForEach(ImportCategoryReviewList.summaryRows(rows), id: \.rowNumber) { row in
                let resolution = resolutionsByRowNumber[row.rowNumber]
                VStack(alignment: .leading, spacing: 2) {
                    Text("第 \(row.rowNumber) 行 · 原始：\(row.categoryName.isEmpty ? "无" : row.categoryName)")
                        .font(.caption)
                    Text(resolution.map(categoryResolutionDescription) ?? "待选择分类 · 待复核")
                        .font(.caption2)
                        .foregroundStyle(resolution?.requiresReview == true ? PFColor.danger : PFColor.secondaryText)
                    Picker("单条分类", selection: rowCategoryBinding(row.rowNumber)) {
                        Text("使用批量/自动结果").tag(nil as UUID?)
                        ForEach(activeCategoryTargets(kind: categoryKind(for: row))) { category in
                            Text(category.displayPath(in: categories)).tag(category.id as UUID?)
                        }
                    }
                    .labelsHidden()
                }
            }
            Button("查看并修改全部 \(rows.count) 条待复核记录") {
                rowReviewContext = ImportRowReviewContext(rows: rows, source: source)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("review-all-import-categories")
        }
    }

    private func activeCategoryTargets(kind: CategoryKind) -> [Category] {
        CategoryHierarchy(categories: categories)
            .orderedCategories(kind: kind, activeOnly: true)
    }

    private func categoryMappingBinding(_ group: ImportCategoryGroupSnapshot) -> Binding<UUID?> {
        Binding(
            get: { categoryMappingSelections[group] },
            set: { categoryMappingSelections[group] = $0 }
        )
    }

    private func rowCategoryBinding(_ rowNumber: Int) -> Binding<UUID?> {
        Binding(
            get: { rowCategorySelections[rowNumber] },
            set: { rowCategorySelections[rowNumber] = $0 }
        )
    }

    private func effectiveCategoryMappings(source: ImportSourceType) -> [String: UUID] {
        let snapshot = FinanceCSVService.makeImportModelSnapshot(accounts: [], categories: categories, tags: [])
        var values = ImportCategoryMappingStore.mappings(categories: snapshot.categories)
        for (group, targetID) in categoryMappingSelections {
            values[ImportCategoryMappingStore.stableKey(
                source: source,
                rawCategory: group.rawCategory,
                kind: group.kind
            )] = targetID
        }
        return values
    }

    private func categoryKind(for row: ImportCandidate) -> CategoryKind {
        row.type == .income ? .income : .expense
    }

    private func categoryKindName(_ kind: CategoryKind) -> String {
        kind == .income ? "收入" : "支出"
    }

    private func categoryResolutionDescription(_ resolution: ImportCategoryResolution) -> String {
        if let id = resolution.resolvedCategoryID,
           let category = categories.first(where: { $0.id == id }) {
            return "\(category.displayPath(in: categories)) · \(resolutionReasonName(resolution.reason))"
        }
        if let rootID = resolution.proposedRootID,
           let root = categories.first(where: { $0.id == rootID }),
           let child = resolution.proposedChildName {
            return "建议新建：\(root.name) / \(child) · 待确认"
        }
        return "待选择分类 · 待复核"
    }

    private func resolutionReasonName(_ reason: ImportCategoryResolutionReason) -> String {
        switch reason {
        case .rememberedMapping: "已记住映射"
        case .exactPath: "完整路径匹配"
        case .uniqueChildName: "唯一小类匹配"
        case .sourceAlias: "来源别名匹配"
        case .inferredFromDescription: "备注或商户推断"
        case .existingRoot: "已有大类匹配"
        case .proposedChild: "高置信度小类候选"
        case .unresolved: "无法可靠匹配"
        }
    }

    private func rebuildPlan() {
        guard let document else { return }
        let planningKey = ImportPlanningKey(
            documentID: documentID,
            mapping: mapping,
            parserMode: parserMode
        )
        guard scheduledPlanningKey != planningKey else { return }
        scheduledPlanningKey = planningKey
        let generation = UUID()
        planGeneration = generation
        planningTask?.cancel()
        previewTask?.cancel()
        previewSnapshot = nil
        isPlanning = true
        let currentMapping = mapping
        let currentFileName = fileName
        let currentMode = parserMode
        let modelContainer = modelContext.container
        planningTask = Task {
            do {
                try await Task.sleep(nanoseconds: 75_000_000)
                try Task.checkCancellation()
                let parseTask = Task.detached(priority: .userInitiated) {
                    try FinanceCSVService.parsePlan(
                        document: document,
                        mapping: currentMapping,
                        fileName: currentFileName,
                        parserMode: currentMode
                    )
                }
                let parsedPlan = try await withTaskCancellationHandler {
                    try await parseTask.value
                } onCancel: {
                    parseTask.cancel()
                }
                try Task.checkCancellation()
                let planner = ImportPlanningActor(modelContainer: modelContainer)
                let existingRecords = try await planner.duplicateRecords(for: parsedPlan)
                try Task.checkCancellation()
                let assessmentTask = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return FinanceCSVService.assessDuplicates(
                        parsedPlan,
                        existingRecords: existingRecords
                    )
                }
                let rebuiltPlan = try await withTaskCancellationHandler {
                    try await assessmentTask.value
                } onCancel: {
                    assessmentTask.cancel()
                }
                guard planGeneration == generation else { return }
                plan = rebuiltPlan
                planErrorMessage = nil
                rebuildPreviewSnapshot(for: rebuiltPlan)
            } catch is CancellationError {
                return
            } catch {
                guard planGeneration == generation else { return }
                plan = nil
                previewSnapshot = nil
                planErrorMessage = error.localizedDescription
            }
            if planGeneration == generation {
                isPlanning = false
            }
        }
    }

    private func rebuildPreviewSnapshot(for targetPlan: ImportPlan? = nil) {
        guard let currentPlan = targetPlan ?? plan else { return }
        let generation = UUID()
        previewGeneration = generation
        previewTask?.cancel()
        previewSnapshot = nil
        isPreparingPreview = true
        let modelSnapshot = FinanceCSVService.makeImportModelSnapshot(
            accounts: accounts,
            categories: categories,
            tags: tags
        )
        let rememberedMappings = effectiveCategoryMappings(source: currentPlan.source)
        let rowOverrides = rowCategorySelections
        let shouldIncludeSuspected = includeSuspectedDuplicates
        let shouldIncludeConfirmed = includeConfirmedDuplicates
        previewTask = Task {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
                let preparationTask = Task.detached(priority: .userInitiated) {
                    try FinanceCSVService.makePreviewSnapshot(
                        plan: currentPlan,
                        modelSnapshot: modelSnapshot,
                        includeSuspectedDuplicates: shouldIncludeSuspected,
                        includeConfirmedDuplicates: shouldIncludeConfirmed,
                        rememberedCategoryMappings: rememberedMappings,
                        rowCategoryOverrides: rowOverrides
                    )
                }
                let snapshot = try await withTaskCancellationHandler {
                    try await preparationTask.value
                } onCancel: {
                    preparationTask.cancel()
                }
                guard previewGeneration == generation else { return }
                previewSnapshot = snapshot
            } catch is CancellationError {
                return
            } catch {
                guard previewGeneration == generation else { return }
                previewSnapshot = nil
                planErrorMessage = error.localizedDescription
            }
            if previewGeneration == generation {
                isPreparingPreview = false
            }
        }
    }

    private func fileSummary(_ document: BillImportDocument) -> String {
        var parts = [fileName, document.format.rawValue]
        if let encoding = document.encodingName { parts.append(encoding) }
        if let sheetName = document.sheetName { parts.append(sheetName) }
        parts.append("表头第 \(document.headerRowNumber) 行")
        return parts.joined(separator: " · ")
    }
}

private struct ImportCategoryRowReviewView: View {
    @Environment(\.dismiss) private var dismiss

    let rows: [ImportCandidate]
    let source: ImportSourceType
    let categories: [Category]
    let rememberedCategoryMappings: [String: UUID]
    @Binding var rowCategorySelections: [Int: UUID]

    @State private var query = ""

    private var filteredRows: [ImportCandidate] {
        ImportCategoryReviewList.filteredRows(rows, query: query)
    }

    var body: some View {
        NavigationStack {
            List(filteredRows) { row in
                VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
                    Text("第 \(row.rowNumber) 行 · \(kindName(for: row)) · 原始：\(rawName(for: row))")
                        .font(.subheadline.weight(.semibold))
                    if !row.persistedNote.isEmpty {
                        Text(row.persistedNote)
                            .font(.caption)
                            .foregroundStyle(PFColor.secondaryText)
                            .lineLimit(2)
                    }
                    Text(resolutionDescription(for: row))
                        .font(.caption)
                        .foregroundStyle(PFColor.secondaryText)
                    Picker("逐条覆盖", selection: binding(for: row.rowNumber)) {
                        Text("使用批量/自动结果").tag(nil as UUID?)
                        ForEach(activeTargets(for: row)) { category in
                            Text(category.displayPath(in: categories)).tag(category.id as UUID?)
                        }
                    }
                    .accessibilityIdentifier("import-row-category-\(row.rowNumber)")
                }
                .padding(.vertical, PFSpacing.xSmall)
            }
            .overlay {
                if filteredRows.isEmpty {
                    PFEmptyState(
                        symbol: "magnifyingglass",
                        title: "没有匹配记录",
                        message: "可搜索行号、原始分类、备注、商户或收支类型。"
                    )
                }
            }
            .searchable(text: $query, prompt: "搜索待复核记录")
            .navigationTitle("全部待复核记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func activeTargets(for row: ImportCandidate) -> [Category] {
        let kind: CategoryKind = row.type == .income ? .income : .expense
        return CategoryHierarchy(categories: categories)
            .orderedCategories(kind: kind, activeOnly: true)
    }

    private func binding(for rowNumber: Int) -> Binding<UUID?> {
        Binding(
            get: { rowCategorySelections[rowNumber] },
            set: { rowCategorySelections[rowNumber] = $0 }
        )
    }

    private func resolutionDescription(for row: ImportCandidate) -> String {
        let kind: CategoryKind = row.type == .income ? .income : .expense
        let key = ImportCategoryMappingStore.stableKey(
            source: source,
            rawCategory: row.categoryName,
            kind: kind
        )
        let resolution = ImportCategoryResolutionService.resolve(
            source: source,
            rawCategory: row.categoryName,
            note: row.persistedNote,
            merchant: row.merchantName,
            type: row.type,
            kind: kind,
            categories: categories,
            rememberedCategoryID: rowCategorySelections[row.rowNumber]
                ?? rememberedCategoryMappings[key]
        )
        guard let id = resolution.resolvedCategoryID,
              let category = categories.first(where: { $0.id == id }) else {
            return "待选择分类"
        }
        return "当前：\(category.displayPath(in: categories))"
    }

    private func rawName(for row: ImportCandidate) -> String {
        row.categoryName.isEmpty ? "无" : row.categoryName
    }

    private func kindName(for row: ImportCandidate) -> String {
        row.type == .income ? "收入" : "支出"
    }
}

private struct BillExportView: View {
    @Environment(\.modelContext) private var modelContext
    private enum Scope: String, CaseIterable {
        case all = "全部"
        case currentMonth = "本月"
        case custom = "自定义"
    }

    @State private var scope: Scope = .all
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var preparedExport: (scope: LedgerExportScope, url: URL)?
    @State private var errorMessage: String?
    @State private var countResult: (scope: LedgerExportScope, count: Int)?
    @State private var isExporting = false

    var body: some View {
        Form {
            Section("导出范围") {
                Picker("范围", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if scope == .custom {
                    DatePicker("开始", selection: $startDate, displayedComponents: .date)
                    DatePicker("结束", selection: $endDate, displayedComponents: .date)
                }
                let count = countResult.flatMap { $0.scope == resolvedExportScope() ? $0.count : nil }
                LabeledContent("有效交易", value: count.map { "\($0) 笔" } ?? "…")
            }
            .disabled(isExporting)

            Section {
                Text("CSV 使用 UTF-8 BOM、精确十进制金额和标准转义，不包含软删除交易。")
                    .font(.footnote)
                    .foregroundStyle(PFColor.secondaryText)
                Text("CSV 用于 Excel/Numbers 与外部交换，不是完整恢复格式；完整恢复请使用“完整备份与恢复”。")
                    .font(.footnote)
                    .foregroundStyle(PFColor.secondaryText)
                Button(isExporting ? "正在生成…" : "生成 CSV") { prepareExport() }
                    .disabled(isExporting)
                    .accessibilityIdentifier("prepare-export")
                if isExporting {
                    ProgressView("正在生成导出文件…")
                }
                if let preparedExport, preparedExport.scope == resolvedExportScope() {
                    ShareLink(item: preparedExport.url) {
                        Label("分享或保存文件", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("share-export")
                }
            } header: {
                Text("文件")
            } footer: {
                Text("文件在本地生成，App 不会自动上传；分享后的去向由你在系统分享面板中选择。")
            }
        }
        .navigationTitle("导出账单")
        .task(id: resolvedExportScope()) {
            let scope = resolvedExportScope()
            let count = try? await LedgerExportActor(modelContainer: modelContext.container).count(scope: scope)
            if !Task.isCancelled, let count { countResult = (scope, count) }
        }
        .onChange(of: resolvedExportScope()) { preparedExport = nil }
        .alert("无法导出", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func prepareExport() {
        guard !isExporting else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let suffix = scope == .custom
            ? "\(formatter.string(from: min(startDate, endDate)))_\(formatter.string(from: max(startDate, endDate)))"
            : formatter.string(from: Date())
        let exportScope = resolvedExportScope()
        let modelContainer = modelContext.container
        isExporting = true
        Task {
            do {
                let exporter = LedgerExportActor(modelContainer: modelContainer)
                let url = try await exporter.export(
                    scope: exportScope,
                    fileName: "PersonalFinanceOS_Transactions_\(suffix).csv"
                )
                if exportScope == resolvedExportScope() { preparedExport = (exportScope, url) }
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }

    private func resolvedExportScope() -> LedgerExportScope {
        switch scope {
        case .all:
            return .all
        case .currentMonth:
            let range = LedgerQueryService.localDayRange(for: Date())
            return .localDayRange(
                lowerBound: range.lowerBound,
                upperBound: range.upperBound,
                includesUpperBound: false
            )
        case .custom:
            return .localDayRange(
                lowerBound: LocalDayKey.make(for: min(startDate, endDate), timeZone: .current),
                upperBound: LocalDayKey.make(for: max(startDate, endDate), timeZone: .current),
                includesUpperBound: true
            )
        }
    }
}
