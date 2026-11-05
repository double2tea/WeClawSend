import AppKit
import SwiftUI

struct BasketConversionMenu: View {
    @ObservedObject private var store = BasketConversionPresetStore.shared
    let items: [ShelfItem]
    let isRunning: Bool
    let start: (BasketConversionPreset, Bool) -> Void

    var body: some View {
        let presets = store.presets.filter { preset in
            preset.isEnabled && !items.isEmpty
                && items.allSatisfy { $0.kind == .folder || preset.action.accepts($0.url) }
        }
        if !presets.isEmpty {
            Menu("转换") {
                ForEach(presets) { preset in
                    if items.contains(where: { $0.kind == .folder }) {
                        Menu(preset.name) {
                            Button("仅文件夹内文件") { start(preset, false) }
                            Button("包含子文件夹") { start(preset, true) }
                        }
                    } else {
                        Button(preset.name) { start(preset, false) }
                    }
                }
            }
            .disabled(isRunning)
        }
    }
}

private enum ConversionSettingsPage: String, CaseIterable, Identifiable {
    case presets = "预设"
    case video = "视频"
    case audio = "音频"
    case image = "图片"
    case document = "文档"
    case output = "输出"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .presets: "square.stack"
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .document: "doc.text"
        case .output: "folder"
        }
    }

    var category: BasketConversionCategory? {
        switch self {
        case .video: .video
        case .audio: .audio
        case .image: .image
        case .document: .document
        default: nil
        }
    }
}

