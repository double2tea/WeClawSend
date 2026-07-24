import AppKit
import Combine
import QuickLookUI
import QuartzCore
import SwiftUI

enum ShelfWindowAppearance: Equatable {
    case none
    case standard
    case shake
}

enum ShelfWindowDismissal: Equatable {
    case standard
    case shake
}

@MainActor
final class ShelfWindowController: NSObject, NSWindowDelegate {
    private enum Layout {
        static let expandedSize = NSSize(width: 276, height: 292)
        static let collapsedSize = NSSize(width: 248, height: 52)
        static let animationDuration: TimeInterval = 0.32
        static let standardDismissalDuration: TimeInterval = 0.18
        static let shakeDismissalDuration: TimeInterval = 0.26
        static let pointerGap: CGFloat = 12
    }

    private let model: AppModel
    private let basket: ShelfModel
    private let session: ShelfSessionState
    private let chooseFiles: () -> Void
    private let sendAll: () -> FileBasketSendResult
    private let requestClose: () -> Void
    private let requestDelete: () -> Void
    private let onActivate: () -> Void
    private let onWindowStateChange: (FileBasketWindowState) -> Void
    private let quickLook = ShelfQuickLookBridge()
    private let panel: ShelfPanel
    private var cancellables = Set<AnyCancellable>()
    private var localKeyMonitor: Any?
    private var savedOrigin: String?
    private var archiveTask: Task<Void, Never>?
    private var motionCompletionTask: Task<Void, Never>?
    private var isPresenting = false
    private var isDismissing = false

