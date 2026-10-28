import SwiftUI
import AppKit

/// Manual lookup owns its composer, suggestions and history navigation.
struct MainLookupView: View {
    @ObservedObject var model: LookupModel
    let openSettings: () -> Void
    let close: () -> Void
    let captureSelection: () -> Void
    let captureScreenshot: () -> Void
    let editQuery: () -> Void
    let openAISettings: () -> Void
    let dragWindow: (NSEvent) -> Void
    var openSetup: (SettingsCategory) -> Void = { _ in }
    @State private var searchFocused = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.mode == .ai {
                // One scroll surface keeps the full read-only source reachable without
                // allowing a long source to push the answer outside the window.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            aiComposer.padding(.horizontal, 16).padding(.vertical, 12)
                                .id("ai-composer")
                            Divider()
                            LookupResultView(model: model, openSettings: openSettings,
                                openAISettings: openAISettings, scrollsAIContent: false)
                        }
                    }
                    .onChange(of: model.focusRequest) { _ in
                        proxy.scrollTo("ai-composer", anchor: .top)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    HStack(alignment: .top, spacing: 0) {
                        if model.hasMultipleSuggestions {
                            candidateSidebar.frame(width: min(220, geometry.size.width * 0.36))
                            Divider()
                        }
                        if model.mode == .dictionary, model.query.isEmpty, model.recent.isEmpty,
                           model.captureStatus == nil, model.message == nil,
                           !model.isLoading, !model.isSuggesting, model.contentVisible {
                            LookupWelcomeView(openSetup: openSetup)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            LookupResultView(model: model, openSettings: openSettings,
                                openAISettings: openAISettings)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            Divider()
            LookupFooter(model: model, openSettings: openSettings, openAISettings: openAISettings,
                captureSelection: captureSelection, captureScreenshot: captureScreenshot, dragWindow: dragWindow) {
                Menu {
                    Button("退出 ODict") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 14)).frame(width: 22, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundColor(lookupSecondaryInk).help("更多").accessibilityLabel("更多操作")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                LookupModePicker(selection: Binding(get: { model.mode }, set: { editQuery(); model.setMode($0) }))
                    .frame(width: 136, height: 28)
                Spacer().allowsHitTesting(false)
                LookupIconButton("关闭（Esc）", icon: "xmark", action: close)
            }
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
            .background { LookupDragArea(drag: dragWindow) }
            if model.mode != .ai { searchBar }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var aiComposer: some View {
        AIComposerView(model: model.ai, text: model.query, focusRequest: model.focusRequest,
            allowsFocus: model.acceptsSearchFocus, changed: { text in
                editQuery(); model.editQuery(text, composing: false)
            }, clear: {
                model.ai.reset()
                editQuery(); model.editQuery("", composing: false); model.focusRequest = UUID()
            }, close: close)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundColor(lookupSecondaryInk)
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
                .buttonStyle(.plain).foregroundColor(lookupSecondaryInk)
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
            Text("候选词").font(AppTypography.caption).foregroundColor(lookupSecondaryInk)
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
                    ReadingText(item.word, bold: true, fixedSize: 16).foregroundColor(.primary)
                        .lineLimit(2)
                    if let text = item.translationPreview ?? item.translation {
                        ReadingText(text, fixedSize: 13).foregroundColor(lookupSecondaryInk).lineLimit(2)
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