struct BasketConversionSettingsView: View {
    @State private var page: ConversionSettingsPage = .presets
    @ObservedObject private var store = BasketConversionPresetStore.shared
    @AppStorage(BasketConversionSettings.enabledKey) private var enabled = true
    @AppStorage(BasketConversionSettings.outputFolderKey) private var outputFolder = ""
    @AppStorage(BasketConversionSettings.besideOriginalKey) private var besideOriginal = false
    @AppStorage(BasketConversionSettings.keepOriginalNameKey) private var keepOriginalName = false
    @AppStorage(BasketConversionSettings.nameSuffixKey) private var nameSuffix = "-转换"
    @State private var editing: BasketConversionPreset?
    @State private var pendingDelete: BasketConversionPreset?
    @State private var draft = BasketConversionPreset(name: "视频分享", action: .mp4, settings: BasketConversionSettings())
    @State private var savedMessage: String?
    @State private var drafts: [BasketConversionCategory: BasketConversionPreset] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(ConversionSettingsPage.allCases) { option in
                    Button {
                        page = option
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: option.systemImage)
                                .font(.system(size: 10, weight: .medium))
                            Text(option.rawValue)
                                .font(.system(size: 11, weight: page == option ? .semibold : .medium))
                        }
                            .foregroundStyle(page == option ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                page == option ? Color.primary.opacity(0.085) : .clear,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.rawValue)
                    .accessibilityAddTraits(page == option ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    switch page {
                    case .presets: presetList
                    case .output: outputSettings
                    default:
                        ConversionPresetFields(preset: $draft, showsCategorySelector: false)
                    }
                    if let error = store.errorMessage {
                        Text(error).foregroundStyle(Brand.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 26)
                .padding(.top, 6)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CompactScrollViewConfigurator())
            }
            .id(page)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if page.category != nil {
                Divider().opacity(0.4)
                HStack(spacing: 12) {
                    Text(savedMessage ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        if store.save(draft) {
                            savedMessage = "已添加到预设"
                            draft.id = UUID()
                        }
                    } label: {
                        Label("添加预设", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.settings.isValid || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
            }
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .onChange(of: page) { previous, page in
            if let category = previous.category { drafts[category] = draft }
            savedMessage = nil
            if let category = page.category,
               let action = BasketConversionAction.allCases.first(where: { $0.category == category }) {
                draft = drafts[category] ?? BasketConversionPreset(
                    name: "\(category.title)预设", action: action, settings: BasketConversionSettings()
                )
            }
        }
        .sheet(item: $editing) { ConversionPresetEditor(preset: $0) }
        .alert("删除预设？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let preset = pendingDelete { store.remove(preset.id) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { Text(pendingDelete?.name ?? "") }
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("快捷转换", isOn: $enabled).toggleStyle(.switch)
                Spacer()
                Button {
                    editing = BasketConversionPreset(name: "新预设", action: .mp4, settings: BasketConversionSettings())
                } label: { Label("新建", systemImage: "plus") }
            }
            Text("保存独立参数，按文件类型出现在文件篮与右键菜单。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            FFmpegSetupView()
            if store.presets.isEmpty {
                Text("还没有预设。点「新建」或在分类中配置后添加。").foregroundStyle(.secondary)
            }
            ForEach(BasketConversionCategory.allCases) { category in
                let presets = store.presets.filter { $0.action.category == category }
                if !presets.isEmpty {
                    Label(category.title, systemImage: category.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(presets) { preset in
                        HStack(spacing: 8) {
                            Toggle(preset.name, isOn: Binding(
                                get: { preset.isEnabled },
                                set: { store.setEnabled(preset.id, enabled: $0) }
                            ))
                            .labelsHidden().toggleStyle(.checkbox)
                            Button { editing = preset } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: preset.action.systemImage)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(preset.name).fontWeight(.medium).foregroundStyle(.primary)
                                        Text(preset.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Menu {
                                Button("编辑", systemImage: "pencil") { editing = preset }
                                Button("复制", systemImage: "doc.on.doc") {
                                    var copy = preset
                                    copy.id = UUID()
                                    copy.name += " 副本"
                                    editing = copy
                                }
                                Button("删除…", systemImage: "trash", role: .destructive) { pendingDelete = preset }
                            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                        .padding(10).background(Brand.surface, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
        }
    }

    private var outputSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            ConversionFormRow("保存位置") {
                Picker("保存位置", selection: $besideOriginal) {
                    Text("指定文件夹").tag(false)
                    Text("原文件旁").tag(true)
                }.labelsHidden()
            }
            ConversionFormRow("文件名称") {
                Picker("文件名称", selection: $keepOriginalName) {
                    Text("原名 + 后缀").tag(false)
                    Text("保留原名").tag(true)
                }.labelsHidden()
            }
            if !keepOriginalName {
                ConversionFormRow("名称后缀") { TextField("后缀", text: $nameSuffix).textFieldStyle(.roundedBorder) }
            }
            if !besideOriginal {
                HStack {
                    Text("输出文件夹")
                    Spacer()
                    Button("选择…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { outputFolder = url.path }
                    }
                    Button("还原") { outputFolder = "" }
                }
                Text(outputFolder.isEmpty ? BasketConversionSettings.defaultOutputFolder.path : outputFolder)
                    .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text("输出规则对所有预设共用。同名自动编号，不覆盖原文件；结果加入文件篮，不自动发送。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).background(Brand.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ConversionFormRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        }
        .frame(minHeight: 26)
    }
}

struct FFmpegSetupView: View {
    @ObservedObject private var support = FFmpegSupport.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(support.isAvailable ? "FFmpeg 已就绪" : "FFmpeg 扩展格式",
                      systemImage: support.isAvailable ? "checkmark.circle" : "shippingbox").fontWeight(.medium)
                Spacer()
                if support.isBusy { ProgressView().controlSize(.mini) }
                Button("检测本机", action: support.detect).disabled(support.isBusy)
                if !support.isAvailable {
                    Button("一键安装", action: support.install).disabled(support.isBusy)
                }
            }
            if !support.isAvailable {
                Text(support.status).foregroundStyle(.secondary).lineLimit(2)
            }
            if !support.isAvailable {
                Text("安装到 App 支持目录，无需 Homebrew 或管理员权限。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = support.errorMessage {
                Text(error).foregroundStyle(Brand.danger).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("版本与安装位置") {
                VStack(alignment: .leading, spacing: 8) {
                    if support.isAvailable {
                        Text(support.status).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text(support.path.isEmpty ? "未配置" : support.path)
                            .lineLimit(2).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button("选择…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url { support.select(url) }
                        }
                    }
                }
            }
        }
        .padding(10).background(Brand.surface, in: RoundedRectangle(cornerRadius: 9))
        .task { if !support.isAvailable && !support.isBusy { support.detect() } }
    }
}

struct BasketConversionBar: View {
    @ObservedObject var controller: BasketConversionController
    @ObservedObject private var store = BasketConversionPresetStore.shared
    let selectedURLs: [URL]
    let draggedURLs: [URL]
    let shelf: ShelfModel
    let pointerPresenceChanged: (Bool) -> Void
    var close: () -> Void = {}
    var selectResults: ([URL]) -> Void = { _ in }
    @State private var targetedPreset: UUID?
    @State private var showsQueue = false
    @State private var showsDetails = false
    @State private var includeSubfolders = false

    private var inputURLs: [URL] {
        draggedURLs.isEmpty ? selectedURLs : draggedURLs
    }

    private var presets: [BasketConversionPreset] {
        let urls = inputURLs
        guard !urls.isEmpty else { return [] }
        return store.presets.filter { preset in
            preset.isEnabled && urls.allSatisfy { ShelfItem.kind(for: $0) == .folder || preset.action.accepts($0) }
        }
    }

    var body: some View {
        let title = if !showsQueue || controller.queue.isEmpty {
            "快捷转换"
        } else if controller.isRunning {
            "正在转换"
        } else {
            "转换结果"
        }
        VStack(spacing: 8) {
            HStack {
                Text(title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                if !controller.isRunning && !showsQueue && !controller.queue.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            showsQueue = true
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 9.5))
                            Text("上次结果")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看上次转换结果")
                }
                Button(action: close) { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .buttonStyle(.plain).accessibilityLabel("收起转换面板")
            }
            if controller.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    if let progress = controller.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .accessibilityLabel("转换进度")
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在处理文件")
                    }
                    HStack {
                        Text(controller.isScanning ? "正在扫描文件夹…" : "已完成 \(controller.completedCount)/\(controller.totalCount) 个")
                            .foregroundStyle(.secondary)
                        if controller.progress != nil || controller.isCancelling {
                            Text(controller.progressLabel)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(controller.isCancelling ? "正在取消…" : "取消转换", action: controller.cancel)
                            .disabled(controller.isCancelling)
                    }
                }
                if controller.skippedCount > 0 {
                    Text("已跳过 \(controller.skippedCount) 个不匹配项目")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                queueList
            } else if showsQueue && !controller.queue.isEmpty {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(controller.status.isEmpty
                             ? "已完成 \(controller.completedCount)/\(controller.totalCount) 个"
                             : controller.status)
                            .fontWeight(.medium)
                        if !controller.outputs.isEmpty {
                            Text(controller.sizeSummary)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        if controller.skippedCount > 0 {
                            Text("已跳过 \(controller.skippedCount) 个不匹配项目")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        Button {
                            withAnimation(.easeOut(duration: 0.16)) {
                                showsQueue = false
                            }
                        } label: {
                            Text("选择预设")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("选择转换格式，继续处理选中的文件")

                        if !controller.outputs.isEmpty {
                            Button("查看结果") { selectResults(controller.resultURLs) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("在文件篮中选中本次转换的结果文件或文件夹")
                        }
                    }
                }
                if controller.queue.count > 1 || controller.outputs.count != controller.queue.count {
                    DisclosureGroup("文件明细", isExpanded: $showsDetails) {
                        queueList
                    }
                    .foregroundStyle(.secondary)
                }
            } else if presets.isEmpty {
                Text("没有适用预设，请在设置 → 转换中新建或启用。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                if inputURLs.contains(where: { ShelfItem.kind(for: $0) == .folder }) {
                    Toggle("包含子文件夹", isOn: $includeSubfolders)
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                        ForEach(presets) { preset in
                            Button {
                                controller.start(
                                    urls: selectedURLs, preset: preset, shelf: shelf,
                                    includeSubfolders: includeSubfolders
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(preset.name, systemImage: preset.action.systemImage).fontWeight(.medium).lineLimit(1)
                                    Text(preset.summary).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading).padding(7)
                                .background(targetedPreset == preset.id ? Brand.controlAccent.opacity(0.2) : Brand.surface,
                                            in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(controller.isRunning).help(preset.summary)
                            .dropDestination(for: URL.self) { urls, _ in
                                controller.start(
                                    urls: urls, preset: preset, shelf: shelf,
                                    includeSubfolders: includeSubfolders
                                )
                            } isTargeted: { targeted in
                                targetedPreset = targeted ? preset.id : nil
                                if targeted { pointerPresenceChanged(true) }
                            }
                        }
                    }
                }
                .frame(height: min(132, CGFloat((presets.count + 1) / 2) * 66))
            }
        }
        .font(.system(size: 11)).buttonStyle(.plain).padding(10)
        .onChange(of: controller.isRunning) { _, running in
            if running {
                showsQueue = true
                showsDetails = false
            }
        }
        .onChange(of: inputURLs) { previous, current in
            if !controller.isRunning && previous != current {
                showsQueue = false
            }
        }
        .alert("转换未完成", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )) {
            Button("好") { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }

    private var queueList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(controller.queue) { item in
                    HStack(spacing: 7) {
                        Image(systemName: item.state.systemImage)
                            .foregroundStyle(item.state == .failed ? Brand.danger : Color.secondary)
                            .frame(width: 14)
                            .accessibilityHidden(true)
                        Text(item.displayName)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if item.state == .running, let progress = item.progress {
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().foregroundStyle(.secondary)
                        } else {
                            Text(item.state.rawValue).foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 30)
                    .help(item.message ?? "\(item.displayName) · \(item.state.rawValue)")
                }
            }
            .padding(.trailing, 14)
        }
        .frame(height: min(96, CGFloat(controller.queue.count) * 30))
        .accessibilityLabel("本批转换队列")
    }
}
