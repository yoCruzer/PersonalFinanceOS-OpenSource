import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var modelContext
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @Environment(LedgerUsageMetricsStore.self) private var usageMetricsStore
    @Environment(ICloudSyncController.self) private var iCloudSync
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @AppStorage(SmartSuggestionPreferences.foundationModelEnabledKey) private var foundationModelEnabled =
        SmartSuggestionPreferences.defaultEnabled
    @AppStorage(SmartSuggestionPreferences.historyCutoffKey) private var suggestionHistoryCutoff = 0.0
    @State private var isClearSuggestionConfirmationPresented = false
    @State private var didClearSuggestionData = false
    @State private var learningError: String?
    @State private var foundationAvailability: FoundationClassificationAvailability = .unknown
    @State private var syncConfirmation: Bool?
    @State private var showsDiagnostics = false
    @State private var usageRetry = 0

    private var defaultAccountName: String {
        accounts.first(where: { $0.archivedAt == nil && $0.isDefault })?.name ?? "未设置"
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        List {
            Section {
                usageSummaryCard
            }
            .listRowBackground(PFColor.card)
            .listRowInsets(EdgeInsets(
                top: PFSpacing.small,
                leading: PFSpacing.xLarge,
                bottom: PFSpacing.small,
                trailing: PFSpacing.xLarge
            ))

            Section {
                NavigationLink {
                    AccountManagementView()
                } label: {
                    settingsRow(
                        title: "账户",
                        subtitle: "默认：\(defaultAccountName)",
                        symbol: "creditcard"
                    )
                }

                NavigationLink {
                    CategoryManagementView()
                } label: {
                    settingsRow(
                        title: "分类",
                        subtitle: "管理收入与支出分类",
                        symbol: "square.grid.2x2"
                    )
                }

                NavigationLink {
                    TagManagementView()
                } label: {
                    settingsRow(
                        title: "标签",
                        subtitle: "管理跨分类的灵活标记",
                        symbol: "tag"
                    )
                }
            } header: {
                Text("记账设置")
            } footer: {
                Text("停用不会影响历史交易；永久删除前会检查并迁移或处理全部关联数据。")
            }

            Section("外观") {
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    settingsRow(
                        title: "显示与字体",
                        subtitle: "跟随系统、浅色、深色与字体大小",
                        symbol: "circle.lefthalf.filled"
                    )
                }
            }

            Section("数据管理") {
                NavigationLink {
                    DataManagementView()
                } label: {
                    settingsRow(
                        title: "导入与导出",
                        subtitle: "迁入账单并随时取回 CSV",
                        symbol: "arrow.up.arrow.down"
                    )
                }
            }

            Section {
                Toggle("iCloud 同步", isOn: Binding(
                    get: { iCloudSync.isEnabled },
                    set: { syncConfirmation = $0 }
                ))
                .disabled(iCloudSync.status == .stopping)
                .accessibilityIdentifier("icloud-sync-toggle")
                DisclosureGroup {
                    let snapshot = iCloudSync.displaySnapshot
                    Text("待上传或确认 \(snapshot.pendingChanges) 项记录变化")
                    if snapshot.pendingDatabaseChanges > 0 { Text("正在准备 iCloud 空间（\(snapshot.pendingDatabaseChanges) 项）") }
                    if !snapshot.engineAvailable && iCloudSync.isEnabled { Text("连接尚未就绪，可重试恢复连接。") }
                    if let failure = snapshot.failures.first {
                        Text("当前问题：\(failure.phase) · \(failure.reasonCode ?? "\(failure.domain).\(failure.code)")")
                        if let delay = failure.retryAfter { Text("服务建议 \(delay.rounded(.up).formatted(.number.precision(.fractionLength(0)))) 秒后重试") }
                    }
                    if let date = snapshot.lastUploadAt { LabeledContent("最近上传成功", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    if let date = snapshot.lastAppliedAt { LabeledContent("最近完成本机检查", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    Text(snapshot.failures.compactMap(\.recoveryMessage).first ?? iCloudSync.status.description).font(.caption)
                    if let historical = snapshot.historicalFailures.last {
                        Text("历史问题：\(historical.phase) · \(historical.reasonCode ?? "\(historical.domain).\(historical.code)")")
                            .foregroundStyle(.secondary)
                    }
                    if let date = snapshot.completedRequestAt {
                        LabeledContent("最近一轮完成", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    Text("本轮只确认请求时的变化；之后的编辑会继续同步。本机检查包括空拉取，不表示另一设备有新增数据或已收到。")
                        .accessibilityIdentifier("icloud-sync-completion-explanation")
                    if iCloudSync.isEnabled {
                        Button(iCloudSync.isSyncRequested ? "同步请求已保留…" : "立即同步 / 重试") {
                            Task { await iCloudSync.syncNow(in: modelContext, changes: ledgerChangeCenter) }
                        }.disabled(iCloudSync.isSyncRequested && iCloudSync.requestPause != .attention)
                        .accessibilityIdentifier("icloud-sync-now")
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(iCloudSync.displaySnapshot.title)
                        if let date = iCloudSync.displaySnapshot.lastConfirmedAt {
                            Text((iCloudSync.displaySnapshot.stage == .confirmed ? "截至 " : "上次确认 ") + date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("icloud-sync-status")
                }.accessibilityIdentifier("icloud-sync-disclosure")
                if let review = iCloudSync.categoryReview {
                    NavigationLink {
                        FirstJoinCategoryReviewView(review: review)
                    } label: {
                        Label("审阅分类差异（\(review.conflicts.count)）", systemImage: "rectangle.2.swap")
                    }
                    .accessibilityIdentifier("icloud-category-review")
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text(iCloudSync.status.description)
                    .accessibilityIdentifier("icloud-sync-status")
            }

            Section("提醒") {
                NavigationLink {
                    DailyReminderSettingsView()
                } label: {
                    settingsRow(
                        title: "每日记账提醒",
                        subtitle: "默认关闭，可自定义每天提醒时间",
                        symbol: "bell"
                    )
                }
            }

            Section {
                Toggle(isOn: $foundationModelEnabled) {
                    Label("设备端模型辅助分类", systemImage: "sparkles")
                }
                .accessibilityIdentifier("smart-suggestions-toggle")

                LabeledContent("设备端模型", value: foundationAvailability.localizedDescription)
                if foundationAvailability != .available {
                    Text(foundationAvailability.recoveryDescription)
                        .font(.footnote)
                        .foregroundStyle(PFColor.secondaryText)
                }

                Button("清除历史学习记录", role: .destructive) {
                    isClearSuggestionConfirmationPresented = true
                }
                .accessibilityIdentifier("clear-smart-suggestion-data")
            } header: {
                Text("智能建议")
            } footer: {
                Text("普通分类规则不确定时，可使用设备端模型理解备注。智能分类仅在本机处理；关闭后规则和个人学习仍正常工作。")
            }

            Section {
                settingsRow(
                    title: "本机优先保存",
                    subtitle: "核心记账无需登录或网络",
                    symbol: "internaldrive"
                )
                settingsRow(
                    title: "精确金额",
                    subtitle: "人民币金额以分为单位保存",
                    symbol: "yensign.circle"
                )
                Link(destination: URL(string: "https://github.com/yoCruzer/PersonalFinanceOS-OpenSource/blob/main/README.md#privacy")!) {
                    Label("隐私说明", systemImage: "hand.raised")
                }
                .accessibilityIdentifier("privacy-policy-link")
                Link(destination: URL(string: "https://github.com/yoCruzer/PersonalFinanceOS-OpenSource/issues")!) {
                    Label("使用支持", systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("support-link")
            } header: {
                Text("数据与隐私")
            } footer: {
                Text("只有主动开启 iCloud 同步后，账本才会同步到您的私人 iCloud。请保管好设备及备份。")
            }

            Section {
                Button { showsDiagnostics.toggle() } label: {
                    HStack {
                        Text("诊断与支持")
                        Spacer()
                        Image(systemName: showsDiagnostics ? "chevron.down" : "chevron.right")
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsDiagnostics ? "已展开" : "已折叠")
                .accessibilityIdentifier("diagnostics-disclosure")
                if showsDiagnostics { LocalDiagnosticsView() }
            }

            Section("关于") {
                LabeledContent("PersonalFinanceOS", value: versionText)
                LabeledContent("数据模型", value: "PersonalFinanceOS V2")
                NavigationLink("开源许可") { OpenSourceNoticesView() }
                    .accessibilityIdentifier("open-source-notices")
            }
        }
        .contentMargins(.top, PFSpacing.xSmall, for: .scrollContent)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(ledgerChangeCenter.revision):\(usageRetry)") {
            let revision = ledgerChangeCenter.revision
            let container = modelContext.container
            await usageMetricsStore.refreshIfNeeded(revision: revision) {
                try await LedgerUsageMetricsActor(modelContainer: container).compute()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            foundationAvailability = await AppleFoundationClassificationProvider().availability()
        }
        .confirmationDialog(
            "清除历史学习记录？",
            isPresented: $isClearSuggestionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("确认清除", role: .destructive) {
                suggestionHistoryCutoff = Date().timeIntervalSince1970
                let store = ClassificationProfileStore.shared
                let generation = store.beginClear()
                Task {
                    do { didClearSuggestionData = try await store.reset(generation: generation) }
                    catch {
                        learningError = error.localizedDescription
                        await SmartClassificationDiagnostics.shared.recordLearningWriteFailure()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("历史交易、分类、标签和账户都不会改变；清除时间之前的交易不再作为建议依据。")
        }
        .alert("无法清除学习记录", isPresented: Binding(
            get: { learningError != nil }, set: { if !$0 { learningError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: { Text(learningError ?? "") }
        .alert("已清除", isPresented: $didClearSuggestionData) {
            Button("好", role: .cancel) {}
        } message: {
            Text("历史账单保持不变。之后新增或编辑的交易会重新参与本机学习。")
        }
        .alert(
            syncConfirmation == true ? "开启 iCloud 同步？" : "关闭 iCloud 同步？",
            isPresented: Binding(
                get: { syncConfirmation != nil },
                set: { if !$0 { syncConfirmation = nil } }
            )
        ) {
            if syncConfirmation == true {
                Button("开启同步") {
                    Task {
                        await iCloudSync.enable()
                        await iCloudSync.reconcile(in: modelContext, changes: ledgerChangeCenter)
                    }
                }
            } else {
                Button("关闭同步") { Task { await iCloudSync.disable() } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if syncConfirmation == true {
                Text("开启后，本机账本将通过当前 Apple 账户的私人 iCloud 同步到您的其他设备。本机现有数据不会被删除。")
            } else {
                Text("关闭后，本机数据仍会保留，之后的修改将不再与 iCloud 自动同步。iCloud 中已经同步的数据不会自动删除。")
            }
        }
    }

    private var usageSummaryCard: some View {
        VStack(alignment: .leading, spacing: PFSpacing.medium) {
            Text("账本概况")
                .font(.headline)
                .foregroundStyle(PFColor.primaryText)
            if let metrics = usageMetricsStore.metrics {
                // The clock updates only the day label, never re-queries the ledger.
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    VStack(alignment: .leading, spacing: PFSpacing.small) {
                        usageMetricRow("使用天数", value: "\(LedgerUsageMetricsPresentation.companionDayCount(createdAt: metrics.appCreatedAt, now: timeline.date).formatted(.number.locale(locale))) 天")
                        usageMetricRow("交易总笔数", value: "\(metrics.activeTransactionCount.formatted(.number.locale(locale))) 笔")
                        usageMetricRow("最早账单日", value: metrics.earliestLocalDayKey ?? "暂无记录")
                        usageMetricRow("有账天数", value: "\(metrics.distinctActiveDayCount.formatted(.number.locale(locale))) 天")
                    }
                }
            }
            if usageMetricsStore.isLoading {
                HStack(spacing: PFSpacing.small) {
                    ProgressView()
                    Text(usageMetricsStore.metrics == nil ? "正在读取账本概况…" : "正在更新账本概况…")
                        .font(.footnote)
                        .foregroundStyle(PFColor.secondaryText)
                }
            } else if usageMetricsStore.errorMessage != nil {
                VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
                    Text(usageMetricsStore.metrics == nil ? "账本概况暂时不可用" : "更新未完成，以上为上次读取结果")
                        .font(.footnote).foregroundStyle(PFColor.secondaryText)
                    Button("重试读取") { usageRetry &+= 1 }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("settings-usage-retry")
                }
            } else if usageMetricsStore.metrics == nil {
                Text("账本概况暂时不可用").foregroundStyle(PFColor.secondaryText)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-usage-summary")
    }

    private func usageMetricRow(_ title: String, value: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: PFSpacing.xSmall) {
                    Text(title).foregroundStyle(PFColor.secondaryText)
                    Text(value).fontWeight(.semibold).monospacedDigit()
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: PFSpacing.medium) {
                    Text(title).foregroundStyle(PFColor.secondaryText)
                    Spacer(minLength: PFSpacing.small)
                    Text(value).fontWeight(.semibold).monospacedDigit().multilineTextAlignment(.trailing)
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(PFColor.primaryText)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func settingsRow(title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: PFSpacing.medium) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(PFColor.accent)
                .frame(width: 34, height: 34)
                .background(PFColor.accent.opacity(0.12), in: RoundedRectangle(
                    cornerRadius: PFRadius.small,
                    style: .continuous
                ))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(PFColor.primaryText)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(PFColor.secondaryText)
            }
        }
        .padding(.vertical, PFSpacing.xSmall)
    }
}
