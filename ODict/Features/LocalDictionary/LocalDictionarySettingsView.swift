import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LocalDictionarySettingsModel: ObservableObject {
    @Published private(set) var dictionaries: [LocalDictionaryConfiguration]
    @Published var mode: DictionaryMode
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private let store = LocalDictionaryStore()
    private let queue = BlockingWorkQueue(label: "com.touchany.odict.dictionary-discovery")
    private var task: Task<Void, Never>?

    init() { dictionaries = store.load(); mode = store.mode }
    @discardableResult
    private func save() -> Bool {
        do { try store.save(dictionaries, mode: mode); return true }
        catch { message = error.localizedDescription; return false }
    }
    func changeMode() { save() }
    func reload() {
        guard save() else { return }
        message = "已重新加载词典配置；下次查询使用最新样式与摘要规则。"
    }
    func enabled(_ id: UUID, _ value: Bool) {
        guard let i = dictionaries.firstIndex(where: { $0.id == id }) else { return }
        dictionaries[i].enabled = value; save()
    }
    func overrideStyle(_ id: UUID, _ value: Bool) {
        guard let i = dictionaries.firstIndex(where: { $0.id == id }) else { return }
        dictionaries[i].usesOverrideStyle = value
        save()
    }
    func move(_ id: UUID, by delta: Int) {
        guard let i = dictionaries.firstIndex(where: { $0.id == id }), dictionaries.indices.contains(i + delta) else { return }
        dictionaries.swapAt(i, i + delta); save()
    }
    func remove(_ id: UUID) { dictionaries.removeAll { $0.id == id }; save() }
    func add() {
        let panel = NSOpenPanel()
        panel.title = "添加本地词典"
        panel.message = "选择 MDX 文件或词典文件夹。每本词典放在独立文件夹时，可自动关联其中所有 MDD 资源包。"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        // A directory must itself pass the type filter, otherwise Open merely
        // navigates into it even when canChooseDirectories is enabled.
        panel.allowedContentTypes = [UTType(filenameExtension: "mdx") ?? .data, .folder]
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        busy = true; message = nil
        task = Task { [weak self, queue] in
            do {
                let additions = try await queue.perform { try urls.flatMap { try LocalDictionaryDiscovery.discover($0) } }
                guard let self, !Task.isCancelled else { return }
                defer { self.busy = false; self.task = nil }
                var seen = Set(self.dictionaries.map(\.mdxPath))
                let unique = additions.filter { seen.insert($0.mdxPath).inserted }
                guard self.dictionaries.count + unique.count <= LocalDictionaryStore.maximumCount else {
                    self.message = "最多添加 \(LocalDictionaryStore.maximumCount) 本词典。"; return
                }
                var overrideFailures = false
                for item in unique {
                    do { try LocalDictionaryOverrides.create(in: item.folder) }
                    catch { overrideFailures = true }
                }
                self.dictionaries.append(contentsOf: unique)
                self.save()
                self.message = unique.isEmpty ? "所选词典已经添加。" : "已添加 \(unique.count) 本词典。首次查词时读取内置索引，不生成额外索引文件。"
                if overrideFailures { self.message! += "部分目录无法写入覆盖样式，展示时将使用默认样式。" }
            } catch {
                guard !Task.isCancelled else { return }
                self?.message = error.localizedDescription; self?.busy = false; self?.task = nil
            }
        }
    }
    func associate(_ dictionary: LocalDictionaryConfiguration) {
        let panel = NSOpenPanel()
        panel.title = "关联 \(dictionary.name) 的资源包"
        panel.message = "选择属于这本词典的全部 MDD 文件；此次选择会替换原有关联。"
        panel.directoryURL = dictionary.folder
        panel.allowedContentTypes = [UTType(filenameExtension: "mdd") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, let i = dictionaries.firstIndex(where: { $0.id == dictionary.id }) else { return }
        dictionaries[i].resources = panel.urls.map { $0.standardizedFileURL.path }.sorted()
        save()
    }
    func openOverrides(_ dictionary: LocalDictionaryConfiguration) {
        do {
            try LocalDictionaryOverrides.create(in: dictionary.folder)
            NSWorkspace.shared.activateFileViewerSelecting([dictionary.folder.appendingPathComponent(LocalDictionaryOverrides.cssName)])
        } catch { message = error.localizedDescription }
    }
    func close() { task?.cancel(); task = nil; busy = false }
}

struct LocalDictionarySettingsView: View {
    @ObservedObject var model: LocalDictionarySettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("词典管理").font(AppTypography.section)
            Picker("查询方式", selection: $model.mode) {
                ForEach(DictionaryMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.onChange(of: model.mode) { _ in model.changeMode() }
            Text("本地词典按从上到下的顺序查询，命中后停止；全部未命中时使用在线词典。中文释义反查使用在线服务。")
                .font(AppTypography.secondary).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(model.dictionaries.enumerated()), id: \.element.id) { index, dictionary in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(get: { dictionary.enabled }, set: { model.enabled(dictionary.id, $0) })) {
                            Text(dictionary.name).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Button { model.move(dictionary.id, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).help("提高优先级").accessibilityLabel("提高优先级")
                        Button { model.move(dictionary.id, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == model.dictionaries.count - 1).help("降低优先级").accessibilityLabel("降低优先级")
                        Menu {
                            Button("关联资源包…") { model.associate(dictionary) }
                            Button("查看覆盖样式文件") { model.openOverrides(dictionary) }
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dictionary.mdxPath)]) }
                            Divider()
                            Button("移除词典") { model.remove(dictionary.id) }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                            .accessibilityLabel("词典选项")
                    }
                    Toggle("使用覆盖样式", isOn: Binding(
                        get: { dictionary.usesOverrideStyle },
                        set: { model.overrideStyle(dictionary.id, $0) }))
                        .font(AppTypography.secondary)
                        .help("仅控制这本词典的 odict-overrides.css，不影响原始样式和脚本。")
                    Text("\(dictionary.folder.path) · \(dictionary.resources.count) 个资源包")
                        .font(AppTypography.caption).foregroundColor(.secondary).lineLimit(2).textSelection(.enabled)
                }.padding(10).background(Color.primary.opacity(0.035)).cornerRadius(8)
            }
            HStack {
                Button("添加词典…", action: model.add).disabled(model.busy)
                Button("重新加载样式与摘要规则", action: model.reload).disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
            }
            Text("每本词典建议使用独立文件夹。可独立开关每本词典的覆盖样式。展示样式可编辑目录中的 odict-overrides.css，也可自行添加 odict-overrides.js；重新查询后生效。移除配置不会删除词典文件。")
                .font(AppTypography.secondary).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = model.message {
                Text(message).font(AppTypography.secondary).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.font(AppTypography.body).onDisappear { model.close() }
    }
}
