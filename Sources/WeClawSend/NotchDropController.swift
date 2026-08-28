import AppKit
import SwiftUI

enum NotchDropTarget: Equatable, Sendable {
    case basket
    case direct
}

enum NotchDropSubmission: Equatable {
    case sending([URL])
    case saved(String)
    case rejected(String)
}

struct NotchDropLayout: Equatable {
    static let width: CGFloat = 352
    static let capsuleHeight: CGFloat = 72
    static let verticalGap: CGFloat = 6

    let screenFrame: NSRect
    let topInset: CGFloat
    let notchCenterX: CGFloat
    let notchFrame: NSRect

    init?(
        screenFrame: NSRect,
        topInset: CGFloat,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?
    ) {
        guard
            topInset > 0,
            let auxiliaryTopLeftArea,
            let auxiliaryTopRightArea,
            auxiliaryTopLeftArea.maxX < auxiliaryTopRightArea.minX
        else { return nil }
        self.screenFrame = screenFrame
        self.topInset = topInset
        notchCenterX = (auxiliaryTopLeftArea.maxX + auxiliaryTopRightArea.minX) / 2
        notchFrame = NSRect(
            x: auxiliaryTopLeftArea.maxX,
            y: screenFrame.maxY - topInset,
            width: auxiliaryTopRightArea.minX - auxiliaryTopLeftArea.maxX,
            height: topInset
        )
    }

