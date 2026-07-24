import AppKit
import SwiftUI

struct ShelfView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AppModel
    @ObservedObject var shelf: ShelfModel
    @ObservedObject var session: ShelfSessionState

    let chooseFiles: () -> Void
    let sendAll: () -> Void
    let close: () -> Void
    let deleteBasket: () -> Void
    let sendZIP: (String) -> Void
    let copyPaths: () -> Void
    let revealAll: () -> Void
    let toggleCollapsed: () -> Void
    let toggleAlwaysOnTop: () -> Void
    let quickLook: (ShelfItem) -> Void
    let revealInFinder: (ShelfItem) -> Void

    @State private var isDropTargeted = false
    @State private var hoveredItemID: UUID?
    @State private var showsDeleteConfirmation = false
    @State private var showsZIPNaming = false
    @State private var zipName = ""

    private let cornerRadius: CGFloat = 14

    var body: some View {
        shelfChrome
            .frame(
                width: session.isCollapsed ? 248 : 276,
                height: session.isCollapsed ? 52 : 292,
                alignment: .top
            )
            .background(shelfBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(shelfBorder)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .dropDestination(for: URL.self, action: handleDrop, isTargeted: setDropTargeted)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.32, extraBounce: 0),
                value: session.isCollapsed
            )
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.2, extraBounce: 0),
                value: session.statusMessage
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(shelf.title)
            .help("拖入文件到文件篮；点选后空格预览，可拖出到其他 App")
            .alert("删除\(shelf.title)？", isPresented: $showsDeleteConfirmation) {
                Button("删除", role: .destructive, action: deleteBasket)
                Button("取消", role: .cancel) {}
            } message: {
                Text("将移除篮内 \(shelf.items.count) 个文件引用，不会删除原文件。")
            }
            .alert("压缩并发送", isPresented: $showsZIPNaming) {
                TextField("压缩包名称", text: $zipName)
                Button("压缩并发送") {
                    sendZIP(zipName)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(FileBasketArchiver.normalizedArchiveName(zipName) == nil)
                Button("取消", role: .cancel) {}
            } message: {
                Text("确认后立即压缩并发送；名称不能包含 / 或 :，也不会清空当前文件篮。")
            }
    }

    @ViewBuilder
    private var shelfChrome: some View {
        ZStack(alignment: .bottom) {
            Group {
                if session.isCollapsed {
                    collapsedChrome
                } else {
                    expandedChrome
                }
            }
            .transition(chromeTransition)

            if let status = session.statusMessage {
                toast(status)
                    .padding(.bottom, session.isCollapsed ? 8 : 46)
                    .transition(toastTransition)
            }
        }
    }

    private var shelfBackground: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.42))
            }
    }

    private var shelfBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(
                isDropTargeted ? Brand.accent.opacity(0.48) : Brand.hairline,
                lineWidth: isDropTargeted ? 1.2 : 0.8
            )
    }

    // MARK: - Collapsed

    private var collapsedChrome: some View {
        HStack(spacing: 10) {
            stackGlyph
                .frame(width: 34, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(collapsedTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(collapsedSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 2)

            chromeButton("展开", systemImage: "chevron.down", action: toggleCollapsed)
            chromeButton("关闭", systemImage: "xmark", action: close)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleCollapsed)
        .accessibilityLabel(shelf.items.isEmpty ? "\(shelf.title)为空，点击展开" : "\(shelf.title)中有 \(shelf.items.count) 个文件，点击展开")
        .accessibilityAddTraits(.isButton)
    }

    private var collapsedTitle: String {
        shelf.title
    }

    private var collapsedSubtitle: String {
        if isDropTargeted { return "松开以加入" }
        guard let firstName = shelf.items.first?.fileName else { return "拖入或点击展开" }
        return "\(shelf.items.count) 个文件 · \(firstName)"
    }

    private var stackGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(width: 26, height: 20)
                .rotationEffect(.degrees(-7))
                .offset(x: -4, y: 2)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 26, height: 20)
                .rotationEffect(.degrees(4))
                .offset(x: 3, y: 1)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.1))
                .frame(width: 26, height: 20)
            Image(systemName: shelf.items.isEmpty ? "tray" : "doc.on.doc.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isDropTargeted ? Brand.accent : Color.secondary)
        }
    }

    // MARK: - Expanded

    private var expandedChrome: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.22)
            bodyContent
            Divider().opacity(0.22)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            chromeButton("关闭文件篮", systemImage: "xmark", action: close)
            Spacer(minLength: 2)
            titleBadge
            Spacer(minLength: 2)
            chromeButton(
                session.isAlwaysOnTop ? "取消置顶" : "置顶",
                systemImage: session.isAlwaysOnTop ? "pin.fill" : "pin",
                emphasized: session.isAlwaysOnTop,
                action: toggleAlwaysOnTop
            )
            chromeButton("折叠", systemImage: "chevron.up", action: toggleCollapsed)
            basketActionsMenu
            chromeButton("添加文件", systemImage: "plus", action: chooseFiles)
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
    }

    private var titleBadge: some View {
        HStack(spacing: 5) {
            Text(shelf.title)
                .font(.system(size: 11.5, weight: .semibold))
            if !shelf.items.isEmpty {
                Text("\(shelf.items.count)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
        }
    }

    private var basketActionsMenu: some View {
        Menu {
            Button {
                zipName = "\(shelf.title).zip"
                showsZIPNaming = true
            } label: {
                Label("压缩为 ZIP 并发送", systemImage: "archivebox")
            }
            .disabled(shelf.items.isEmpty || !model.isReady)
            Button(action: copyPaths) {
                Label("复制全部文件路径", systemImage: "doc.on.doc")
            }
            .disabled(shelf.items.isEmpty)
            Button(action: revealAll) {
                Label("在 Finder 中显示全部", systemImage: "folder")
            }
            .disabled(shelf.items.isEmpty)
            Divider()
            Button("清空文件", role: .destructive, action: clearBasket)
                .disabled(shelf.items.isEmpty)
            Divider()
            Button(shelf.items.isEmpty ? "删除文件篮" : "删除文件篮…", role: .destructive) {
                if shelf.items.isEmpty {
                    deleteBasket()
                } else {
                    showsDeleteConfirmation = true
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.05)))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多文件篮操作")
        .accessibilityLabel("更多文件篮操作")
    }

    @ViewBuilder
    private var bodyContent: some View {
        if shelf.items.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        } else {
            itemList
        }
    }

    private var itemList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(shelf.items) { item in
                        ShelfItemRow(
                            item: item,
                            isSelected: session.selectedItemID == item.id,
                            isHovered: hoveredItemID == item.id,
                            onHover: { hovering in
                                hoveredItemID = hovering ? item.id : (hoveredItemID == item.id ? nil : hoveredItemID)
                            },
                            onSelect: {
                                session.select(item.id)
                            },
                            onPreview: {
                                session.select(item.id)
                                quickLook(item)
                            },
                            onRemove: { remove(item) },
                            onReveal: { revealInFinder(item) }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: session.selectedItemID) { _, newID in
                guard let newID else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.2, extraBounce: 0)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        Button(action: chooseFiles) {
            VStack(spacing: 8) {
                Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "tray.and.arrow.down")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(isDropTargeted ? Brand.accent : Color.secondary)
                    .symbolEffect(.pulse, isActive: isDropTargeted && !reduceMotion)

                VStack(spacing: 3) {
                    Text(isDropTargeted ? "松开以加入" : "拖入文件到文件篮")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("空格预览 · 仅保存引用")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isDropTargeted ? Color.primary.opacity(0.04) : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Brand.accent.opacity(0.4) : Color.primary.opacity(0.1),
                        style: StrokeStyle(lineWidth: 1, dash: isDropTargeted ? [] : [3.5, 2.5])
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择或拖入文件加入\(shelf.title)")
    }

    private func toast(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Brand.hairline, lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .allowsHitTesting(false)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("清空") {
                clearBasket()
            }
            .buttonStyle(ShelfPressButtonStyle(scale: 0.97))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(shelf.items.isEmpty ? Color.secondary.opacity(0.4) : Brand.danger.opacity(0.88))
            .disabled(shelf.items.isEmpty)

            Spacer(minLength: 4)

            Button(action: sendAll) {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(sendButtonTitle)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(sendEnabled ? Color.white : Color.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(
                    Capsule(style: .continuous)
                        .fill(sendEnabled ? Brand.action : Color.primary.opacity(0.07))
                )
            }
            .buttonStyle(ShelfPressButtonStyle(scale: 0.97))
            .disabled(!sendEnabled)
            .help(model.isReady ? "发送当前文件篮内全部文件" : "请先登录微信")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    private var sendEnabled: Bool {
        model.isReady && !shelf.items.isEmpty
    }

    private var sendButtonTitle: String {
        if !model.isReady { return "未登录" }
        if shelf.items.isEmpty { return "发送" }
        return "发送 \(shelf.items.count)"
    }

    // MARK: - Controls

    private func clearBasket() {
        shelf.clear()
        session.select(nil)
        session.flash("已清空")
    }

    private func chromeButton(
        _ title: String,
        systemImage: String,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(emphasized ? Brand.accent : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(Color.primary.opacity(emphasized ? 0.1 : 0.05))
                )
                .contentShape(Circle())
        }
        .buttonStyle(ShelfPressButtonStyle())
        .help(title)
        .accessibilityLabel(title)
    }

    private func remove(_ item: ShelfItem) {
        let items = shelf.items
        let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
        shelf.remove(id: item.id)
        let remaining = shelf.items
        if remaining.isEmpty {
            session.select(nil)
        } else if session.selectedItemID == item.id {
            session.select(remaining[min(index, remaining.count - 1)].id)
        }
    }

    private func setDropTargeted(_ targeted: Bool) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.18, extraBounce: 0)) {
            isDropTargeted = targeted
        }
    }

    private var chromeTransition: AnyTransition {
        .opacity
    }

    private var toastTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
    }

    @discardableResult
    private func handleDrop(_ urls: [URL], _: CGPoint) -> Bool {
        let files = urls.filter { url in
            guard url.isFileURL else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
        let added = shelf.add(urls: files)
        if added > 0 {
            if session.isCollapsed {
                toggleCollapsed()
            }
            if let last = shelf.items.last {
                session.select(last.id)
            }
            session.flash(added == 1 ? "已加入 1 个" : "已加入 \(added) 个")
            return true
        }
        if !files.isEmpty {
            session.flash("已在文件篮中")
        } else if !urls.isEmpty {
            session.flash("仅支持普通文件")
        }
        return false
    }
}

