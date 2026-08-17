import AppKit
import QuickLookThumbnailing
import SwiftUI

enum ShelfShareDestination {
    case airDrop
    case mail
    case messages

    var serviceName: NSSharingService.Name {
        switch self {
        case .airDrop: .sendViaAirDrop
        case .mail: .composeEmail
        case .messages: .composeMessage
        }
    }

    var title: String {
        switch self {
        case .airDrop: "隔空投送"
        case .mail: "邮件"
        case .messages: "信息"
        }
    }

    var systemImage: String {
        switch self {
        case .airDrop: "airdrop"
        case .mail: "envelope"
        case .messages: "message"
        }
    }
}

struct ShelfView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AppModel
    @ObservedObject var shelf: ShelfModel
    @ObservedObject var session: ShelfSessionState

    let chooseFiles: () -> Void
    let sendAll: () -> Void
    let scheduleAll: (Int) -> Void
    let close: () -> Void
    let deleteBasket: () -> Void
    let sendZIP: (String) -> Void
    let scheduleZIP: (String, Int) -> Void
    let copyFiles: ([ShelfItem]) -> Void
    let shareFiles: ([ShelfItem], ShelfShareDestination) -> Void
    let copyPaths: () -> Void
    let revealAll: () -> Void
    let toggleCollapsed: () -> Void
    let toggleAlwaysOnTop: () -> Void
    let pointerPresenceChanged: (Bool) -> Void
    let quickLook: (ShelfItem) -> Void
    let revealInFinder: (ShelfItem) -> Void

    @State private var isDropTargeted = false
    @State private var hoveredItemID: UUID?
    @State private var showsDeleteConfirmation = false
    @State private var showsZIPNaming = false
    @State private var showsTimingPicker = false
    @State private var showsCustomDelayPicker = false
    @State private var pendingZIPScheduleDelaySeconds: Int?
    @State private var zipName = ""
    @State private var hoveredChromeButton: String?
    @State private var isTitleHovered = false
    @State private var isActionsMenuHovered = false
    @State private var itemFrames: [UUID: CGRect] = [:]
    @State private var marqueeRect: CGRect?
    @State private var marqueeBaseSelection: Set<UUID> = []
    @State private var ignoresMarqueeDrag = false

    private let cornerRadius: CGFloat = 14
    private let itemListCoordinateSpace = "ShelfItemList"

    var body: some View {
        shelfChrome
            .frame(
                width: session.isCollapsed ? 248 : 340,
                height: session.isCollapsed ? 52 : 340,
                alignment: .top
            )
            .background(shelfBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(shelfBorder)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .dropDestination(for: URL.self, action: handleDrop, isTargeted: setDropTargeted)
            .onHover(perform: pointerPresenceChanged)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.2, extraBounce: 0),
                value: session.statusMessage
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(shelf.title)
            .help("拖入文件或文件夹；空白处拖框或按 ⌘A 多选，选中后可拖出到其他 App")
            .alert("删除\(shelf.title)？", isPresented: $showsDeleteConfirmation) {
                Button("删除", role: .destructive, action: deleteBasket)
                Button("取消", role: .cancel) {}
            } message: {
                Text("将移除篮内 \(shelf.items.count) 个项目引用，不会删除原内容。")
            }
            .alert(zipAlertTitle, isPresented: $showsZIPNaming) {
                TextField("压缩包名称", text: $zipName)
                Button(zipConfirmationTitle) {
                    if let delaySeconds = pendingZIPScheduleDelaySeconds {
                        scheduleZIP(zipName, delaySeconds)
                    } else {
                        sendZIP(zipName)
                    }
                    pendingZIPScheduleDelaySeconds = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(FileBasketArchiver.normalizedArchiveName(zipName) == nil)
                Button("取消", role: .cancel) {
                    pendingZIPScheduleDelaySeconds = nil
                }
            } message: {
                Text(zipAlertMessage)
            }
            .sheet(isPresented: $showsTimingPicker) {
                ScheduledSendTimingPicker(
                    itemDescription: scheduledItemDescription,
                    previewURLs: shelf.urls,
                    canSendImmediately: model.isReady,
                    initialDelaySeconds: model.sendDefaultDelaySeconds,
                    cancel: { showsTimingPicker = false },
                    sendImmediately: sendCurrentItemsImmediately,
                    schedule: scheduleCurrentItems(afterDelay:)
                )
                .frame(width: 340)
            }
            .sheet(isPresented: $showsCustomDelayPicker) {
                ScheduledSendCustomDelayPicker(itemDescription: scheduledItemDescription) { seconds in
                    scheduleCurrentItems(afterDelay: seconds)
                }
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

            if session.isCollapsed, let status = session.statusMessage {
                toast(status)
                    .padding(.bottom, 8)
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
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleCollapsed)

            Spacer(minLength: 2)

            chromeButton("展开", systemImage: "chevron.down", action: toggleCollapsed)
            chromeButton("关闭", systemImage: "xmark", action: close)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragHandle())
        .accessibilityLabel(shelf.items.isEmpty ? "\(shelf.title)为空，点击展开" : "\(shelf.title)中有 \(shelf.items.count) 个项目，点击展开")
    }

    private var collapsedTitle: String {
        shelf.title
    }

    private var collapsedSubtitle: String {
        if isDropTargeted { return "松开以加入" }
        guard let firstName = shelf.items.first?.fileName else { return "拖入或点击展开" }
        return "\(shelf.items.count) 个项目 · \(firstName)"
    }

    private var stackGlyph: some View {
        ZStack {
            if shelf.items.isEmpty {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 28, height: 22)
                Image(systemName: "tray")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isDropTargeted ? Brand.accent : Color.secondary)
            } else {
                ForEach(Array(shelf.items.prefix(3).enumerated()), id: \.element.id) { index, item in
                    FileThumbnailView(
                        url: item.url,
                        width: 28,
                        height: 22,
                        cornerRadius: 4
                    )
                    .rotationEffect(.degrees(stackRotation(at: index)))
                    .offset(x: stackOffset(at: index).x, y: stackOffset(at: index).y)
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                }
            }
        }
    }

    private func stackRotation(at index: Int) -> Double {
        [-8, 6, 0][min(index, 2)]
    }

    private func stackOffset(at index: Int) -> CGPoint {
        [CGPoint(x: -4, y: 2), CGPoint(x: 4, y: 1), .zero][min(index, 2)]
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
        HStack(spacing: 8) {
            chromeButton("关闭文件篮", systemImage: "xmark", action: close)
            titleControl
            Spacer(minLength: 12)

            HStack(spacing: 3) {
                displayModeControl
                chromeButton(
                    session.isAlwaysOnTop ? "取消置顶" : "置顶",
                    systemImage: session.isAlwaysOnTop ? "pin.fill" : "pin",
                    emphasized: session.isAlwaysOnTop,
                    action: toggleAlwaysOnTop
                )
                basketActionsMenu
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 52)
        .background {
            WindowDragHandle()
                .overlay(Color.primary.opacity(0.012))
        }
    }

    private var titleControl: some View {
        Button(action: toggleCollapsed) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(shelf.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                Text(basketSummary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .frame(height: 34)
            .contentShape(Rectangle())
            .opacity(isTitleHovered ? 0.72 : 1)
        }
        .buttonStyle(ShelfPressButtonStyle(scale: 0.985))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isTitleHovered = hovering
            }
        }
        .help("折叠文件篮")
        .accessibilityLabel("折叠\(shelf.title)")
    }

    private var displayModeControl: some View {
        HStack(spacing: 0) {
            displayModeButton(.grid, title: "网格视图", systemImage: "square.grid.2x2")
            displayModeButton(.list, title: "列表视图", systemImage: "list.bullet")
        }
        .padding(2)
        .background(Color.primary.opacity(0.045), in: Capsule(style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文件篮显示方式")
    }

    private func displayModeButton(
        _ mode: ShelfDisplayMode,
        title: String,
        systemImage: String
    ) -> some View {
        Button {
            session.displayMode = mode
            itemFrames = [:]
            marqueeRect = nil
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(session.displayMode == mode ? Color.primary : Color.secondary)
                .frame(width: 25, height: 24)
                .background(
                    Capsule(style: .continuous)
                        .fill(session.displayMode == mode ? Color.primary.opacity(0.09) : Color.clear)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(ShelfPressButtonStyle())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(session.displayMode == mode ? .isSelected : [])
    }

    private var basketSummary: String {
        guard !shelf.items.isEmpty else { return "拖入文件或文件夹" }
        let fileBytes = shelf.items.reduce(Int64.zero) { total, item in
            guard item.kind == .file else { return total }
            return total + ShelfItemPresentationCache.fileSize(for: item.url)
        }
        let count = "\(shelf.items.count) 个项目"
        return fileBytes > 0 ? "\(count) · \(formatBytes(fileBytes))" : count
    }

    private var basketActionsMenu: some View {
        Menu {
            Button(action: chooseFiles) {
                Label("添加文件或文件夹…", systemImage: "plus")
            }
            Divider()
            basketShareButton(.airDrop)
            basketShareButton(.mail)
            basketShareButton(.messages)
            Divider()
            Button {
                presentZIPNaming()
            } label: {
                Label("压缩为 ZIP 并发送", systemImage: "archivebox")
            }
            .disabled(shelf.items.isEmpty || !model.isReady)
            Button {
                copyFiles(shelf.items)
            } label: {
                Label("复制全部项目", systemImage: "doc.on.doc.fill")
            }
            .disabled(shelf.items.isEmpty)
            Button(action: copyPaths) {
                Label("复制全部项目路径", systemImage: "text.alignleft")
            }
            .disabled(shelf.items.isEmpty)
            Button(action: revealAll) {
                Label("在 Finder 中显示全部", systemImage: "folder")
            }
            .disabled(shelf.items.isEmpty)
            Divider()
            Button("清空内容", role: .destructive, action: clearBasket)
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
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isActionsMenuHovered ? 0.075 : 0))
                )
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isActionsMenuHovered = hovering
            }
        }
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
                Group {
                    if session.displayMode == .grid {
                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 92, maximum: 104), spacing: 8),
                            ],
                            spacing: 8
                        ) {
                            ForEach(shelf.items) { item in
                                trackedCollectionItem(item)
                            }
                        }
                    } else {
                        LazyVStack(spacing: 3) {
                            ForEach(shelf.items) { item in
                                trackedCollectionItem(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: itemListCoordinateSpace)
            .onPreferenceChange(ShelfItemFramePreferenceKey.self) { frames in
                itemFrames = frames
            }
            .overlay(alignment: .topLeading) {
                if let marqueeRect {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Brand.controlAccent.opacity(0.1))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Brand.controlAccent.opacity(0.72), lineWidth: 1)
                        }
                        .frame(width: marqueeRect.width, height: marqueeRect.height)
                        .offset(x: marqueeRect.minX, y: marqueeRect.minY)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .simultaneousGesture(marqueeSelectionGesture)
            .onChange(of: session.selectedItemID) { _, newID in
                guard marqueeRect == nil, let newID else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.2, extraBounce: 0)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func trackedCollectionItem(_ item: ShelfItem) -> some View {
        collectionItem(item)
            .id(item.id)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ShelfItemFramePreferenceKey.self,
                        value: [
                            item.id: geometry.frame(
                                in: .named(itemListCoordinateSpace)
                            ),
                        ]
                    )
                }
            }
    }

    @ViewBuilder
    private func collectionItem(_ item: ShelfItem) -> some View {
        let isSelected = session.selectedItemIDs.contains(item.id)
        if session.displayMode == .grid {
            ShelfItemTile(
                item: item,
                isSelected: isSelected,
                selectedCount: session.selectedItemIDs.count,
                isHovered: hoveredItemID == item.id,
                onHover: { hovering in updateHoveredItem(item.id, hovering: hovering) },
                onSelect: { extending, toggling in select(item, extending: extending, toggling: toggling) },
                dragItems: { session.dragItems(startingAt: item.id, in: shelf.items) },
                onPreview: { preview(item) },
                onCopy: { copy(item) },
                onShare: { destination in share(item, via: destination) },
                onRemove: { remove(item) },
                onReveal: { revealInFinder(item) }
            )
        } else {
            ShelfItemRow(
                item: item,
                isSelected: isSelected,
                selectedCount: session.selectedItemIDs.count,
                isHovered: hoveredItemID == item.id,
                onHover: { hovering in updateHoveredItem(item.id, hovering: hovering) },
                onSelect: { extending, toggling in select(item, extending: extending, toggling: toggling) },
                dragItems: { session.dragItems(startingAt: item.id, in: shelf.items) },
                onPreview: { preview(item) },
                onCopy: { copy(item) },
                onShare: { destination in share(item, via: destination) },
                onRemove: { remove(item) },
                onReveal: { revealInFinder(item) }
            )
        }
    }

    private func updateHoveredItem(_ id: UUID, hovering: Bool) {
        hoveredItemID = hovering ? id : (hoveredItemID == id ? nil : hoveredItemID)
    }

    private func select(_ item: ShelfItem, extending: Bool, toggling: Bool) {
        session.select(
            item.id,
            in: shelf.items,
            extending: extending,
            toggling: toggling
        )
    }

    private func preview(_ item: ShelfItem) {
        session.select(item.id)
        quickLook(item)
    }

    private func copy(_ item: ShelfItem) {
        copyFiles(actionItems(for: item))
    }

    private func share(_ item: ShelfItem, via destination: ShelfShareDestination) {
        shareFiles(actionItems(for: item), destination)
    }

    private func basketShareButton(_ destination: ShelfShareDestination) -> some View {
        Button {
            shareFiles(session.selectedItems(in: shelf.items), destination)
        } label: {
            Label("\(destination.title)所选项目", systemImage: destination.systemImage)
        }
        .disabled(shelf.items.isEmpty || session.selectedItemIDs.isEmpty)
    }

    private func actionItems(for item: ShelfItem) -> [ShelfItem] {
        guard session.selectedItemIDs.contains(item.id) else {
            session.select(item.id)
            return [item]
        }
        return session.selectedItems(in: shelf.items)
    }

    private var marqueeSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(itemListCoordinateSpace))
            .onChanged(updateMarqueeSelection)
            .onEnded { _ in
                marqueeRect = nil
                marqueeBaseSelection = []
                ignoresMarqueeDrag = false
            }
    }

    private func updateMarqueeSelection(_ value: DragGesture.Value) {
        if marqueeRect == nil {
            guard !itemFrames.isEmpty else {
                ignoresMarqueeDrag = true
                return
            }
            if itemFrames.values.contains(where: { $0.contains(value.startLocation) }) {
                ignoresMarqueeDrag = true
                return
            }
            let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            marqueeBaseSelection = modifiers.contains(.command) || modifiers.contains(.shift)
                ? session.selectedItemIDs
                : []
        }
        guard !ignoresMarqueeDrag else { return }

        let rect = CGRect(
            x: min(value.startLocation.x, value.location.x),
            y: min(value.startLocation.y, value.location.y),
            width: abs(value.location.x - value.startLocation.x),
            height: abs(value.location.y - value.startLocation.y)
        )
        marqueeRect = rect
        let enclosedIDs = ShelfMarqueeSelection.intersectingItemIDs(
            in: rect,
            itemFrames: itemFrames
        )
        session.setSelection(marqueeBaseSelection.union(enclosedIDs), in: shelf.items)
    }

    private var emptyState: some View {
        Button(action: chooseFiles) {
            VStack(spacing: 8) {
                Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "tray.and.arrow.down")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(isDropTargeted ? Brand.accent : Color.secondary)
                    .symbolEffect(.pulse, isActive: isDropTargeted && !reduceMotion)

                VStack(spacing: 3) {
                    Text(isDropTargeted ? "松开以加入" : "拖入文件或文件夹")
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
        .accessibilityLabel("选择或拖入文件或文件夹加入\(shelf.title)")
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
            if let status = session.statusMessage {
                Text(status)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else {
                Button("清空") {
                    clearBasket()
                }
                .buttonStyle(ShelfPressButtonStyle(scale: 0.97))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(shelf.items.isEmpty ? Color.secondary.opacity(0.4) : Brand.danger.opacity(0.88))
                .disabled(shelf.items.isEmpty)
            }

            Spacer(minLength: 4)

            Button(action: sendCurrentItems) {
                HStack(spacing: 4) {
                    Image(systemName: sendButtonSymbol)
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
            .help(sendButtonHelp)

            Menu {
                if model.sendDefaultBehavior != .immediate {
                    Button("立即发送") {
                        sendCurrentItemsImmediately()
                    }
                    .disabled(!model.isReady)
                    Divider()
                }
                ForEach(ScheduledSendPreset.allCases) { preset in
                    Button(preset.title) {
                        scheduleCurrentItems(afterDelay: preset.rawValue)
                    }
                }
                Divider()
                Button("自定义分钟…") {
                    showsCustomDelayPicker = true
                }
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(shelf.items.isEmpty ? Color.secondary.opacity(0.45) : Brand.accent)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(shelf.items.isEmpty)
            .help("延时发送当前文件篮")
            .accessibilityLabel("延时发送当前文件篮")
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
    }

    private var sendEnabled: Bool {
        guard !shelf.items.isEmpty else { return false }
        return model.sendDefaultBehavior == .immediate ? model.isReady : true
    }

    private var sendButtonTitle: String {
        if shelf.items.isEmpty { return "发送" }
        switch model.sendDefaultBehavior {
        case .immediate:
            if !model.isReady { return "未登录" }
            return hasDirectories ? "压缩发送 \(shelf.items.count)" : "发送 \(shelf.items.count)"
        case .askEveryTime:
            return "选择方式 \(shelf.items.count)"
        case .fixedDelay:
            let delay = ScheduledSendDelay.compactTitle(seconds: model.sendDefaultDelaySeconds)
            return "\(delay)后发送"
        }
    }

    private var sendButtonSymbol: String {
        switch model.sendDefaultBehavior {
        case .immediate: hasDirectories ? "archivebox.fill" : "paperplane.fill"
        case .askEveryTime: "clock.badge.questionmark"
        case .fixedDelay: "timer"
        }
    }

    // MARK: - Controls

    private func clearBasket() {
        shelf.clear()
        session.select(nil)
        session.flash("已清空")
    }

    private var hasDirectories: Bool {
        shelf.items.contains(where: \.isDirectory)
    }

    private var sendButtonHelp: String {
        switch model.sendDefaultBehavior {
        case .immediate:
            guard model.isReady else { return "请先登录微信" }
            return hasDirectories ? "文件夹将打包为 ZIP 后发送" : "立即发送当前文件篮内全部文件"
        case .askEveryTime:
            return "选择立即发送或延时发送"
        case .fixedDelay:
            return "按设置中的固定延时建立发送计划"
        }
    }

    private func sendCurrentItems() {
        switch model.sendDefaultBehavior {
        case .immediate:
            sendCurrentItemsImmediately()
        case .askEveryTime:
            showsTimingPicker = true
        case .fixedDelay:
            scheduleCurrentItems(afterDelay: model.sendDefaultDelaySeconds)
        }
    }

    private func sendCurrentItemsImmediately() {
        if hasDirectories {
            presentZIPNaming()
        } else {
            sendAll()
        }
    }

    private func scheduleCurrentItems(afterDelay seconds: Int) {
        if hasDirectories {
            presentZIPNaming(delaySeconds: seconds)
        } else {
            scheduleAll(seconds)
        }
    }

    private func presentZIPNaming(delaySeconds: Int? = nil) {
        pendingZIPScheduleDelaySeconds = delaySeconds
        zipName = "\(shelf.title).zip"
        showsZIPNaming = true
    }

    private var scheduledItemDescription: String {
        "\(shelf.title) · \(shelf.items.count) 个项目"
    }

    private var zipAlertTitle: String {
        pendingZIPScheduleDelaySeconds == nil ? "压缩并发送" : "压缩并加入待发送"
    }

    private var zipConfirmationTitle: String {
        pendingZIPScheduleDelaySeconds == nil ? "压缩并发送" : "压缩并加入待发送"
    }

    private var zipAlertMessage: String {
        if let delaySeconds = pendingZIPScheduleDelaySeconds {
            let delay = ScheduledSendDelay.compactTitle(seconds: delaySeconds)
            return "将先创建 ZIP，再于 \(delay)后发送；名称不能包含 / 或 :。"
        }
        return "确认后立即压缩并发送；名称不能包含 / 或 :，也不会清空当前文件篮。"
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
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(chromeButtonBackground(title, emphasized: emphasized))
                )
                .contentShape(Circle())
        }
        .buttonStyle(ShelfPressButtonStyle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                hoveredChromeButton = hovering ? title : (hoveredChromeButton == title ? nil : hoveredChromeButton)
            }
        }
        .help(title)
        .accessibilityLabel(title)
    }

    private func chromeButtonBackground(
        _ title: String,
        emphasized: Bool
    ) -> Color {
        if emphasized {
            return Brand.accent.opacity(hoveredChromeButton == title ? 0.16 : 0.11)
        }
        if hoveredChromeButton == title {
            return Color.primary.opacity(0.075)
        }
        return .clear
    }

    private func remove(_ item: ShelfItem) {
        let items = shelf.items
        let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
        let wasOnlySelection = session.selectedItemIDs == [item.id]
        shelf.remove(id: item.id)
        let remaining = shelf.items
        if wasOnlySelection, !remaining.isEmpty {
            session.select(remaining[min(index, remaining.count - 1)].id)
        } else {
            session.ensureSelection(in: remaining)
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
        let supportedItems = urls.filter(ShelfModel.isSupportedItem)
        let added = shelf.add(urls: supportedItems)
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
        if !supportedItems.isEmpty {
            session.flash("已在文件篮中")
        } else if !urls.isEmpty {
            session.flash("不支持此项目或符号链接")
        }
        return false
    }
}

private struct ShelfItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
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

// MARK: - Grid Item

private struct ShelfItemTile: View {
    let item: ShelfItem
    let isSelected: Bool
    let selectedCount: Int
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onSelect: (_ extending: Bool, _ toggling: Bool) -> Void
    let dragItems: () -> [ShelfItem]
    let onPreview: () -> Void
    let onCopy: () -> Void
    let onShare: (ShelfShareDestination) -> Void
    let onRemove: () -> Void
    let onReveal: () -> Void

    @StateObject private var dragSource = ShelfItemDragSource()

    var body: some View {
        interactiveTile
            .help("\(item.path)\n方向键选择 · 拖出项目 · 双击预览 · ⌘C 复制")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.fileName)，\(detailText)")
            .accessibilityValue(accessibilitySelectionValue)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction(named: "快速预览", onPreview)
            .accessibilityAction(named: "复制项目", onCopy)
            .accessibilityAction(named: "隔空投送") { onShare(.airDrop) }
            .accessibilityAction(named: "在 Finder 中显示", onReveal)
            .accessibilityAction(named: "移除", onRemove)
    }

    private var interactiveTile: some View {
        tileContent
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover(perform: onHover)
            .background {
                ShelfItemDragSourceAnchor(source: dragSource)
                    .allowsHitTesting(false)
            }
            .simultaneousGesture(selectionGesture)
            .simultaneousGesture(previewGesture)
            .simultaneousGesture(dragGesture)
            .contextMenu {
                Button(copyMenuTitle, action: onCopy)
                Button("快速预览", action: onPreview)
                Button("在 Finder 中显示", action: onReveal)
                Divider()
                shareButtons
                Divider()
                Button("移除", role: .destructive, action: onRemove)
            }
    }

    @ViewBuilder
    private var shareButtons: some View {
        Button { onShare(.airDrop) } label: {
            Label("隔空投送", systemImage: "airdrop")
        }
        Button { onShare(.mail) } label: {
            Label("邮件", systemImage: "envelope")
        }
        Button { onShare(.messages) } label: {
            Label("信息", systemImage: "message")
        }
    }

    private var tileContent: some View {
        VStack(spacing: 6) {
            FileThumbnailView(
                url: item.url,
                width: 84,
                height: 62,
                cornerRadius: 7
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Brand.controlAccent)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(4)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                }
            }

            Text(item.fileName)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            Text(detailText)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(7)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? Brand.controlAccent.opacity(0.58) : Color.primary.opacity(0.035),
                    lineWidth: isSelected ? 1.2 : 0.8
                )
        }
    }

    private var selectionGesture: some Gesture {
        TapGesture().onEnded {
            let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            onSelect(modifiers.contains(.shift), modifiers.contains(.command))
        }
    }

    private var previewGesture: some Gesture {
        TapGesture(count: 2).onEnded(onPreview)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4).onChanged { _ in
            dragSource.beginDragging(items: dragItems())
        }
    }

    private var copyMenuTitle: String {
        selectedCount > 1 && isSelected ? "复制所选 \(selectedCount) 个项目" : "复制项目"
    }

    private var accessibilitySelectionValue: String {
        guard isSelected else { return "" }
        return selectedCount > 1 ? "已选中，共 \(selectedCount) 个项目" : "已选中"
    }

    private var backgroundColor: Color {
        if isSelected { return Brand.controlAccent.opacity(0.1) }
        if isHovered { return Color.primary.opacity(0.035) }
        return Color.primary.opacity(0.012)
    }

    private var detailText: String {
        switch item.kind {
        case .folder: "文件夹"
        case .package: "包"
        case .file: formatBytes(ShelfItemPresentationCache.fileSize(for: item.url))
        case nil: "不可用"
        }
    }
}