    init?(screen: NSScreen) {
        self.init(
            screenFrame: screen.frame,
            topInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    var dragFrame: NSRect {
        let height = topInset + Self.capsuleHeight + Self.verticalGap * 2
        return frame(height: height, top: screenFrame.maxY)
    }

    var feedbackFrame: NSRect {
        let height = Self.capsuleHeight + Self.verticalGap * 2
        return frame(height: height, top: screenFrame.maxY - topInset)
    }

    var activationFrame: NSRect {
        notchFrame.intersection(screenFrame)
    }

    func target(
        at screenPoint: NSPoint,
        behavior: NotchDropBehavior,
        basketEnabled: Bool
    ) -> NotchDropTarget {
        switch behavior {
        case .choose:
            guard basketEnabled else { return .direct }
            return screenPoint.x < notchCenterX ? .basket : .direct
        case .direct:
            return .direct
        case .fileBasket:
            return .basket
        }
    }

    private func frame(height: CGFloat, top: CGFloat) -> NSRect {
        let unclampedX = notchCenterX - Self.width / 2
        let x = min(max(unclampedX, screenFrame.minX), screenFrame.maxX - Self.width)
        return NSRect(x: x, y: top - height, width: Self.width, height: height)
    }
}

enum NotchDropReleasePolicy {
    static func accepts(
        point: NSPoint,
        layout: NotchDropLayout,
        isArmed: Bool,
        pendingItemCount: Int
    ) -> Bool {
        isArmed && pendingItemCount > 0 && layout.dragFrame.contains(point)
    }
}

enum NotchTrackedTransferState: Equatable {
    case waiting
    case sending(progress: Double?)
    case success
    case failure(String)
}

struct NotchTransferTracker: Equatable {
    let paths: Set<String>
    let baselineTransferIDs: Set<UUID>

    init(urls: [URL], baselineTransferIDs: Set<UUID>) {
        paths = Set(urls.map { $0.standardizedFileURL.path })
        self.baselineTransferIDs = baselineTransferIDs
    }

    func state(in transfers: [TransferRecord]) -> NotchTrackedTransferState {
        let candidates = transfers.filter {
            !baselineTransferIDs.contains($0.id) && paths.contains($0.fileURL.standardizedFileURL.path)
        }
        guard !candidates.isEmpty else { return .waiting }

        var latestByPath: [String: TransferRecord] = [:]
        for transfer in candidates.sorted(by: { $0.date < $1.date }) {
            latestByPath[transfer.fileURL.standardizedFileURL.path] = transfer
        }
        let latest = Array(latestByPath.values)
        if let failed = latest.first(where: { $0.status == .failed }) {
            return .failure(failed.message ?? "发送失败")
        }
        if latestByPath.count == paths.count, latest.allSatisfy({ $0.status == .sent }) {
            return .success
        }

        let progressValues = paths.compactMap { path -> Double? in
            guard let transfer = latestByPath[path] else { return 0 }
            switch transfer.status {
            case .queued: return 0
            case .sending: return transfer.progress
            case .sent: return 1
            case .failed: return nil
            }
        }
        let progress = progressValues.count == paths.count
            ? progressValues.reduce(0, +) / Double(paths.count)
            : nil
        return .sending(progress: progress)
    }
}

private enum NotchDropPhase: Equatable {
    case dragging(
        target: NotchDropTarget,
        basketEnabled: Bool,
        behavior: NotchDropBehavior
    )
    case preparing
    case sending(progress: Double?)
    case success(message: String, target: NotchDropTarget)
    case failure(message: String, target: NotchDropTarget)

    var detailTarget: NotchDropTarget? {
        switch self {
        case let .dragging(target, _, _), let .success(_, target), let .failure(_, target): target
        case .preparing, .sending: .direct
        }
    }
}

@MainActor
private final class NotchDropPresentation: ObservableObject {
    @Published var isPresented = false
    @Published var topInset: CGFloat = 0
    @Published var notchWidth: CGFloat = 220
    @Published var phase: NotchDropPhase = .dragging(
        target: .direct,
        basketEnabled: false,
        behavior: .choose
    )
}

@MainActor
final class NotchDropController {
    typealias Submit = (NotchDropTarget, [URL]) -> NotchDropSubmission

    private let presentation = NotchDropPresentation()
    private let panel: NotchDropPanel
    private let currentTransfers: () -> [TransferRecord]
    private let isBasketEnabled: () -> Bool
    private let dropBehavior: () -> NotchDropBehavior
    private let submit: Submit
    private let openDetails: (NotchDropTarget) -> Void
    private var isEnabled: Bool
    private var currentLayout: NotchDropLayout?
    private var tracker: NotchTransferTracker?
    private var dismissalTask: Task<Void, Never>?
    private var visibilityRevision = 0
    private var isDropZoneArmed = false
    private var pendingURLs: [URL] = []
    private var pendingTarget: NotchDropTarget?
    nonisolated(unsafe) private var screenParametersObserver: NSObjectProtocol?

    init(
        isEnabled: Bool,
        currentTransfers: @escaping () -> [TransferRecord],
        isBasketEnabled: @escaping () -> Bool,
        dropBehavior: @escaping () -> NotchDropBehavior,
        submit: @escaping Submit,
        openDetails: @escaping (NotchDropTarget) -> Void
    ) {
        self.isEnabled = isEnabled
        self.currentTransfers = currentTransfers
        self.isBasketEnabled = isBasketEnabled
        self.dropBehavior = dropBehavior
        self.submit = submit
        self.openDetails = openDetails
        let contentView = NotchDropDestinationView(
            presentation: presentation,
            isBasketEnabled: isBasketEnabled,
            dropBehavior: dropBehavior
        )
        panel = NotchDropPanel(contentView: contentView)
        contentView.onDrop = { [weak self] target, urls in
            self?.acceptDrop(target: target, urls: urls)
        }
        contentView.onOpenDetails = { [weak self] in
            self?.showDetails()
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, panel.isVisible else { return }
                hide(immediately: true)
            }
        }
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if !enabled {
            hide(immediately: true)
        }
    }

    func handleFileDragMoved(to point: NSPoint) {
        guard isEnabled else { return }
        guard
            let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
            let layout = NotchDropLayout(screen: screen)
        else {
            if isDropZoneArmed {
                hide()
            }
            return
        }
        if layout.activationFrame.contains(point) {
            isDropZoneArmed = true
        }
        guard isDropZoneArmed, layout.dragFrame.contains(point) else {
            if isDropZoneArmed {
                hide()
            }
            return
        }

        let urls = fileURLs(
            from: NSPasteboard(name: .drag),
            includingDirectories: true
        )
        guard !urls.isEmpty else { return }
        tracker = nil
        dismissalTask?.cancel()
        currentLayout = layout
        let behavior = dropBehavior()
        let target = layout.target(
            at: point,
            behavior: behavior,
            basketEnabled: isBasketEnabled()
        )
        pendingURLs = urls
        pendingTarget = target
        presentation.topInset = layout.topInset
        presentation.notchWidth = layout.notchFrame.width
        presentation.phase = .dragging(
            target: target,
            basketEnabled: isBasketEnabled(),
            behavior: behavior
        )
        show(frame: layout.dragFrame)
    }

    func handleFileDragEnded(at point: NSPoint) {
        guard case .dragging = presentation.phase else {
            isDropZoneArmed = false
            return
        }
        guard
            let currentLayout,
            NotchDropReleasePolicy.accepts(
                point: point,
                layout: currentLayout,
                isArmed: isDropZoneArmed,
                pendingItemCount: pendingURLs.count
            ),
            let pendingTarget
        else {
            isDropZoneArmed = false
            scheduleHide(after: .milliseconds(120))
            return
        }
        acceptDrop(target: pendingTarget, urls: pendingURLs)
    }

    func update(transfers: [TransferRecord]) {
        guard let tracker else { return }
        switch tracker.state(in: transfers) {
        case .waiting:
            presentation.phase = .preparing
        case let .sending(progress):
            presentation.phase = .sending(progress: progress)
        case .success:
            self.tracker = nil
            presentation.phase = .success(
                message: "发送完成",
                target: .direct
            )
            scheduleHide(after: .seconds(1.6))
        case let .failure(message):
            self.tracker = nil
            presentation.phase = .failure(message: message, target: .direct)
            scheduleHide(after: .seconds(4))
        }
    }

#if DEBUG
    func showForDebug(_ requestedPhase: String) {
        guard
            let screen = NSScreen.screens.first(where: { NotchDropLayout(screen: $0) != nil }),
            let layout = NotchDropLayout(screen: screen)
        else { return }
        currentLayout = layout
        presentation.notchWidth = layout.notchFrame.width
        switch requestedPhase {
        case "basket":
            presentation.topInset = layout.topInset
            presentation.phase = .dragging(
                target: .basket,
                basketEnabled: true,
                behavior: .choose
            )
            show(frame: layout.dragFrame)
        case "direct":
            presentation.topInset = layout.topInset
            presentation.phase = .dragging(
                target: .direct,
                basketEnabled: true,
                behavior: .choose
            )
            show(frame: layout.dragFrame)
        case "edge-direct":
            presentation.topInset = layout.topInset
            presentation.phase = .dragging(
                target: .direct,
                basketEnabled: true,
                behavior: .direct
            )
            show(frame: layout.dragFrame)
        case "edge-basket":
            presentation.topInset = layout.topInset
            presentation.phase = .dragging(
                target: .basket,
                basketEnabled: true,
                behavior: .fileBasket
            )
            show(frame: layout.dragFrame)
        case "sending":
            presentation.topInset = 0
            presentation.phase = .sending(progress: 0.64)
            show(frame: layout.feedbackFrame)
        case "success":
            presentation.topInset = 0
            presentation.phase = .success(message: "发送完成", target: .direct)
            show(frame: layout.feedbackFrame)
        case "failure":
            presentation.topInset = 0
            presentation.phase = .failure(message: "网络连接中断", target: .direct)
            show(frame: layout.feedbackFrame)
        default:
            return
        }
    }
#endif

    private func acceptDrop(target: NotchDropTarget, urls: [URL]) {
        guard isEnabled, !urls.isEmpty, case .dragging = presentation.phase else { return }
        isDropZoneArmed = false
        pendingURLs = []
        pendingTarget = nil
        dismissalTask?.cancel()
        transitionToFeedbackFrame()
        presentation.phase = .preparing
        let baselineIDs = Set(currentTransfers().map(\.id))
        switch submit(target, urls) {
        case let .sending(acceptedURLs):
            guard !acceptedURLs.isEmpty else {
                presentation.phase = .failure(message: "没有可发送的文件", target: .direct)
                scheduleHide(after: .seconds(4))
                return
            }
            tracker = NotchTransferTracker(
                urls: acceptedURLs,
                baselineTransferIDs: baselineIDs
            )
            update(transfers: currentTransfers())
        case let .saved(message):
            tracker = nil
            presentation.phase = .success(message: message, target: .basket)
            scheduleHide(after: .seconds(1.6))
        case let .rejected(message):
            tracker = nil
            presentation.phase = .failure(message: message, target: target)
            scheduleHide(after: .seconds(4))
        }
    }

    private func showDetails() {
        guard let target = presentation.phase.detailTarget else { return }
        hide(immediately: true)
        openDetails(target)
    }

    private func transitionToFeedbackFrame() {
        guard let currentLayout else { return }
        presentation.topInset = 0
        let frame = currentLayout.feedbackFrame
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func show(frame: NSRect) {
        visibilityRevision += 1
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            presentation.isPresented = false
            panel.orderFrontRegardless()
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.presentation.isPresented = true
            }
        } else {
            presentation.isPresented = true
        }
    }

