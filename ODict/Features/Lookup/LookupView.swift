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
                detailPane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .font(.system(size: 14, weight: .regular))
        .frame(width: panelSize.width, height: panelSize.height)
        .onAppear { model.focusRequest = UUID(); resize(panelSize) }
        .onChange(of: panelSize) { resize($0) }
        .onExitCommand(perform: close)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundColor(secondaryInk)
            CandidateSearchField(text: Binding(
                get: { model.query },
                set: { editQuery(); model.query = $0; model.queryChanged() }
            ), focused: $searchFocused, focusRequest: model.focusRequest,
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
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
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

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("最近查过")
            ForEach(model.recent, id: \.self) { word in
                Button { model.lookup(word) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "clock").font(.system(size: 12)).foregroundColor(secondaryInk)
                        Text(word).foregroundColor(.primary)
                        Spacer()
                    }.padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
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

// Handle field-editor commands rather than monitoring keys globally. Marked text
// belongs to the input method, including its arrow and Return key handling.
private struct CandidateSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let focusRequest: UUID
    let move: (Int) -> Bool
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = .labelColor
        field.placeholderString = "查单词、短语或中文"
        field.isEditable = true
        field.isSelectable = true
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel("查词输入框")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: SearchTextField, context: Context) {
        context.coordinator.parent = self
        // Avoid replacing the field editor's marked text during IME composition.
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if field.stringValue != text, !composing {
            field.stringValue = text
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            field.requestFocus()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CandidateSearchField
        var lastFocusRequest: UUID?
        init(_ parent: CandidateSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch NSStringFromSelector(commandSelector) {
            case "moveDown:": return parent.move(1)
            case "moveUp:": return parent.move(-1)
            case "insertNewline:": parent.submit(); return true
            case "cancelOperation:": parent.cancel(); return true
            default: return false
            }
        }
    }

    final class SearchTextField: NSTextField {
        private var pendingFocus = false

        func requestFocus() {
            pendingFocus = true
            focusWhenAttached()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusWhenAttached()
        }

        private func focusWhenAttached() {
            guard pendingFocus, window != nil else { return }
            pendingFocus = false
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