    init(
        model: AppModel,
        basket: ShelfModel,
        initialWindowState: FileBasketWindowState,
        chooseFiles: @escaping () -> Void,
        sendAll: @escaping () -> FileBasketSendResult,
        requestClose: @escaping () -> Void,
        requestDelete: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onWindowStateChange: @escaping (FileBasketWindowState) -> Void
    ) {
        self.model = model
        self.basket = basket
        self.chooseFiles = chooseFiles
        self.sendAll = sendAll
        self.requestClose = requestClose
        self.requestDelete = requestDelete
        self.onActivate = onActivate
        self.onWindowStateChange = onWindowStateChange
        savedOrigin = initialWindowState.origin
        session = ShelfSessionState(
            isCollapsed: initialWindowState.isCollapsed,
            isAlwaysOnTop: initialWindowState.isAlwaysOnTop
        )
        panel = ShelfPanel(
            contentRect: NSRect(origin: .zero, size: Layout.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.quickLookBridge = quickLook
        panel.onAcceptsQuickLook = { [weak self] in
            guard let self else { return false }
            return self.panel.isVisible && !self.basket.items.isEmpty
        }
        quickLook.onArrow = { [weak self] down in
            Task { @MainActor in
                self?.handleArrowKey(down: down)
                self?.syncQuickLookIndexToSelection()
            }
        }
        quickLook.onSpace = { [weak self] in
            Task { @MainActor in
                self?.closeQuickLookAndRestoreFocus()
            }
        }
        configurePanel()
        installContent()
        observeSession()
        observeItems()
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        panel.frame.contains(point)
    }

    func toggle() {
        isVisible ? requestClose() : show()
    }

    func show(
        near point: CGPoint? = nil,
        expanded: Bool = false,
        appearance: ShelfWindowAppearance = .none
    ) {
        guard model.shelfEnabled else { return }
        let wasVisible = panel.isVisible
        let wasDismissing = isDismissing
        isDismissing = false
        if expanded, session.isCollapsed {
            setCollapsed(false, animated: panel.isVisible)
        }
        if !wasVisible {
            let size = session.isCollapsed ? Layout.collapsedSize : Layout.expandedSize
            resize(to: size, animated: false)
            panel.setFrameOrigin(origin(for: point))
        }
        session.ensureSelection(in: basket.items)
        let shouldAnimate = !wasVisible && appearance != .none && !prefersReducedMotion
        if !wasVisible || wasDismissing {
            motionCompletionTask?.cancel()
            motionCompletionTask = nil
            panel.contentView?.layer?.removeAllAnimations()
            resetContentLayer()
            panel.alphaValue = 1
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        installKeyMonitorIfNeeded()
        onActivate()
        if shouldAnimate {
            animateAppearance(appearance)
        } else if !wasVisible {
            publishWindowState()
        }
    }

    func hide() {
        isPresenting = false
        isDismissing = false
        motionCompletionTask?.cancel()
        motionCompletionTask = nil
        session.clearStatus()
        closeQuickLookIfNeeded()
        removeKeyMonitor()
        panel.orderOut(nil)
        panel.contentView?.layer?.removeAllAnimations()
        resetContentLayer()
        panel.alphaValue = 1
    }

    func dismiss(
        style: ShelfWindowDismissal = .standard,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        guard panel.isVisible else {
            completion()
            return
        }
        guard !isDismissing else { return }
        guard !prefersReducedMotion else {
            hide()
            completion()
            return
        }

        isPresenting = false
        isDismissing = true
        motionCompletionTask?.cancel()
        motionCompletionTask = nil
        closeQuickLookIfNeeded()
        removeKeyMonitor()

        let duration = style == .shake
            ? Layout.shakeDismissalDuration
            : Layout.standardDismissalDuration
        let targetScale: CGFloat = style == .shake ? 0.84 : 0.96
        let layer = panel.contentView?.layer
        let currentTransform = layer?.presentation()?.transform ?? CATransform3DIdentity
        let currentOpacity = layer?.presentation()?.opacity ?? 1
        layer?.removeAllAnimations()
        let targetTransform = scaleTransform(targetScale)
        setContentLayer(transform: targetTransform, opacity: 0)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: currentTransform)
        scale.toValue = NSValue(caTransform3D: targetTransform)
        scale.duration = duration
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer?.add(scale, forKey: "shelfDismissalScale")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = currentOpacity
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = scale.timingFunction
        layer?.add(fade, forKey: "shelfDismissalOpacity")

        motionCompletionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled, self.isDismissing else { return }
            self.isDismissing = false
            self.motionCompletionTask = nil
            self.session.clearStatus()
            self.panel.orderOut(nil)
            self.panel.contentView?.layer?.removeAllAnimations()
            self.resetContentLayer()
            completion()
        }
    }

    func applyPreferences() {
        panel.level = session.isAlwaysOnTop ? .floating : .normal
        if !model.shelfEnabled {
            hide()
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPresenting, !isDismissing else { return }
        publishWindowState()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        installKeyMonitorIfNeeded()
        onActivate()
    }

    // MARK: - Private

    private func configurePanel() {
        panel.delegate = self
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = session.isAlwaysOnTop ? .floating : .normal
        panel.title = basket.title
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
    }

    private func installContent() {
        let root = ShelfView(
            model: model,
            shelf: basket,
            session: session,
            chooseFiles: chooseFiles,
            sendAll: { [weak self] in self?.sendBasketItems() },
            close: { [weak self] in self?.requestClose() },
            deleteBasket: { [weak self] in self?.requestDelete() },
            sendZIP: { [weak self] name in self?.sendBasketZIP(named: name) },
            copyPaths: { [weak self] in self?.copyBasketPaths() },
            revealAll: { [weak self] in self?.revealAllBasketItems() },
            toggleCollapsed: { [weak self] in self?.toggleCollapsed() },
            toggleAlwaysOnTop: { [weak self] in self?.toggleAlwaysOnTop() },
            quickLook: { [weak self] item in self?.showQuickLook(item) },
            revealInFinder: { item in
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        )
        panel.contentViewController = NSHostingController(rootView: root)
        panel.contentView?.wantsLayer = true
    }

    private func observeSession() {
        session.$isCollapsed
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] collapsed in
                guard let self else { return }
                resize(
                    to: collapsed ? Layout.collapsedSize : Layout.expandedSize,
                    animated: panel.isVisible
                )
                publishWindowState()
            }
            .store(in: &cancellables)
    }

    private func observeItems() {
        basket.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                guard let self else { return }
                session.ensureSelection(in: items)
                quickLook.urls = validPreviewURLs(from: items)
                if let ql = QLPreviewPanel.shared(), ql.isVisible, ql.dataSource === quickLook {
                    ql.reloadData()
                    syncQuickLookIndexToSelection()
                }
            }
            .store(in: &cancellables)
    }

