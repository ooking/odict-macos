import SwiftUI
import AppKit

enum LookupWindowLayout {
    static let defaultSize = NSSize(width: 480, height: 440)
    static let minimumSize = NSSize(width: 440, height: 360)
}

enum LookupPresentationMode {
    case manual
    case capture
}

/// Shared presentation state; the window controller owns behavior and lifetime.
@MainActor
final class LookupPresentation: ObservableObject {
    @Published var mode: LookupPresentationMode = .manual
    @Published var isPinned = false
}

// Keep supporting text readable over both native glass and reduced-transparency surfaces.
private let secondaryInk = Color(nsColor: .labelColor).opacity(0.72)

struct LookupView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @ObservedObject var model: LookupModel
    let openSettings: () -> Void
    let close: () -> Void
    var captureSelection: () -> Void = {}
    var captureScreenshot: () -> Void = {}
    var editQuery: () -> Void = {}
    var openAISettings: () -> Void = {}
    @ObservedObject var presentation = LookupPresentation()
    var togglePin: () -> Void = {}
    var dragWindow: (NSEvent) -> Void = { _ in }
    @State private var searchFocused = false
    @StateObject private var localRenderer = LocalArticleRenderer()

    var body: some View {
        VStack(spacing: 0) {
            if presentation.mode == .manual {
                header
                Divider()
            }
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 0) {
                    if presentation.mode == .manual && model.hasMultipleSuggestions {
                        candidateSidebar.frame(width: min(220, geometry.size.width * 0.36))
                        Divider()
                    }
                    if model.mode == .ai && model.captureStatus == nil {
                        AIResultView(model: model.ai, query: model.query, openSettings: openAISettings, isPresentation: presentation.mode == .capture)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let article = model.localArticle, model.contentVisible {
                        VStack(alignment: .leading, spacing: 0) {
                            LocalArticleView(article: article, renderer: localRenderer, lookup: { model.lookup($0) })
                            if let notice = model.message {
                                Text(notice).font(AppTypography.secondary).foregroundColor(.secondary).padding(12)
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        detailPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(presentation.mode == .capture ? Color.white : Color.clear)
        .environment(\.colorScheme, presentation.mode == .capture ? .light : systemColorScheme)
        .font(AppTypography.body)
        .frame(minWidth: LookupWindowLayout.minimumSize.width, maxWidth: .infinity,
               minHeight: LookupWindowLayout.minimumSize.height, maxHeight: .infinity)
        .onChange(of: model.contentVisible) { visible in
            if !visible { localRenderer.release() }
        }
        .onChange(of: model.mode) { _ in localRenderer.release() }
        .onChange(of: model.entry != nil) { online in
            if online { localRenderer.release() }
        }
        .onDisappear { localRenderer.release() }
        .onExitCommand(perform: close)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                LookupModePicker(selection: Binding(get: { model.mode }, set: { editQuery(); model.setMode($0) }))
                    .frame(width: 136, height: 28)
                Spacer().allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
            .background { LookupDragArea(drag: dragWindow) }
            if model.mode == .ai {
                AIComposerView(model: model.ai, text: model.query, focusRequest: model.focusRequest,
                    allowsFocus: model.acceptsSearchFocus, changed: { text in
                        editQuery(); model.editQuery(text, composing: false)
                    }, close: close)
            } else { searchBar }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var pinButton: some View {
        Button(action: togglePin) {
            Image(systemName: presentation.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 14)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(presentation.isPinned ? .accentColor : secondaryInk)
        .help(presentation.isPinned ? "取消固定，点击外部可关闭" : "固定窗口，切换应用时保留")
        .accessibilityLabel(presentation.isPinned ? "取消固定窗口" : "固定窗口")
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundColor(secondaryInk)
            CandidateSearchField(text: model.query, changed: { text, composing in
                editQuery()
                model.editQuery(text, composing: composing)
            }, focused: $searchFocused, focusRequest: model.focusRequest, allowsFocus: model.acceptsSearchFocus,
                move: { model.moveSuggestion(by: $0) }, submit: { editQuery(); model.submit() }, cancel: close)
                .frame(height: 24)
            if model.isLoading || model.isSuggesting {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(model.isSuggesting ? "正在查找候选词" : "正在载入释义")
            }
            if !model.query.isEmpty {
                Button {
                    editQuery(); model.editQuery("", composing: false); model.focusRequest = UUID()
                } label: {
                    Image(systemName: "xmark.circle.fill").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).foregroundColor(secondaryInk)
                .help("清空").accessibilityLabel("清空输入")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(0.05)).cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
            searchFocused ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1
        ))
    }

    private var candidateSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("候选词").font(AppTypography.caption).foregroundColor(secondaryInk)
                .padding(.horizontal, 16).padding(.top, 16)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(model.suggestions) { item in
                            CandidateRow(item: item, selected: model.selectedSuggestion?.word == item.word) {
                                model.selectSuggestion(item.word)
                            }.id(item.word)
                        }
                    }.padding(.horizontal, 8).padding(.bottom, 12)
                }
                .onChange(of: model.selectedSuggestionIndex) { _ in
                    if let word = model.selectedSuggestion?.word { proxy.scrollTo(word) }
                }
            }
        }.background(Color.primary.opacity(0.025))
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let status = model.captureStatus {
                    HStack(alignment: .top, spacing: 10) {
                        if model.captureIsBusy { ProgressView().controlSize(.small) }
                        Text(status).font(AppTypography.secondary).foregroundColor(secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.captureIsBusy {
                        HStack(spacing: 12) {
                            Button("截图取词", action: captureScreenshot)
                            Button("打开设置", action: openSettings)
                        }.controlSize(.small)
                    }
                } else if let entry = model.entry {
                    entryContent(entry)
                    if let source = model.source {
                        Text("来源：" + source).font(AppTypography.caption).foregroundColor(secondaryInk)
                    }
                } else if model.isLoading || model.isSuggesting {
                    Text(model.isSuggesting ? "正在查找候选词…" : "正在载入释义…")
                        .font(AppTypography.secondary).foregroundColor(secondaryInk).padding(.top, 12)
                } else if model.query.isEmpty {
                    if model.recent.isEmpty { emptyState } else { recentList }
                }
                if let message = model.message {
                    Label {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "info.circle") }
                    .font(AppTypography.secondary).foregroundColor(secondaryInk)
                    HStack(spacing: 12) {
                        Button("重试") { model.submit() }
                        if presentation.mode == .manual, model.mode == .dictionary, model.query.count > 255 {
                            Button("用 AI 翻译") { model.useAIForCurrentQuery() }
                        }
                        Button("打开设置", action: openSettings)
                    }.controlSize(.small)
                }
            }
            .padding(.horizontal, showingHistory ? 12 : 22)
            .padding(.vertical, showingHistory ? 16 : 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // New entry starts at its heading instead of inheriting a long previous word's scroll position.
        .id(model.entry?.word ?? "pending")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed.fill").font(.system(size: 14)).foregroundColor(.accentColor)
                .allowsHitTesting(false)
            Text("ODict").font(.system(size: 12, weight: .semibold)).allowsHitTesting(false)
            Spacer().allowsHitTesting(false)
            captureButton("选中取词", icon: "text.cursor", action: captureSelection)
            captureButton("截图取词", icon: "viewfinder", action: captureScreenshot)
            Button(action: model.mode == .ai ? openAISettings : openSettings) {
                Image(systemName: "gearshape").font(.system(size: 14))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundColor(secondaryInk)
            .help("设置（⌘,）").accessibilityLabel("设置").keyboardShortcut(",", modifiers: .command)
            pinButton
            if presentation.mode == .capture {
                captureButton("关闭（Esc）", icon: "xmark", action: close)
            } else {
                Menu {
                    Button("清空查词记录") { model.clearHistory() }.disabled(model.recent.isEmpty)
                    Divider()
                    Button("退出 ODict") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 14)).frame(width: 22, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundColor(secondaryInk).help("更多").accessibilityLabel("更多操作")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 5)
        .background { LookupDragArea(drag: dragWindow) }
    }

    private func captureButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundColor(secondaryInk)
        .help(title).accessibilityLabel(title)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("随手一查，继续阅读").font(.system(size: 18, weight: .medium))
            Text("输入英文查释义，输入中文找单词")
                .font(AppTypography.secondary).foregroundColor(secondaryInk)
            Button("快捷键与设置", action: openSettings)
                .buttonStyle(.link).font(AppTypography.caption).padding(.top, 4)
        }.padding(.vertical, 18)
    }

    private var showingHistory: Bool {
        model.query.isEmpty && !model.recent.isEmpty && model.entry == nil
            && model.captureStatus == nil && !model.isLoading && !model.isSuggesting
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("最近查过")
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
                Text(entry.word).font(AppTypography.word).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let phonetic = entry.phonetic, !phonetic.isEmpty {
                        Text(phonetic).font(.system(size: 14)).foregroundColor(secondaryInk).textSelection(.enabled)
                    }
                    Button { model.pronounce(entry.word) } label: {
                        Image(systemName: "speaker.wave.2").font(.system(size: 14))
                            .frame(width: 30, height: 28)
                            .background(Color.primary.opacity(0.06)).cornerRadius(7)
                    }.buttonStyle(.plain).foregroundColor(secondaryInk).help("朗读单词").accessibilityLabel("朗读单词")
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
                            Text(form.typeName).font(AppTypography.caption).foregroundColor(secondaryInk)
                            Button(form.form) { model.lookup(form.form) }.buttonStyle(.link)
                                .font(AppTypography.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !entry.tags.isEmpty {
                Text(entry.tags.map { $0.name ?? $0.code }.joined(separator: " · "))
                    .font(AppTypography.caption).foregroundColor(secondaryInk)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(secondaryInk)
    }

    private func definition(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(title)
            Text(text).font(AppTypography.body).lineSpacing(4)
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
                Text(word)
                    .font(AppTypography.navigation)
                    .foregroundColor(.primary)
                    .frame(width: 132, alignment: .leading)
                Text(translation ?? "")
                    .font(AppTypography.secondary)
                    .foregroundColor(secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                if !hasSummary {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(secondaryInk)
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

private struct CandidateRow: View {
    let item: Suggestion
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2).fill(selected ? Color.accentColor : .clear).frame(width: 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.word).font(AppTypography.candidate).foregroundColor(.primary)
                        .lineLimit(2)
                    if let text = item.translationPreview ?? item.translation {
                        Text(text).font(AppTypography.secondary).foregroundColor(secondaryInk).lineLimit(2)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(selected ? Color.accentColor.opacity(0.23) : Color.primary.opacity(hovered ? 0.08 : 0))
            .cornerRadius(8).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .accessibilityValue(selected ? "已选中" : "")
    }
}

/// Drag only the header/footer background, preserving input controls and selectable results.
private struct LookupDragArea: NSViewRepresentable {
    let drag: (NSEvent) -> Void
    func makeNSView(context: Context) -> DragView { DragView(drag: drag) }
    func updateNSView(_ view: DragView, context: Context) { view.drag = drag }

    final class DragView: NSView {
        var drag: (NSEvent) -> Void
        init(drag: @escaping (NSEvent) -> Void) {
            self.drag = drag
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { drag(event) }
    }
}


/// An unlabeled native control with explicit bounds, aligned with the input's leading edge.
private struct LookupModePicker: NSViewRepresentable {
    @Binding var selection: QueryMode
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: QueryMode.allCases.map(\.title), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.selectMode(_:)))
        control.segmentDistribution = .fill
        control.segmentStyle = .rounded
        control.controlSize = .regular
        control.setAccessibilityLabel("查询模式")
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = selection == .dictionary ? 0 : 1
    }
    final class Coordinator: NSObject {
        var parent: LookupModePicker
        init(_ parent: LookupModePicker) { self.parent = parent }
        @objc func selectMode(_ sender: NSSegmentedControl) {
            guard QueryMode.allCases.indices.contains(sender.selectedSegment) else { return }
            parent.selection = QueryMode.allCases[sender.selectedSegment]
        }
    }
}
