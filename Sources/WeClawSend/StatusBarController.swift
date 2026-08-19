import AppKit
import Combine
import OSLog
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private static let contextRefreshNotificationIdentifier = "weclaw-send-context-refresh"
    private static let notificationLogger = Logger(
        subsystem: "com.chacha.WeClawSend",
        category: "Notifications"
    )

    private let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var openPanel: NSOpenPanel?
    private var openPanelDestination: FileSelectionDestination?
    private var fileBasketCoordinator: FileBasketWindowCoordinator!
    private let shelfActivationController = ShelfActivationController()
    private var popoverAutoClosePolicy = PopoverAutoClosePolicy()
    private var popoverAutoCloseTask: Task<Void, Never>?
    private var popoverEventMonitor: Any?
    private var popoverKeyMonitor: Any?
    private let queueQuickLook = QueueQuickLookBridge()
    private var shakeBasketID: UUID?
    private var statusDropView: StatusItemDropView?
    private var statusItemCancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        dismissContextRefreshNotification()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = Brand.menuBarImage
        button.toolTip = "\(Brand.name) · 拖入立即发送 · ⌥⌘S 显示最近文件篮"

        let dropView = StatusItemDropView(frame: .zero)
        dropView.translatesAutoresizingMaskIntoConstraints = false
        dropView.onClick = { [weak self] in
            self?.togglePopover()
        }
        dropView.onDrop = { [weak self] urls in
            guard let self else { return }
            let didEnqueue = model.send(urls: urls)
            if didEnqueue {
                model.showsServices = false
            }
            showPopover()
        }
        dropView.onDraggingChanged = { [weak self] isDragging in
            guard let self else { return }
            self.statusItem?.button?.highlight(isDragging || self.popover.isShown)
        }
        dropView.onRightClick = { [weak self] event in
            self?.showStatusItemMenu(with: event)
        }
        statusDropView = dropView
        button.addSubview(dropView)
        NSLayoutConstraint.activate([
            dropView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            dropView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            dropView.topAnchor.constraint(equalTo: button.topAnchor),
            dropView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])

        popover.behavior = .transient
        popover.contentSize = NSSize(width: Brand.panelWidth, height: Brand.panelHeight)
        fileBasketCoordinator = FileBasketWindowCoordinator(
            model: model,
            chooseFiles: { [weak self] id in self?.chooseBasketFiles(id: id) },
            sendAll: { [unowned self] id in sendBasketItems(id: id) }
        )
        // 与 Brand 尺寸保持一致，避免 SwiftUI 内容被裁切
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                model: model,
                chooseFiles: { [weak self] in self?.chooseFiles() },
                chooseFilesForTiming: { [weak self] in self?.chooseFilesForTiming() },
                fileBasketCommands: FileBasketCommands(
                    create: { [weak self] in self?.createBasketFromPopover() },
                    toggleRecent: { [weak self] in
                        self?.popover.close()
                        self?.fileBasketCoordinator.toggleRecent()
                    },
                    show: { [weak self] id in self?.showBasketFromPopover(id: id) },
                    showAll: { [weak self] in self?.showAllBasketsFromPopover() },
                    closeAll: { [weak self] in self?.fileBasketCoordinator.closeAll() },
                    delete: { [weak self] id in self?.fileBasketCoordinator.delete(id: id) },
                    deleteAll: { [weak self] in self?.fileBasketCoordinator.deleteAll() }
                )
            )
        )
        popover.delegate = self
        self.statusItem = statusItem
        observeMenuBarActivity()

        shelfActivationController.onShortcut = { [weak self] in
            self?.popover.close()
            self?.fileBasketCoordinator.toggleRecent()
        }
        shelfActivationController.onShake = { [weak self] point in
            guard let self else { return }
            shakeBasketID = fileBasketCoordinator.createShakeBasket(near: point)
        }
        shelfActivationController.onShakeEnded = { [weak self] point in
            guard let self, let id = shakeBasketID else { return }
            shakeBasketID = nil
            fileBasketCoordinator.discardEmptyShakeBasket(id: id, toward: point)
        }
        shelfActivationController.onError = { [weak self] message in
            guard let self else { return }
            model.presentedError = message
            showPopover()
        }
        shelfActivationController.update(options: shelfActivationOptions)
        shelfActivationController.start()

        model.onContextRefreshRequired = { [weak self] in
            guard let self, !popover.isShown else { return }
            deliverContextRefreshNotification()
        }
        model.onContextRefreshResolved = { [weak self] in
            self?.dismissContextRefreshNotification()
        }
        model.onShelfPreferencesChanged = { [weak self] in
            self?.applyShelfPreferences()
        }
        model.onQuickLookRequested = { [weak self] in
            self?.openQueueQuickLook()
        }

