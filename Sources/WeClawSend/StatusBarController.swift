import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var openPanel: NSOpenPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = Brand.menuBarImage
        button.toolTip = "\(Brand.name) · 拖入文件发送到微信"

        let dropView = StatusItemDropView(frame: .zero)
        dropView.translatesAutoresizingMaskIntoConstraints = false
        dropView.onClick = { [weak self] in
            self?.togglePopover()
        }
        dropView.onDrop = { [weak self] urls in
            guard let self else { return }
            showPopover()
            model.send(urls: urls)
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
        // 与 Brand 尺寸保持一致，避免 SwiftUI 内容被裁切
        popover.contentViewController = NSHostingController(
            rootView: ContentView(model: model) { [weak self] in
                self?.chooseFiles()
            }
        )
        popover.delegate = self
        self.statusItem = statusItem
        model.onContextRefreshRequired = { [weak self] in
            guard let self, !popover.isShown else { return }
            deliverContextRefreshNotification()
        }
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
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
        model.stopMonitoringServices()
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
                try await center.add(
                    UNNotificationRequest(
                        identifier: "weclaw-send-context-refresh",
                        content: content,
                        trigger: nil
                    )
                )
            } catch {
                await MainActor.run {
                    self?.model.presentedError = "微信会话需要刷新，但系统通知发送失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func chooseFiles() {
        if let openPanel {
            NSApp.activate()
            openPanel.makeKeyAndOrderFront(nil)
            return
        }

        popover.close()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = "发送"
        openPanel = panel

        NSApp.activate()
        panel.begin { [weak self] response in
            guard let self else { return }
            let urls = response == .OK ? panel.urls : []
            openPanel = nil
            showPopover()
            guard !urls.isEmpty else { return }
            model.send(urls: urls)
        }
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
