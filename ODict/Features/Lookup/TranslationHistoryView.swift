import SwiftUI

struct TranslationHistoryView: View {
    @ObservedObject var history: TranslationHistoryModel
    let select: (TranslationHistoryGroup) -> Void
    let openSettings: () -> Void
    @State private var confirmClear = false
    var clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecentLookupHeader(isSaving: history.isSaving, clearDisabled: history.groups.isEmpty && history.message == nil && !history.isSaving) {
                confirmClear = true
            }
            TranslationHistoryStatus(history: history)
            if history.isLoading { ProgressView().controlSize(.small) }
            if history.groups.isEmpty && !history.isLoading {
                LookupEmptyState(subtitle: "输入单词查释义，输入句子看翻译", openSettings: openSettings)
            }
            LazyVStack(spacing: 4) {
                ForEach(history.groups) { group in
                    TranslationHistoryRow(group: group) { select(group) }
                }
            }
        }
        .onAppear { history.load() }
        .confirmationDialog("清除所有查询历史？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除历史记录", role: .destructive, action: clear)
            Button("取消", role: .cancel) { }
        } message: {
            Text("将删除所有原文及各翻译方式保存的结果，清除后无法恢复。")
        }
    }
}

struct TranslationHistoryStatus: View {
    @ObservedObject var history: TranslationHistoryModel
    var body: some View {
        if let message = history.message {
            LookupNotice(title: "查询历史尚未完成保存", message: message, icon: "exclamationmark.circle") {
                Button("重试") { history.retry(); history.load() }.buttonStyle(LookupActionStyle())
            }
        }
    }
}

private struct TranslationHistoryRow: View {
    let group: TranslationHistoryGroup
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ReadingText(String(group.source.prefix(160)), bold: true, fixedSize: 14)
                    .foregroundColor(.primary).lineLimit(2)
                ReadingText(group.selected?.preview ?? "该方式尚无已保存结果", fixedSize: 12)
                    .foregroundColor(lookupSecondaryInk).lineLimit(2)
                HStack(spacing: 8) {
                    Text(group.selectedMethod == .automatic ? "自动选择 · " + (group.selected?.title ?? "尚无结果") : group.selected?.title ?? group.selectedMethod.title(in: []))
                    Text(group.date.formatted(date: .abbreviated, time: .shortened))
                }.font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(hovered ? Color.accentColor.opacity(0.10) : .clear)
            .cornerRadius(7).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
    }
}
