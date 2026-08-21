import AppKit
import Carbon
import Foundation

struct ShelfActivationOptions: Equatable, Sendable {
    var isEnabled: Bool
    var shortcutEnabled: Bool
    var shortcut: ShelfGlobalShortcut
    var shakeEnabled: Bool
    var shakeSensitivity: ShelfShakeSensitivity

    static let enabled = ShelfActivationOptions(
        isEnabled: true,
        shortcutEnabled: true,
        shortcut: .default,
        shakeEnabled: true,
        shakeSensitivity: .medium
    )
}

struct DragShakeDetector: Sendable {
    private struct Sample: Sendable {
        let point: CGPoint
        let time: TimeInterval
    }

    var sensitivity: ShelfShakeSensitivity {
        didSet { reset() }
    }

    private var samples: [Sample] = []
    private var lastDirection = 0
    private var reversalTimes: [TimeInterval] = []
    private var lastTriggerTime: TimeInterval?

    init(sensitivity: ShelfShakeSensitivity = .medium) {
        self.sensitivity = sensitivity
    }

    mutating func observe(point: CGPoint, at time: TimeInterval) -> Bool {
        if let lastTriggerTime, time - lastTriggerTime < thresholds.cooldown {
            remember(point: point, at: time)
            return false
        }

        guard let previous = samples.last else {
            remember(point: point, at: time)
            return false
        }

        remember(point: point, at: time)

        let deltaX = point.x - previous.point.x
        guard abs(deltaX) >= thresholds.minimumSegmentDistance else { return false }

        let direction = deltaX > 0 ? 1 : -1
        if lastDirection != 0, direction != lastDirection {
            reversalTimes.append(time)
        }
        lastDirection = direction
        trim(at: time)

        guard
            reversalTimes.count >= thresholds.minimumReversals,
            horizontalTravel >= thresholds.minimumHorizontalTravel
        else {
            return false
        }

        lastTriggerTime = time
        samples = [Sample(point: point, time: time)]
        lastDirection = 0
        reversalTimes.removeAll(keepingCapacity: true)
        return true
    }

    mutating func observe(point: CGPoint, at date: Date) -> Bool {
        observe(point: point, at: date.timeIntervalSinceReferenceDate)
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        lastDirection = 0
        reversalTimes.removeAll(keepingCapacity: true)
        lastTriggerTime = nil
    }

    private var thresholds: Thresholds {
        switch sensitivity {
        case .low:
            Thresholds(
                window: 0.9,
                cooldown: 1.2,
                minimumSegmentDistance: 44,
                minimumHorizontalTravel: 280,
                minimumReversals: 4
            )
        case .medium:
            Thresholds(
                window: 0.8,
                cooldown: 1.0,
                minimumSegmentDistance: 32,
                minimumHorizontalTravel: 210,
                minimumReversals: 3
            )
        case .high:
            Thresholds(
                window: 0.7,
                cooldown: 0.8,
                minimumSegmentDistance: 24,
                minimumHorizontalTravel: 160,
                minimumReversals: 3
            )
        }
    }

    private var horizontalTravel: CGFloat {
        zip(samples, samples.dropFirst()).reduce(0) { total, pair in
            total + abs(pair.1.point.x - pair.0.point.x)
        }
    }

    private mutating func remember(point: CGPoint, at time: TimeInterval) {
        samples.append(Sample(point: point, time: time))
        trim(at: time)
    }

    private mutating func trim(at time: TimeInterval) {
        let minimumTime = time - thresholds.window
        samples.removeAll { $0.time < minimumTime }
        reversalTimes.removeAll { $0 < minimumTime }
    }

    private struct Thresholds {
        let window: TimeInterval
        let cooldown: TimeInterval
        let minimumSegmentDistance: CGFloat
        let minimumHorizontalTravel: CGFloat
        let minimumReversals: Int
    }
}

struct DragShakeSession: Sendable {
    var sensitivity: ShelfShakeSensitivity {
        didSet {
            detector.sensitivity = sensitivity
            hasTriggeredCurrentDrag = false
        }
    }

    private var detector: DragShakeDetector
    private var hasTriggeredCurrentDrag = false

    init(sensitivity: ShelfShakeSensitivity = .medium) {
        self.sensitivity = sensitivity
        detector = DragShakeDetector(sensitivity: sensitivity)
    }

    mutating func observe(point: CGPoint, at time: TimeInterval, containsFiles: Bool) -> Bool {
        guard containsFiles else {
            detector.reset()
            return false
        }
        guard !hasTriggeredCurrentDrag else { return false }
        guard detector.observe(point: point, at: time) else { return false }
        hasTriggeredCurrentDrag = true
        return true
    }

    mutating func reset() {
        detector.reset()
        hasTriggeredCurrentDrag = false
    }

