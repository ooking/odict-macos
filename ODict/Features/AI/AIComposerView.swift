import SwiftUI

/// Keep the clear action beside the editor so it cannot cover text or its scrollbar.
struct AIComposerView: View {
    @ObservedObject var model: AIQueryModel
    let text: String
    let focusRequest: UUID
    let allowsFocus: Bool
    let changed: (String) -> Void
    let clear: () -> Void
    let close: () -> Void
    @State private var inputHeight: CGFloat = 35
    @State private var editingFocusRequest = UUID()

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                input
                if !text.isEmpty {
                    Button(action: clear) {
                        Image(systemName: "xmark.circle.fill").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain).foregroundColor(lookupSecondaryInk)
                    .help("清空并开始新翻译").accessibilityLabel("清空输入，返回查询历史")
                    .padding(.top, 5)
                }
            }
            HStack(spacing: 8) {
                if model.isInputLocked {
                    Label(model.isLoading ? "正在翻译，原文只读" : "只读 · 点击编辑修改原文", systemImage: "lock.fill")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                } else {
                    Text("Enter 查询 · Shift + Enter 换行")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
                if text.count >= 3600 {
                    Text("\(text.count)/4000").font(.system(size: 10))
                        .foregroundColor(text.count > 4000 ? .red : .secondary)
                }
                Button {
                    if model.isLoading { model.cancel() }
                    else if model.isInputLocked {
                        model.beginEditingInput()
                        editingFocusRequest = UUID()
                    } else { model.submit(text) }
                } label: {
                    Label(model.isLoading ? "停止" : model.isInputLocked ? "编辑" : "查询",
                          systemImage: model.isLoading ? "stop.fill" : model.isInputLocked ? "pencil" : "arrow.up")
                        .font(.system(size: 11, weight: .medium))
                }.buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.isRestoringHistory || (!model.isInputLocked && (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 4000)))
                    .help(model.isLoading ? "停止生成，保留已有内容" : model.isInputLocked ? "编辑原文" : "查询（Enter）")
                    .accessibilityLabel(model.isLoading ? "停止生成" : model.isInputLocked ? "编辑原文" : "提交 AI 查询")
            }.padding(.horizontal, 4)
        }.padding(10)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.92)).cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
            .onChange(of: focusRequest) { editingFocusRequest = $0 }
    }

    private var input: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("输入原文，查看译文与释义\n支持单词、短语和句子，自动识别语言。")
                    .font(.system(size: 16)).foregroundColor(.secondary)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.top, 7).allowsHitTesting(false)
            }
            AITextInput(text: text, focusRequest: editingFocusRequest, allowsFocus: allowsFocus,
                isEditable: !model.isInputLocked, expandsToFit: model.hasSubmitted || model.isRestoringHistory,
                changed: { value in if !model.isInputLocked { changed(value) } }, rejected: model.rejectOversizedPaste,
                measuredHeight: { value in if abs(value - inputHeight) > 0.5 { inputHeight = value } },
                submit: { if !model.isInputLocked { model.submit(text) } }, cancel: close)
                .frame(height: max(inputHeight, text.isEmpty ? 64 : 35))
        }.frame(maxWidth: .infinity)
    }
}