// MARK: - Row

private struct ShelfItemRow: View {
    let item: ShelfItem
    let isSelected: Bool
    let selectedCount: Int
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onSelect: (_ extending: Bool, _ toggling: Bool) -> Void
    let dragItems: () -> [ShelfItem]
    let onPreview: () -> Void
    let onCopy: () -> Void
    let onShare: (ShelfShareDestination) -> Void
    let onRemove: () -> Void
    let onReveal: () -> Void

    @StateObject private var dragSource = ShelfItemDragSource()

    var body: some View {
        rowContent
            .help("\(item.path)\n方向键选择 · 拖出项目 · ⌘C 复制 · 空格预览 · ⌫ 移除")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.fileName)，\(detailText)")
            .accessibilityValue(
                isSelected
                    ? (selectedCount > 1 ? "已选中，共 \(selectedCount) 个项目" : "已选中")
                    : ""
            )
            .accessibilityHint("可快速预览、在 Finder 中显示、移除或拖出到其他应用")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction(named: "快速预览", onPreview)
            .accessibilityAction(named: "复制项目", onCopy)
            .accessibilityAction(named: "隔空投送") { onShare(.airDrop) }
            .accessibilityAction(named: "在 Finder 中显示", onReveal)
            .accessibilityAction(named: "移除", onRemove)
    }

    private var rowContent: some View {
        HStack(spacing: 6) {
            draggableContent

            if isHovered {
                rowAction("预览", systemImage: "eye", action: onPreview)
                rowAction("复制项目", systemImage: "doc.on.doc", action: onCopy)
                rowAction("移除", systemImage: "xmark", action: onRemove)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    isSelected ? Brand.controlAccent.opacity(0.42) : Color.clear,
                    lineWidth: 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover(perform: onHover)
        .contextMenu {
            Button(selectedCount > 1 && isSelected ? "复制所选 \(selectedCount) 个项目" : "复制项目", action: onCopy)
            Button("快速预览", action: onPreview)
            Button("在 Finder 中显示", action: onReveal)
            Divider()
            shareButtons
            Divider()
            Button("移除", role: .destructive, action: onRemove)
        }
    }

    @ViewBuilder
    private var shareButtons: some View {
        Button { onShare(.airDrop) } label: {
            Label("隔空投送", systemImage: "airdrop")
        }
        Button { onShare(.mail) } label: {
            Label("邮件", systemImage: "envelope")
        }
        Button { onShare(.messages) } label: {
            Label("信息", systemImage: "message")
        }
    }

    private var draggableContent: some View {
        HStack(spacing: 10) {
            FileThumbnailView(
                url: item.url,
                width: 36,
                height: 36,
                cornerRadius: 6
            )

            Text(item.fileName)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if !isHovered {
                Text(detailText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .background {
            ShelfItemDragSourceAnchor(source: dragSource)
                .allowsHitTesting(false)
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                onSelect(modifiers.contains(.shift), modifiers.contains(.command))
            }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded(onPreview)
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 4).onChanged { _ in
                dragSource.beginDragging(items: dragItems())
            }
        )
    }

    private var backgroundColor: Color {
        if isSelected { return Brand.controlAccent.opacity(0.11) }
        if isHovered { return Color.primary.opacity(0.04) }
        return .clear
    }

    private var fileSize: Int64 {
        ShelfItemPresentationCache.fileSize(for: item.url)
    }

    private var detailText: String {
        switch item.kind {
        case .folder: "文件夹"
        case .package: "包"
        case .file: formatBytes(fileSize)
        case nil: "不可用"
        }
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

@MainActor
private final class ShelfItemDragSource: NSObject, ObservableObject, NSDraggingSource {
    weak var sourceView: NSView?
    private weak var draggingSession: NSDraggingSession?

    func beginDragging(items: [ShelfItem]) {
        guard draggingSession == nil,
              !items.isEmpty,
              let sourceView,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDragged
        else { return }

        let cursor = sourceView.convert(event.locationInWindow, from: nil)
        let draggingItems = items.enumerated().map { index, item in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let image = NSWorkspace.shared.icon(forFile: item.path)
            image.size = NSSize(width: 32, height: 32)
            let offset = CGFloat(min(index, 4)) * 3
            draggingItem.setDraggingFrame(
                NSRect(x: cursor.x - 16 + offset, y: cursor.y - 16 - offset, width: 32, height: 32),
                contents: image
            )
            return draggingItem
        }
        draggingSession = sourceView.beginDraggingSession(
            with: draggingItems,
            event: event,
            source: self
        )
    }

    func draggingSession(
        _: NSDraggingSession,
        sourceOperationMaskFor _: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _: NSDraggingSession,
        endedAt _: NSPoint,
        operation _: NSDragOperation
    ) {
        draggingSession = nil
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

private struct ShelfItemDragSourceAnchor: NSViewRepresentable {
    let source: ShelfItemDragSource

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        source.sourceView = view
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        source.sourceView = view
    }
}

struct FilePreviewHitTarget<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let preview: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var isHovered = false

    var body: some View {
        content()
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.black.opacity(isHovered ? 0.28 : 0))
                if isHovered {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .scaleEffect(!reduceMotion && isHovered ? 1.04 : 1)
            .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: isHovered)
            .onHover { isHovered = $0 }
            .onTapGesture(perform: preview)
            .help("预览")
    }
}

struct FileThumbnailView: View {
    let url: URL
    var fileName: String? = nil
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    var policy: FilePreviewPolicy = .always

    @State private var thumbnail: NSImage?

    private var kind: FilePreviewKind {
        FilePreviewKind(fileName: fileName ?? url.lastPathComponent)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.045))

            if let thumbnail, kind.hasVisualContent {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(3)
            } else if policy == .always {
                FilePreviewIcon(url: url, size: min(width, height) * 0.56)
            } else {
                Image(systemName: kind.symbol)
                    .font(.system(size: min(width, height) * 0.42, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.7)
        }
        .task(id: cacheKey) {
            thumbnail = nil
            guard shouldLoadThumbnail else { return }
            await loadThumbnail()
        }
        .accessibilityHidden(true)
    }

    private var shouldLoadThumbnail: Bool {
        FileManager.default.fileExists(atPath: url.path)
            && (policy == .always || kind.hasVisualContent)
    }

    private var cacheKey: String {
        ShelfItemPresentationCache.thumbnailKey(
            for: url,
            width: width,
            height: height
        ) + "#\(policy == .visualContentOnly ? "visual" : "always")"
    }

    @MainActor
    private func loadThumbnail() async {
        if let cached = ShelfItemPresentationCache.thumbnail(forKey: cacheKey) {
            thumbnail = cached
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: width, height: height),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request),
              !Task.isCancelled
        else { return }
        let image = representation.nsImage
        ShelfItemPresentationCache.storeThumbnail(image, forKey: cacheKey)
        thumbnail = image
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
    private static let thumbnails = NSCache<NSString, NSImage>()

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

    static func thumbnailKey(
        for url: URL,
        width: CGFloat,
        height: CGFloat
    ) -> String {
        "\(url.path)#\(Int(width.rounded()))x\(Int(height.rounded()))"
    }

    static func thumbnail(forKey key: String) -> NSImage? {
        thumbnails.object(forKey: key as NSString)
    }

    static func storeThumbnail(_ image: NSImage, forKey key: String) {
        thumbnails.setObject(image, forKey: key as NSString)
    }
}