    private func toggleCollapsed() {
        setCollapsed(!session.isCollapsed, animated: true)
    }

    private func setCollapsed(_ collapsed: Bool, animated: Bool) {
        guard collapsed != session.isCollapsed else { return }
        if animated, !prefersReducedMotion {
            withAnimation(.smooth(duration: Layout.animationDuration, extraBounce: 0)) {
                session.isCollapsed = collapsed
            }
        } else {
            session.isCollapsed = collapsed
        }
        if collapsed {
            closeQuickLookIfNeeded()
        } else {
            panel.makeKey()
            installKeyMonitorIfNeeded()
        }
    }

    private func resize(to size: NSSize, animated: Bool) {
        let oldFrame = panel.frame
        let newFrame = clamped(
            frame: NSRect(
                x: oldFrame.midX - size.width / 2,
                y: oldFrame.maxY - size.height,
                width: size.width,
                height: size.height
            )
        )
        guard animated, panel.isVisible, !prefersReducedMotion else {
            panel.setFrame(newFrame, display: true, animate: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.animationDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.78, 0.2, 1)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    private func animateAppearance(_ style: ShelfWindowAppearance) {
        isPresenting = true
        let layer = panel.contentView?.layer
        let spring = CASpringAnimation(keyPath: "transform")
        let fromScale: CGFloat
        let fadeDuration: TimeInterval
        switch style {
        case .none:
            isPresenting = false
            return
        case .standard:
            fromScale = 0.9
            fadeDuration = 0.3
            spring.stiffness = 240
            spring.damping = 31
        case .shake:
            fromScale = 0.82
            fadeDuration = 0.34
            spring.stiffness = 220
            spring.damping = 28
        }
        spring.fromValue = NSValue(
            caTransform3D: scaleTransform(fromScale)
        )
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        layer?.add(spring, forKey: "shelfAppearanceScale")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = fadeDuration
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        layer?.add(fade, forKey: "shelfAppearanceOpacity")
        motionCompletionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(spring.duration))
            guard let self, !Task.isCancelled, self.isPresenting else { return }
            self.isPresenting = false
            self.motionCompletionTask = nil
            self.panel.contentView?.layer?.removeAnimation(forKey: "shelfAppearanceScale")
            self.publishWindowState()
        }
    }

    private func scaleTransform(_ scale: CGFloat) -> CATransform3D {
        CATransform3DMakeScale(scale, scale, 1)
    }

    private func resetContentLayer() {
        setContentLayer(transform: CATransform3DIdentity, opacity: 1)
    }

    private func setContentLayer(transform: CATransform3D, opacity: Float) {
        guard let layer = panel.contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        layer.opacity = opacity
        CATransaction.commit()
    }

    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func toggleAlwaysOnTop() {
        session.isAlwaysOnTop.toggle()
        panel.level = session.isAlwaysOnTop ? .floating : .normal
        publishWindowState()
    }

    private func sendBasketItems() {
        switch sendAll() {
        case .enqueued, .loginRequired:
            break
        case .empty:
            session.flash("文件篮为空")
        case let .unavailableFilesRemoved(count):
            session.flash("\(count) 个文件已失效并移除，请确认后重试", duration: 2.4)
        }
    }

