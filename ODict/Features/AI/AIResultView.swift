import SwiftUI
import AppKit

struct AIResultView: View {
    @ObservedObject var model: AIQueryModel
    let query: String
    let openSettings: () -> Void
    var isPresentation = false
    @State private var explanationExpanded = false
    @State private var copied = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.isLoading {
                    HStack(alignment: .top, spacing: 12) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.isThinking ? "正在思考…" : "正在生成…").font(AppTypography.navigation)
                            Text(model.isThinking ? "思考可能需要更长时间，你可以随时取消。" : "正在解释或翻译这段内容。")
                                .font(AppTypography.secondary).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("取消") { model.cancel() }.controlSize(.small)
                    }.padding(.top, 12)
                } else if let answer = model.answer {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(answer.kind == .translation ? "译文" : "核心释义")
                            .font(AppTypography.caption).foregroundColor(.secondary)
                        Text(answer.translation).font(.system(size: 17)).lineSpacing(6)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(answer.translation, forType: .string)
                            copied = true
                        } label: { Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        Button { model.submit(query) } label: { Label("重新生成", systemImage: "arrow.clockwise") }
                    }.buttonStyle(.borderless).controlSize(.small)
                    if !answer.explanation.isEmpty {
                        Divider()
                        DisclosureGroup(answer.kind == .translation ? "句子解析" : "用法说明", isExpanded: $explanationExpanded) {
                            Text(answer.explanation).font(AppTypography.body).lineSpacing(5)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }
                    }
                    if !answer.examples.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("例句").font(AppTypography.caption).foregroundColor(.secondary)
                            ForEach(Array(answer.examples.enumerated()), id: \.offset) { _, example in
                                Text(example).lineSpacing(4).textSelection(.enabled)
                            }
                        }
                    }
                    DisclosureGroup("原文") {
                        Text(model.sourceText).font(AppTypography.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                    Text("AI 生成 · \(model.savedConfiguration.model)")
                        .font(AppTypography.caption).foregroundColor(.secondary)
                } else if model.message == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 24)).foregroundColor(.accentColor)
                        Text(model.isConfigured ? (isPresentation ? "AI 查询" : "从一个词，到一句话") : "连接你的 AI 服务")
                            .font(.system(size: 18, weight: .medium))
                        Text(model.isConfigured ? (isPresentation ? "选中或截图取词后，在这里查看解释或译文。" : "解释单词与短语，或翻译一段文字。\n回车查询，Shift + Enter 换行。") : "配置服务地址、模型和密钥后，即可开始。")
                            .font(AppTypography.secondary).foregroundColor(.secondary).lineSpacing(5)
                        if !model.isConfigured { Button("配置 AI 服务", action: openSettings) }
                    }.padding(.vertical, 14)
                }
                if let message = model.message {
                    Label(message, systemImage: "info.circle").font(AppTypography.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if model.isConfigured { Button("重试") { model.submit(query) } }
                        Button("AI 设置", action: openSettings)
                    }.controlSize(.small)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.sourceText) { _ in copied = false; explanationExpanded = false }
    }
}
