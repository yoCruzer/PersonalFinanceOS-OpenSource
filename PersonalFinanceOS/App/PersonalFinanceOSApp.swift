import SwiftData
import SwiftUI

@main
@MainActor
struct PersonalFinanceOSApp: App {
    private let container: ModelContainer?
    private let persistenceError: String?
    @State private var iCloudSync = ICloudSyncController()
    @State private var ledgerChangeCenter = LedgerChangeCenter()

    init() {
        do {
#if DEBUG
            if Build21SyntheticFixture.isEnabled {
                let synthetic = try ModelContainerFactory.make(isStoredInMemoryOnly: true)
                try Build21SyntheticFixture.seed(in: ModelContext(synthetic))
                container = synthetic
            } else {
                container = try ModelContainerFactory.make()
            }
#else
            container = try ModelContainerFactory.make()
#endif
            persistenceError = nil
        } catch {
            container = nil
            persistenceError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            AppearanceRootView(content:
                Group {
                    if let container {
                        AppShellView()
                            .modelContainer(container)
                    } else {
                        PFErrorState(
                            title: "无法打开本地数据",
                            message: persistenceError ?? "请重新启动 App。"
                        )
                        .background(PFColor.background)
                    }
                }
            )
#if DEBUG
            .modifier(DiagnosticSideEffectsFixture())
#endif
            .environment(\.locale, AppDateFormatter.interfaceLocale)
            .environment(iCloudSync)
            .environment(ledgerChangeCenter)
        }
    }
}