    private func sendBasketZIP(named archiveName: String) {
        guard archiveTask == nil else {
            session.flash("正在压缩 ZIP…")
            return
        }
        session.showStatus("正在压缩 ZIP…")
        let model = model
        let basketID = basket.id
        archiveTask = Task { [weak self, model] in
            let result = await model.sendBasketArchive(id: basketID, archiveName: archiveName)
            guard let self else { return }
            archiveTask = nil
            switch result {
            case let .enqueued(fileName):
                session.flash("“\(fileName)”已加入发送队列", duration: 2)
            case .empty:
                session.flash("文件篮为空")
            case .loginRequired:
                session.flash("请先登录微信")
            case let .unavailableFilesRemoved(count):
                session.flash("\(count) 个文件已失效并移除，请重试", duration: 2.4)
            case let .failed(message):
                session.flash(message, duration: 3)
            }
        }
    }

    private func copyBasketPaths() {
        guard !basket.items.isEmpty else {
            session.flash("文件篮为空")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let paths = basket.items.map(\.path).joined(separator: "\n")
        if pasteboard.setString(paths, forType: .string) {
            session.flash("已复制 \(basket.items.count) 条路径")
        } else {
            session.flash("复制失败")
        }
    }

    private func revealAllBasketItems() {
        let unavailableCount = basket.removeUnavailableItems()
        guard !basket.items.isEmpty else {
            session.flash(unavailableCount > 0 ? "文件已失效并移除" : "文件篮为空")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(basket.urls)
        if unavailableCount > 0 {
            session.flash("已移除 \(unavailableCount) 个失效文件")
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, panel.isKeyWindow else { return event }
            return handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if let ql = QLPreviewPanel.shared(), ql.isVisible, ql.isKeyWindow {
            return false
        }
        guard panel.isVisible, !session.isCollapsed else {
            if event.keyCode == 49, session.isCollapsed {
                setCollapsed(false, animated: true)
                return true
            }
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isEmpty || flags == .function else { return false }

        switch event.keyCode {
        case 49: // space
            toggleQuickLookForSelection()
            return true
        case 36, 76: // return
            if let item = session.selectedItem(in: basket.items) {
                showQuickLook(item)
                return true
            }
            return false
        case 125:
            handleArrowKey(down: true)
            return true
        case 126:
            handleArrowKey(down: false)
            return true
        case 51, 117:
            removeSelectedItem()
            return true
        case 53:
            if let ql = QLPreviewPanel.shared(), ql.isVisible {
                ql.orderOut(nil)
                return true
            }
            requestClose()
            return true
        default:
            return false
        }
    }

    private func handleArrowKey(down: Bool) {
        session.moveSelection(by: down ? 1 : -1, in: basket.items)
    }

    private func removeSelectedItem() {
        guard let item = session.selectedItem(in: basket.items) else { return }
        let items = basket.items
        let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
        basket.remove(id: item.id)
        let remaining = basket.items
        if remaining.isEmpty {
            session.selectedItemID = nil
        } else {
            session.selectedItemID = remaining[min(index, remaining.count - 1)].id
        }
    }

    private func toggleQuickLookForSelection() {
        guard let item = session.selectedItem(in: basket.items) else { return }
        if let ql = QLPreviewPanel.shared(), ql.isVisible {
            closeQuickLookAndRestoreFocus()
            return
        }
        showQuickLook(item)
    }

    private func closeQuickLookAndRestoreFocus() {
        QLPreviewPanel.shared()?.orderOut(nil)
        panel.makeKey()
    }

    private func showQuickLook(_ item: ShelfItem) {
        let isRegularFile = (try? item.url.resourceValues(
            forKeys: [.isRegularFileKey]
        ).isRegularFile) == true
        guard isRegularFile else {
            basket.remove(id: item.id)
            session.flash("“\(item.fileName)”已失效，已移除")
            return
        }
        session.select(item.id)
        panel.makeKeyAndOrderFront(nil)
        quickLook.urls = validPreviewURLs(from: basket.items)
        guard let previewPanel = QLPreviewPanel.shared() else { return }
        previewPanel.updateController()
        previewPanel.dataSource = quickLook
        previewPanel.delegate = quickLook
        if let index = quickLook.urls.firstIndex(where: { $0.path == item.url.path }) {
            previewPanel.currentPreviewItemIndex = index
        }
        previewPanel.reloadData()
        previewPanel.makeKeyAndOrderFront(nil)
    }

    private func syncQuickLookIndexToSelection() {
        guard let previewPanel = QLPreviewPanel.shared(), previewPanel.isVisible else { return }
        guard let item = session.selectedItem(in: basket.items),
              let index = quickLook.urls.firstIndex(where: { $0.path == item.url.path })
        else { return }
        previewPanel.currentPreviewItemIndex = index
    }

    private func closeQuickLookIfNeeded() {
        guard let previewPanel = QLPreviewPanel.shared(), previewPanel.isVisible else { return }
        if previewPanel.dataSource === quickLook {
            previewPanel.orderOut(nil)
        }
    }

    private func validPreviewURLs(from items: [ShelfItem]) -> [URL] {
        items.compactMap { item in
            let ok = (try? item.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            return ok ? item.url : nil
        }
    }

    private func origin(for point: CGPoint?) -> CGPoint {
        if let point {
            let screen = screen(containing: point) ?? NSScreen.main
            let visibleFrame = screen?.visibleFrame ?? .zero
            let gap = Layout.pointerGap
            let x = point.x + gap + panel.frame.width <= visibleFrame.maxX
                ? point.x + gap
                : point.x - gap - panel.frame.width
            let y = point.y - gap - panel.frame.height >= visibleFrame.minY
                ? point.y - gap - panel.frame.height
                : point.y + gap
            let proposedFrame = NSRect(
                x: x,
                y: y,
                width: panel.frame.width,
                height: panel.frame.height
            )
            return clamped(frame: proposedFrame).origin
        }

        if let saved = savedOrigin {
            let savedFrame = NSRect(origin: NSPointFromString(saved), size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(savedFrame) }) {
                return savedFrame.origin
            }
        }

        let mouse = NSEvent.mouseLocation
        let screen = screen(containing: mouse) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        return CGPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY - panel.frame.height / 2
        )
    }

    private func publishWindowState() {
        guard panel.isVisible else { return }
        let origin = NSStringFromPoint(panel.frame.origin)
        savedOrigin = origin
        onWindowStateChange(
            FileBasketWindowState(
                origin: origin,
                isCollapsed: session.isCollapsed,
                isAlwaysOnTop: session.isAlwaysOnTop
            )
        )
    }

    private func clamped(frame: NSRect) -> NSRect {
        let screen = screen(containing: frame.center)
            ?? NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) })
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return frame }
        return NSRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}

// MARK: - Quick Look bridge (nonisolated NSObject)

private final class ShelfQuickLookBridge: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let lock = NSLock()
    private var storedURLs: [URL] = []
    var onArrow: ((Bool) -> Void)?
    var onSpace: (() -> Void)?

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

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 49:
            onSpace?()
            return true
        case 125:
            onArrow?(true)
            return true
        case 126:
            onArrow?(false)
            return true
        default:
            return false
        }
    }
}

private final class ShelfPanel: NSPanel {
    // QL 回调走响应链，声明为 nonisolated(unsafe)；实际只在主线程读写。
    nonisolated(unsafe) var quickLookBridge: ShelfQuickLookBridge?
    nonisolated(unsafe) var onAcceptsQuickLook: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        onAcceptsQuickLook?() ?? false
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        let bridge = quickLookBridge
        MainActor.assumeIsolated {
            panel.dataSource = bridge
            panel.delegate = bridge
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

private extension NSRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
