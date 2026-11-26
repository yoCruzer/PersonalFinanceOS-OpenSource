import SwiftUI

struct MerchantEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String) -> Void
    @State private var value: String
    @FocusState private var isFocused: Bool

    init(initialValue: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: PFSpacing.large) {
                Text("商户会用于搜索和本机历史建议；开启 iCloud 同步后会随账本同步。")
                    .font(.footnote)
                    .foregroundStyle(PFColor.secondaryText)
                TextField("商户名称（可选）", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .focused($isFocused)
                    .accessibilityIdentifier("transaction-merchant")
                    .onSubmit(save)
                Spacer()
            }
            .padding(PFSpacing.xLarge)
            .background(PFColor.background)
            .navigationTitle("商户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: save)
                        .fontWeight(.semibold)
                }
            }
            .task { isFocused = true }
        }
    }

    private func save() {
        onSave(value.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}
