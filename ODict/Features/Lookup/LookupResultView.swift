import SwiftUI
import AppKit

// Shared ink remains readable on glass and reduced-transparency surfaces.
let lookupSecondaryInk = Color(nsColor: .labelColor).opacity(0.72)

struct LookupResultView: View {
    @ObservedObject var model: LookupModel
    let openSettings: () -> Void
    let openAISettings: () -> Void
    var isCapture = false
    @StateObject private var localRenderer = LocalArticleRenderer()
    @State private var confirmClearHistory = false

    var body: some View {
        Group {
            if !model.contentVisible {
                EmptyView()
            } else if (model.mode == .ai || model.isUsingAIForCurrentQuery) && model.captureStatus == nil {
                AIResultView(model: model.ai, query: model.query, openSettings: openAISettings,
                    isPresentation: isCapture,
                    restoredInput: model.restoreAIInput, showsSourceBeforeAnswer: model.isUsingAIForCurrentQuery)
            } else if let article = model.localArticle, model.contentVisible {
                VStack(alignment: .leading, spacing: 0) {
                    LocalArticleView(article: article, renderer: localRenderer, lookup: { model.lookup($0) })
                    if let notice = model.message {
                        Text(notice).font(AppTypography.secondary).foregroundColor(.secondary).padding(12)
                    }
                }
            } else {
                detailPane
            }
        }
        .onChange(of: model.contentVisible) { visible in
            if !visible { localRenderer.release() }
        }
        .onChange(of: model.mode) { _ in localRenderer.release() }
        .onChange(of: model.isUsingAIForCurrentQuery) { active in
            if active { localRenderer.release() }
        }
        .onChange(of: model.entry != nil) { online in
            if online { localRenderer.release() }
        }
        .onDisappear { localRenderer.release() }
        .confirmationDialog("清除所有词典查询历史？", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("清除历史记录", role: .destructive) { model.clearHistory() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("清除后无法恢复。")
        }
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let status = model.captureStatus {
                    LookupNotice(title: model.captureIsBusy ? "正在取词" : "本次取词未完成",
                        message: status, icon: "text.viewfinder", isBusy: model.captureIsBusy,
                        footnote: model.captureIsBusy ? nil : "关闭窗口后，可重新使用取词快捷键。") { EmptyView() }
                } else if let entry = model.entry {
                    entryContent(entry)
                    if let source = model.source {
                        Text("来源：" + source).font(AppTypography.caption).foregroundColor(lookupSecondaryInk)
                    }
                } else if model.isLoading || model.isSuggesting {
                    LookupNotice(title: model.isSuggesting ? "正在查找候选词" : "正在载入释义",
                        message: "请稍候…", isBusy: true) { EmptyView() }
                } else if model.query.isEmpty {
                    if model.recent.isEmpty { emptyState } else { recentList }
                }
                if model.offersAITranslation {
                    aiTranslationOffer
                } else if let message = model.message {
                    if model.result != nil {
                        Text(message).font(AppTypography.secondary).foregroundColor(lookupSecondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        LookupNotice(title: "暂时无法完成查询", message: message,
                            source: model.query.isEmpty ? nil : model.query,
                            footnote: isCapture ? "关闭窗口后，可重新使用取词快捷键。" : "可以修改输入后再次查询。") {
                            Button("打开设置", action: openSettings).buttonStyle(LookupActionStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, showingHistory ? 12 : 22)
            .padding(.vertical, showingHistory ? 16 : 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // New entry starts at its heading instead of inheriting a long previous word's scroll position.
        .id(model.entry?.word ?? "pending")
    }

    private var aiTranslationOffer: some View {
        LookupNotice(title: model.sentenceDetected ? "用 AI 翻译这段内容？" : "词典暂未找到释义",
            message: model.query.count > AIConfiguration.maximumInput
                ? (model.message ?? "请缩短内容后再查询。")
                : model.sentenceDetected ? "这段内容可能是句子，词典更适合查询单词和短语。"
                : "词典中没有找到对应释义，可以尝试用 AI 翻译。",
            icon: "sparkles", source: model.query,
            footnote: model.query.count > AIConfiguration.maximumInput ? nil : model.ai.isConfigured
                ? "原文将发送至已配置的 AI 服务，仅本次使用 AI。"
                : "在「设置 → AI」配置服务后，再确认翻译。") {
            if model.query.trimmingCharacters(in: .whitespacesAndNewlines).count <= AIConfiguration.maximumInput {
                if model.ai.isConfigured {
                    Button(action: model.useAIForCurrentQuery) {
                        Label("仅本次用 AI 翻译", systemImage: "sparkles")
                    }.buttonStyle(LookupActionStyle(prominent: true))
                } else {
                    Button(action: openAISettings) {
                        Label("配置 AI 服务", systemImage: "slider.horizontal.3")
                    }.buttonStyle(LookupActionStyle(prominent: true))
                }
            }
        }
    }

    private var emptyState: some View {
        LookupEmptyState(subtitle: "输入英文查释义，输入中文找单词", openSettings: openSettings)
    }

    private var showingHistory: Bool {
        model.query.isEmpty && !model.recent.isEmpty && model.entry == nil
            && model.captureStatus == nil && !model.isLoading && !model.isSuggesting
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecentLookupHeader(clearDisabled: model.recent.isEmpty) { confirmClearHistory = true }
                .padding(.horizontal, 10)
            VStack(spacing: 4) {
                ForEach(model.recent, id: \.self) { word in
                    RecentWordRow(word: word, translation: model.recentTranslations[word]) { model.lookup(word) }
                }
            }
        }
    }

    private func entryContent(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                ReadingText(entry.word, bold: true, fixedSize: 30).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let phonetic = entry.phonetic, !phonetic.isEmpty {
                    ReadingText(phonetic, fixedSize: 14).foregroundColor(lookupSecondaryInk).textSelection(.enabled)
                }
            }
            if let translation = entry.translation, !translation.isEmpty { definition("中文释义", translation) }
            if let text = entry.definition, !text.isEmpty {
                Divider()
                definition("英文释义", text)
            }
            if !entry.inflections.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(entry.inflections.enumerated()), id: \.offset) { _, form in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(form.typeName).font(AppTypography.caption).foregroundColor(lookupSecondaryInk)
                            Button { model.lookup(form.form) } label: { ReadingText(form.form, fixedSize: 13) }.buttonStyle(.link)
                                .font(AppTypography.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !entry.tags.isEmpty {
                Text(entry.tags.map { $0.name ?? $0.code }.joined(separator: " · "))
                    .font(AppTypography.caption).foregroundColor(lookupSecondaryInk)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(lookupSecondaryInk)
    }

    private func definition(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(title)
            ReadingText(text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RecentWordRow: View {
    let word: String
    let translation: String?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    private var hasSummary: Bool { translation?.isEmpty == false }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                // The history panel is 440pt wide. Keep a stable word column and
                // give the longer definitions the remaining space.
                ReadingText(word, bold: true, fixedSize: 14)
                    .foregroundColor(.primary)
                    .frame(width: 132, alignment: .leading)
                ReadingText(translation ?? "", fixedSize: 13)
                    .foregroundColor(lookupSecondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                if !hasSummary {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(lookupSecondaryInk)
                        .opacity(hovered ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(hovered ? Color.accentColor.opacity(0.10) : Color.clear)
            .cornerRadius(7)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .help([word, translation].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}


/// Shared history controls; each mode keeps its existing record layout.
struct RecentLookupHeader: View {
    var isSaving = false
    var clearDisabled = false
    let clear: () -> Void

    var body: some View {
        HStack {
            Text("最近查过")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            if isSaving {
                ProgressView().controlSize(.small).help("正在保存历史记录")
            }
            Button(action: clear) {
                HistoryBroomIcon()
                    .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 18, height: 18)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(clearDisabled)
            .help("清除历史记录")
            .accessibilityLabel("清除历史记录")
        }
        .foregroundColor(lookupSecondaryInk)
    }
}

private struct HistoryBroomIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scale = min(rect.width, rect.height) / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        path.move(to: point(15, 2))
        path.addLine(to: point(9, 8))
        path.move(to: point(7, 7))
        path.addLine(to: point(11, 11))
        path.addLine(to: point(8, 16))
        path.addQuadCurve(to: point(2, 10), control: point(3, 16))
        path.closeSubpath()
        path.move(to: point(7, 10))
        path.addLine(to: point(4, 13))
        path.move(to: point(9, 12))
        path.addLine(to: point(6, 15))
        return path
    }
}

struct LookupEmptyState: View {
    let subtitle: String
    let openSettings: () -> Void

    var body: some View {
        LookupNotice(title: "随手一查，继续阅读", message: subtitle, icon: "book.closed") {
            Button("快捷键与设置", action: openSettings).buttonStyle(LookupActionStyle())
        }.padding(.vertical, 14)
    }
}
