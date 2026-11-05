import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(CaptureWindowSettings.closesOnOutsideClickKey) private var closesOnOutsideClick = false
    @AppStorage(CaptureWindowSettings.fitsContentHeightKey) private var fitsContentHeight = false
    @AppStorage(CaptureWindowSettings.maximumHeightKey) private var maximumHeight = CaptureWindowSettings.defaultMaximumHeight
    @AppStorage(CaptureWindowSettings.defaultWidthKey) private var defaultWidth = CaptureWindowSettings.defaultWidth
    @State private var options = LookupSourceSettings().load()
    @State private var available: Set<LookupSource> = [.system]
    @State private var refreshID = UUID()
    @State private var autoTranslateSentences = AISettingsStore.autoTranslateSentences
    var body: some View {
        SettingsPage {
            orderSettings
            fallbackSettings
            captureWindowSettings
        }
        .task(id: refreshID) { await refreshAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: LocalDictionaryStore.changed)) { _ in
            options = LookupSourceSettings().load()
        }
        .onReceive(NotificationCenter.default.publisher(for: AISettingsStore.changed)) { _ in
            autoTranslateSentences = AISettingsStore.autoTranslateSentences
            refreshID = UUID()
        }
    }

    private var orderSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("查询顺序").font(AppTypography.section)
            Text("选择「自动选择翻译方式」时，按从上到下的顺序使用已启用的来源，命中后停止。AI 在确认查询后才会请求；输入和候选预览不会自动发送给 AI。主界面和取词窗口均可直接选择指定的翻译方式。")
                .font(AppTypography.secondary).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                HStack {
                    Toggle(option.source.title, isOn: Binding(get: { option.enabled && available.contains(option.source) }, set: { enabled in
                        options[index].enabled = enabled
                        LookupSourceSettings().save(options)
                    }))
                    Spacer()
                    Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0).help("提高优先级").accessibilityLabel("提高优先级")
                    Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == options.count - 1).help("降低优先级").accessibilityLabel("降低优先级")
                }
                .disabled(!available.contains(option.source))
                .opacity(available.contains(option.source) ? 1 : 0.45)
                .help(availabilityHint(option.source))
                .padding(10).background(Color.primary.opacity(0.035)).cornerRadius(8)
            }
            Text("设置自动保存，下次查询生效。系统词典的启用状态与「本地词典」页面同步；各本 MDX 的内部顺序仍在「本地词典」中调整。若将 AI 排在前面，确认查询时会优先使用 AI；请先在 AI翻译 中完成配置。未完成配置的来源不可启用；配置完成后可手动勾选。")
                .font(AppTypography.secondary).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var fallbackSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("词典查询回退").font(AppTypography.section)
            Toggle("识别到句子时自动用 AI翻译", isOn: $autoTranslateSentences)
                .disabled(!available.contains(.ai) || !LookupSourceSettings().isEnabled(.ai))
                .onChange(of: autoTranslateSentences) { AISettingsStore.autoTranslateSentences = $0 }
            Text("使用「自动选择翻译方式」时，确认查询或取词后若识别为句子，将直接使用已启用且配置完成的 AI翻译；关闭时先显示原文，由你确认。单词与短语按照上方顺序查询。手动选择具体词典时，不自动回退到其他方式。")
                .font(AppTypography.secondary).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var captureWindowSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("取词窗口").font(AppTypography.section)
            HStack {
                Text("默认宽度")
                Spacer()
                Text("\(CaptureWindowSettings.boundedWidth(defaultWidth)) 点")
                    .monospacedDigit().foregroundColor(.secondary)
                Stepper("取词窗口默认宽度", value: Binding(
                    get: { CaptureWindowSettings.boundedWidth(defaultWidth) },
                    set: { defaultWidth = CaptureWindowSettings.boundedWidth($0) }),
                    in: CaptureWindowSettings.widthRange, step: 20)
                    .labelsHidden().fixedSize()
            }
            Text("默认 480 点，可调整为 440–1200 点。每次重新打开取词窗口时使用此宽度，也可临时拖动窗口边缘调整；实际宽度受屏幕可用空间限制。")
                .font(AppTypography.secondary).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("点击窗口外部时关闭", isOn: $closesOnOutsideClick)
                .onChange(of: closesOnOutsideClick) { _ in
                    NotificationCenter.default.post(name: CaptureWindowSettings.changed, object: nil)
                }
            Text("开启后，点击取词窗口以外的区域会关闭窗口；关闭后，窗口会保留，直到手动关闭。固定窗口位置不影响此设置。")
                .font(AppTypography.secondary).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("根据内容自动调整高度", isOn: $fitsContentHeight)
                .onChange(of: fitsContentHeight) { _ in
                    NotificationCenter.default.post(name: CaptureWindowSettings.changed, object: nil)
                }
            if fitsContentHeight {
                HStack {
                    Text("最大高度")
                    Spacer()
                    Text("\(CaptureWindowSettings.boundedMaximumHeight(maximumHeight)) 点")
                        .monospacedDigit().foregroundColor(.secondary)
                    Stepper("最大高度", value: Binding(
                        get: { CaptureWindowSettings.boundedMaximumHeight(maximumHeight) },
                        set: { maximumHeight = CaptureWindowSettings.boundedMaximumHeight($0) }),
                        in: CaptureWindowSettings.maximumHeightRange, step: 40)
                        .labelsHidden().fixedSize()
                }
                Text("默认 720 点，可调整为 240–1200 点；实际高度不超过屏幕可用空间。")
                    .font(AppTypography.secondary).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("根据取词结果调整窗口高度，宽度保持不变；内容超过最大高度时可滚动查看。关闭后使用手动调整的窗口大小。以上设置仅影响取词窗口。")
                .font(AppTypography.secondary).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .onChange(of: defaultWidth) { _ in
            NotificationCenter.default.post(name: CaptureWindowSettings.widthChanged, object: nil)
        }
        .onChange(of: maximumHeight) { _ in
            NotificationCenter.default.post(name: CaptureWindowSettings.changed, object: nil)
        }
    }

    @MainActor private func refreshAvailability() async {
        var ready: Set<LookupSource> = [.system]
        if LocalDictionaryStore().load().contains(where: \.enabled) { ready.insert(.local) }
        if (try? AISettingsStore.validate(AISettingsStore.configuration, key: "")) != nil { ready.insert(.ai) }
        let user = try? await AccountStore.shared.user(endpoint: ODictService.apiAddress)
        guard !Task.isCancelled else { return }
        if user != nil { ready.insert(.online) }
        available = ready
        LookupSourceSettings().reconcile(available: ready)
        options = LookupSourceSettings().load()
    }

    private func availabilityHint(_ source: LookupSource) -> String {
        guard !available.contains(source) else { return "调整查询顺序和启用状态" }
        switch source {
        case .system: return "使用 macOS 已启用的系统词典"
        case .local: return "请在本地词典中添加并启用至少一本 MDX 词典"
        case .online: return "请在在线词典中登录 ODict 账号"
        case .ai: return "请在 AI翻译 中保存有效的服务地址与模型配置"
        }
    }

    private func move(_ index: Int, by delta: Int) {
        guard options.indices.contains(index + delta) else { return }
        options.swapAt(index, index + delta)
        LookupSourceSettings().save(options)
    }
}
