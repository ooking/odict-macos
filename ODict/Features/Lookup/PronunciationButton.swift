import SwiftUI

struct PronunciationButton: View {
    let text: String
    let owner: UUID
    @ObservedObject private var settings = PronunciationSettingsStore.shared
    @ObservedObject private var playback = PronunciationService.shared
    @State private var presented = false
    @State private var pending: Task<Void, Never>?

    private var state: PronunciationService.State { playback.owner == owner ? playback.state : .idle }
    private var disabled: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || settings.enabledSources.isEmpty }
    private var status: String {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "输入文字后发音" }
        if settings.enabledSources.isEmpty { return "请在设置中添加并启用发音来源" }
        switch state {
        case .idle: return "发音"
        case .loading: return "正在加载发音"
        case .playing: return "正在播放，点击可切换或重播"
        case .error: return playback.errorMessage ?? "发音失败，请重试"
        }
    }

    var body: some View {
        Button { pending?.cancel(); presented.toggle() } label: {
            Group {
                if state == .loading { ProgressView().controlSize(.small).scaleEffect(0.65) }
                else { Image(systemName: state == .playing ? "speaker.wave.2.fill" : state == .error ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 14)) }
            }.frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(state == .playing ? Color.accentColor : lookupSecondaryInk)
        .disabled(disabled).help(status).accessibilityLabel("发音").accessibilityValue(status)
        .onHover { hovering in
            pending?.cancel(); pending = nil
            guard hovering, !disabled, !presented else { return }
            pending = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                presented = true; pending = nil
            }
        }
        .popover(isPresented: $presented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Text("发音").font(AppTypography.section)
                if state == .error { Text(status).font(AppTypography.caption).foregroundColor(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(settings.enabledSources) { source in
                            Button {
                                pending?.cancel(); pending = nil; presented = false
                                playback.play(source: source, text: text, owner: owner)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "speaker.wave.2.fill").foregroundColor(source.iconColor)
                                    Text(source.name).foregroundColor(.primary)
                                    Spacer()
                                }.padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("播放 \(source.name)")
                        }
                    }
                }.frame(height: CGFloat(min(settings.enabledSources.count, 6)) * 38)
                if state == .playing || state == .loading {
                    Button("停止播放") { presented = false; playback.stop(owner: owner) }
                }
            }.padding(18).frame(width: 240)
        }
        .onChange(of: text) { _ in dismiss() }
        .onChange(of: disabled) { if $0 { dismiss() } }
        .onDisappear { dismiss(); playback.stop(owner: owner) }
    }

    private func dismiss() { pending?.cancel(); pending = nil; presented = false }
}
