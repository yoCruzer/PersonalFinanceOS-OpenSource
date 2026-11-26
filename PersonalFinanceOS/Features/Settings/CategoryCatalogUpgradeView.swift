import SwiftData
import SwiftUI

struct CategoryCatalogUpgradeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ICloudSyncController.self) private var sync
    @Environment(LedgerChangeCenter.self) private var changes
    @Environment(CategoryCompletionState.self) private var completion

    var body: some View {
        List {
            Section {
                Text(completion.description(sync: sync))
                Text("缺少的分类会在数据就绪后自动补充。已有分类设置与历史记录均保留；您可在分类管理中调整新分类。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let value = completion.completion {
                    LabeledContent("已可用", value: "\(value.available) 项目录用途")
                    LabeledContent("已存在（含保留设置）", value: "\(value.installed) 项目录用途")
                    LabeledContent("待补充", value: "\(value.waiting) 项")
                    LabeledContent("保留设置", value: "\(value.skipped) 项")
                    if value.added > 0 { Text("本次新增 \(value.added) 项") }
                }
                if let review = sync.categoryReview {
                    NavigationLink("处理 \(review.conflicts.count) 项分类差异") {
                        FirstJoinCategoryReviewView(review: review)
                    }
                }
                Button("检查并重试") {
                    Task {
                        await sync.reconcile(in: modelContext, changes: changes)
                        await completion.refresh(in: modelContext, sync: sync, changes: changes)
                    }
                }.disabled(completion.isRunning)
            }
        }
        .navigationTitle("分类补充状态")
    }
}
