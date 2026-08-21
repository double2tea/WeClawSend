import SwiftUI

/// 文件夹监控设置卡。
///
/// 视图只负责展示和编辑状态，文件选择、规则持久化以及监控服务由外部回调处理。
/// 这样设置页可以在不依赖 AppModel 的情况下复用，也方便单独测试规则编辑。
struct FolderWatchSettingsView: View {
    @ObservedObject var store: FolderWatchStore

    let baskets: [ShelfModel]
    let addFolders: () -> Void
    let update: (FolderWatchRule) -> Void
    let remove: (UUID) -> Void

    @State private var expandedRules: Set<UUID> = []
    @AppStorage(AppSettings.folderWatchEnabledKey) private var monitoringEnabled = false

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
                        Text(monitoringEnabled ? "新文件完成后自动处理" : "已暂停所有监控规则")
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
                    Text("文件稳定约 3–6 秒后处理")
                }
                .font(.system(size: 9.5, weight: .medium))
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
        if let message = record.message, !message.isEmpty {
            return message
        }
        return record.discoveredAt.formatted(date: .omitted, time: .shortened)
    }
}

private struct FolderWatchRuleRow: View {
    let rule: FolderWatchRule
    let baskets: [ShelfModel]
    @Binding var isExpanded: Bool
    let update: (FolderWatchRule) -> Void
    let remove: () -> Void

    @State private var customExtensions = ""

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
                    Text(rule.enabled ? actionTitle(rule.action) : "已暂停")
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
        .onAppear {
            customExtensions = rule.customExtensions.joined(separator: ", ")
        }
        .onChange(of: rule.id) { _, _ in
            customExtensions = rule.customExtensions.joined(separator: ", ")
        }
    }

    private var ruleDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("包含子文件夹")
                    .font(.system(size: 10.5, weight: .medium))
                Spacer(minLength: 6)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { rule.includesSubfolders },
                        set: { include in mutate { $0.includesSubfolders = include } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Brand.controlAccent)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("处理方式")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)

                Picker("处理方式", selection: Binding(
                    get: { rule.action },
                    set: { action in mutate { $0.action = action } }
                )) {
                    ForEach(FolderWatchAction.allCases) { action in
                        Text(actionTitle(action)).tag(action)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if rule.action == .basket {
                HStack(spacing: 8) {
                    Text("目标文件篮")
                        .font(.system(size: 10.5, weight: .medium))
                    Spacer(minLength: 6)
                    Picker("目标文件篮", selection: Binding(
                        get: { rule.basketID },
                        set: { basketID in mutate { $0.basketID = basketID } }
                    )) {
                        Text("最近使用").tag(UUID?.none)
                        ForEach(baskets, id: \.id) { basket in
                            Text(basket.title).tag(Optional(basket.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 130)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("仅处理这些类型")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)],
                    spacing: 5
                ) {
                    ForEach(FolderWatchFileType.allCases) { type in
                        typeChip(type)
                    }
                }

                if rule.fileTypeAllowlist.contains(.custom) {
                    TextField("扩展名，例如 mp4, mov, pdf", text: $customExtensions)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                        .onSubmit(commitCustomExtensions)
                        .onChange(of: customExtensions) { _, value in
                            guard value.last == "," || value.last == " " else { return }
                            commitCustomExtensions()
                        }
                }
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

    private func typeChip(_ type: FolderWatchFileType) -> some View {
        let isSelected = rule.fileTypeAllowlist.contains(type)
        return Button {
            mutate { updated in
                if type == .all {
                    updated.fileTypeAllowlist = [.all]
                } else {
                    updated.fileTypeAllowlist.remove(.all)
                    if isSelected {
                        updated.fileTypeAllowlist.remove(type)
                    } else {
                        updated.fileTypeAllowlist.insert(type)
                    }
                    if updated.fileTypeAllowlist.isEmpty {
                        updated.fileTypeAllowlist = [.all]
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9, weight: .semibold))
                Text(typeTitle(type))
                    .font(.system(size: 9.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Brand.accent : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 25)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Brand.controlAccent.opacity(0.13) : Color.primary.opacity(0.035))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? Brand.controlAccent.opacity(0.28) : Brand.hairline, lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("文件类型：\(typeTitle(type))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func commitCustomExtensions() {
        let normalized = customExtensions
            .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
            .map { token in
                let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return trimmed.lowercased()
            }
            .filter { !$0.isEmpty }
        guard normalized != rule.customExtensions else { return }
        mutate { $0.customExtensions = normalized }
        customExtensions = normalized.joined(separator: ", ")
    }

    private func actionTitle(_ action: FolderWatchAction) -> String {
        switch action {
        case .direct: "直接发送"
        case .basket: "进入文件篮"
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

    private func mutate(_ body: (inout FolderWatchRule) -> Void) {
        var copy = rule
        body(&copy)
        update(copy)
    }
}
