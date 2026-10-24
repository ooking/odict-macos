import SwiftUI
import AppKit

struct AIResultView: View {
    @ObservedObject var model: AIQueryModel
    let query: String
    let openSettings: () -> Void
    var isPresentation = false
    var captureScreenshot: (() -> Void)? = nil
    var restoredInput: (String) -> Void = { _ in }
    @State private var copied = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
                        ProgressView().controlSize(.small)
                        Text(model.isThinking ? "正在思考…" : model.hasStreamContent ? "正在生成…" : "正在等待回答…")
                            .font(AppTypography.secondary).foregroundColor(.secondary)
                        Spacer()
                        if isPresentation {
                            Button { model.cancel() } label: { Image(systemName: "stop.fill") }
                                .buttonStyle(.borderless).help("停止生成，保留已有内容").accessibilityLabel("停止生成")
                        }
                    }
                } else if model.isCancelled {
                    Label(model.isViewingHistory ? "未完成的历史回答" : model.answer == nil ? "已停止生成" : "已停止，保留已有内容", systemImage: "stop.circle")
                        .font(AppTypography.secondary).foregroundColor(.secondary)
                    if model.answer == nil { Button("重新生成") { model.submit(model.submittedText) }.controlSize(.small) }
                }
                if let answer = model.answer {
                    if let date = model.historyDate {
                        Text("历史记录 · \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(AppTypography.caption).foregroundColor(.secondary)
                    }
                    if model.isShowingPreviousAnswer {
                        Text(model.isLoading ? "上次结果 · 正在生成新的回答" : "上次结果").font(AppTypography.caption).foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("原文").font(AppTypography.caption).foregroundColor(.secondary)
                        Text(model.sourceText).font(AppTypography.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
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
                            Button { model.submit(model.sourceText) } label: { Label("重新生成", systemImage: "arrow.clockwise") }
                        }.buttonStyle(.borderless).controlSize(.small)
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
                        VStack(alignment: .leading, spacing: 10) {
                            Text("配置 AI 后开始查询").font(.system(size: 18, weight: .medium))
                            Text("在设置中填写服务地址、模型和密钥。")
                                .font(AppTypography.secondary).foregroundColor(lookupSecondaryInk)
                            Button("配置 AI 服务", action: openSettings)
                                .buttonStyle(.link).font(AppTypography.caption).padding(.top, 4)
                        }.padding(.vertical, 18)
                    } else {
                        Text("选中或截图取词后，原文与结果会显示在这里。")
                            .font(AppTypography.secondary).foregroundColor(.secondary)
                    }
                }

                if let message = model.message {
                    Label(message, systemImage: "info.circle").font(AppTypography.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if model.isConfigured { Button("重试") { model.submit(model.hasSubmitted ? model.submittedText : query) } }
                        if let captureScreenshot { Button("截图取词", action: captureScreenshot) }
                        Button("AI 设置", action: openSettings)
                    }.controlSize(.small)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if !isPresentation { model.history.load() } }
        .onChange(of: model.isLoading) { loading in if loading { copied = false } }
        .onChange(of: model.isRestoringHistory) { restoring in if restoring { copied = false } }
    }

}
