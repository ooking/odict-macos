import SwiftUI

/// The same native menu is used in the main header and capture footer.
struct TranslationMethodPicker: View {
    @ObservedObject var model: LookupModel
    var beforeSelection: () -> Void = {}
    var compact = false

    var body: some View {
        Menu {
            Picker("翻译方式", selection: Binding(
                get: { model.selectedMethod },
                set: { method in
                    beforeSelection()
                    model.selectMethod(method)
                }
            )) {
                options(model.methodOptions.filter { !$0.isMDX && !$0.isAI })
                if model.methodOptions.contains(where: \.isMDX) {
                    Section(header: Text("MDX 词典")) {
                        options(model.methodOptions.filter(\.isMDX))
                    }
                }
                if model.methodOptions.contains(where: \.isAI) {
                    Section(header: Text("AI 翻译")) {
                        options(model.methodOptions.filter(\.isAI))
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.swap")
                Text(model.methodTitle).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: compact ? 11 : 13, weight: .medium))
            .frame(maxWidth: compact ? 145 : 260, alignment: .leading)
            .frame(height: 28)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help("选择翻译方式：" + model.methodTitle)
        .accessibilityLabel("翻译方式")
        .accessibilityValue(model.methodTitle)
    }

    private func options(_ values: [TranslationMethodOption]) -> some View {
        ForEach(values) { option in
            Text(option.title + (option.unavailableReason.map { "（\($0)）" } ?? ""))
                .tag(option.method)
                .disabled(option.unavailableReason != nil)
        }
    }
}
