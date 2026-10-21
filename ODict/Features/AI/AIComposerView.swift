import SwiftUI

struct AIComposerView: View {
    @ObservedObject var model: AIQueryModel
    let text: String
    let focusRequest: UUID
    let allowsFocus: Bool
    let changed: (String) -> Void
    let close: () -> Void
    private var inputHeight: CGFloat {
        let lines = max(text.components(separatedBy: "\n").count, (text.count / 48) + 1)
        return CGFloat(min(4, max(2, lines))) * 23 + 12
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("输入单词、短语或句子…").font(.system(size: 16)).foregroundColor(.secondary)
                        .padding(.horizontal, 8).padding(.top, 7).allowsHitTesting(false)
                }
                AITextInput(text: text, focusRequest: focusRequest, allowsFocus: allowsFocus,
                            changed: changed, rejected: model.rejectOversizedPaste, submit: { model.submit(text) }, cancel: close)
                    .frame(height: inputHeight)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text("\(text.count)/4000").font(.system(size: 10)).foregroundColor(text.count > 4000 ? .red : .secondary)
                Button { model.submit(text) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 22, height: 22)
                }.buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 4000 || model.isLoading)
                    .help("查询（Enter）；Shift + Enter 换行").accessibilityLabel("提交 AI 查询")
            }.controlSize(.small)
        }.padding(10)
            .background(Color.primary.opacity(0.04)).cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
    }
}
