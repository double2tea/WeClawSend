import SwiftUI

struct FileBasketCommands {
    let create: () -> Void
    let toggleRecent: () -> Void
    let show: (UUID) -> Void
    let showAll: () -> Void
    let closeAll: () -> Void
    let delete: (UUID) -> Void
    let deleteAll: () -> Void
}

private enum FileBasketDeletionRequest: Equatable {
    case basket(UUID)
    case all
}

private enum TransferHistoryFilter: String, CaseIterable, Identifiable {
    case active
    case failed
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: "进行中"
        case .failed: "失败"
        case .all: "全部"
        }
    }
}

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AppModel
    @ObservedObject private var fileBaskets: FileBasketStore
    let chooseFiles: () -> Void
    let chooseFilesForTiming: () -> Void
    let fileBasketCommands: FileBasketCommands
    @State private var isDropHovered = false
    @State private var hoveredTransferID: UUID?
    @State private var isDataSafetyHovered = false
    @State private var pendingBasketDeletion: FileBasketDeletionRequest?
    @State private var transferFilter: TransferHistoryFilter = .all
    @State private var hoveredTransferFilter: TransferHistoryFilter?

    init(
        model: AppModel,
        chooseFiles: @escaping () -> Void,
        chooseFilesForTiming: @escaping () -> Void,
        fileBasketCommands: FileBasketCommands
    ) {
        self.model = model
        _fileBaskets = ObservedObject(wrappedValue: model.fileBaskets)
        self.chooseFiles = chooseFiles
        self.chooseFilesForTiming = chooseFilesForTiming
        self.fileBasketCommands = fileBasketCommands
    }

    var body: some View {
        Group {
            if model.showsServices {
                ServicesView(model: model)
            } else {
                sendView
                    .overlay {
                        if let selection = model.pendingSendSelection {
                            timingOverlay(selection)
                        }
                    }
            }
        }
        .frame(width: Brand.panelWidth, height: Brand.panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            if let notice = model.transientNotice {
                Label(notice, systemImage: "bell.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Brand.hairline, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            } else if let update = model.appUpdateNotice {
                AppUpdateNoticeCard(
                    notice: update,
                    dismiss: model.dismissAppUpdateNotice,
                    showDetails: model.showAppUpdateDetails
                )
                .padding(.horizontal, 18)
                .padding(.top, 62)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25, extraBounce: 0), value: model.transientNotice)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25, extraBounce: 0), value: model.appUpdateNotice)
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
        .confirmationDialog(
            deletionDialogTitle,
            isPresented: Binding(
                get: { pendingBasketDeletion != nil },
                set: { if !$0 { pendingBasketDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(deletionButtonTitle, role: .destructive, action: confirmBasketDeletion)
            Button("取消", role: .cancel) {
                pendingBasketDeletion = nil
            }
        } message: {
            Text(pendingBasketDeletionMessage)
        }
    }

    private func timingOverlay(_ selection: PendingSendSelection) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.16))
                .contentShape(Rectangle())
                .onTapGesture(perform: model.cancelPendingSendSelection)

            ScheduledSendTimingPicker(
                itemDescription: selection.itemDescription,
                previewURLs: selection.urls,
                canSendImmediately: model.isReady,
                initialDelaySeconds: model.sendDefaultDelaySeconds,
                cancel: model.cancelPendingSendSelection,
                sendImmediately: { model.sendPendingSelectionNow(selection) },
                schedule: { model.schedulePendingSelection(selection, afterDelay: $0) }
            )
            .frame(width: 352)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Brand.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
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
        .overlay(alignment: .bottomTrailing) {
            if isDataSafetyHovered {
                DataSafetyHint.card
                    .padding(.trailing, 20)
                    .padding(.bottom, 42)
                    .allowsHitTesting(false)
            }
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
            if model.shelfEnabled {
                Menu {
                    Button {
                        fileBasketCommands.create()
                    } label: {
                        Label("新建文件篮", systemImage: "plus")
                    }
                    if !fileBaskets.baskets.isEmpty {
                        Divider()
                        ForEach(fileBaskets.baskets, id: \.id) { basket in
                            Button {
                                fileBasketCommands.show(basket.id)
                            } label: {
                                Text("\(basket.title) · \(basket.items.count) 个文件")
                            }
                        }
                        Divider()
                        Button("显示全部文件篮", action: fileBasketCommands.showAll)
                        Button("关闭全部文件篮", action: fileBasketCommands.closeAll)
                        Menu("删除文件篮") {
                            ForEach(fileBaskets.baskets, id: \.id) { basket in
                                Button(basket.title, role: .destructive) {
                                    requestBasketDeletion(basket)
                                }
                            }
                        }
                        Divider()
                        Button("删除全部文件篮…", role: .destructive) {
                            pendingBasketDeletion = .all
                        }
                    }
                } label: {
                    Image(systemName: fileBaskets.baskets.isEmpty ? "rectangle.stack.badge.plus" : "rectangle.stack.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Brand.accent)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .overlay(alignment: .topTrailing) {
                            if !fileBaskets.baskets.isEmpty {
                                Text(fileBaskets.baskets.count > 9 ? "9+" : String(fileBaskets.baskets.count))
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3.5)
                                    .frame(minWidth: 14, minHeight: 14)
                                    .background(Capsule().fill(Brand.action))
                                    .offset(x: 3, y: -2)
                            }
                        }
                } primaryAction: {
                    fileBasketCommands.toggleRecent()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(fileBaskets.baskets.isEmpty ? "新建文件篮" : "显示或隐藏最近文件篮；菜单可管理全部")
                .accessibilityLabel("文件篮，当前有 \(fileBaskets.baskets.count) 个")
            }
            Button {
                model.queueHoverSelection = nil
                model.showsServices = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .overlay(alignment: .topTrailing) {
                        if model.hasAppUpdate {
                            Circle()
                                .fill(Brand.danger)
                                .frame(width: 6, height: 6)
                                .offset(x: -2, y: 2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private func requestBasketDeletion(_ basket: ShelfModel) {
        if basket.items.isEmpty {
            fileBasketCommands.delete(basket.id)
        } else {
            pendingBasketDeletion = .basket(basket.id)
        }
    }

    private func confirmBasketDeletion() {
        guard let request = pendingBasketDeletion else { return }
        pendingBasketDeletion = nil
        switch request {
        case let .basket(id):
            fileBasketCommands.delete(id)
        case .all:
            fileBasketCommands.deleteAll()
        }
    }

    private var deletionDialogTitle: String {
        pendingBasketDeletion == .all ? "删除全部文件篮？" : "删除文件篮？"
    }

    private var deletionButtonTitle: String {
        pendingBasketDeletion == .all ? "全部删除" : "删除"
    }

    private var pendingBasketDeletionMessage: String {
        guard let request = pendingBasketDeletion else {
            return "只会移除文件引用，不会删除原文件。"
        }
        if request == .all {
            return "将删除 \(fileBaskets.baskets.count) 个文件篮并移除 \(fileBaskets.totalItemCount) 个项目引用，不会删除原内容。"
        }
        guard
            case let .basket(id) = request,
            let basket = fileBaskets.basket(id: id)
        else { return "只会移除文件引用，不会删除原文件。" }
        return "将删除\(basket.title)并移除篮内 \(basket.items.count) 个文件引用，不会删除原文件。"
    }

    private var headerStatusText: String {
        if model.sendingTransferCount > 0, model.queuedTransferCount > 0 {
            return "发送 \(model.sendingTransferCount) · 排队 \(model.queuedTransferCount)"
        }
        if model.sendingTransferCount > 0 { return "发送中 \(model.sendingTransferCount)" }
        if model.queuedTransferCount > 0 { return "排队 \(model.queuedTransferCount)" }
        if case .checking = model.weChatStatus { return "连接中" }
        return model.isReady ? "已连接" : "未登录"
    }

    private var headerStatusColor: Color {
        if model.sendingTransferCount > 0 { return Brand.accent }
        if model.queuedTransferCount > 0 { return Brand.warning }
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
        .accessibilityLabel(dropZoneAccessibilityLabel)
        .animation(reduceMotion ? nil : .smooth(duration: 0.18, extraBounce: 0), value: dropZoneIsHighlighted)
        .dropDestination(for: URL.self) { urls, _ in
            model.send(urls: urls)
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
        if model.isReady || model.sendDefaultBehavior != .immediate {
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
        if model.isDropTargeted { return "松开后立即发送" }
        if model.sendingTransferCount > 0, model.queuedTransferCount > 0 {
            return "\(model.sendingTransferCount) 个处理中，\(model.queuedTransferCount) 个排队"
        }
        if model.sendingTransferCount > 0 { return "正在处理 \(model.sendingTransferCount) 个文件" }
        if model.queuedTransferCount > 0 { return "\(model.queuedTransferCount) 个文件排队中" }
        if case .checking = model.weChatStatus { return "正在连接微信" }
        if !model.isReady, model.sendDefaultBehavior == .immediate {
            return "请先登录微信"
        }
        return "拖入或点击选择文件"
    }

    private var dropZoneSubtitle: String {
        if model.isDropTargeted { return "拖入不会使用默认延时" }
        if model.hasActiveTransfers { return "可继续添加文件" }
        if case .checking = model.weChatStatus { return "请稍候" }
        switch model.sendDefaultBehavior {
        case .immediate:
            return model.isReady ? "支持多选" : "点击前往设置扫码"
        case .askEveryTime:
            return "点击后选择发送时间 · 拖入立即发送"
        case .fixedDelay:
            let delay = ScheduledSendDelay.compactTitle(seconds: model.sendDefaultDelaySeconds)
            return "点击后延时 \(delay) · 拖入立即发送"
        }
    }

    private var dropZoneAccessibilityLabel: String {
        if !model.isReady, model.sendDefaultBehavior == .immediate {
            return "打开设置登录微信"
        }
        return switch model.sendDefaultBehavior {
        case .immediate: "选择文件立即发送；拖入文件也会立即发送"
        case .askEveryTime: "选择文件后选择发送时间；拖入文件会立即发送"
        case .fixedDelay:
            "选择文件后按固定延时发送；拖入文件会立即发送"
        }
    }

    // MARK: - Transfers

    private var transferSectionHeader: some View {
        HStack(spacing: 10) {
            Text("发送任务")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.6)

            Spacer()
            historyFilterBar

            Button(action: chooseFilesForTiming) {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.045)))
            }
            .buttonStyle(.plain)
            .help("选择文件并设置发送时间")
            .accessibilityLabel("选择文件并设置发送时间")

            if filteredTransfers.contains(where: \.isTerminal) {
                Button("清空") {
                    model.clearTransfers(ids: Set(filteredTransfers.filter(\.isTerminal).map(\.id)))
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 24)
    }

    private var historyFilterBar: some View {
        HStack(spacing: 2) {
            ForEach(TransferHistoryFilter.allCases) { filter in
                historyFilterButton(filter)
            }
        }
        .padding(2.5)
        .frame(width: 132)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.065), lineWidth: 0.8)
        }
    }

    private func historyFilterButton(_ filter: TransferHistoryFilter) -> some View {
        let isSelected = transferFilter == filter
        let isHovered = hoveredTransferFilter == filter
        return Button {
            model.queueHoverSelection = nil
            transferFilter = filter
        } label: {
            Text(filter.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(historyFilterBackground(isSelected: isSelected, isHovered: isHovered))
                        .shadow(
                            color: isSelected ? Color.black.opacity(0.08) : .clear,
                            radius: 2,
                            y: 1
                        )
                }
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(Brand.accent)
                            .frame(width: 14, height: 1.5)
                            .offset(y: -1.5)
                    }
                }
                .animation(
                    reduceMotion ? nil : .smooth(duration: 0.16, extraBounce: 0),
                    value: isSelected
                )
                .contentShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                hoveredTransferFilter = hovering
                    ? filter
                    : (hoveredTransferFilter == filter ? nil : hoveredTransferFilter)
            }
        }
        .accessibilityLabel(filter.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func historyFilterBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return Color.primary.opacity(0.085) }
        if isHovered { return Color.primary.opacity(0.045) }
        return .clear
    }

    @ViewBuilder
    private var transferList: some View {
        if filteredScheduledSends.isEmpty, filteredTransfers.isEmpty {
            VStack(spacing: 6) {
                Text(transferEmptyTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(transferEmptySubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 12)
        } else {
            let transfers = filteredTransfers
            let plans = filteredScheduledSends
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !plans.isEmpty {
                        listSubheader("等待发送")
                    }

                    ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                        ScheduledSendPlanView(
                            plan: plan,
                            isSelected: model.queueSelection == .scheduled(plan.id),
                            onSelect: { model.queueSelection = .scheduled(plan.id) },
                            onPreview: { model.previewQueueItem(.scheduled(plan.id)) },
                            sendNow: { model.sendScheduledNow(plan) },
                            reschedule: { model.rescheduleScheduled(plan, to: $0) },
                            cancel: { model.cancelScheduled(plan) },
                            onHoverChange: { hovering in
                                updateQueueHoverSelection(.scheduled(plan.id), hovering: hovering)
                            }
                        )

                        if index < plans.count - 1 {
                            Divider()
                                .padding(.leading, 60)
                                .opacity(0.4)
                        }
                    }

                    if !plans.isEmpty, !transfers.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                            .opacity(0.45)

                        listSubheader("最近传输")
                    }

                    ForEach(Array(transfers.enumerated()), id: \.element.id) { index, transfer in
                        transferItem(transfer)

                        if index < transfers.count - 1 {
                            Divider()
                                .padding(.leading, 48)
                                .opacity(0.4)
                        }
                    }
                }
                .padding(.leading, 18)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
            .background(CompactScrollViewConfigurator())
        }
    }

    private var filteredTransfers: [TransferRecord] {
        model.displayedTransfers.filter { transfer in
            switch transferFilter {
            case .active:
                transfer.status == .queued || transfer.status == .sending
            case .failed:
                transfer.status == .failed && !isCancelledTransfer(transfer)
            case .all:
                true
            }
        }
    }

    private var filteredScheduledSends: [ScheduledSendPlan] {
        switch transferFilter {
        case .failed:
            []
        case .active, .all:
            model.displayedScheduledSends
        }
    }

    private var transferEmptyTitle: String {
        switch transferFilter {
        case .active: "没有进行中的任务"
        case .failed: "没有失败记录"
        case .all: "暂无记录"
        }
    }

    private var transferEmptySubtitle: String {
        switch transferFilter {
        case .active: "新任务会显示在这里"
        case .failed: "发送失败后可在这里重新发送"
        case .all:
            model.isReady ? "选择文件后可立即发送或设置延时" : "延时计划可先创建，发送时需登录"
        }
    }

    private func listSubheader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func transferItem(_ transfer: TransferRecord) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                FilePreviewHitTarget {
                    model.previewQueueItem(.transfer(transfer.id))
                } content: {
                    FileThumbnailView(
                        url: transfer.fileURL,
                        fileName: transfer.fileName,
                        width: 40,
                        height: 30,
                        cornerRadius: 7,
                        policy: .visualContentOnly
                    )
                }

                Button {
                    model.queueSelection = .transfer(transfer.id)
                } label: {
                    transferText(transfer)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        model.revealTransfer(transfer)
                    }
                )
            }

            if transfer.status == .queued || transfer.status == .sending {
                HStack {
                    Spacer()
                    Button {
                        model.cancel(transfer)
                    } label: {
                        Label("取消发送", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Brand.danger)
                }
                .padding(.top, 2)
                .padding(.bottom, 2)
            } else if transfer.status == .failed {
                HStack {
                    Spacer()
                    Button {
                        model.retry(transfer)
                    } label: {
                        Label(
                            model.wasRetried(transfer) ? "已重新发送" : "重新发送",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(model.wasRetried(transfer))
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Brand.accent)
                }
                .padding(.top, 2)
                .padding(.bottom, 2)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    model.queueSelection == .transfer(transfer.id) || hoveredTransferID == transfer.id
                        ? Brand.surfaceElevated
                        : .clear
                )
        )
        .onHover { hovering in
            hoveredTransferID = hovering ? transfer.id : nil
            updateQueueHoverSelection(.transfer(transfer.id), hovering: hovering)
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: model.queueSelection == .transfer(transfer.id) || hoveredTransferID == transfer.id
        )
        .help(displayedFailureMessage(transfer) ?? transfer.message ?? "点缩略图预览，连按文件名在 Finder 中显示")
    }

    private func updateQueueHoverSelection(_ selection: QueueSelection, hovering: Bool) {
        if hovering {
            model.queueHoverSelection = selection
        } else if model.queueHoverSelection == selection {
            model.queueHoverSelection = nil
        }
    }

    private func transferText(_ transfer: TransferRecord) -> some View {
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
                if transfer.stage == .waitingForContext {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Brand.warning)
                } else {
                    ProgressView(value: transfer.progress ?? 0)
                        .progressViewStyle(.linear)
                        .tint(Brand.accent)
                        .animation(
                            reduceMotion ? nil : .linear(duration: 0.14),
                            value: transfer.progress
                        )
                }
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

                if let message = displayedFailureMessage(transfer) {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Brand.danger)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func displayedFailureMessage(_ transfer: TransferRecord) -> String? {
        guard transfer.status == .failed,
              let message = transfer.message,
              !message.isEmpty else {
            return nil
        }
        if isCancelledTransfer(transfer) { return nil }
        return message
    }

    private func isCancelledTransfer(_ transfer: TransferRecord) -> Bool {
        guard transfer.status == .failed, let message = transfer.message else { return false }
        return message == "发送已取消"
            || message == "已取消"
            || message.contains("Swift.CancellationError")
    }

    private func transferStatusText(_ transfer: TransferRecord) -> String {
        switch transfer.status {
        case .queued: "排队"
        case .sending:
            switch transfer.stage {
            case .waitingToSend: "等待提交"
            case .waitingForContext: "等待刷新"
            default: "\(Int((transfer.progress ?? 0) * 100))%"
            }
        case .sent: "完成"
        case .failed: isCancelledTransfer(transfer) ? "已取消" : "失败"
        }
    }

    private func transferStatusColor(_ transfer: TransferRecord) -> Color {
        switch transfer.status {
        case .queued: .secondary
        case .sending: .primary
        case .sent: Brand.success
        case .failed: isCancelledTransfer(transfer) ? .secondary : Brand.danger
        }
    }

    private func progressDetail(_ transfer: TransferRecord) -> String {
        let stage: String
        switch transfer.stage {
        case .preparing: stage = "准备"
        case .encrypting: stage = "加密"
        case .uploading: stage = "上传"
        case .waitingToSend: stage = "等待微信提交"
        case .sending: stage = "提交"
        case .waitingForContext: stage = "请给 ClawBot 发一条消息，收到后自动继续"
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
                Text(activitySummary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                DataSafetyHint(isHovered: $isDataSafetyHovered)
                SocialLinksView(appVersion: model.appVersion)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 36)
    }

    private var activitySummary: String {
        if model.sendingTransferCount > 0, model.queuedTransferCount > 0 {
            return "\(model.sendingTransferCount) 处理中 · \(model.queuedTransferCount) 排队"
        }
        if model.sendingTransferCount > 0 { return "\(model.sendingTransferCount) 个处理中" }
        if model.queuedTransferCount > 0 { return "\(model.queuedTransferCount) 个排队中" }
        return "就绪"
    }
}

private struct AppUpdateNoticeCard: View {
    let notice: AppUpdateNotice
    let dismiss: () -> Void
    let showDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(Brand.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("发现新版本 v\(notice.version.description)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("更新内容")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("本版本不再提醒")
            }

            if notice.notes.isEmpty {
                Text("前往更新页面查看完整说明")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(notice.notes, id: \.self) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle()
                                .fill(Brand.accent)
                                .frame(width: 4, height: 4)
                            Text(note)
                                .font(.system(size: 11.5))
                                .lineLimit(2)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("知道了", action: dismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Button("查看并更新", action: showDetails)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Brand.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 7)
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