private struct ShelfPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.16, extraBounce: 0),
                value: configuration.isPressed
            )
    }
}

// MARK: - Row

private struct ShelfItemRow: View {
    let item: ShelfItem
    let isSelected: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onRemove: () -> Void
    let onReveal: () -> Void

    var body: some View {
        rowContent
            .help("\(item.path)\n空格预览 · ↑↓ 选择 · ⌫ 移除")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.fileName)，\(formatBytes(fileSize))")
            .accessibilityValue(isSelected ? "已选中" : "")
            .accessibilityHint("可快速预览、在 Finder 中显示、移除或拖出到其他应用")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction(named: "快速预览", onPreview)
            .accessibilityAction(named: "在 Finder 中显示", onReveal)
            .accessibilityAction(named: "移除", onRemove)
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            FilePreviewIcon(url: item.url, size: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.fileName)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(formatBytes(fileSize))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            if isHovered || isSelected {
                rowAction("预览", systemImage: "eye", action: onPreview)
                rowAction("移除", systemImage: "xmark", action: onRemove)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Brand.accent.opacity(0.22) : Color.clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover(perform: onHover)
        .simultaneousGesture(
            TapGesture().onEnded(onSelect)
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded(onPreview)
        )
        .onDrag {
            onSelect()
            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.url as NSURL)
        }
        .contextMenu {
            Button("快速预览", action: onPreview)
            Button("在 Finder 中显示", action: onReveal)
            Divider()
            Button("移除", role: .destructive, action: onRemove)
        }
    }

    private var backgroundColor: Color {
        if isSelected { return Color.primary.opacity(0.08) }
        if isHovered { return Color.primary.opacity(0.045) }
        return .clear
    }

    private var fileSize: Int64 {
        ShelfItemPresentationCache.fileSize(for: item.url)
    }

    private func rowAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(ShelfPressButtonStyle())
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct FilePreviewIcon: View {
    let url: URL
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var icon: NSImage {
        ShelfItemPresentationCache.icon(for: url, size: size)
    }
}

@MainActor
private enum ShelfItemPresentationCache {
    private static let fileSizes = NSCache<NSString, NSNumber>()
    private static let icons = NSCache<NSString, NSImage>()

    static func fileSize(for url: URL) -> Int64 {
        let key = url.path as NSString
        if let cached = fileSizes.object(forKey: key) {
            return cached.int64Value
        }
        let value = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        fileSizes.setObject(NSNumber(value: value), forKey: key)
        return value
    }

    static func icon(for url: URL, size: CGFloat) -> NSImage {
        let key = "\(url.path)#\(size)" as NSString
        if let cached = icons.object(forKey: key) {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: size, height: size)
        icons.setObject(image, forKey: key)
        return image
    }
}
