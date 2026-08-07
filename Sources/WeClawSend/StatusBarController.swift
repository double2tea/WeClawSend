import AppKit
import OSLog
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
    private var shakeBasketID: UUID?

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
                fileBasketCommands: FileBasketCommands(
                    create: { [weak self] in self?.createBasketFromPopover() },
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
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
        model.stopMonitoringServices()
        stopPopoverAutoCloseMonitoring()
    }

    private func togglePopover() {
        if popover.isShown {
            popover.close()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard !popover.isShown, let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
        chooseFiles(for: .send)
    }

    private func chooseBasketFiles(id: UUID) {
        chooseFiles(for: .basket(id))
    }

    private func chooseFiles(for destination: FileSelectionDestination) {
        if case .send = destination {
            popover.close()
        }
        if let openPanel {
            openPanelDestination = destination
            configure(openPanel, for: destination)
            NSApp.activate()
            openPanel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSOpenPanel()
        configure(panel, for: destination)
        openPanel = panel
        openPanelDestination = destination

        NSApp.activate()
        panel.begin { [weak self] response in
            guard let self else { return }
            let urls = response == .OK ? panel.urls : []
            openPanel = nil
            guard let destination = openPanelDestination else { return }
            openPanelDestination = nil
            switch destination {
            case .send:
                showPopover()
                guard !urls.isEmpty else { return }
                model.send(urls: urls)
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
}

private enum FileSelectionDestination {
    case send
    case basket(UUID)

    var prompt: String {
        switch self {
        case .send: "发送"
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
    var onDrop: ([URL]) -> Void = { _ in }
    var onDraggingChanged: (Bool) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
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
}
