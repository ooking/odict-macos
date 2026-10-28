import SwiftUI

struct AIHistoryView: View {
    @ObservedObject var history: AIHistoryModel
    let select: (UUID) -> Void
    var emptySettings: (() -> Void)? = nil
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !history.records.isEmpty {
                RecentLookupHeader(isSaving: history.isSaving,
                    clearDisabled: history.isSaving) {
                    confirmClear = true
                }
            }
            if history.isLoading { ProgressView().controlSize(.small) }
            if let message = history.message {
                LookupNotice(title: "历史记录暂不可用", message: message, icon: "clock") {
                    Button("重新加载") { history.retry(); history.load() }.buttonStyle(LookupActionStyle())
                }
            }
            if history.records.isEmpty && !history.isLoading, let emptySettings {
                LookupEmptyState(subtitle: "输入单词查释义，输入句子看翻译", openSettings: emptySettings)
            }
            LazyVStack(spacing: 4) {
                ForEach(history.records) { item in
                    AIHistoryRow(item: item) { select(item.id) }
                }
            }
        }
        .onAppear { history.load() }
        .confirmationDialog("清除所有 AI 查询历史？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除历史记录", role: .destructive) { history.clear() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("已保存的原文与回答将从本机删除。")
        }
    }
}

struct AIHistorySaveStatus: View {
    @ObservedObject var history: AIHistoryModel
    var body: some View {
        if let message = history.message {
            LookupNotice(title: "历史记录尚未保存", message: message, icon: "exclamationmark.circle") {
                Button("重新保存") { history.retry(); history.load() }.buttonStyle(LookupActionStyle())
            }
        }
    }
}

private struct AIHistoryRow: View {
    let item: AIHistorySummary
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ReadingText(item.sourcePreview, fixedSize: 13).foregroundColor(.primary).lineLimit(2)
                ReadingText(item.answerPreview, fixedSize: 12).foregroundColor(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    ReadingText(item.date.formatted(date: .abbreviated, time: .shortened), fixedSize: 10)
                    ReadingText(item.model, fixedSize: 10).lineLimit(1)
                    if item.isPartial { ReadingText("未完成", fixedSize: 10) }
                }.font(.system(size: 10)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(hovered ? Color.accentColor.opacity(0.10) : .clear)
            .cornerRadius(7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(item.sourcePreview + (item.isPartial ? "，未完成的 AI 回答" : "，AI 回答"))
    }
}

/// Observe only history metadata so loading or clearing updates the entry immediately.
struct AIHistoryMenu: View {
    @ObservedObject var history: AIHistoryModel
    let select: (UUID) -> Void
    @State private var isPresented = false

    var body: some View {
        if !history.records.isEmpty {
            HStack {
                Spacer()
                Button("最近查过") { isPresented = true }
                    .buttonStyle(.borderless).controlSize(.small)
                    .popover(isPresented: $isPresented) {
                        ScrollView {
                            AIHistoryView(history: history) { id in
                                isPresented = false
                                select(id)
                            }.padding(16)
                        }.frame(width: 380, height: 440)
                    }
            }
            .onChange(of: history.records.isEmpty) { empty in
                if empty { isPresented = false }
            }
        }
    }
}