    mutating func endDrag() -> Bool {
        let didTrigger = hasTriggeredCurrentDrag
        reset()
        return didTrigger
    }
}

@MainActor
final class ShelfActivationController {
    var onShortcut: (() -> Void)?
    var onShake: ((NSPoint) -> Void)?
    var onShakeEnded: ((NSPoint) -> Void)?
    var onError: ((String) -> Void)?

    private var options: ShelfActivationOptions
    private var isRunning = false
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var hotKeyHandlerRef: EventHandlerRef?
    nonisolated(unsafe) private var globalDragMonitor: Any?
    nonisolated(unsafe) private var localDragMonitor: Any?
    private var shakeSession: DragShakeSession

    init(
        options: ShelfActivationOptions = .enabled,
        onShortcut: (() -> Void)? = nil,
        onShake: ((NSPoint) -> Void)? = nil
    ) {
        self.options = options
        self.onShortcut = onShortcut
        self.onShake = onShake
        shakeSession = DragShakeSession(sensitivity: options.shakeSensitivity)
    }

    deinit {
        if let globalDragMonitor {
            NSEvent.removeMonitor(globalDragMonitor)
        }
        if let localDragMonitor {
            NSEvent.removeMonitor(localDragMonitor)
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
        }
    }

    func start() {
        guard !isRunning else {
            applyOptions()
            return
        }
        isRunning = true
        applyOptions()
    }

    func update(options: ShelfActivationOptions) {
        let shortcutChanged = options.shortcut != self.options.shortcut
        self.options = options
        shakeSession.sensitivity = options.shakeSensitivity
        guard isRunning else { return }
        if shortcutChanged {
            unregisterHotKey()
        }
        applyOptions()
    }

    func stop() {
        isRunning = false
        unregisterHotKey()
        removeDragMonitor()
        shakeSession.reset()
    }

    private func applyOptions() {
        if options.isEnabled, options.shortcutEnabled {
            registerHotKeyIfNeeded()
        } else {
            unregisterHotKey()
        }

        if options.isEnabled, options.shakeEnabled {
            installDragMonitorIfNeeded()
        } else {
            removeDragMonitor()
            shakeSession.reset()
        }
    }

    private func registerHotKeyIfNeeded() {
        guard hotKeyRef == nil else { return }
        guard installHotKeyHandlerIfNeeded() else { return }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        var registeredHotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            options.shortcut.keyCode,
            options.shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard status == noErr else {
            if let hotKeyHandlerRef {
                RemoveEventHandler(hotKeyHandlerRef)
                self.hotKeyHandlerRef = nil
            }
            onError?("无法注册全局快捷键 \(options.shortcut.displayText)（错误 \(status)），可能已被其他 App 占用")
            return
        }
        hotKeyRef = registeredHotKey
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    private func installHotKeyHandlerIfNeeded() -> Bool {
        guard hotKeyHandlerRef == nil else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else {
            onError?("无法启用文件篮全局快捷键（错误 \(status)）")
            return false
        }
        hotKeyHandlerRef = handlerRef
        return true
    }

    private func installDragMonitorIfNeeded() {
        guard globalDragMonitor == nil, localDragMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleDragEvent(event)
            }
        }
        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleDragEvent(event)
            }
            return event
        }
    }

    private func removeDragMonitor() {
        if let globalDragMonitor {
            NSEvent.removeMonitor(globalDragMonitor)
            self.globalDragMonitor = nil
        }
        if let localDragMonitor {
            NSEvent.removeMonitor(localDragMonitor)
            self.localDragMonitor = nil
        }
    }

    private func handleDragEvent(_ event: NSEvent) {
        let mouseLocation = NSEvent.mouseLocation
        if event.type == .leftMouseUp {
            if shakeSession.endDrag() {
                onShakeEnded?(mouseLocation)
            }
            return
        }
        guard event.type == .leftMouseDragged else {
            shakeSession.reset()
            return
        }
        if shakeSession.observe(
            point: mouseLocation,
            at: event.timestamp,
            containsFiles: !fileURLs(
                from: NSPasteboard(name: .drag),
                includingDirectories: true
            ).isEmpty
        ) {
            onShake?(mouseLocation)
        }
    }

    private nonisolated func handleHotKeyPressed() {
        Task { @MainActor [weak self] in
            self?.onShortcut?()
        }
    }

    private static let hotKeySignature = OSType(
        UInt32(UInt8(ascii: "W")) << 24
            | UInt32(UInt8(ascii: "C")) << 16
            | UInt32(UInt8(ascii: "S")) << 8
            | UInt32(UInt8(ascii: "H"))
    )

    private nonisolated static let hotKeyHandler: EventHandlerUPP = { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<ShelfActivationController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        controller.handleHotKeyPressed()
        return noErr
    }
}
