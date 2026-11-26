import SwiftData
import SwiftUI

struct AppShellView: View {
    private enum Destination: Hashable {
        case overview
        case transactions
        case insights
        case settings

        var accessibilityName: String {
            switch self {
            case .overview: "overview"
            case .transactions: "transactions"
            case .insights: "insights"
            case .settings: "settings"
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ICloudSyncController.self) private var iCloudSync
    @Environment(LedgerChangeCenter.self) private var ledgerChangeCenter
    @State private var selection: Destination = .overview
    @State private var isQuickAddPresented = false
    @State private var bootstrapError: String?
    @State private var successMessage: String?
    @State private var usageMetricsStore = LedgerUsageMetricsStore()
    @State private var categoryCompletion = CategoryCompletionState()

    var body: some View {
        TabView(selection: $selection) {
            OverviewView(
                onShowTransactions: { selection = .transactions }
            )
            .tag(Destination.overview)
            .tabItem {
                Label("概览", systemImage: "house")
            }

            TodayView()
                .tag(Destination.transactions)
                .tabItem {
                    Label("流水", systemImage: "list.bullet.rectangle")
                }

            InsightsView()
                .tag(Destination.insights)
                .tabItem {
                    Label("统计", systemImage: "chart.bar.xaxis")
                }

            NavigationStack {
                SettingsView()
            }
            .tag(Destination.settings)
            .tabItem {
                Label("设置", systemImage: "gearshape")
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .tint(PFColor.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomNavigationBar
        }
        .overlay(alignment: .bottom) {
            if let successMessage {
                Label(successMessage, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, PFSpacing.large)
                    .padding(.vertical, PFSpacing.medium)
                    .background(.black.opacity(0.78), in: Capsule())
                    .padding(.bottom, 82)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(PFColor.background)
        .environment(usageMetricsStore)
        .environment(categoryCompletion)
        .sheet(isPresented: $isQuickAddPresented) {
            TransactionFormView {
                showSuccess("已保存")
            }
            .environment(ledgerChangeCenter)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .task {
            guard !isUnitTestHost else { return }
            ledgerChangeCenter.observeSaves(in: modelContext.container)
            do {
                try DefaultFinanceDataService.ensureDefaults(in: modelContext)
                await iCloudSync.activate()
                await reconcileAndComplete()
            } catch {
                bootstrapError = error.localizedDescription
            }
        }
        .task(id: scenePhase) {
            iCloudSync.setForeground(scenePhase == .active)
            guard scenePhase == .active else { return }
            await iCloudSync.activate()
            await reconcileAndComplete()
        }
        .task(id: ledgerChangeCenter.revision) {
            await reconcileAndComplete()
        }
        .onReceive(NotificationCenter.default.publisher(for: PrivateCloudReplicaSession.didChange).receive(on: RunLoop.main)) { _ in
            iCloudSync.invalidateCurrentConfirmation()
            Task { await reconcileAndComplete() }
        }
        .onReceive(NotificationCenter.default.publisher(for: LedgerSaveRevision.contentDidChange).receive(on: RunLoop.main)) { notification in
            guard let container = notification.object as? ModelContainer, container === modelContext.container else { return }
            iCloudSync.invalidateCurrentConfirmation()
        }
        .onReceive(NotificationCenter.default.publisher(for: LedgerSaveRevision.editingDidEnd).receive(on: RunLoop.main)) { notification in
            guard let container = notification.object as? ModelContainer, container === modelContext.container else { return }
            Task { await reconcileAndComplete() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: RunLoop.main)) { _ in
            Task { await reconcileAndComplete() }
        }
        .alert(
            "无法准备本地账本",
            isPresented: Binding(
                get: { bootstrapError != nil },
                set: { if !$0 { bootstrapError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(bootstrapError ?? "")
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: selection)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: successMessage)
    }

    private var isUnitTestHost: Bool {
#if DEBUG
        NSClassFromString("XCTestCase") != nil
#else
        false
#endif
    }

    private func reconcileAndComplete() async {
        guard !isUnitTestHost else { return }
        await iCloudSync.synchronize(in: modelContext, changes: ledgerChangeCenter)
#if DEBUG
        // The isolated retry fixture leaves the initial check for the real Settings button.
        if Build21SyntheticFixture.isEnabled && ProcessInfo.processInfo.arguments.contains("-deferAutomaticCatalogCheck") { return }
#endif
        await categoryCompletion.refresh(in: modelContext, sync: iCloudSync, changes: ledgerChangeCenter)
        if let added = categoryCompletion.completion?.added, added > 0 { showSuccess("已补充 \(added) 项分类") }
    }

    private var bottomNavigationBar: some View {
        HStack(spacing: PFSpacing.xSmall) {
            navigationButton(
                .overview,
                title: "概览",
                symbol: "house",
                selectedSymbol: "house.fill"
            )
            navigationButton(
                .transactions,
                title: "流水",
                symbol: "list.bullet.rectangle",
                selectedSymbol: "list.bullet.rectangle.fill"
            )

            Button {
                isQuickAddPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(PFColor.accent, in: Circle())
                    .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("快速记账")
            .accessibilityHint("新增一笔交易")
            .accessibilityIdentifier("quick-add")

            navigationButton(
                .insights,
                title: "统计",
                symbol: "chart.bar.xaxis",
                selectedSymbol: "chart.bar.xaxis"
            )
            navigationButton(
                .settings,
                title: "设置",
                symbol: "gearshape",
                selectedSymbol: "gearshape.fill"
            )
        }
        .padding(.horizontal, PFSpacing.medium)
        .padding(.vertical, PFSpacing.xSmall)
        .overlay(alignment: .top) { Divider() }
        .background {
            Rectangle()
                .fill(.bar)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func navigationButton(
        _ destination: Destination,
        title: String,
        symbol: String,
        selectedSymbol: String
    ) -> some View {
        let isSelected = selection == destination
        return Button {
            selection = destination
        } label: {
            VStack(spacing: 2) {
                Image(systemName: isSelected ? selectedSymbol : symbol)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                Text(title)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isSelected ? PFColor.accent : PFColor.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("primary-tab-\(destination.accessibilityName)")
    }

    private func showSuccess(_ message: String) {
        successMessage = message
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if successMessage == message {
                successMessage = nil
            }
        }
    }
}
