import SwiftData
import SwiftUI

struct TransactionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Tag.sortOrder) private var tags: [Tag]
    @AppStorage(SmartSuggestionPreferences.foundationModelEnabledKey) private var foundationModelEnabled =
        SmartSuggestionPreferences.defaultEnabled
    @AppStorage(SmartSuggestionPreferences.historyCutoffKey) private var suggestionHistoryCutoff = 0.0

    private let transaction: FinanceTransaction?
    private let onSaved: () -> Void
    private let foundationProvider: any FoundationClassificationProviding
    @State private var draft: TransactionDraft
    @State private var amountInputSession: AmountInputSession
    @State private var pendingDate: Date
    @State private var isDateEditorPresented = false
    @State private var isSaving = false
    @State private var saveSucceeded = false
    @State private var saveError: String?
    @State private var suggestion = SmartTransactionSuggestion.none
    @State private var suggestionSession: SmartSuggestionSession
    @State private var suggestionRequestTracker = SmartSuggestionRequestTracker()
    @State private var automaticCategoryRevision: Int?
    @State private var suggestionTask: Task<Void, Never>?
    @State private var didAutoFillSuggestion = false
    @State private var isShowingManualSuggestion = false
    @State private var isMerchantEditorPresented = false
    @State private var isCategoryListPresented = false
    @State private var isTagPickerPresented = false
    @State private var quickAddHistory: [FinanceTransaction] = []
    @State private var classificationProfile = ClassificationProfile.empty
    @State private var classificationProfileTask: Task<Void, Never>?
    @State private var classificationProfileRequest = UUID()
    @State private var classificationProfileIsRefreshing = false
    @State private var classificationHistoryStatus: ClassificationHistoryStatus = .loading
    @State private var classificationReadRevision: UInt64?
    @State private var classificationLearningGeneration: ClassificationLearningGeneration?
    @State private var classificationCategories: [SuggestionCategory] = []
    @State private var classificationTags: [SuggestionTag] = []
    @State private var liveFormHeight: CGFloat = 0
    @State private var renderedCategoryGridHeight: CGFloat = 0
    @State private var fourRowCategoryGridHeight: CGFloat = 0
    @FocusState private var focusedTextField: FocusedTextField?

    private enum FocusedTextField: Hashable {
        case note
    }

    private enum ClassificationHistoryStatus {
        case loading, ready, unavailable
    }

    private enum FormDensity {
        case standard
        case compactAmount

        var formSpacing: CGFloat {
            switch self {
            case .standard: return PFSpacing.large
            case .compactAmount: return PFSpacing.medium
            }
        }

        var categoryRowSpacing: CGFloat {
            switch self {
            case .standard: return PFSpacing.small
            case .compactAmount: return 6
            }
        }

        var categoryItemSpacing: CGFloat {
            switch self {
            case .standard: return PFSpacing.xSmall
            case .compactAmount: return 2
            }
        }

        var categoryIconSize: CGFloat {
            switch self {
            case .standard: return 38
            case .compactAmount: return 34
            }
        }

        var categoryItemMinimumHeight: CGFloat {
            switch self {
            case .standard: return 60
            case .compactAmount: return 52
            }
        }
    }

    init(
        transaction: FinanceTransaction? = nil,
        initialDraft: TransactionDraft? = nil,
        initialDate: Date? = nil,
        foundationProvider: any FoundationClassificationProviding = AppleFoundationClassificationProvider(),
        onSaved: @escaping () -> Void = {}
    ) {
        self.transaction = transaction
        self.onSaved = onSaved
        self.foundationProvider = foundationProvider
        var startingDraft = initialDraft
            ?? transaction.map(TransactionDraft.init)
            ?? TransactionDraft()
        if transaction == nil, initialDraft == nil, let initialDate {
            startingDraft.occurredAt = initialDate
        }
#if DEBUG
        let testOccurredAt = UserDefaults.standard.double(forKey: "classificationFormTestOccurredAt")
        if transaction == nil, initialDraft == nil, testOccurredAt > 0 {
            startingDraft.occurredAt = Date(timeIntervalSince1970: testOccurredAt)
        }
#endif
        _draft = State(initialValue: startingDraft)
        _amountInputSession = State(initialValue: AmountInputSession(
            initialExpression: startingDraft.amountText
        ))
        _pendingDate = State(initialValue: startingDraft.occurredAt)
        _suggestionSession = State(initialValue: SmartSuggestionSession(
            editingExisting: transaction != nil,
            hasInitialCategory: startingDraft.categoryID != nil,
            initialTagIDs: startingDraft.tagIDs
        ))
    }

    private var availableAccounts: [Account] {
        accounts.filter { $0.archivedAt == nil || $0.id == draft.accountID }
    }

    private var availableCategories: [Category] {
        // Keep ancestors for historical paths; each selection surface applies
        // effective eligibility to the complete graph instead of removing parents.
        categories.filter { $0.kind == categoryKind }
    }

    private var hierarchy: CategoryHierarchy {
        CategoryHierarchy(categories: availableCategories)
    }

    private var selectableCategories: [Category] {
        var values = hierarchy.selectableCategories(kind: categoryKind)
        if let selected = hierarchy.category(id: draft.categoryID),
           !values.contains(where: { $0.id == selected.id }) {
            values.append(selected)
        }
        return values
    }

    private var selectedCategory: Category? {
        hierarchy.category(id: draft.categoryID)
    }

    private func quickCategories(limit: Int) -> [Category] {
        CategoryQuickAccessService.visibleCategories(
            categories: availableCategories,
            transactions: quickAddHistory,
            kind: categoryKind,
            selectedID: draft.categoryID,
            suggestedID: suggestion.categoryID,
            limit: limit
        )
    }

    private var categoryKind: CategoryKind {
        draft.type == .income ? .income : .expense
    }

    private var evaluatedMoney: Money? {
        try? AmountExpression.evaluateMoney(draft.amountText, currencyCode: draft.currencyCode)
    }

    private var canSave: Bool {
        !isSaving &&
        availableAccounts.contains { $0.id == draft.accountID } &&
        availableCategories.contains { $0.id == draft.categoryID } &&
        evaluatedMoney != nil
    }

    private var inputMode: TransactionEntryInputMode {
        if focusedTextField == .note {
            return .note
        }
        if isMerchantEditorPresented {
            return .merchant
        }
        if isDateEditorPresented || isCategoryListPresented || isTagPickerPresented {
            return .none
        }
        return .amount
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                formContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                bottomControls
            }
            .background(PFColor.background)
            .navigationTitle(transaction == nil ? "记一笔" : "编辑交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .accessibilityIdentifier("transaction-cancel")
                }
            }
            .task { await initializeForm() }
            .onChange(of: accounts.count) {
                handleAccountCountChange()
            }
            .onChange(of: draft.note) {
                handleSuggestionInputChange()
            }
            .onChange(of: draft.rawMerchantText) {
                handleSuggestionInputChange()
            }
            .onChange(of: draft.type) {
                handleTransactionTypeChange()
            }
            .onChange(of: foundationModelEnabled) {
                handleSmartSuggestionPreferenceChange()
            }
            .onChange(of: ledgerChangeCenter.revision) { requestClassificationRefresh() }
            .onChange(of: suggestionHistoryCutoff) { requestClassificationRefresh() }
            .onChange(of: categories.map(MetadataEditSnapshot.CategoryValue.init)) { requestClassificationRefresh() }
            .onChange(of: tags.map(MetadataEditSnapshot.TagValue.init)) { requestClassificationRefresh() }
            .onDisappear {
                invalidateClassificationRefresh()
                suggestionTask?.cancel()
                suggestionRequestTracker.invalidate()
            }
            .sheet(isPresented: $isDateEditorPresented, onDismiss: restoreAmountMode) {
                dateEditor
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $isMerchantEditorPresented, onDismiss: restoreAmountMode) {
                MerchantEditorSheet(initialValue: draft.rawMerchantText) { value in
                    draft.rawMerchantText = value
                    draft.merchantID = nil
                }
                .presentationDetents([.height(220)])
            }
            .sheet(isPresented: $isCategoryListPresented, onDismiss: restoreAmountMode) {
                CategoryPickerSheet(
                    categories: availableCategories,
                    transactions: quickAddHistory,
                    kind: categoryKind,
                    selectedID: draft.categoryID,
                    onSelect: selectCategory
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isTagPickerPresented) {
                TagPickerSheet(
                    tagIDs: $draft.tagIDs,
                    suggestionSession: $suggestionSession
                )
                .presentationDetents([.medium, .large])
            }
            .alert(
                "无法完成操作",
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
            .sensoryFeedback(.success, trigger: saveSucceeded)
        }
        .environment(\.locale, locale)
    }

    private var formContent: some View {
        GeometryReader { geometry in
            ScrollView {
                formFields(
                    categoryLimit: categoryLimit(availableFormHeight: geometry.size.height),
                    density: formDensity
                )
            }
            .scrollDismissesKeyboard(.never)
        }
        .accessibilityIdentifier("transaction-form-scroll")
    }

    private var formDensity: FormDensity {
        inputMode == .amount && !dynamicTypeSize.isAccessibilitySize ? .compactAmount : .standard
    }

    private func categoryLimit(availableFormHeight: CGFloat) -> Int {
        QuickAddCategoryLimit.intrinsicLimit(
            availableFormHeight: availableFormHeight,
            liveFormHeight: liveFormHeight,
            renderedCategoryGridHeight: renderedCategoryGridHeight,
            fourRowCategoryGridHeight: fourRowCategoryGridHeight,
            inputMode: inputMode,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    private func formFields(
        categoryLimit: Int,
        density: FormDensity = .standard
    ) -> some View {
        VStack(alignment: .leading, spacing: density.formSpacing) {
            typePicker
            currentCategoryAndAmount
            secondaryInfoBar
            categoryPicker(categoryLimit: categoryLimit, density: density)
            smartSuggestionSection
            noteInput
        }
        .padding(.horizontal, PFSpacing.xLarge)
        .padding(.top, PFSpacing.medium)
        .padding(.bottom, PFSpacing.large)
        .background {
            GeometryReader { proxy in
                Color.clear.task(id: proxy.size.height) {
                    liveFormHeight = proxy.size.height
                }
            }
        }
    }

    private var noteInput: some View {
        HStack(spacing: PFSpacing.small) {
            Image(systemName: "note.text")
                .foregroundStyle(PFColor.secondaryText)
            TextField("写点备注…", text: $draft.note)
                .lineLimit(1)
                .submitLabel(.done)
                .focused($focusedTextField, equals: .note)
                .accessibilityIdentifier("transaction-note")
                .onSubmit { restoreAmountMode() }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, PFSpacing.medium)
        .background(PFColor.elevatedSurface, in: Capsule())
    }

    @ViewBuilder
    private var smartSuggestionSection: some View {
        if !suggestionSession.allowsAutomaticRun || suggestion.hasContent || isShowingManualSuggestion ||
            (classificationReadRevision != nil && classificationHistoryStatus != .ready &&
             (!draft.note.isEmpty || !draft.rawMerchantText.isEmpty)) {
            VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
                HStack(spacing: PFSpacing.small) {
                    Image(systemName: suggestionSession.allowsAutomaticRun ? "sparkles" : "hand.raised")
                    Text(suggestionSession.allowsAutomaticRun
                         ? (didAutoFillSuggestion ? "已智能识别 · \(suggestionSummary)"
                            : suggestionSummary.isEmpty ? "基础建议" : suggestionSummary)
                         : "已手动选定")
                        .accessibilityIdentifier("smart-suggestion")
                    Spacer()
                    if didAutoFillSuggestion && suggestionSession.allowsAutomaticRun {
                        Button("撤销") { undoAutomaticSuggestion() }
                            .accessibilityIdentifier("undo-smart-suggestion")
                    } else if !suggestionSession.allowsAutomaticRun {
                        Button("重新建议") {
                            isShowingManualSuggestion = true
                            scheduleSuggestionIfAllowed()
                        }
                        .accessibilityIdentifier("refresh-smart-suggestion")
                    } else if shouldOfferSuggestionAdoption && suggestion.alternatives.isEmpty {
                        Button("采用") { acceptSuggestion() }
                            .accessibilityIdentifier("accept-smart-suggestion")
                    }
                }
                if suggestion.hasContent && (!didAutoFillSuggestion || isShowingManualSuggestion) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: PFSpacing.small) {
                            ForEach(suggestionCandidates) { candidate in
                                if let category = hierarchy.category(id: candidate.categoryID), hierarchy.isEligibleForSelection(category) {
                                    Button(hierarchy.displayPath(for: category)) { acceptSuggestion(categoryID: category.id) }
                                        .buttonStyle(.bordered)
                                        .frame(minHeight: 44)
                                        .disabled(!isSuggestionCurrent)
                                }
                            }
                        }
                    }
                } else if isShowingManualSuggestion {
                    Text("建议仅供选择，当前分类保持不变")
                        .foregroundStyle(PFColor.secondaryText)
                }
                if !suggestion.explanation.isEmpty {
                    Text(suggestion.explanation)
                        .foregroundStyle(PFColor.secondaryText)
                }
                if classificationReadRevision != nil && classificationHistoryStatus != .ready {
                    Text(classificationHistoryStatus == .loading
                         ? "基础规则可用，个人建议更新中"
                         : "个人建议暂不可用，基础规则仍可用")
                        .foregroundStyle(PFColor.secondaryText)
                }
            }
            .font(.caption)
            .foregroundStyle(PFColor.accent)
        }
    }

    @ViewBuilder
    private var typePicker: some View {
        if draft.type == .refund {
            Label("退款记录", systemImage: "arrow.uturn.backward.circle")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("transaction-type")
        } else {
            Picker("交易类型", selection: $draft.type) {
                Text("支出").tag(TransactionType.expense)
                Text("收入").tag(TransactionType.income)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("transaction-type")
        }
    }

    private var currentCategoryAndAmount: some View {
        Button {
            restoreAmountMode()
        } label: {
            HStack(spacing: PFSpacing.medium) {
                CategoryIconView(
                    symbolName: selectedCategory?.symbolName ?? CategoryIconLibrary.fallback,
                    color: selectedCategory.map { PFColor.category($0.colorToken) } ?? PFColor.secondaryText,
                    size: 44
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedCategory?.name ?? "请选择分类")
                        .font(.headline)
                        .foregroundStyle(PFColor.primaryText)
                        .lineLimit(1)
                    if let selectedCategory, selectedCategory.parentID != nil {
                        Text(hierarchy.rootCategory(for: selectedCategory).name)
                            .font(.caption)
                            .foregroundStyle(PFColor.secondaryText)
                    } else {
                        Text(categoryKind == .expense ? "支出分类" : "收入分类")
                            .font(.caption)
                            .foregroundStyle(PFColor.secondaryText)
                    }
                }

                Spacer(minLength: PFSpacing.small)

                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(draft.currencyCode == Money.cnyCode ? "¥" : draft.currencyCode)
                            .font(.headline)
                            .foregroundStyle(PFColor.secondaryText)
                        Text(draft.amountText.isEmpty ? "0.00" : draft.amountText)
                            .font(.system(.title, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.45)
                            .foregroundStyle(
                                draft.amountText.isEmpty ? PFColor.secondaryText : PFColor.primaryText
                            )
                    }
                    if containsOperation, let evaluatedMoney {
                        Text("= \(evaluatedMoney.formatted())")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(PFColor.accent)
                    }
                }
                .accessibilityIdentifier("transaction-amount")
                .accessibilityLabel("金额表达式，\(draft.currencyCode)")
                .accessibilityValue(draft.amountText.isEmpty ? "空" : draft.amountText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, PFSpacing.large)
        .padding(.vertical, PFSpacing.medium)
        .background(
            PFColor.elevatedSurface,
            in: RoundedRectangle(cornerRadius: PFRadius.medium, style: .continuous)
        )
    }

    private func categoryPicker(
        categoryLimit: Int,
        density: FormDensity
    ) -> some View {
        VStack(alignment: .leading, spacing: PFSpacing.small) {
            HStack {
                Text("常用分类")
                    .font(.subheadline.weight(.semibold))
            }

            if selectableCategories.isEmpty {
                Text("没有可用的\(categoryKind == .expense ? "支出" : "收入")分类，请先在设置中启用或新增。")
                    .font(.footnote)
                    .foregroundStyle(PFColor.secondaryText)
                    .padding(.vertical, PFSpacing.medium)
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: PFSpacing.small),
                        count: 4
                    ),
                    spacing: density.categoryRowSpacing
                ) {
                    ForEach(quickCategories(limit: categoryLimit)) { category in
                        categoryButton(category, density: density)
                    }
                    allCategoriesButton(density: density)
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.task(id: proxy.size.height) {
                    renderedCategoryGridHeight = proxy.size.height
                }
            }
        }
        .background(alignment: .topLeading) {
            fourRowCategoryGridMeasurement(density: density)
        }
        .accessibilityIdentifier("quick-category-grid")
    }

    private func fourRowCategoryGridMeasurement(density: FormDensity) -> some View {
        VStack(alignment: .leading, spacing: PFSpacing.small) {
            Text("常用分类")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: PFSpacing.small),
                    count: 4
                ),
                spacing: density.categoryRowSpacing
            ) {
                ForEach(quickCategories(limit: 15)) { category in
                    categoryMeasurementItem(category, density: density)
                }
                allCategoriesMeasurementItem(density: density)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { proxy in
                Color.clear.task(id: proxy.size.height) {
                    fourRowCategoryGridHeight = proxy.size.height
                }
            }
        }
        .hidden()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func categoryMeasurementItem(_ category: Category, density: FormDensity) -> some View {
        VStack(spacing: density.categoryItemSpacing) {
            CategoryIconView(
                symbolName: category.symbolName,
                color: PFColor.category(category.colorToken),
                size: density.categoryIconSize
            )
            Text(category.name)
                .font(.caption)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: density.categoryItemMinimumHeight)
    }

    private func allCategoriesMeasurementItem(density: FormDensity) -> some View {
        VStack(spacing: density.categoryItemSpacing) {
            Image(systemName: "square.grid.2x2")
                .frame(width: density.categoryIconSize, height: density.categoryIconSize)
            Text("全部")
                .font(.caption)
        }
        .frame(maxWidth: .infinity, minHeight: density.categoryItemMinimumHeight)
    }

    private func allCategoriesButton(density: FormDensity) -> some View {
        Button {
            focusedTextField = nil
            isCategoryListPresented = true
        } label: {
            VStack(spacing: density.categoryItemSpacing) {
                Image(systemName: "square.grid.2x2")
                    .frame(width: density.categoryIconSize, height: density.categoryIconSize)
                    .foregroundStyle(PFColor.secondaryText)
                    .background(PFColor.secondaryText.opacity(0.12), in: Circle())
                Text("全部")
                    .font(.caption)
                    .foregroundStyle(PFColor.primaryText)
            }
            .frame(maxWidth: .infinity, minHeight: density.categoryItemMinimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("all-categories")
    }

    private func categoryButton(
        _ category: Category,
        density: FormDensity
    ) -> some View {
        let isSelected = draft.categoryID == category.id
        return Button {
            selectCategory(category)
        } label: {
            VStack(spacing: density.categoryItemSpacing) {
                ZStack(alignment: .topTrailing) {
                    CategoryIconView(
                        symbolName: category.symbolName,
                        color: PFColor.category(category.colorToken),
                        size: density.categoryIconSize,
                        isSelected: isSelected
                    )
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.white, PFColor.accent)
                            .offset(x: 4, y: -3)
                    }
                }
                Text(category.name)
                    .font(.caption)
                    .foregroundStyle(PFColor.primaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: density.categoryItemMinimumHeight)
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: PFRadius.small, style: .continuous)
                    .stroke(isSelected ? PFColor.accent.opacity(0.5) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("category-\(category.name)")
        .accessibilityLabel("\(category.name)分类")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var secondaryInfoBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PFSpacing.small) {
                Button {
                    focusedTextField = nil
                    pendingDate = draft.occurredAt
                    isDateEditorPresented = true
                } label: {
                    infoChip(transactionTimeLabel, systemImage: "calendar")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("transaction-date")

                if availableAccounts.isEmpty {
                    infoChip("没有账户", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(PFColor.danger)
                } else {
                    Menu {
                        ForEach(availableAccounts) { account in
                            Button(accountName(account)) { draft.accountID = account.id }
                        }
                    } label: {
                        infoChip(
                            draft.accountID
                                .flatMap { id in availableAccounts.first { $0.id == id } }
                                .map(accountName) ?? "账户",
                            systemImage: "creditcard"
                        )
                    }
                    .accessibilityIdentifier("transaction-account")
                }

                Button {
                    focusedTextField = nil
                    isMerchantEditorPresented = true
                } label: {
                    infoChip(
                        draft.rawMerchantText.isEmpty ? "商户" : draft.rawMerchantText,
                        systemImage: "storefront"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("transaction-merchant-entry")

                Button {
                    focusedTextField = nil
                    isTagPickerPresented = true
                } label: {
                    infoChip(
                        draft.tagIDs.isEmpty ? "标签" : "标签 \(draft.tagIDs.count)",
                        systemImage: "tag"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("transaction-tags")
            }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: PFSpacing.xSmall) {
            if inputMode.showsAmountPad {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: PFSpacing.small),
                        count: 4
                    ),
                    spacing: QuickAddLayoutMetrics.calculatorRowSpacing
                ) {
                    ForEach(["7", "8", "9", "÷", "4", "5", "6", "×", "1", "2", "3", "−", "C", "0", ".", "+"], id: \.self) {
                        calculatorButton($0)
                    }
                }
                .accessibilityIdentifier("amount-keypad")
            }

            HStack(spacing: PFSpacing.small) {
                if inputMode.showsAmountPad {
                    Button("⌫") {
                        handleCalculatorInput("⌫")
                    }
                    .buttonStyle(CalculatorButtonStyle())
                    .accessibilityIdentifier("calculator-⌫")
                    .accessibilityLabel("退格")

                    Button("=") {
                        evaluateExpression()
                    }
                    .buttonStyle(CalculatorButtonStyle(isEmphasized: true))
                    .accessibilityIdentifier("calculator-equals")
                } else {
                    Button("返回金额输入") { restoreAmountMode() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("restore-amount-input")
                }

                Button(transaction == nil ? "保存" : "保存修改") {
                    save()
                }
                .buttonStyle(PFPrimaryButtonStyle())
                .disabled(!canSave)
                .accessibilityIdentifier("transaction-save")
            }
        }
        .padding(.horizontal, PFSpacing.xLarge)
        .padding(.top, PFSpacing.xSmall)
        .padding(.bottom, inputMode.showsAmountPad ? PFSpacing.xSmall : PFSpacing.small)
        .background(.ultraThinMaterial)
    }

    private func calculatorButton(_ label: String) -> some View {
        Button(label) {
            handleCalculatorInput(label)
        }
        .buttonStyle(CalculatorButtonStyle(isEmphasized: ["+", "÷", "×", "−"].contains(label)))
        .accessibilityIdentifier("calculator-\(label)")
        .accessibilityLabel(label == "⌫" ? "退格" : label == "C" ? "清空" : label)
    }

    private var dateEditor: some View {
        NavigationStack {
            VStack(spacing: PFSpacing.large) {
                DatePicker(
                    "日期",
                    selection: $pendingDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .accessibilityIdentifier("transaction-date-picker")

                DatePicker(
                    "时间",
                    selection: $pendingDate,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.compact)
                .accessibilityIdentifier("transaction-time-picker")
                .padding(.horizontal, PFSpacing.xLarge)

                Spacer()
            }
            .environment(\.timeZone, draftTimeZone)
            .navigationTitle("交易时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        isDateEditorPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        updateOccurredAt(pendingDate)
                        isDateEditorPresented = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var transactionTimeLabel: String {
        AppDateFormatter.contextualDateTime(
            draft.occurredAt,
            locale: locale,
            timeZone: draftTimeZone
        )
    }

    private var draftTimeZone: TimeZone {
        TimeZone(identifier: draft.timeZoneIdentifier) ?? .autoupdatingCurrent
    }

    private var containsOperation: Bool {
        draft.amountText.contains { ["+", "−", "×", "÷"].contains($0) }
    }

    private var availableTags: [Tag] {
        tags.filter { $0.archivedAt == nil || draft.tagIDs.contains($0.id) }
    }

    private func accountName(_ account: Account) -> String {
        account.archivedAt == nil ? account.name : "\(account.name)（已停用）"
    }

    private func infoChip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(PFColor.primaryText)
            .padding(.horizontal, PFSpacing.medium)
            .frame(minHeight: 36)
            .background(PFColor.elevatedSurface, in: Capsule())
    }

    private func selectCategory(_ category: Category) {
        suggestionSession.markManualCategorySelection(selectedCategoryID: category.id)
        suggestionTask?.cancel()
        suggestionRequestTracker.invalidate()
        isShowingManualSuggestion = false
        suggestion = .none
        didAutoFillSuggestion = false
        draft.categoryID = category.id
    }

    private func restoreAmountMode() {
        focusedTextField = nil
    }

    private func applyDefaultsIfNeeded() {
        if draft.accountID == nil {
            draft.accountID = availableAccounts.first(where: \.isDefault)?.id
                ?? availableAccounts.first?.id
        }
    }

    private func initializeForm() async {
        do {
            try DefaultFinanceDataService.ensureDefaults(in: modelContext)
            refreshQuickAddHistory()
            applyDefaultsIfNeeded()
            applyTimePrior()
            scheduleSuggestionIfAllowed()
            await refreshClassificationProfile()
            scheduleSuggestionIfAllowed()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func refreshQuickAddHistory() {
        do {
            let history = try LedgerQueryService.fetchRecentlyUpdated(limit: 500, in: modelContext)
            quickAddHistory = history
        } catch {
            quickAddHistory = []
        }
    }

    private func requestClassificationRefresh() {
        guard !isSaving else { return }
        restoreCategoryBeforeAutomaticSuggestion()
        didAutoFillSuggestion = false
        suggestion = .none
        invalidateClassificationRefresh()
        classificationProfileTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            await refreshClassificationProfile()
        }
    }

    private func refreshClassificationProfile() async {
        guard !Task.isCancelled else { return }
        if let revision = classificationReadRevision, let generation = classificationLearningGeneration,
           (try? LedgerSaveRevision.shared.readContentStamp()) == revision,
           ClassificationProfileStore.shared.generation == generation { return }
        let request = UUID()
        classificationProfileRequest = request
        classificationProfileIsRefreshing = true
        classificationHistoryStatus = .loading
        classificationProfile = .empty
        classificationReadRevision = nil
        suggestionTask?.cancel()
        suggestionRequestTracker.invalidate()
        suggestion = .none
        defer {
            if classificationProfileRequest == request {
                classificationProfileIsRefreshing = false
                classificationProfileTask = nil
            }
        }
        let store = ClassificationProfileStore.shared
        let rollingCutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? .distantPast
        if transaction == nil,
           let revision = try? LedgerSaveRevision.shared.readContentStamp(),
           let cached = ClassificationValidatedProfileCache.entry,
           cached.containerID == ObjectIdentifier(modelContext.container),
           cached.restoreGeneration == LedgerSaveRevision.shared.restoreGeneration,
           cached.revision == revision,
           cached.learningGeneration == store.generation,
           cached.historyCutoff == suggestionHistoryCutoff,
           cached.oldestHistoryDate.map({ $0 >= rollingCutoff }) ?? true {
            classificationProfile = cached.profile
            classificationCategories = cached.categories
            classificationTags = cached.tags
            classificationReadRevision = revision
            classificationLearningGeneration = cached.learningGeneration
            classificationHistoryStatus = .ready
            scheduleSuggestionIfAllowed()
            return
        }
        do {
            let revision = try LedgerSaveRevision.shared.readContentStamp()
            let currentContext = ModelContext(modelContext.container)
            let currentCategories = try currentContext.fetch(FetchDescriptor<Category>()).map {
                SuggestionCategory(id: $0.id, name: $0.name, kind: $0.kind,
                                   isActive: $0.isActiveForSelection, parentID: $0.parentID,
                                   defaultDefinitionKey: $0.defaultDefinitionKey)
            }
            let currentTags = try currentContext.fetch(FetchDescriptor<Tag>()).map {
                SuggestionTag(id: $0.id, name: $0.name, isActive: $0.archivedAt == nil)
            }
            guard !Task.isCancelled, classificationProfileRequest == request,
                  try LedgerSaveRevision.shared.readContentStamp() == revision else { return }
            classificationCategories = currentCategories
            classificationTags = currentTags
            classificationReadRevision = revision
            classificationLearningGeneration = ClassificationProfileStore.shared.generation
            scheduleSuggestionIfAllowed()
        } catch {
            await SmartClassificationDiagnostics.shared.recordLearningReadFailure()
        }
        let historyActor = ClassificationHistoryActor(modelContainer: modelContext.container)
        for _ in 0..<2 {
            guard !Task.isCancelled, classificationProfileRequest == request else { return }
            let startingGeneration = store.generation
            let clearedCutoff = suggestionHistoryCutoff > 0 ? Date(timeIntervalSince1970: suggestionHistoryCutoff) : .distantPast
            do {
                let learning: ClassificationProfileStore.Snapshot
                do { learning = try await store.snapshot() }
                catch {
                    await SmartClassificationDiagnostics.shared.recordLearningReadFailure()
                    learning = .init(events: [], generation: store.generation)
                }
                guard learning.generation.epoch == startingGeneration.epoch else { continue }
                let excludedID = transaction?.id
                let events = learning.events.filter { $0.recordedAt >= clearedCutoff && $0.transactionID != excludedID }
#if DEBUG
                let historyDelay = UserDefaults.standard.integer(forKey: "classificationHistoryTestDelayMilliseconds")
                if UserDefaults.standard.bool(forKey: "classificationHistoryTestDelayOnce") {
                    UserDefaults.standard.set(0, forKey: "classificationHistoryTestDelayMilliseconds")
                }
                if historyDelay > 0 { try await Task.sleep(for: .milliseconds(historyDelay)) }
                if UserDefaults.standard.bool(forKey: "classificationHistoryTestFailure") {
                    throw NSError(domain: "ClassificationHistoryTestFailure", code: 1)
                }
#endif
                let inputs = try await historyActor.fetchProfileInputs(
                    cutoff: max(rollingCutoff, clearedCutoff), excluding: excludedID,
                    eventIDs: events.map(\.transactionID)
                )
                let building = Task.detached(priority: .utility) {
                    ClassificationProfileBuilder.build(
                        history: inputs.history, events: events, eventLookups: inputs.eventLookups,
                        eligibleCategoryIDs: Set(SuggestionCategoryEligibility.active(inputs.categories).map(\.id))
                    )
                }
                let profile = await withTaskCancellationHandler {
                    await building.value
                } onCancel: { building.cancel() }
                guard !Task.isCancelled, classificationProfileRequest == request else { return }
                guard store.generation == learning.generation,
                      (try? LedgerSaveRevision.shared.readContentStamp()) == inputs.contentRevision else { continue }
                classificationProfile = profile
                classificationCategories = inputs.categories
                classificationTags = inputs.tags
                classificationReadRevision = inputs.contentRevision
                classificationLearningGeneration = learning.generation
                classificationHistoryStatus = .ready
                if transaction == nil {
                    ClassificationValidatedProfileCache.entry = .init(
                        containerID: ObjectIdentifier(modelContext.container),
                        restoreGeneration: LedgerSaveRevision.shared.restoreGeneration,
                        revision: inputs.contentRevision,
                        learningGeneration: learning.generation,
                        historyCutoff: suggestionHistoryCutoff,
                        oldestHistoryDate: inputs.history.map(\.occurredAt).min(),
                        profile: profile,
                        categories: inputs.categories,
                        tags: inputs.tags
                    )
                }
                scheduleSuggestionIfAllowed()
                return
            } catch is CancellationError { return }
            catch { await SmartClassificationDiagnostics.shared.recordLearningReadFailure() }
        }
        if classificationProfileRequest == request { classificationHistoryStatus = .unavailable }
    }

    private func handleTransactionTypeChange() {
        isShowingManualSuggestion = false
        restoreCategoryBeforeAutomaticSuggestion()
        draft.categoryID = nil
        suggestion = .none
        applyTimePrior()
        scheduleSuggestionIfAllowed()
    }

    private func handleAccountCountChange() {
        applyDefaultsIfNeeded()
    }

    private func updateOccurredAt(_ date: Date) {
        draft.occurredAt = date
        applyTimePrior()
    }

    private func handleSuggestionInputChange() {
        isShowingManualSuggestion = false
        scheduleSuggestionIfAllowed()
    }

    private func handleSmartSuggestionPreferenceChange() {
        isShowingManualSuggestion = false
        scheduleSuggestionIfAllowed()
    }

    private func handleCalculatorInput(_ input: String) {
        draft.amountText = amountInputSession.applying(input, to: draft.amountText)
    }

    private func evaluateExpression() {
        do {
            draft.amountText = try AmountExpression.evaluateMoney(draft.amountText, currencyCode: draft.currencyCode).decimalString
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func save() {
        guard !isSaving else {
            return
        }
        if suggestionSession.selectionState == .automatic {
            let currentAutomaticChoice = automaticCategoryRevision.map { revision in
                suggestionRequestTracker.accepts(
                    revision: revision,
                    note: draft.note,
                    merchant: draft.rawMerchantText,
                    type: draft.type
                )
            } ?? false
            if !currentAutomaticChoice || !isSuggestionCurrent ||
                suggestion.categoryConfidence != .high || suggestion.requiresUserChoice ||
                suggestion.categoryID != draft.categoryID {
                restoreCategoryBeforeAutomaticSuggestion()
                didAutoFillSuggestion = false
                guard canSave else { return }
            }
        }
        suggestionTask?.cancel()
        suggestionRequestTracker.invalidate()
        invalidateClassificationRefresh()
        isSaving = true
        defer { isSaving = false }

        do {
#if DEBUG
            if UserDefaults.standard.bool(forKey: "classificationSaveTestFailure") {
                throw NSError(domain: "ClassificationSaveTestFailure", code: 1)
            }
#endif
            let saved = try TransactionLifecycleService.save(
                draft: draft,
                editing: transaction,
                accounts: availableAccounts,
                categories: availableCategories,
                tags: tags,
                categoryDecisionSource: suggestionSession.categoryDecisionSource,
                in: modelContext
            )
            ledgerChangeCenter.recordMutation()
            if let event = classificationLearningEvent(for: saved) {
                let learningGeneration = ClassificationProfileStore.shared.generation
                Task {
                    if event.source == .explicitCorrection || event.source == .manualChoice {
                        await SmartClassificationDiagnostics.shared.recordManualOverride()
                    }
                    do { try await ClassificationProfileStore.shared.record(event, generation: learningGeneration) }
                    catch { await SmartClassificationDiagnostics.shared.recordLearningWriteFailure() }
                }
            }
            saveSucceeded.toggle()
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
            isSaving = false
            requestClassificationRefresh()
        }
    }

    private func invalidateClassificationRefresh() {
        classificationProfileTask?.cancel()
        classificationProfileTask = nil
        classificationProfileRequest = UUID()
        classificationProfileIsRefreshing = false
        classificationReadRevision = nil
    }

    private var suggestionSummary: String {
        var values: [String] = []
        if let categoryID = suggestion.categoryID,
           let category = availableCategories.first(where: { $0.id == categoryID }) {
            values.append("分类：\(category.name)")
        }
        let suggestedTagNames = availableTags
            .filter { suggestion.tagIDs.contains($0.id) }
            .map(\.name)
        if !suggestedTagNames.isEmpty {
            values.append("标签：\(suggestedTagNames.joined(separator: "、"))")
        }
        return values.joined(separator: " · ")
    }

    private var shouldOfferSuggestionAdoption: Bool {
        let categoryNeedsAdoption = suggestion.categoryID.map { $0 != draft.categoryID } ?? false
        let tagIDs = suggestionSession.eligibleAutomaticTags(suggestion.tagIDs)
        return categoryNeedsAdoption || !tagIDs.isSubset(of: draft.tagIDs)
    }

    private func scheduleSuggestionIfAllowed() {
        suggestionTask?.cancel()
        restoreCategoryBeforeAutomaticSuggestion()
        didAutoFillSuggestion = false
        let showOnly = isShowingManualSuggestion
        guard suggestionSession.allowsAutomaticRun || showOnly,
              (!SmartTransactionSuggestionService.normalize(draft.note).isEmpty ||
                !SmartTransactionSuggestionService.normalize(draft.rawMerchantText).isEmpty) else {
            suggestion = .none
            LocalDiagnostics.shared.classification(noteLength: draft.note.count, merchantLength: draft.rawMerchantText.count,
                type: draft.type, suggestion: .none, targetAvailable: false,
                manualLocked: !suggestionSession.allowsAutomaticRun, modelEnabled: foundationModelEnabled, elapsed: .zero)
            restoreCategoryBeforeAutomaticSuggestion()
            removeAutomaticTags()
            return
        }

        let requestedNote = draft.note
        let requestedMerchant = draft.rawMerchantText
        let requestedType = draft.type
        let revision = suggestionRequestTracker.begin(
            note: requestedNote,
            merchant: requestedMerchant,
            type: requestedType
        )

        suggestionTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled,
                  suggestionRequestTracker.accepts(
                    revision: revision,
                    note: draft.note,
                    merchant: draft.rawMerchantText,
                    type: draft.type
                  ) else { return }

            guard let readRevision = classificationReadRevision,
                  let learningGeneration = classificationLearningGeneration,
                  classificationSnapshotIsCurrent(revision: readRevision, generation: learningGeneration) else {
                if !classificationProfileIsRefreshing { requestClassificationRefresh() }
                return
            }
            let categoryInputs = classificationCategories
            let tagInputs = classificationTags
            let profile = classificationProfile
            let deterministic = await Task.detached(priority: .userInitiated) {
                SmartTransactionSuggestionService.suggest(
                    note: requestedNote,
                    merchant: requestedMerchant,
                    type: requestedType,
                    categories: categoryInputs,
                    tags: tagInputs,
                    profile: profile
                )
            }.value
            guard !Task.isCancelled,
                  classificationSnapshotIsCurrent(revision: readRevision, generation: learningGeneration),
                  showOnly ? isShowingManualSuggestion : suggestionSession.allowsAutomaticRun,
                  suggestionRequestTracker.accepts(
                    revision: revision,
                    note: draft.note,
                    merchant: draft.rawMerchantText,
                    type: draft.type
                  ) else { return }
            let result = await SmartClassificationCoordinator(
                provider: foundationProvider
            ).resolve(
                deterministic: deterministic,
                note: requestedNote,
                merchant: requestedMerchant,
                type: requestedType,
                categories: categoryInputs,
                settingEnabled: foundationModelEnabled,
                manualLocked: !suggestionSession.allowsAutomaticRun && !showOnly
            )
            guard !Task.isCancelled,
                  classificationSnapshotIsCurrent(revision: readRevision, generation: learningGeneration),
                  showOnly ? isShowingManualSuggestion : suggestionSession.allowsAutomaticRun,
                  suggestionRequestTracker.accepts(
                    revision: revision,
                    note: draft.note,
                    merchant: draft.rawMerchantText,
                    type: draft.type
                  ) else {
                return
            }
            suggestion = result
            guard !showOnly else {
                isShowingManualSuggestion = false
                return
            }
            let resolvedID = suggestionSession.categoryAfterSuggestion(
                result,
                currentCategoryID: draft.categoryID
            )
            if resolvedID != draft.categoryID { draft.categoryID = resolvedID }
            automaticCategoryRevision = suggestionSession.selectionState == .automatic ? revision : nil
            didAutoFillSuggestion = suggestionSession.selectionState == .automatic
            applyHighConfidenceTags(result)
        }
    }

    private func applyTimePrior() {
        guard transaction == nil else { return }
        let categoryInputs = categories.map {
            SuggestionCategory(
                id: $0.id,
                name: $0.name,
                kind: $0.kind,
                isActive: $0.archivedAt == nil && !$0.isHidden,
                parentID: $0.parentID,
                defaultDefinitionKey: $0.defaultDefinitionKey
            )
        }
        let priorID = draft.type == .expense
            ? QuickAddTimePriorService.categoryID(
                occurredAt: draft.occurredAt,
                timeZone: draftTimeZone,
                categories: categoryInputs
            )
            : nil
        let updatedID = suggestionSession.applyTimePriorCategory(
            priorID,
            currentCategoryID: draft.categoryID
        )
        if updatedID != draft.categoryID {
            draft.categoryID = updatedID
        }
    }

    private func restoreCategoryBeforeAutomaticSuggestion() {
        let restoredID = suggestionSession.categoryAfterAutomaticSuggestionUnavailable(
            currentCategoryID: draft.categoryID
        )
        automaticCategoryRevision = nil
        if restoredID != draft.categoryID {
            draft.categoryID = restoredID
        }
    }

    private func applyHighConfidenceTags(_ result: SmartTransactionSuggestion) {
        let suggestedTagIDs = result.tagConfidence == .high ? result.tagIDs : []
        let reconciled = suggestionSession.reconcileAutomaticTags(
            suggestedTagIDs,
            currentTagIDs: draft.tagIDs
        )
        if reconciled != draft.tagIDs {
            draft.tagIDs = reconciled
            if !suggestedTagIDs.isEmpty {
                didAutoFillSuggestion = true
            }
        }
    }

    private func removeAutomaticTags() {
        draft.tagIDs = suggestionSession.clearAutomaticTags(currentTagIDs: draft.tagIDs)
    }

    private var isSuggestionCurrent: Bool {
        guard let revision = classificationReadRevision, let generation = classificationLearningGeneration else { return false }
        return classificationSnapshotIsCurrent(revision: revision, generation: generation)
    }

    private func classificationSnapshotIsCurrent(
        revision: UInt64, generation: ClassificationLearningGeneration
    ) -> Bool {
        guard (try? LedgerSaveRevision.shared.readContentStamp()) == revision else { return false }
        return classificationHistoryStatus != .ready || ClassificationProfileStore.shared.generation == generation
    }

    private var suggestionCandidates: [SmartClassificationAlternative] {
        if !suggestion.alternatives.isEmpty { return suggestion.alternatives }
        guard let id = suggestion.categoryID else { return [] }
        return [.init(categoryID: id, score: suggestion.score, explanation: suggestion.explanation)]
    }

    private func undoAutomaticSuggestion() {
        suggestionTask?.cancel()
        suggestionRequestTracker.invalidate()
        draft.categoryID = suggestionSession.undoAutomaticSuggestion(currentCategoryID: draft.categoryID)
        removeAutomaticTags()
        didAutoFillSuggestion = false
        isShowingManualSuggestion = false
        suggestion = .none
    }

    private func acceptSuggestion(categoryID proposedID: UUID? = nil) {
        guard isSuggestionCurrent else { requestClassificationRefresh(); return }
        let selectedID = proposedID ?? suggestion.categoryID
        if let categoryID = selectedID {
            guard let category = hierarchy.category(id: categoryID), hierarchy.isEligibleForSelection(category) else { return }
            draft.categoryID = categoryID
            suggestionSession.markManualCategorySelection(selectedCategoryID: categoryID)
        }
        let tagIDs = selectedID == suggestion.categoryID ? suggestionSession.eligibleAutomaticTags(suggestion.tagIDs) : []
        draft.tagIDs.formUnion(tagIDs)
        suggestionSession.adoptSuggestedTagsAsManual(tagIDs)
        suggestionTask?.cancel()
        suggestionRequestTracker.invalidate()
        isShowingManualSuggestion = false
        didAutoFillSuggestion = false
        suggestion = .none
    }

    private func classificationLearningEvent(
        for transaction: FinanceTransaction
    ) -> ClassificationLearningEvent? {
        guard let categoryID = transaction.categoryID else { return nil }
        if let baseline = draft.editBaseline,
           baseline.categoryID == categoryID, baseline.typeRawValue == transaction.typeRawValue {
            return nil
        }
        let rejectedSuggestion = suggestionSession.rejectedAutomaticCategoryID
            ?? suggestion.categoryID.flatMap { $0 == categoryID ? nil : $0 }
        let source: ClassificationLearningSource
        switch suggestionSession.categoryDecisionSource {
        case .manualConfirmed:
            source = rejectedSuggestion == nil ? .manualChoice : .explicitCorrection
        case .automaticAccepted:
            source = .automaticAccepted
        case .unchanged, .timePrior:
            return nil
        }
        return ClassificationLearningEvent(
            transactionID: transaction.id,
            recordedAt: Date(),
            type: transaction.type,
            note: transaction.note,
            merchant: transaction.rawMerchantText,
            categoryID: categoryID,
            rejectedCategoryID: rejectedSuggestion,
            source: source
        )
    }
}

@MainActor
private enum ClassificationValidatedProfileCache {
    struct Entry {
        let containerID: ObjectIdentifier
        let restoreGeneration: UUID
        let revision: UInt64
        let learningGeneration: ClassificationLearningGeneration
        let historyCutoff: Double
        let oldestHistoryDate: Date?
        let profile: ClassificationProfile
        let categories: [SuggestionCategory]
        let tags: [SuggestionTag]
    }

    static var entry: Entry?
}

private struct CalculatorButtonStyle: ButtonStyle {
    var isEmphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .frame(maxWidth: .infinity, minHeight: QuickAddLayoutMetrics.calculatorKeyMinimumHeight)
            .foregroundStyle(isEmphasized ? PFColor.accent : PFColor.primaryText)
            .background(
                configuration.isPressed
                ? PFColor.accent.opacity(0.14)
                : PFColor.elevatedSurface,
                in: RoundedRectangle(cornerRadius: PFRadius.small, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