#if DEBUG
        if let path = ProcessInfo.processInfo.environment["WECLAW_READER_QA_FILE"] {
            let url = URL(fileURLWithPath: path)
            let mode = ProcessInfo.processInfo.environment["WECLAW_READER_QA_MODE"] ?? "reader"
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                self?.fileBasketCoordinator.showReaderForDebug(url: url, mode: mode)
            }
        }
#endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { [weak self] in
            guard let self else { return }
            await model.sendOpened(urls: urls)
            showPopover()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.fileBaskets.flushPendingPersistence()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func popoverWillShow(_ notification: Notification) {
        statusItem?.button?.highlight(true)
        model.startMonitoringServices()
        startPopoverAutoCloseMonitoring()
        startPopoverKeyMonitor()
    }

    func popoverDidShow(_ notification: Notification) {
        makePopoverKey()
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        openPanel == nil && QLPreviewPanel.shared()?.isVisible != true
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
        model.queueHoverSelection = nil
        model.stopMonitoringServices()
        stopPopoverAutoCloseMonitoring()
        stopPopoverKeyMonitor()
        closeQueueQuickLook()
        popover.behavior = .transient
    }

    private func togglePopover() {
        if popover.isShown {
            popover.close()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        if openPanel != nil {
            closeOpenPanel()
        }
        guard !popover.isShown, let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        makePopoverKey()
    }

    private func makePopoverKey() {
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
        popover.contentViewController?.view.window?.makeFirstResponder(
            popover.contentViewController?.view
        )
    }

    private var shelfActivationOptions: ShelfActivationOptions {
        ShelfActivationOptions(
            isEnabled: model.shelfEnabled,
            shortcutEnabled: model.shelfGlobalShortcutEnabled,
            shakeEnabled: model.shelfShakeToOpenEnabled,
            shakeSensitivity: model.shelfShakeSensitivity
        )
    }

    private func applyShelfPreferences() {
        fileBasketCoordinator.applyPreferences()
        shelfActivationController.update(options: shelfActivationOptions)
    }

    private func observeMenuBarActivity() {
        model.$recentTransfers
            .combineLatest(model.$scheduledSends)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.refreshStatusItemActivity()
            }
            .store(in: &statusItemCancellables)
        refreshStatusItemActivity()
    }

    private func refreshStatusItemActivity() {
        let activity = model.menuBarActivity
        statusDropView?.setActivity(activity)
        statusItem?.button?.toolTip = menuBarTooltip(activity)
    }

    private func menuBarTooltip(_ activity: MenuBarActivity) -> String {
        let base = "\(Brand.name) · 拖入立即发送 · ⌥⌘S 显示最近文件篮"
        if activity.isSending, activity.badgeCount > 0 {
            return "发送中 · 队列 \(activity.badgeCount) · \(base)"
        }
        if activity.isSending {
            return "发送中 · \(base)"
        }
        if activity.badgeCount > 0 {
            return "待处理 \(activity.badgeCount) · \(base)"
        }
        return base
    }

    private func createBasketFromPopover() {
        popover.close()
        fileBasketCoordinator.createBasket(near: NSEvent.mouseLocation)
    }

    private func showBasketFromPopover(id: UUID) {
        popover.close()
        fileBasketCoordinator.show(id: id)
    }

    private func showAllBasketsFromPopover() {
        popover.close()
        fileBasketCoordinator.showAll()
    }

    private func startPopoverAutoCloseMonitoring() {
        popoverAutoClosePolicy.opened(at: .now)
        popoverAutoCloseTask?.cancel()
        popoverAutoCloseTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, popover.isShown else { return }
                if popoverAutoClosePolicy.shouldClose(
                    at: .now,
                    hasActiveTransfers: model.hasActiveTransfers,
                    blocksAutoClose: model.blocksPopoverAutoClose
                        || openPanel != nil
                        || (QLPreviewPanel.shared()?.isVisible == true)
                ) {
                    popover.close()
                    return
                }
            }
        }
        let events: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .keyDown,
            .scrollWheel,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]
        popoverEventMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.notePopoverInteraction()
            return event
        }
    }

    private func stopPopoverAutoCloseMonitoring() {
        popoverAutoCloseTask?.cancel()
        popoverAutoCloseTask = nil
        popoverAutoClosePolicy.closed()
        if let popoverEventMonitor {
            NSEvent.removeMonitor(popoverEventMonitor)
            self.popoverEventMonitor = nil
        }
    }

    private func notePopoverInteraction() {
        guard popover.isShown else { return }
        popoverAutoClosePolicy.interacted(at: .now)
    }

    private func deliverContextRefreshNotification() {
        let center = UNUserNotificationCenter.current()
        Task { [weak self] in
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return }
                guard let self, model.hasPendingContextRefresh, !popover.isShown else { return }
                let content = UNMutableNotificationContent()
                content.title = Brand.name
                content.body = "请在微信里给 ClawBot 发送任意消息；收到后 App 会自动继续发送文件。"
                content.sound = .default
                center.removeDeliveredNotifications(
                    withIdentifiers: [Self.contextRefreshNotificationIdentifier]
                )
                center.removePendingNotificationRequests(
                    withIdentifiers: [Self.contextRefreshNotificationIdentifier]
                )
                try await center.add(
                    UNNotificationRequest(
                        identifier: Self.contextRefreshNotificationIdentifier,
                        content: content,
                        trigger: nil
                    )
                )
            } catch {
                Self.notificationLogger.warning(
                    "Context refresh notification unavailable: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func dismissContextRefreshNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(
            withIdentifiers: [Self.contextRefreshNotificationIdentifier]
        )
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.contextRefreshNotificationIdentifier]
        )
    }

    private func chooseFiles() {
        switch model.sendDefaultBehavior {
        case .immediate:
            chooseFiles(for: .send)
        case .askEveryTime:
            chooseFiles(for: .chooseTiming)
        case .fixedDelay:
            chooseFiles(for: .scheduleAfter(model.sendDefaultDelaySeconds))
        }
    }

    private func chooseFilesForTiming() {
        chooseFiles(for: .chooseTiming)
    }

    private func chooseBasketFiles(id: UUID) {
        chooseFiles(for: .basket(id))
    }

    private func chooseFiles(for destination: FileSelectionDestination) {
        closeOpenPanel()
        switch destination {
        case .send, .chooseTiming, .scheduleAfter(_):
            popover.close()
        case .basket:
            break
        }

        let panel = NSOpenPanel()
        configure(panel, for: destination)
        openPanel = panel
        openPanelDestination = destination

        NSApp.activate()
        panel.begin { [weak self] response in
            guard let self else { return }
            let urls = response == .OK ? panel.urls : []
            let isCurrent = openPanel === panel
            if isCurrent {
                finishOpenPanel(panel)
            }
            guard isCurrent, response == .OK else { return }
            DispatchQueue.main.async { [weak self] in
                self?.completeFileSelection(destination: destination, urls: urls)
                self?.makePopoverKey()
            }
        }
    }

    private func completeFileSelection(destination: FileSelectionDestination, urls: [URL]) {
        switch destination {
        case .send:
            showPopover()
            guard !urls.isEmpty else { return }
            model.send(urls: urls)
        case .chooseTiming:
            showPopover()
            guard !urls.isEmpty else { return }
            model.prepareSendTiming(urls: urls)
        case let .scheduleAfter(seconds):
            showPopover()
            guard !urls.isEmpty else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await model.schedule(urls: urls, afterDelay: seconds)
                } catch {
                    model.presentedError = error.localizedDescription
                }
            }
        case let .basket(id):
            guard !urls.isEmpty else { return }
            guard let basket = model.fileBaskets.basket(id: id) else {
                model.presentedError = "文件篮已被删除，无法加入项目"
                showPopover()
                return
            }
            basket.add(urls: urls)
            fileBasketCoordinator.show(id: id, expanded: true)
        }
    }

    private func closeOpenPanel() {
        guard let panel = openPanel else { return }
        finishOpenPanel(panel)
        panel.cancel(nil)
    }

    private func finishOpenPanel(_ panel: NSOpenPanel) {
        if openPanel === panel {
            openPanel = nil
            openPanelDestination = nil
        }
        panel.orderOut(nil)
    }

    private func configure(_ panel: NSOpenPanel, for destination: FileSelectionDestination) {
        panel.allowedContentTypes = destination.includesDirectories ? [.item] : [.data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = destination.includesDirectories
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = destination.prompt
    }

    private func sendBasketItems(id: UUID) -> FileBasketSendResult {
        let result = model.sendBasketItems(id: id)
        if result == .loginRequired {
            showPopover()
        }
        return result
    }

    private func showStatusItemMenu(with event: NSEvent) {
        guard let view = event.window?.contentView?.hitTest(event.locationInWindow) else { return }
        NSMenu.popUpContextMenu(statusItemMenu(), with: event, for: view)
    }

    private func statusItemMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("打开", action: #selector(openPopoverFromMenu)))
        menu.addItem(menuItem("设置", action: #selector(openSettingsFromMenu), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(toggleItem("文件篮", isOn: model.shelfEnabled, action: #selector(toggleShelfFromMenu)))
        menu.addItem(
            toggleItem(
                "发送结果通知",
                isOn: model.sendResultNotificationsEnabled,
                action: #selector(toggleSendResultNotificationsFromMenu)
            )
        )
        menu.addItem(
            toggleItem("本地接口", isOn: model.localAPIEnabled, action: #selector(toggleLocalAPIFromMenu))
        )
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 WeClaw Send", action: #selector(quitFromMenu), keyEquivalent: "q"))
        return menu
    }

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func toggleItem(_ title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let item = menuItem(title, action: action)
        item.state = isOn ? .on : .off
        return item
    }

    @objc private func openPopoverFromMenu() {
        closeOpenPanel()
        showPopover()
    }

    @objc private func openSettingsFromMenu() {
        closeOpenPanel()
        model.showsServices = true
        showPopover()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func toggleShelfFromMenu() {
        model.setShelfEnabled(!model.shelfEnabled)
    }

    @objc private func toggleSendResultNotificationsFromMenu() {
        model.setSendResultNotificationsEnabled(!model.sendResultNotificationsEnabled)
    }

    @objc private func toggleLocalAPIFromMenu() {
        model.setLocalAPIEnabled(!model.localAPIEnabled)
    }

    private func startPopoverKeyMonitor() {
        stopPopoverKeyMonitor()
        popoverKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, handlePopoverKeyDown(event) else { return event }
            return nil
        }
    }

    private func stopPopoverKeyMonitor() {
        if let popoverKeyMonitor {
            NSEvent.removeMonitor(popoverKeyMonitor)
            self.popoverKeyMonitor = nil
        }
    }

    private func handlePopoverKeyDown(_ event: NSEvent) -> Bool {
        guard popover.isShown else { return false }
        if let first = NSApp.keyWindow?.firstResponder,
           first is NSTextView || first is NSTextField {
            return false
        }
        guard event.keyCode == 49 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isEmpty || flags == .function else { return false }
        if model.showsServices || model.pendingSendSelection != nil { return false }
        toggleQueueQuickLook()
        return true
    }

    private func toggleQueueQuickLook() {
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            closeQueueQuickLook()
            return
        }
        openQueueQuickLook()
    }

    private func openQueueQuickLook() {
        guard let selection = model.queueHoverSelection ?? model.queueSelection else { return }
        let urls = model.previewURLs(for: selection).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !urls.isEmpty else { return }
        queueQuickLook.urls = urls
        queueQuickLook.onClose = { [weak self] in
            self?.popover.behavior = .transient
            self?.makePopoverKey()
        }
        NSApp.activate()
        popover.behavior = .applicationDefined
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = queueQuickLook
        panel.delegate = queueQuickLook
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    private func closeQueueQuickLook() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        if panel.dataSource === queueQuickLook {
            panel.orderOut(nil)
        }
    }
}

private final class QueueQuickLookBridge: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let lock = NSLock()
    private var storedURLs: [URL] = []
    var onClose: (() -> Void)?

    var urls: [URL] {
        get { lock.withLock { storedURLs } }
        set { lock.withLock { storedURLs = newValue } }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let snapshot = urls
        guard snapshot.indices.contains(index) else { return nil }
        return snapshot[index] as NSURL
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        onClose?()
    }
}

private enum FileSelectionDestination {
    case send
    case chooseTiming
    case scheduleAfter(Int)
    case basket(UUID)

    var prompt: String {
        switch self {
        case .send: "发送"
        case .chooseTiming: "下一步"
        case .scheduleAfter(_): "加入待发送"
        case .basket: "加入文件篮"
        }
    }

    var includesDirectories: Bool {
        if case .basket = self { true } else { false }
    }
}

@MainActor
final class StatusItemDropView: NSView {
    var onClick: () -> Void = {}
    var onRightClick: (NSEvent) -> Void = { _ in }
    var onDrop: ([URL]) -> Void = { _ in }
    var onDraggingChanged: (Bool) -> Void = { _ in }

    private var activity = MenuBarActivity.idle
    private var spinAngle: CGFloat = 90
    private var spinTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    override var isOpaque: Bool { false }

    func setActivity(_ activity: MenuBarActivity) {
        let changed = activity != self.activity
        self.activity = activity
        if activity.isIndeterminate {
            startSpin()
        } else {
            stopSpin()
        }
        if changed || activity.isIndeterminate {
            needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick(event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let acceptsDrop = !fileURLs(from: sender.draggingPasteboard).isEmpty
        onDraggingChanged(acceptsDrop)
        return acceptsDrop ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDraggingChanged(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDraggingChanged(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        onDraggingChanged(false)
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        guard activity.isSending || activity.badgeCount > 0 else { return }
        if activity.isSending {
            drawProgressRing()
        }
        if let text = activity.badgeText {
            drawBadge(text)
        }
    }

    private func drawProgressRing() {
        let inset: CGFloat = 1.6
        let bounds = bounds.insetBy(dx: inset, dy: inset)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 0.6
        let track = NSBezierPath()
        track.appendOval(in: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        track.lineWidth = 1.4
        NSColor.labelColor.withAlphaComponent(0.16).setStroke()
        track.stroke()

        let arc = NSBezierPath()
        arc.lineWidth = 1.5
        arc.lineCapStyle = .round
        if let progress = activity.progress {
            let sweep = max(8, 360 * min(max(progress, 0), 1))
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - sweep,
                clockwise: true
            )
        } else {
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: spinAngle,
                endAngle: spinAngle - 92,
                clockwise: true
            )
        }
        Self.progressColor.setStroke()
        arc.stroke()
    }

    private func drawBadge(_ text: String) {
        let size: CGFloat = text.count > 1 ? 10 : 8.5
        let rect = NSRect(
            x: bounds.maxX - size - 0.4,
            y: bounds.maxY - size - 0.2,
            width: size,
            height: size
        )
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: rect).fill()

        let font = NSFont.systemFont(ofSize: text.count > 1 ? 6 : 6.5, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Self.badgeTextColor
        ]
        let drawn = text.size(withAttributes: attributes)
        let point = NSPoint(
            x: rect.midX - drawn.width / 2,
            y: rect.midY - drawn.height / 2 - 0.4
        )
        text.draw(at: point, withAttributes: attributes)
    }

    private func startSpin() {
        guard spinTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.spinAngle -= 14
                if self.spinAngle < 0 { self.spinAngle += 360 }
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        spinTimer = timer
    }

    private func stopSpin() {
        spinTimer?.invalidate()
        spinTimer = nil
    }

    private static var progressColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.52, green: 0.84, blue: 0.64, alpha: 1)
                : NSColor(srgbRed: 0.22, green: 0.52, blue: 0.36, alpha: 1)
        }
    }

    private static var badgeTextColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
                : NSColor.white
        }
    }
}
