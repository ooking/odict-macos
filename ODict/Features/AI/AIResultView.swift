import SwiftUI
import AppKit

struct AIResultView: View {
    @ObservedObject var model: AIQueryModel
    let query: String
    let openSettings: () -> Void
    var isPresentation = false
    var captureScreenshot: (() -> Void)? = nil
    @State private var copied = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
                    Label(model.answer == nil ? "已停止生成" : "已停止，保留已有内容", systemImage: "stop.circle")
                        .font(AppTypography.secondary).foregroundColor(.secondary)
                    if model.answer == nil { Button("重新生成") { model.submit(model.submittedText) }.controlSize(.small) }
                }
                if let answer = model.answer {
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
                        Text("AI 生成 · \(model.savedConfiguration.model)")
                            .font(AppTypography.caption).foregroundColor(.secondary)
                    }
                } else if !model.hasSubmitted && model.message == nil && !model.isLoading {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.isConfigured ? "输入原文，查看译文与释义" : "配置 AI 后开始查询")
                            .font(AppTypography.secondary).foregroundColor(.secondary)
                        Text(model.isConfigured
                             ? (isPresentation ? "选中或截图取词后，原文与结果会显示在这里。" : "支持单词、短语和句子，自动识别语言。")
                             : "在设置中填写服务地址、模型和密钥。")
                            .font(AppTypography.caption).foregroundColor(.secondary)
                        if !model.isConfigured { Button("配置 AI 服务", action: openSettings).controlSize(.small).padding(.top, 4) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
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
        .onChange(of: model.isLoading) { loading in if loading { copied = false } }
    }
}
