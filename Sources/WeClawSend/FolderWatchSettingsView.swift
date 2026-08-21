import SwiftUI

/// 文件夹监控设置卡。
///
/// 视图只负责展示和编辑状态，文件选择、规则持久化以及监控服务由外部回调处理。
/// 这样设置页可以在不依赖 AppModel 的情况下复用，也方便单独测试规则编辑。
struct FolderWatchSettingsView: View {
    @ObservedObject var store: FolderWatchStore

    let baskets: [ShelfModel]
    @Binding var monitoringEnabled: Bool
    let statusText: String
    let shelfEnabled: Bool
    let unavailableRuleIDs: Set<UUID>
    let addFolders: () -> Void
    let update: (FolderWatchRule) -> Void
    let remove: (UUID) -> Void

    @State private var expandedRules: Set<UUID> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            overviewCard

            if store.rules.isEmpty {
                emptyState
            } else {
                rulesCard
            }

            recentRecordsCard
        }
    }

    private var overviewCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    settingIcon("eye.circle.fill", color: monitoringEnabled ? Brand.controlAccent : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("文件夹监控")
                            .font(.system(size: 12, weight: .semibold))
                        Text(monitoringEnabled ? statusText : "已暂停所有监控规则")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 8)

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { monitoringEnabled },
                            set: { monitoringEnabled = $0 }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Brand.controlAccent)
                    .accessibilityLabel("启用文件夹监控")
                }

                HStack(spacing: 6) {
                    Label("事件驱动", systemImage: "bolt.fill")
                    Text("·")
                    Text("默认静默 10 秒并检查文件占用")
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)

                Text("需保持 WeClaw Send 运行；建议开启登录时自动启动。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    Button(action: addFolders) {
                        Label("添加文件夹", systemImage: "folder.badge.plus")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.controlAccent)
                    .controlSize(.small)

                    Text("可添加多个文件夹，每条规则独立设置")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var emptyState: some View {
        SectionCard {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.05)))

                VStack(alignment: .leading, spacing: 2) {
                    Text("还没有监控文件夹")
                        .font(.system(size: 11, weight: .medium))
                    Text("添加一个文件夹后，新增文件会按规则发送或进入文件篮")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var rulesCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeading("监控规则", detail: "\(store.rules.count) 个文件夹")

                ForEach(Array(store.rules.enumerated()), id: \.element.id) { index, rule in
                    if index > 0 {
                        Divider()
                            .opacity(0.32)
                            .padding(.vertical, 7)
                    }

                    FolderWatchRuleRow(
                        rule: rule,
                        baskets: baskets,
                        shelfEnabled: shelfEnabled,
                        isPathUnavailable: unavailableRuleIDs.contains(rule.id),
                        isExpanded: Binding(
                            get: { expandedRules.contains(rule.id) },
                            set: { expanded in
                                if expanded {
                                    expandedRules.insert(rule.id)
                                } else {
                                    expandedRules.remove(rule.id)
                                }
                            }
                        ),
                        update: update,
                        remove: { remove(rule.id) }
                    )
                }
            }
        }
    }

    private var recentRecordsCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeading("最近处理", detail: "最多显示 5 条")

                if store.records.isEmpty {
                    Text("尚未处理文件")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 2)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.records.prefix(5).enumerated()), id: \.element.id) { index, record in
                            if index > 0 {
                                Divider().opacity(0.24)
                            }

                            HStack(spacing: 8) {
                                Image(systemName: recordStatusSystemImage(record.status))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(recordStatusColor(record.status))
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(recordStatusColor(record.status).opacity(0.12)))

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(record.fileName)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(recordDetail(record))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 5)
                                Text(recordStatusTitle(record.status))
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(recordStatusColor(record.status))
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }
        }
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
        }
        .padding(.bottom, 5)
    }

    private func settingIcon(_ name: String, color: Color = .secondary) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.primary.opacity(0.05)))
    }

    private func recordStatusTitle(_ status: FolderWatchRecordStatus) -> String {
        switch status {
        case .discovered: "已发现"
        case .waiting: "等待完成"
        case .processing: "处理中"
        case .sent: "已发送"
        case .addedToBasket: "已入文件篮"
        case .ignored: "已忽略"
        case .failed: "失败"
        }
    }

    private func recordStatusSystemImage(_ status: FolderWatchRecordStatus) -> String {
        switch status {
        case .discovered: "sparkle"
        case .waiting: "clock"
        case .processing: "arrow.triangle.2.circlepath"
        case .sent: "checkmark"
        case .addedToBasket: "tray.and.arrow.down"
        case .ignored: "minus"
        case .failed: "exclamationmark"
        }
    }

    private func recordStatusColor(_ status: FolderWatchRecordStatus) -> Color {
        switch status {
        case .discovered, .waiting: Brand.warning
        case .processing: Brand.controlAccent
        case .sent, .addedToBasket: Brand.success
        case .ignored: .secondary
        case .failed: Brand.danger
        }
    }

    private func recordDetail(_ record: FolderWatchRecord) -> String {
        let folderName = store.rule(id: record.ruleID)?.folderURL.lastPathComponent ?? "监控目录"
        if let message = record.message, !message.isEmpty {
            return "\(folderName) · \(message)"
        }
        return "\(folderName) · \(record.discoveredAt.formatted(date: .omitted, time: .shortened))"
    }
}

