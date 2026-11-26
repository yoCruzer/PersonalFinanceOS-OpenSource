import SwiftUI
import UIKit

struct LocalDiagnosticsView: View {
    @Environment(ICloudSyncController.self) private var sync
    @Environment(CategoryCompletionState.self) private var catalog
    @State private var report: LocalDiagnostics.Report?
    @State private var status: String?
    @State private var share: DiagnosticShareItem?
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: PFSpacing.small) {
            Button { Task { await export() } } label: {
                Label("导出脱敏诊断", systemImage: "square.and.arrow.up").frame(minHeight: 44).contentShape(Rectangle())
            }
                .disabled(isExporting)
                .accessibilityIdentifier("export-redacted-diagnostics")
            if let report {
                LabeledContent("应用", value: report.appVersion + " (" + report.build + ")")
                LabeledContent("Git", value: report.gitCommit == "unavailable" ? "此构建未提供" : String(report.gitCommit.prefix(12)) + (report.gitDirty == true ? " · dirty" : ""))
                LabeledContent("本次会话", value: "\(report.entries.count) / \(report.entryLimit) 条")
            }
            Text("复现后、重启前导出。只含版本、状态、错误码、计数及会话指纹，不含账本内容；不会自动上传。")
                .font(.caption).foregroundStyle(PFColor.secondaryText)
            Button { copySummary() } label: { Text("复制简短摘要").frame(minHeight: 44).contentShape(Rectangle()) }
                .accessibilityIdentifier("copy-redacted-diagnostics")
            if let status { Text(status).font(.caption).accessibilityIdentifier("diagnostic-export-status") }
        }
        // In a Form, automatic buttons in the same row otherwise share its tap action.
        .buttonStyle(.borderless)
        .sheet(item: $share) { item in
            DiagnosticShareSheet(url: item.url) { completed, failed in
                status = failed ? "分享未完成，文件已保留，可重试。" : completed ? "诊断已分享。" : "已取消分享，诊断文件仍保留。"
            }
        }
        .onAppear { report = makeReport() }
    }

    @MainActor
    private func makeReport(counters: SmartClassificationDiagnosticSnapshot? = nil) -> LocalDiagnostics.Report {
        LocalDiagnostics.shared.report(classificationCounters: counters,
            sync: sync.displaySnapshot, catalogInstallation: catalog.completion,
            catalogCheckFailed: catalog.failed, catalogCheckInProgress: catalog.isRunning)
    }

    @MainActor
    private func export() async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let counters = await SmartClassificationDiagnostics.shared.snapshot()
            let snapshot = makeReport(counters: counters)
            let url = try DiagnosticFileStore.write(snapshot)
            report = snapshot
            status = "已生成脱敏诊断文件，请选择存储或分享。"
            share = DiagnosticShareItem(url: url)
        } catch { status = "暂时无法生成诊断文件，请重试。" }
    }

    @MainActor
    private func copySummary() {
        let snapshot = makeReport()
        report = snapshot
        UIPasteboard.general.string = "PersonalFinanceOS \(snapshot.appVersion) (\(snapshot.build)) · Git \(snapshot.gitCommit) · \(snapshot.sync?.title ?? "状态未获取") · 本次会话 \(snapshot.entries.count) 条\n" + (snapshot.sync?.redactedSummary ?? "sync=unavailable")
        status = "已复制简短摘要。"
    }
}

private struct DiagnosticShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct DiagnosticShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool, Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            completion(completed, error != nil)
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
