import SwiftUI

struct AIHistoryView: View {
    @ObservedObject var history: AIHistoryModel
    let select: (UUID) -> Void
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI 历史记录", systemImage: "clock.arrow.circlepath").font(AppTypography.section)
                Spacer()
                if history.isSaving { ProgressView().controlSize(.small).help("正在保存历史记录") }
                Button("清空") { confirmClear = true }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(history.records.isEmpty || history.isSaving)
            }
            if history.isLoading { ProgressView().controlSize(.small) }
            if let message = history.message {
                Text(message).font(AppTypography.caption).foregroundColor(.secondary)
                Button("重试") { history.retry(); history.load() }.controlSize(.small)
            }
            if history.records.isEmpty && !history.isLoading {
                Text("完成 AI 查询后，原文与回答会保存在本机，退出应用后仍可查看。")
                    .font(AppTypography.secondary).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVStack(spacing: 4) {
                ForEach(history.records) { item in
                    AIHistoryRow(item: item) { select(item.id) }
                }
            }
        }
        .onAppear { history.load() }
        .confirmationDialog("清空所有 AI 历史记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空历史记录", role: .destructive) { history.clear() }
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
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(AppTypography.caption).foregroundColor(.secondary)
                Button("重试保存") { history.retry(); history.load() }.controlSize(.small)
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
                Text(item.sourcePreview).font(AppTypography.secondary).foregroundColor(.primary).lineLimit(2)
                Text(item.answerPreview).font(AppTypography.caption).foregroundColor(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                    Text(item.model).lineLimit(1)
                    if item.isPartial { Text("未完成") }
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
