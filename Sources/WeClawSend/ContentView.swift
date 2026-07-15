import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    let chooseFiles: () -> Void
    @State private var isDropHovered = false

    var body: some View {
        Group {
            if model.showsServices {
                ServicesView(model: model)
            } else {
                sendView
            }
        }
        .frame(width: Brand.panelWidth, height: Brand.panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            Brand.name,
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.presentedError ?? "")
        }
    }

    private var sendView: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            dropZone
                .padding(.horizontal, 18)
                .padding(.top, 16)
            transferSectionHeader
                .padding(.top, 18)
            transferList
                .frame(maxHeight: .infinity)
            footer
        }
    }

    // MARK: - Header（仅一处小 Logo）

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 30, cornerRadius: 8)
            Text(Brand.name)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.2)
            Spacer(minLength: 8)
            Text(headerStatusText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            Circle()
                .fill(headerStatusColor)
                .frame(width: 6, height: 6)
            Button {
                model.showsServices = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private var headerStatusText: String {
        if model.hasActiveTransfers { return "发送中" }
        if case .checking = model.weChatStatus { return "连接中" }
        return model.isReady ? "已登录" : "未登录"
    }

    private var headerStatusColor: Color {
        if model.hasActiveTransfers { return Brand.accent }
        if case .checking = model.weChatStatus { return .secondary }
        return model.isReady ? Brand.success : Brand.danger
    }

    // MARK: - Drop zone（无大 Logo，极简线框）

    private var dropZone: some View {
        Button(action: selectFilesFromDropZone) {
            VStack(spacing: 8) {
                Image(systemName: dropZoneSymbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(dropZoneIsHighlighted ? Brand.accent : Color.secondary)
                    .symbolEffect(.pulse, isActive: model.hasActiveTransfers)

                Text(dropZoneTitle)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary)

                Text(dropZoneSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .background(
                RoundedRectangle(cornerRadius: Brand.radiusCard, style: .continuous)
                    .fill(dropZoneBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Brand.radiusCard, style: .continuous)
                    .strokeBorder(
                        dropZoneBorder,
                        style: StrokeStyle(
                            lineWidth: dropZoneIsHighlighted ? 1.25 : 1,
                            dash: dropZoneIsHighlighted ? [] : [5, 4]
                        )
                    )
            }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: Brand.radiusCard, style: .continuous))
        .onHover { isDropHovered = $0 }
        .accessibilityLabel(model.isReady ? "选择或拖入文件发送" : "打开设置登录微信")
        .animation(.easeInOut(duration: 0.15), value: dropZoneIsHighlighted)
        .dropDestination(for: URL.self) { urls, _ in
            model.send(urls: urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted in
            model.isDropTargeted = isTargeted
        }
    }

    private var dropZoneSymbol: String {
        if model.hasActiveTransfers { return "arrow.up.circle" }
        if !model.isReady { return "person.crop.circle" }
        return "square.and.arrow.up"
    }

    private func selectFilesFromDropZone() {
        if model.isReady {
            chooseFiles()
        } else {
            model.showsServices = true
        }
    }

    private var dropZoneIsHighlighted: Bool {
        model.isDropTargeted || isDropHovered
    }

    private var dropZoneBackground: Color {
        dropZoneIsHighlighted ? Color.primary.opacity(0.04) : Color.clear
    }

    private var dropZoneBorder: Color {
        dropZoneIsHighlighted ? Brand.accent.opacity(0.55) : Color.primary.opacity(0.12)
    }

    private var dropZoneTitle: String {
        if model.hasActiveTransfers { return "正在发送 \(model.activeTransferCount) 个文件" }
        if case .checking = model.weChatStatus { return "正在连接微信" }
        return model.isReady ? "拖入或点击选择文件" : "请先登录微信"
    }

    private var dropZoneSubtitle: String {
        if model.hasActiveTransfers { return "可继续添加文件" }
        if case .checking = model.weChatStatus { return "请稍候" }
        return model.isReady ? "支持多选" : "点击前往设置扫码"
    }

    // MARK: - Transfers

    private var transferSectionHeader: some View {
        HStack {
            Text("最近传输")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer()
            if model.recentTransfers.contains(where: \.isTerminal) {
                Button("清空") {
                    model.clearFinishedTransfers()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 24)
    }

    @ViewBuilder
    private var transferList: some View {
        if model.recentTransfers.isEmpty {
            VStack(spacing: 6) {
                Text("暂无记录")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(model.isReady ? "发送后会显示在这里" : "登录后即可发送")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 12)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.recentTransfers.enumerated()), id: \.element.id) { index, transfer in
                        Button {
                            model.revealTransfer(transfer)
                        } label: {
                            transferRow(transfer)
                        }
                        .buttonStyle(.plain)
                        .help(transfer.message ?? "在 Finder 中显示")

                        if index < model.recentTransfers.count - 1 {
                            Divider()
                                .padding(.leading, 48)
                                .opacity(0.4)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }
        }
    }

    private func transferRow(_ transfer: TransferRecord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            FileTypeIcon(fileName: transfer.fileName)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(transfer.fileName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(transferStatusText(transfer))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(transferStatusColor(transfer))
                }

                if transfer.status == .sending {
                    ProgressView(value: transfer.progress ?? 0)
                        .progressViewStyle(.linear)
                        .tint(Brand.accent)
                    Text(progressDetail(transfer))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if transfer.status == .queued {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Brand.accent)
                } else {
                    HStack(spacing: 5) {
                        Text(formatBytes(transfer.byteCount))
                        Text("·")
                        Text(relativeTime(transfer.date))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                    if transfer.status == .failed, let message = transfer.message, !message.isEmpty {
                        Text(message)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Brand.danger)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func transferStatusText(_ transfer: TransferRecord) -> String {
        switch transfer.status {
        case .queued: "排队"
        case .sending: "\(Int((transfer.progress ?? 0) * 100))%"
        case .sent: "完成"
        case .failed: "失败"
        }
    }

    private func transferStatusColor(_ transfer: TransferRecord) -> Color {
        switch transfer.status {
        case .queued: .secondary
        case .sending: .primary
        case .sent: Brand.success
        case .failed: Brand.danger
        }
    }

    private func progressDetail(_ transfer: TransferRecord) -> String {
        let stage: String
        switch transfer.stage {
        case .preparing: stage = "准备"
        case .encrypting: stage = "加密"
        case .uploading: stage = "上传"
        case .sending: stage = "提交"
        case .finished: stage = "完成"
        case nil: stage = "发送中"
        }
        if let sent = transfer.sentBytes, sent > 0 {
            return "\(stage) · \(formatBytes(sent)) / \(formatBytes(transfer.byteCount))"
        }
        return "\(stage) · \(formatBytes(transfer.byteCount))"
    }

    private var footer: some View {
        HStack(spacing: 0) {
            if !model.isReady {
                Button("登录微信") {
                    model.showsServices = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            } else {
                Text(model.hasActiveTransfers ? "发送中" : "就绪")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 36)
    }
}

// MARK: - File icons（低饱和）

private struct FileTypeIcon: View {
    private let kind: FileKind

    init(fileName: String) {
        kind = FileKind(fileName: fileName)
    }

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .accessibilityHidden(true)
    }
}

private enum FileKind {
    case video, audio, image, archive, document, code, generic

    init(fileName: String) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "m4v", "mp4", "mov", "webm", "mkv", "avi": self = .video
        case "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg": self = .audio
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg", "psd", "ai": self = .image
        case "zip", "rar", "7z", "tar", "gz": self = .archive
        case "pdf", "doc", "docx", "pages", "txt", "md", "xls", "xlsx", "ppt", "pptx": self = .document
        case "swift", "js", "ts", "py", "go", "rs", "json", "html", "css", "sh": self = .code
        default: self = .generic
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .archive: "archivebox"
        case .document: "doc"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .generic: "doc"
        }
    }
}

private func relativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    formatter.locale = Locale(identifier: "zh_CN")
    return formatter.localizedString(for: date, relativeTo: Date())
}

func formatBytes(_ byteCount: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
}
