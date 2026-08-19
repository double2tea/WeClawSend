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
        static let expandedSize = NSSize(width: 340, height: 340)
        static let collapsedSize = NSSize(width: 248, height: 52)
        static let animationDuration: TimeInterval = 0.22
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
    private var presentationTransitionTask: Task<Void, Never>?
    private var isPresenting = false
    private var isDismissing = false
    private var isResizing = false
    private var resizeGeneration = 0
    private var dismissWhenPointerLeaves = false
    private var isUndoAvailable = false
    private var readerSize: NSSize?
    private var reminderSize: NSSize?
    private var isUserLiveResizing = false
    private var hadItems: Bool

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
        hadItems = !basket.items.isEmpty
        savedOrigin = initialWindowState.origin
        let initialSession = ShelfSessionState(
            isCollapsed: initialWindowState.isCollapsed,
            isAlwaysOnTop: initialWindowState.isAlwaysOnTop
        )
        if let reminderItemID = initialWindowState.reminderItemID,
           let reminderItem = basket.items.first(where: { $0.id == reminderItemID }),
           reminderItem.isTextDocument {
            _ = initialSession.enterReminder(itemID: reminderItemID, in: basket.items)
        }
        session = initialSession
        readerSize = ReaderWindowSizing.validStoredSize(
            width: initialWindowState.readerWidth,
            height: initialWindowState.readerHeight
        )
        reminderSize = ReaderWindowSizing.validStoredSize(
            width: initialWindowState.reminderWidth,
            height: initialWindowState.reminderHeight
        )
        panel = ShelfPanel(
            contentRect: NSRect(origin: .zero, size: Layout.expandedSize),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
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
                guard let self else { return }
                self.session.moveSelection(by: down ? 1 : -1, in: self.basket.items)
                self.syncQuickLookIndexToSelection()
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
            setCollapsed(false)
        }
        if !wasVisible {
            configurePanelForPresentationMode(session.presentationMode)
            let size = targetSize(for: session.presentationMode)
            resize(to: size, animated: false)
            session.completePresentationTransition()
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
        presentationTransitionTask?.cancel()
        presentationTransitionTask = nil
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

#if DEBUG
    func enterReaderForDebug(mode: String) {
        guard let item = basket.items.first else { return }
        session.select(item.id)
        if mode == "collection" {
            return
        } else if mode == "reminder" {
            _ = session.enterReminder(itemID: item.id, in: basket.items)
        } else {
            _ = session.enterReader(itemID: item.id, in: basket.items)
        }
    }
#endif

    func windowWillMove(_ notification: Notification) {
        if isPresenting || isDismissing {
            motionCompletionTask?.cancel()
            motionCompletionTask = nil
            isPresenting = false
            isDismissing = false
            panel.contentView?.layer?.removeAllAnimations()
            resetContentLayer()
            panel.alphaValue = 1
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPresenting, !isDismissing, !isResizing, !isUserLiveResizing else { return }
        publishWindowState()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard session.presentationMode != .collection else { return }
        isUserLiveResizing = true
        resizeGeneration += 1
        panel.contentView?.layer?.removeAllAnimations()
        resetContentLayer()
    }

    func windowDidResize(_ notification: Notification) {
        neutralizeContentSafeArea()
        guard isUserLiveResizing else { return }
        switch session.presentationMode {
        case .collection:
            break
        case .reader:
            readerSize = panel.frame.size
        case .reminder:
            reminderSize = panel.frame.size
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard isUserLiveResizing else { return }
        isUserLiveResizing = false
        publishWindowState()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if isResizing {
            return frameSize
        }
        guard session.presentationMode != .collection else {
            return session.isCollapsed ? Layout.collapsedSize : Layout.expandedSize
        }
        let visibleFrame = sender.screen?.visibleFrame
        return ReaderWindowSizing.resolvedSize(
            for: session.presentationMode,
            storedSize: frameSize,
            visibleFrame: visibleFrame
        )
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
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
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
            scheduleAll: { [weak self] delaySeconds in
                self?.scheduleBasketItems(afterDelay: delaySeconds)
            },
            close: { [weak self] in self?.requestClose() },
            deleteBasket: { [weak self] in self?.requestDelete() },
            sendZIP: { [weak self] name in self?.sendBasketZIP(named: name) },
            scheduleZIP: { [weak self] name, delaySeconds in
                self?.scheduleBasketZIP(named: name, afterDelay: delaySeconds)
            },
            copyFiles: { [weak self] items in self?.copyFiles(items) },
            shareFiles: { [weak self] items, destination in
                self?.shareFiles(items, via: destination)
            },
            copyPaths: { [weak self] in self?.copyBasketPaths() },
            revealAll: { [weak self] in self?.revealAllBasketItems() },
            toggleCollapsed: { [weak self] in self?.toggleCollapsed() },
            toggleAlwaysOnTop: { [weak self] in self?.toggleAlwaysOnTop() },
            pointerPresenceChanged: { [weak self] isInside in
                self?.pointerPresenceChanged(isInside)
            },
            quickLook: { [weak self] item in self?.showQuickLook(item) },
            revealInFinder: { item in
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            },
            undoAvailabilityChanged: { [weak self] available in
                self?.setUndoAvailable(available)
            },
            resetPresentationSize: { [weak self] in
                self?.resetPresentationSize()
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
                guard session.presentationMode == .collection else { return }
                resize(
                    to: collapsed ? Layout.collapsedSize : Layout.expandedSize,
                    animated: panel.isVisible
                )
                publishWindowState()
            }
            .store(in: &cancellables)

        session.$presentationMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.applyPresentationMode(mode)
            }
            .store(in: &cancellables)
    }

    private func observeItems() {
        basket.$title
            .removeDuplicates()
            .sink { [weak self] title in
                self?.panel.title = title
            }
            .store(in: &cancellables)

        basket.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                guard let self else { return }
                let becameEmpty = hadItems && items.isEmpty
                hadItems = !items.isEmpty
                if !items.isEmpty {
                    dismissWhenPointerLeaves = false
                }
                session.ensureSelection(in: items)
                if !session.ensureFocusedItem(in: items) {
                    session.flash("阅读项目已不可用，已返回文件篮", duration: 2.4)
                }
                quickLook.urls = validPreviewURLs(from: items)
                if let ql = QLPreviewPanel.shared(), ql.isVisible, ql.dataSource === quickLook {
                    ql.reloadData()
                    syncQuickLookIndexToSelection()
                }
                if becameEmpty {
                    dismissWhenPointerLeaves = true
                    if !isUndoAvailable {
                        deleteEmptyBasketIfPointerIsOutside()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func toggleCollapsed() {
        setCollapsed(!session.isCollapsed)
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard session.presentationMode == .collection else { return }
        guard collapsed != session.isCollapsed else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            session.isCollapsed = collapsed
        }
        if collapsed {
            closeQuickLookIfNeeded()
        } else {
            panel.makeKey()
            installKeyMonitorIfNeeded()
        }
    }

    private func applyPresentationMode(_ mode: ShelfPresentationMode) {
        closeQuickLookIfNeeded()
        presentationTransitionTask?.cancel()
        presentationTransitionTask = nil
        configurePanelForPresentationMode(mode)
        let targetSize = targetSize(for: mode)
        let finishTransition: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            guard session.presentationMode == mode else { return }
            presentationTransitionTask?.cancel()
            presentationTransitionTask = nil
            if mode == .collection {
                panel.styleMask.remove(.resizable)
                panel.minSize = targetSize
                panel.maxSize = targetSize
                hideStandardWindowButtons()
            }
            session.completePresentationTransition()
            publishWindowState()
        }
        let shouldAnimate = panel.isVisible && !prefersReducedMotion
        resize(to: targetSize, animated: shouldAnimate, completion: finishTransition)
        if shouldAnimate {
            presentationTransitionTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(Layout.animationDuration + 0.08))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                presentationTransitionTask = nil
                finishTransition()
            }
        }
    }

    private func configurePanelForPresentationMode(_ mode: ShelfPresentationMode) {
        switch mode {
        case .collection:
            panel.minSize = session.isCollapsed ? Layout.collapsedSize : Layout.expandedSize
            panel.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            panel.level = session.isAlwaysOnTop ? .floating : .normal
        case .reader:
            panel.styleMask.insert(.resizable)
            panel.level = session.isAlwaysOnTop ? .floating : .normal
            applyResizableLimits(for: .reader)
        case .reminder:
            panel.styleMask.insert(.resizable)
            panel.level = .floating
            applyResizableLimits(for: .reminder)
        }
        hideStandardWindowButtons()
        neutralizeContentSafeArea()
    }

    private func hideStandardWindowButtons() {
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func applyResizableLimits(for mode: ShelfPresentationMode) {
        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let minimum = ReaderWindowSizing.resolvedSize(
            for: mode,
            storedSize: ReaderWindowSizing.minimumSize(for: mode == .reader ? .reader : .reminder),
            visibleFrame: visibleFrame
        )
        let maximum = ReaderWindowSizing.resolvedSize(
            for: mode,
            storedSize: visibleFrame?.insetBy(dx: 12, dy: 12).size,
            visibleFrame: visibleFrame
        )
        panel.minSize = minimum
        panel.maxSize = maximum
    }

    private func targetSize(for mode: ShelfPresentationMode) -> NSSize {
        if mode == .collection {
            return session.isCollapsed ? Layout.collapsedSize : Layout.expandedSize
        }
        let storedSize = mode == .reader ? readerSize : reminderSize
        return ReaderWindowSizing.resolvedSize(
            for: mode,
            storedSize: storedSize,
            visibleFrame: panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        )
    }

    private func resetPresentationSize() {
        switch session.presentationMode {
        case .collection:
            return
        case .reader:
            readerSize = nil
        case .reminder:
            reminderSize = nil
        }
        applyPresentationMode(session.presentationMode)
    }

    private func resize(
        to size: NSSize,
        animated: Bool,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        resizeGeneration += 1
        let generation = resizeGeneration
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
            isResizing = false
            panel.setFrame(newFrame, display: true, animate: false)
            neutralizeContentSafeArea()
            completion?()
            return
        }
        isResizing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.resizeGeneration == generation else { return }
                self.isResizing = false
                self.publishWindowState()
                completion?()
            }
        }
    }

    private func neutralizeContentSafeArea() {
        guard let contentView = panel.contentView else { return }
        let titlebarInset = max(0, panel.frame.height - panel.contentLayoutRect.height)
        contentView.additionalSafeAreaInsets = NSEdgeInsets(
            top: -titlebarInset,
            left: 0,
            bottom: 0,
            right: 0
        )
    }

    private func pointerPresenceChanged(_ isInside: Bool) {
        guard !isInside else { return }
        deleteEmptyBasketIfPointerIsOutside()
    }

    private func deleteEmptyBasketIfPointerIsOutside() {
        guard !isUndoAvailable else { return }
        guard dismissWhenPointerLeaves, basket.items.isEmpty else { return }
        guard !panel.isVisible || !panel.frame.contains(NSEvent.mouseLocation) else { return }
        dismissWhenPointerLeaves = false
        requestDelete()
    }

    private func setUndoAvailable(_ available: Bool) {
        isUndoAvailable = available
        guard !available, basket.items.isEmpty else { return }
        dismissWhenPointerLeaves = true
        deleteEmptyBasketIfPointerIsOutside()
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
        case .requiresArchive:
            session.flash("文件夹需要压缩后发送")
        case let .unavailableFilesRemoved(count):
            session.flash("\(count) 个项目已失效并移除，请确认后重试", duration: 2.4)
        }
    }

    private func scheduleBasketItems(afterDelay seconds: Int) {
        session.showStatus("正在加入待发送…")
        let model = model
        let basketID = basket.id
        Task { [weak self, model] in
            let result = await model.scheduleBasketItems(id: basketID, afterDelay: seconds)
            guard let self else { return }
            switch result {
            case .scheduled:
                let delay = ScheduledSendDelay.compactTitle(seconds: seconds)
                session.flash("已加入待发送：\(delay)后", duration: 2.4)
            case .empty:
                session.flash("文件篮为空")
            case .requiresArchive:
                session.flash("文件夹需要压缩后发送")
            case let .unavailableFilesRemoved(count):
                session.flash("\(count) 个项目已失效并移除，请重试", duration: 2.4)
            case let .failed(message):
                session.flash(message, duration: 3)
            }
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
                session.flash("\(count) 个项目已失效并移除，请重试", duration: 2.4)
            case let .failed(message):
                session.flash(message, duration: 3)
            }
        }
    }

    private func scheduleBasketZIP(named archiveName: String, afterDelay seconds: Int) {
        guard archiveTask == nil else {
            session.flash("正在压缩 ZIP…")
            return
        }
        session.showStatus("正在准备待发送 ZIP…")
        let model = model
        let basketID = basket.id
        archiveTask = Task { [weak self, model] in
            let result = await model.scheduleBasketArchive(
                id: basketID,
                archiveName: archiveName,
                afterDelay: seconds
            )
            guard let self else { return }
            archiveTask = nil
            switch result {
            case let .scheduled(fileName):
                session.flash("“\(fileName)”已加入待发送", duration: 2.4)
            case .empty:
                session.flash("文件篮为空")
            case let .unavailableFilesRemoved(count):
                session.flash("\(count) 个项目已失效并移除，请重试", duration: 2.4)
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

    private func copyFiles(_ items: [ShelfItem]) {
        let availableItems = items.filter { ShelfModel.isSupportedItem($0.url) }
        guard !availableItems.isEmpty else {
            session.flash(items.isEmpty ? "文件篮为空" : "项目已失效")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if availableItems.count == 1,
           let item = availableItems.first,
           BasketTextClipStore.isManaged(item.url),
           let text = try? BasketTextClipStore.readText(at: item.url) {
            if pasteboard.setString(text, forType: .string) {
                session.flash("已复制文本")
            } else {
                session.flash("复制失败")
            }
            return
        }
        guard pasteboard.writeObjects(availableItems.map { $0.url as NSURL }) else {
            session.flash("复制失败")
            return
        }
        session.flash(availableItems.count == 1 ? "已复制项目" : "已复制 \(availableItems.count) 个项目")
    }

    private func pasteIntoBasket() {
        let pasteboard = NSPasteboard.general
        let urls = fileURLs(from: pasteboard, includingDirectories: true)
        if !urls.isEmpty {
            let added = basket.add(urls: urls)
            guard added > 0 else {
                session.flash("文件已在篮中")
                return
            }
            revealPastedItem()
            session.flash(added == 1 ? "已粘贴 1 个文件" : "已粘贴 \(added) 个项目")
            return
        }

        if let image = NSImage(pasteboard: pasteboard) {
            do {
                let url = try BasketImageClipStore.create(image: image)
                guard basket.add(urls: [url]) == 1 else {
                    _ = BasketImageClipStore.deleteIfManaged(url)
                    session.flash("无法加入图片便笺")
                    return
                }
                revealPastedItem()
                session.flash("已粘贴图片")
            } catch {
                session.flash(error.localizedDescription, duration: 3)
            }
            return
        }

        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            session.flash("剪贴板中没有可粘贴的文件、图片或文本")
            return
        }

        do {
            let url = try BasketTextClipStore.create(text: text)
            guard basket.add(urls: [url]) == 1 else {
                _ = BasketTextClipStore.deleteIfManaged(url)
                session.flash("无法加入文本便笺")
                return
            }
            revealPastedItem()
            session.flash("已粘贴文本")
        } catch {
            session.flash(error.localizedDescription, duration: 3)
        }
    }

    private func revealPastedItem() {
        if session.isCollapsed {
            setCollapsed(false)
        }
        if let item = basket.items.last {
            session.select(item.id)
        }
    }

    private func shareFiles(
        _ items: [ShelfItem],
        via destination: ShelfShareDestination
    ) {
        let availableItems = items.filter { ShelfModel.isSupportedItem($0.url) }
        guard !availableItems.isEmpty else {
            session.flash(items.isEmpty ? "未选择项目" : "项目已失效")
            return
        }
        let urls = availableItems.map { $0.url as NSURL }
        guard let service = NSSharingService(named: destination.serviceName),
              service.canPerform(withItems: urls)
        else {
            session.flash("当前无法使用\(destination.title)")
            return
        }
        service.perform(withItems: urls)
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
        if let firstResponder = panel.firstResponder,
           firstResponder is NSTextView || firstResponder is NSTextField {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if session.presentationMode != .collection {
            return handlePresentedContentKeyDown(event, flags: flags)
        }
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            return enterReaderForSelection()
        }
        if flags == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":
                session.selectAll(in: basket.items)
                return true
            case "c":
                let items = session.selectedItems(in: basket.items)
                guard !items.isEmpty else { return false }
                copyFiles(items)
                return true
            case "v":
                pasteIntoBasket()
                return true
            default:
                break
            }
        }
        guard panel.isVisible, !session.isCollapsed else {
            if event.keyCode == 49, session.isCollapsed {
                setCollapsed(false)
                return true
            }
            return false
        }

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
        case 123: // left
            handleArrowKey(.left)
            return true
        case 124: // right
            handleArrowKey(.right)
            return true
        case 125: // down
            handleArrowKey(.down)
            return true
        case 126: // up
            handleArrowKey(.up)
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

    private func handlePresentedContentKeyDown(
        _ event: NSEvent,
        flags: NSEvent.ModifierFlags
    ) -> Bool {
        if event.keyCode == 53, flags.isEmpty {
            session.returnToCollection(in: basket.items)
            return true
        }
        guard flags == .command else { return false }
        switch event.keyCode {
        case 123:
            _ = session.moveFocus(by: -1, in: basket.items)
            return true
        case 124:
            _ = session.moveFocus(by: 1, in: basket.items)
            return true
        case 36 where session.presentationMode == .reminder,
             76 where session.presentationMode == .reminder:
            guard let focusedItemID = session.focusedItemID else { return false }
            return session.enterReader(itemID: focusedItemID, in: basket.items)
        default:
            return false
        }
    }

    private func enterReaderForSelection() -> Bool {
        guard let item = session.selectedItem(in: basket.items) else {
            session.flash("请先选择一个项目")
            return true
        }
        switch BasketReaderRouter.route(
            for: item.url,
            isManagedText: BasketTextClipStore.isManaged(item.url)
        ) {
        case .reader:
            _ = session.enterReader(itemID: item.id, in: basket.items)
        case .failure:
            session.flash("该项目暂时无法展开阅读")
        }
        return true
    }

    private enum ArrowDirection {
        case left
        case right
        case up
        case down
    }

    private func handleArrowKey(_ direction: ArrowDirection) {
        let offset: Int
        switch (session.displayMode, direction) {
        case (.grid, .left), (.list, .left), (.list, .up):
            offset = -1
        case (.grid, .right), (.list, .right), (.list, .down):
            offset = 1
        case (.grid, .up):
            offset = -3
        case (.grid, .down):
            offset = 3
        }
        session.moveSelection(by: offset, in: basket.items)
    }

    private func removeSelectedItem() {
        let selectedItems = session.selectedItems(in: basket.items)
        guard !selectedItems.isEmpty else { return }
        let items = basket.items
        let selectedIDs = Set(selectedItems.map(\.id))
        let index = items.firstIndex(where: { selectedIDs.contains($0.id) }) ?? 0
        basket.remove(ids: selectedIDs)
        let remaining = basket.items
        if remaining.isEmpty {
            session.select(nil)
        } else {
            session.select(remaining[min(index, remaining.count - 1)].id)
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
        guard ShelfModel.isSupportedItem(item.url) else {
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
        items.map(\.url).filter(ShelfModel.isSupportedItem)
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
                isAlwaysOnTop: session.isAlwaysOnTop,
                readerWidth: readerSize.map { Double($0.width) },
                readerHeight: readerSize.map { Double($0.height) },
                reminderWidth: reminderSize.map { Double($0.width) },
                reminderHeight: reminderSize.map { Double($0.height) },
                reminderItemID: session.presentationMode == .reminder
                    ? session.focusedItemID
                    : nil
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
