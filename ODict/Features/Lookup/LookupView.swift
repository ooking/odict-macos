import SwiftUI
import AppKit

// Keep supporting text readable over both native glass and reduced-transparency surfaces.
private let secondaryInk = Color(nsColor: .labelColor).opacity(0.72)

struct LookupView: View {
    @ObservedObject var model: LookupModel
    let openSettings: () -> Void
    let close: () -> Void
    let resize: (NSSize) -> Void
    var captureSelection: () -> Void = {}
    var captureScreenshot: () -> Void = {}
    var editQuery: () -> Void = {}
    @State private var searchFocused = false

    private var panelSize: NSSize {
        NSSize(width: model.hasMultipleSuggestions ? 640 : 440,
               height: model.query.isEmpty && model.recent.isEmpty && model.captureStatus == nil ? 280 : 440)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                if model.hasMultipleSuggestions {
                    candidateSidebar.frame(width: 220)
                    Divider()
                }
                if let article = model.localArticle, model.contentVisible {
                    VStack(alignment: .leading, spacing: 0) {
                        LocalArticleView(article: article, lookup: { model.lookup($0) })
                        if let notice = model.message {
                            Text(notice).font(.caption).foregroundColor(.secondary).padding(12)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    detailPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .font(.system(size: 14, weight: .regular))
        .frame(width: panelSize.width, height: panelSize.height)
        .onAppear { resize(panelSize) }
        .onChange(of: panelSize) { resize($0) }
        .onExitCommand(perform: close)
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
                    editQuery(); model.query = ""; model.queryChanged(); model.focusRequest = UUID()
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
            Text("候选词").font(.system(size: 12)).foregroundColor(secondaryInk)
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
                        Text(status).font(.system(size: 13)).foregroundColor(secondaryInk)
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
                        Text("来源：" + source).font(.system(size: 11)).foregroundColor(secondaryInk)
                    }
                } else if model.isLoading || model.isSuggesting {
                    Text(model.isSuggesting ? "正在查找候选词…" : "正在载入释义…")
                        .font(.system(size: 13)).foregroundColor(secondaryInk).padding(.top, 12)
                } else if model.query.isEmpty {
                    if model.recent.isEmpty { emptyState } else { recentList }
                }
                if let message = model.message {
                    Label {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "info.circle") }
                    .font(.system(size: 13)).foregroundColor(secondaryInk)
                    HStack(spacing: 12) {
                        Button("重试") { model.submit() }
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
            Text("ODict").font(.system(size: 12, weight: .semibold))
            Spacer()
            captureButton("选中取词", icon: "text.cursor", action: captureSelection)
            captureButton("截图取词", icon: "viewfinder", action: captureScreenshot)
            Button(action: openSettings) {
                Image(systemName: "gearshape").font(.system(size: 14))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundColor(secondaryInk)
            .help("设置（⌘,）").accessibilityLabel("设置").keyboardShortcut(",", modifiers: .command)
            Menu {
                Button("清空查词记录") { model.clearHistory() }.disabled(model.recent.isEmpty)
                Divider()
                Button("退出 ODict") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 14)).frame(width: 22, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundColor(secondaryInk).help("更多").accessibilityLabel("更多操作")
        }.padding(.horizontal, 18).padding(.vertical, 5)
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
                .font(.system(size: 13)).foregroundColor(secondaryInk)
            Button("快捷键与设置", action: openSettings)
                .buttonStyle(.link).font(.system(size: 12)).padding(.top, 4)
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
        .task { await model.fillRecentTranslations() }
    }

    private func entryContent(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.word).font(.system(size: 30, weight: .semibold)).textSelection(.enabled)
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
                            Text(form.typeName).font(.system(size: 12)).foregroundColor(secondaryInk)
                            Button(form.form) { model.lookup(form.form) }.buttonStyle(.link)
                                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !entry.tags.isEmpty {
                Text(entry.tags.map { $0.name ?? $0.code }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundColor(secondaryInk)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(secondaryInk)
    }

    private func definition(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(title)
            Text(text).font(.system(size: 14, weight: .regular)).lineSpacing(4)
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 132, alignment: .leading)
                Text(translation.map { $0.isEmpty ? "点击查看释义" : $0 } ?? "点击查看释义")
                    .font(.system(size: 13))
                    .foregroundColor(secondaryInk.opacity(hasSummary ? 1 : 0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
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
                    Text(item.word).font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)
                        .lineLimit(2)
                    if let text = item.translationPreview ?? item.translation {
                        Text(text).font(.system(size: 12)).foregroundColor(secondaryInk).lineLimit(2)
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
