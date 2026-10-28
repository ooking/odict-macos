import SwiftUI
import AppKit

struct AIResultView: View {
    @ObservedObject var model: AIQueryModel
    let query: String
    let openSettings: () -> Void
    var isPresentation = false
    var restoredInput: (String) -> Void = { _ in }
    var showsSourceBeforeAnswer = false
    var showsSource = true
    var scrollsContent = true
    @State private var copied = false
    var body: some View {
        Group {
            if scrollsContent {
                ScrollView { content }
            } else {
                content
            }
        }
        .onAppear { if !isPresentation { model.history.load() } }
        .onChange(of: model.isLoading) { loading in if loading { copied = false } }
        .onChange(of: model.isRestoringHistory) { restoring in if restoring { copied = false } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsSourceBeforeAnswer {
                Label("本次使用 AI", systemImage: "sparkles")
                    .font(AppTypography.caption).foregroundColor(.secondary)
            }
            if showsSource, model.answer == nil, !query.isEmpty, isPresentation || showsSourceBeforeAnswer {
                LookupSourceText(text: query)
                Divider()
            }
            if model.answer != nil || model.hasSubmitted {
                AIHistorySaveStatus(history: model.history)
            }
            if !isPresentation, model.answer != nil || model.hasSubmitted {
                AIHistoryMenu(history: model.history) { id in
                    model.restoreHistory(id, restoredInput: restoredInput)
                }
                .disabled(model.isLoading || model.isRestoringHistory)
            }

            if model.isLoading {
                HStack(spacing: 8) {
                    Text(model.isThinking ? "正在思考…" : model.hasStreamContent ? "正在生成…" : "正在等待回答…")
                        .font(AppTypography.secondary).foregroundColor(.secondary)
                    Spacer()
                    if isPresentation {
                        Button { model.cancel() } label: { Image(systemName: "stop.fill") }
                            .buttonStyle(.borderless).help("停止生成，保留已有内容").accessibilityLabel("停止生成")
                    }
                }
                if !model.hasStreamContent {
                    AIAnswerSkeletonView()
                }
            } else if model.isCancelled {
                LookupNotice(title: model.isViewingHistory ? "未完成的历史回答" : "已停止生成",
                    message: model.answer == nil ? "尚未生成回答，可以使用当前原文重新生成。" : "已保留生成的内容，可继续阅读或重新生成。",
                    icon: "stop.circle") {
                    if model.answer == nil {
                        Button("重新生成") { regenerate(model.submittedText) }
                            .buttonStyle(LookupActionStyle(prominent: true))
                    }
                }
            }
            if let answer = model.answer, !model.isLoading || model.hasStreamContent {
                if let date = model.historyDate {
                    Text("历史记录 · \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(AppTypography.caption).foregroundColor(.secondary)
                }
                if !showsSource, model.isEditingInput,
                   query.trimmingCharacters(in: .whitespacesAndNewlines) != model.sourceText {
                    Text("上次结果 · 修改原文后请重新查询")
                        .font(AppTypography.caption).foregroundColor(.secondary)
                } else if model.isShowingPreviousAnswer {
                    Text(model.isLoading ? "上次结果 · 正在生成新的回答" : "上次结果").font(AppTypography.caption).foregroundColor(.secondary)
                }
                if showsSource {
                    LookupSourceText(text: model.sourceText)
                    Divider()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("译文 / 释义").font(AppTypography.caption).foregroundColor(.secondary)
                    AIMarkdownView(markdown: answer.markdown)
                }
                if !model.isLoading {
                    HStack(spacing: 12) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(answer.markdown, forType: .string)
                            copied = true
                        } label: { Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        Button { regenerate(model.sourceText) } label: { Label("重新生成", systemImage: "arrow.clockwise") }
                    }.buttonStyle(LookupActionStyle())
                }
                if !model.isLoading {
                    Text("AI 生成 · \(model.answerModel)")
                        .font(AppTypography.caption).foregroundColor(.secondary)
                }
            } else if !model.hasSubmitted && model.message == nil && !model.isLoading {
                if !isPresentation {
                    AIHistoryView(history: model.history, select: { id in
                        model.restoreHistory(id, restoredInput: restoredInput)
                    }, emptySettings: openSettings)
                } else if !model.isConfigured {
                    LookupNotice(title: "配置 AI 后开始查询", message: "填写服务地址、模型和密钥，即可翻译句子或解释词语。",
                        icon: "sparkles") {
                        Button("配置 AI 服务", action: openSettings)
                            .buttonStyle(LookupActionStyle(prominent: true))
                    }
                } else {
                    Text("选中或截图取词后，原文与结果会显示在这里。")
                        .font(AppTypography.secondary).foregroundColor(.secondary)
                }
            }

            if let message = model.message {
                LookupNotice(title: "AI 暂时无法完成请求", message: message,
                    icon: "exclamationmark.circle") {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.isConfigured {
                            Button("重新生成") { regenerate(model.hasSubmitted ? model.submittedText : query) }
                                .buttonStyle(LookupActionStyle(prominent: true))
                        }
                        Button("AI 设置", action: openSettings)
                            .buttonStyle(LookupActionStyle(prominent: !model.isConfigured))
                    }
                }
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func regenerate(_ source: String) {
        if !showsSource { restoredInput(source) }
        model.submit(source)
    }
}

/// Static, bounded placeholders avoid animation timers and disappear at the first
/// streamed text. Native colors also respect dark mode and increased contrast.
private struct AIAnswerSkeletonView: View {
    private let paragraphWidths: [[CGFloat]] = [
        [1, 0.94, 0.68], [1, 0.86, 0.54], [0.96, 0.72]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("译文 / 释义").font(AppTypography.caption).foregroundColor(.secondary)
            ForEach(paragraphWidths.indices, id: \.self) { paragraph in
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(paragraphWidths[paragraph].indices, id: \.self) { line in
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: geometry.size.width * paragraphWidths[paragraph][line])
                        }.frame(height: 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在生成译文，回答将在此处显示")
    }
}