    private func scheduleHide(after delay: Duration) {
        dismissalTask?.cancel()
        dismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            self?.hide()
        }
    }

    private func hide(immediately: Bool = false) {
        dismissalTask?.cancel()
        dismissalTask = nil
        visibilityRevision += 1
        let revision = visibilityRevision
        presentation.isPresented = false
        tracker = nil
        isDropZoneArmed = false
        pendingURLs = []
        pendingTarget = nil
        guard !immediately, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, visibilityRevision == revision, !presentation.isPresented else { return }
            panel.orderOut(nil)
        }
    }
}

private final class NotchDropPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentView = contentView
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class NotchDropDestinationView: NSView {
    var onDrop: (NotchDropTarget, [URL]) -> Void = { _, _ in }
    var onOpenDetails: () -> Void = {}

    private let presentation: NotchDropPresentation
    private let isBasketEnabled: () -> Bool
    private let dropBehavior: () -> NotchDropBehavior
    private let hostingView: NSHostingView<NotchDropCapsuleView>

    init(
        presentation: NotchDropPresentation,
        isBasketEnabled: @escaping () -> Bool,
        dropBehavior: @escaping () -> NotchDropBehavior
    ) {
        self.presentation = presentation
        self.isBasketEnabled = isBasketEnabled
        self.dropBehavior = dropBehavior
        hostingView = NSHostingView(rootView: NotchDropCapsuleView(presentation: presentation))
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        if case .dragging = presentation.phase { return }
        onOpenDetails()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDragging(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDragging(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard, includingDirectories: true)
        guard !urls.isEmpty else { return false }
        let target = target(for: sender)
        onDrop(target, urls)
        return true
    }

    private func updateDragging(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(from: sender.draggingPasteboard, includingDirectories: true)
        guard !urls.isEmpty else { return [] }
        presentation.phase = .dragging(
            target: target(for: sender),
            basketEnabled: isBasketEnabled(),
            behavior: dropBehavior()
        )
        return .copy
    }

    private func target(for sender: any NSDraggingInfo) -> NotchDropTarget {
        switch dropBehavior() {
        case .choose:
            guard isBasketEnabled() else { return .direct }
            return sender.draggingLocation.x < bounds.midX ? .basket : .direct
        case .direct:
            return .direct
        case .fileBasket:
            return .basket
        }
    }
}

private struct NotchDropCapsuleView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var presentation: NotchDropPresentation

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: presentation.topInset)
            capsule
                .frame(height: NotchDropLayout.capsuleHeight)
                .padding(.horizontal, 4)
                .padding(.vertical, NotchDropLayout.verticalGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(presentation.isPresented ? 1 : 0)
        .scaleEffect(
            x: presentation.isPresented ? 1 : 0.82,
            y: presentation.isPresented ? 1 : 0.18,
            anchor: .top
        )
        .offset(y: presentation.isPresented ? 0 : -5)
        .animation(motion, value: presentation.isPresented)
        .animation(motion, value: presentation.phase)
    }

    @ViewBuilder
    private var capsule: some View {
        switch presentation.phase {
        case let .dragging(target, basketEnabled, behavior):
            foldedSurface {
                dropAction(
                    target: target,
                    showsSelectionHint: behavior == .choose && basketEnabled
                )
            }
        case .preparing:
            foldedSurface {
                feedbackRow(
                    symbol: "ellipsis",
                    title: "正在准备",
                    subtitle: "读取文件信息",
                    tint: Brand.accent,
                    progress: nil,
                    spins: true
                )
            }
        case let .sending(progress):
            foldedSurface {
                feedbackRow(
                    symbol: "paperplane.fill",
                    title: "正在发送",
                    subtitle: "上传处理中",
                    tint: Brand.success,
                    progress: progress,
                    spins: progress == nil
                )
            }
        case let .success(message, target):
            foldedSurface {
                feedbackRow(
                    symbol: target == .basket ? "tray.full.fill" : "checkmark",
                    title: message,
                    subtitle: target == .basket ? "点击查看最近文件篮" : "发送任务已完成",
                    tint: Brand.success,
                    progress: 1,
                    spins: false
                )
            }
        case let .failure(message, _):
            foldedSurface {
                feedbackRow(
                    symbol: "exclamationmark",
                    title: "操作未完成",
                    subtitle: message,
                    tint: Brand.danger,
                    progress: nil,
                    spins: false
                )
            }
        }
    }

    private func foldedSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: foldWidth, height: 40)
        .background {
            foldShape
                .fill(.ultraThinMaterial)
            foldShape
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.03))
            foldShape
                .fill(atmosphereTint.opacity(0.045))
            foldShape
                .stroke(Brand.hairline, lineWidth: 0.8)
        }
        .overlay(alignment: .top) {
            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 0.6)
                Capsule(style: .continuous)
                    .fill(atmosphereTint.opacity(0.48))
                    .frame(width: 32, height: 1)
            }
        }
        .shadow(color: atmosphereTint.opacity(0.055), radius: 4, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .offset(y: -NotchDropLayout.verticalGap)
    }

    private func dropAction(
        target: NotchDropTarget,
        showsSelectionHint: Bool
    ) -> some View {
        let isBasket = target == .basket
        let tint = isBasket ? Brand.accent : Brand.success
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: isBasket ? "tray.and.arrow.down.fill" : "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                Text(isBasket ? "松手加入文件篮" : "松手发送")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            if showsSelectionHint {
                Text("刘海内左右切换")
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .id(target)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func feedbackRow(
        symbol: String,
        title: String,
        subtitle: String,
        tint: Color,
        progress: Double?,
        spins: Bool
    ) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(tint.opacity(0.16))
                if spins {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let progress, progress < 1 {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let progress, progress < 1 {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .frame(height: 1.5)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var motion: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78)
    }

    private var foldWidth: CGFloat {
        min(max(presentation.notchWidth * 0.66, 144), 156)
    }

    private var foldShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 12,
            bottomTrailingRadius: 12,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var atmosphereTint: Color {
        switch presentation.phase {
        case let .dragging(target, _, _):
            target == .direct ? Brand.success : Brand.accent
        case .preparing:
            Brand.accent
        case .sending, .success:
            Brand.success
        case .failure:
            Brand.danger
        }
    }
}