private struct FolderWatchRouteRow: View {
    let index: Int
    let route: FolderWatchRoute
    let baskets: [ShelfModel]
    let shelfEnabled: Bool
    let unavailableTypes: Set<FolderWatchFileType>
    let canRemove: Bool
    let update: (FolderWatchRoute) -> Void
    let remove: () -> Void

    @State private var customExtensions = ""
    @FocusState private var isCustomFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(width: 15, height: 15)
                    .background(Color.primary.opacity(0.05), in: Circle())

                Menu {
                    ForEach(FolderWatchFileType.allCases) { type in
                        Button {
                            var copy = route
                            copy.fileTypeAllowlist = [type]
                            if type != .custom { copy.customExtensions = [] }
                            update(copy)
                        } label: {
                            if route.fileTypeAllowlist.contains(type) {
                                Label(typeTitle(type), systemImage: "checkmark")
                            } else {
                                Text(typeTitle(type))
                            }
                        }
                        .disabled(unavailableTypes.contains(type) || (type == .all && !unavailableTypes.isEmpty))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: typeSystemImage)
                        Text(typeSummary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Brand.controlAccent)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(Brand.controlAccent.opacity(0.08), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .controlSize(.mini)
                .fixedSize()

                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.quaternary)

                Menu {
                    Button {
                        mutate { $0.action = .direct }
                    } label: {
                        Label("直接发送", systemImage: route.action == .direct ? "checkmark" : "paperplane")
                    }
                    Divider()
                    Menu("进入文件篮") {
                        Button {
                            mutate {
                                $0.action = .basket
                                $0.basketID = nil
                            }
                        } label: {
                            if route.action == .basket, route.basketID == nil {
                                Label("最近使用", systemImage: "checkmark")
                            } else {
                                Text("最近使用")
                            }
                        }
                        ForEach(baskets, id: \.id) { basket in
                            Button {
                                mutate {
                                    $0.action = .basket
                                    $0.basketID = basket.id
                                }
                            } label: {
                                if route.action == .basket, route.basketID == basket.id {
                                    Label(basket.title, systemImage: "checkmark")
                                } else {
                                    Text(basket.title)
                                }
                            }
                        }
                    }
                    .disabled(!shelfEnabled)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: destinationSystemImage)
                        Text(destinationSummary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(route.action == .basket && !shelfEnabled ? Brand.warning : Color.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(Color.primary.opacity(0.04), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .controlSize(.mini)
                .frame(maxWidth: 118, alignment: .leading)

                Spacer(minLength: 2)

                if canRemove {
                    Button(role: .destructive, action: remove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .semibold))
                            .frame(width: 17, height: 17)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.danger)
                    .help("移除此分流")
                }
            }

            if route.fileTypeAllowlist.contains(.custom) {
                TextField("扩展名，例如 psd, exr", text: $customExtensions)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                    .focused($isCustomFieldFocused)
                    .onSubmit(commitCustomExtensions)
                    .onChange(of: isCustomFieldFocused) { _, focused in
                        if !focused { commitCustomExtensions() }
                    }
                if route.customExtensions.isEmpty {
                    Text("至少填写一个扩展名")
                        .font(.system(size: 9))
                        .foregroundStyle(Brand.danger)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .onAppear { customExtensions = route.customExtensions.joined(separator: ", ") }
        .onChange(of: route.customExtensions) { _, value in
            if !isCustomFieldFocused { customExtensions = value.joined(separator: ", ") }
        }
        .onDisappear(perform: commitCustomExtensions)
    }

    private var selectedType: FolderWatchFileType {
        route.fileTypeAllowlist.first ?? .all
    }

    private var typeSummary: String { typeTitle(selectedType) }

    private var destinationSummary: String {
        guard route.action == .basket else { return "直接发送" }
        guard shelfEnabled else { return "文件篮未启用" }
        guard let basketID = route.basketID else { return "最近使用" }
        return baskets.first(where: { $0.id == basketID })?.title ?? "目标已删除"
    }

    private var destinationSystemImage: String {
        route.action == .direct ? "paperplane" : "tray"
    }

    private var typeSystemImage: String {
        switch selectedType {
        case .all: "doc.on.doc"
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        case .document: "doc.text"
        case .archive: "archivebox"
        case .custom: "tag"
        }
    }

    private func typeTitle(_ type: FolderWatchFileType) -> String {
        switch type {
        case .all: "全部文件"
        case .video: "视频"
        case .image: "图片"
        case .audio: "音频"
        case .document: "文档"
        case .archive: "压缩包"
        case .custom: "自定义"
        }
    }

    private func commitCustomExtensions() {
        let normalized = FolderWatchRule.normalizeExtensions(
            customExtensions.split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
                .map(String.init)
        )
        guard normalized != route.customExtensions else { return }
        mutate { $0.customExtensions = normalized }
        customExtensions = normalized.joined(separator: ", ")
    }

    private func mutate(_ mutation: (inout FolderWatchRoute) -> Void) {
        var copy = route
        mutation(&copy)
        update(copy.normalized())
    }
}

private struct FolderWatchRuleRow: View {
    let rule: FolderWatchRule
    let baskets: [ShelfModel]
    let shelfEnabled: Bool
    let isPathUnavailable: Bool
    @Binding var isExpanded: Bool
    let update: (FolderWatchRule) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: rule.enabled ? "folder.fill" : "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(rule.enabled ? Brand.controlAccent : .secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.05)))

                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.folderPath)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(ruleStatusSubtitle)
                        .font(.system(size: 9))
                    .foregroundStyle(rule.enabled ? .tertiary : .secondary)
                }

                Spacer(minLength: 4)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { rule.enabled },
                        set: { enabled in mutate { $0.enabled = enabled } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Brand.controlAccent)
                .accessibilityLabel("启用 \(rule.folderPath) 监控")

                Button {
                    withAnimation(.smooth(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.045)))
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "收起规则" : "展开规则")
                .accessibilityLabel(isExpanded ? "收起规则" : "展开规则")
            }

            if isExpanded {
                ruleDetails
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var ruleDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Label("子文件夹", systemImage: "folder.badge.plus")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Toggle("", isOn: Binding(
                    get: { rule.includesSubfolders },
                    set: { include in mutate { $0.includesSubfolders = include } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Brand.controlAccent)
                .accessibilityLabel("包含子文件夹")
                .accessibilityValue(rule.includesSubfolders ? "开启" : "关闭")

                Spacer(minLength: 6)

                Text("稳定")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("稳定等待", selection: Binding(
                    get: { rule.stabilityDelay },
                    set: { delay in mutate { $0.stabilityDelay = delay } }
                )) {
                    ForEach(FolderWatchStabilityDelay.allCases) { delay in
                        Text(delay.title).tag(delay)
                    }
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 78)
                .help("文件最后一次变化后继续等待，再确认大小与修改时间")
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("文件类型分流")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Button(action: addRoute) {
                    Label("添加分流", systemImage: "plus")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.controlAccent)
                .disabled(nextAvailableType == nil)
            }

            VStack(spacing: 0) {
                ForEach(Array(rule.routes.enumerated()), id: \.element.id) { index, route in
                    if index > 0 {
                        Divider().opacity(0.28).padding(.leading, 22)
                    }
                    FolderWatchRouteRow(
                        index: index,
                        route: route,
                        baskets: baskets,
                        shelfEnabled: shelfEnabled,
                        unavailableTypes: usedTypes(excluding: route.id),
                        canRemove: rule.routes.count > 1,
                        update: { updatedRoute in updateRoute(updatedRoute) },
                        remove: { removeRoute(route.id) }
                    )
                }
            }
            .background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Brand.hairline, lineWidth: 0.7)
            }

            HStack(spacing: 8) {
                Text(rule.includesSubfolders ? "包含所有子目录中的新增文件" : "仅监控当前文件夹")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button(role: .destructive, action: remove) {
                    Label("移除", systemImage: "trash")
                        .font(.system(size: 9.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.danger)
                .help("移除监控规则")
            }
        }
        .padding(.leading, 32)
        .padding(.top, 2)
    }

    private var nextAvailableType: FolderWatchFileType? {
        guard !rule.routes.contains(where: { $0.fileTypeAllowlist.contains(.all) }) else { return nil }
        return FolderWatchFileType.allCases
            .filter { $0 != .all }
            .first { !usedTypes(excluding: nil).contains($0) }
    }

    private func usedTypes(excluding routeID: UUID?) -> Set<FolderWatchFileType> {
        rule.routes
            .filter { $0.id != routeID }
            .reduce(into: Set<FolderWatchFileType>()) { result, route in
                result.formUnion(route.fileTypeAllowlist)
            }
    }

    private func addRoute() {
        guard let type = nextAvailableType else { return }
        mutate { updated in
            updated.routes.append(FolderWatchRoute(
                action: shelfEnabled ? .basket : .direct,
                fileTypeAllowlist: [type]
            ))
        }
    }

    private func updateRoute(_ route: FolderWatchRoute) {
        mutate { updated in
            guard let index = updated.routes.firstIndex(where: { $0.id == route.id }) else { return }
            updated.routes[index] = route
        }
    }

    private func removeRoute(_ id: UUID) {
        mutate { updated in
            guard updated.routes.count > 1 else { return }
            updated.routes.removeAll { $0.id == id }
        }
    }

    private func actionTitle(_ action: FolderWatchAction) -> String {
        switch action {
        case .direct: "直接发送"
        case .basket: "进入文件篮"
        }
    }

    private var ruleStatusSubtitle: String {
        if isPathUnavailable { return "路径不可用" }
        if rule.enabled, rule.routes.allSatisfy({ $0.action == .basket }), !shelfEnabled {
            return "文件篮未启用，规则已暂停"
        }
        return rule.enabled ? "\(rule.routes.count) 条类型分流" : "已暂停"
    }

    private func mutate(_ body: (inout FolderWatchRule) -> Void) {
        var copy = rule
        body(&copy)
        update(copy)
    }
}
