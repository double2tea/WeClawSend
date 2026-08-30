import AppKit
import Carbon

struct FinderShortcutOptions: Equatable, Sendable {
    var sendEnabled: Bool
    var sendShortcut: ShelfGlobalShortcut
    var basketEnabled: Bool
    var basketShortcut: ShelfGlobalShortcut
}

@MainActor
final class FinderShortcutController: NSObject {
    var onSend: (() -> Void)?
    var onAddToBasket: (() -> Void)?
    var onError: ((String) -> Void)?

    private enum Action: UInt32 {
        case send = 1
        case addToBasket = 2

        var title: String {
            switch self {
            case .send: "Finder 立即发送"
            case .addToBasket: "Finder 放入文件篮"
            }
        }
    }

    private var options: FinderShortcutOptions
    private var isRunning = false
    private var isFinderFrontmost = false
    private var observesWorkspaceActivation = false
    nonisolated(unsafe) private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    nonisolated(unsafe) private var hotKeyHandlerRef: EventHandlerRef?

    init(options: FinderShortcutOptions) {
        self.options = options
        super.init()
    }

    deinit {
        if observesWorkspaceActivation {
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if !observesWorkspaceActivation {
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(workspaceDidActivateApplication),
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil
            )
            observesWorkspaceActivation = true
        }
        isFinderFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        applyOptions()
    }

    func update(options: FinderShortcutOptions) {
        guard options != self.options else { return }
        self.options = options
        guard isRunning else { return }
        applyOptions()
    }

    func stop() {
        isRunning = false
        if observesWorkspaceActivation {
            NSWorkspace.shared.notificationCenter.removeObserver(
                self,
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil
            )
            observesWorkspaceActivation = false
        }
        isFinderFrontmost = false
        unregisterHotKeys()
        removeHotKeyHandler()
    }

    private func applyOptions() {
        unregisterHotKeys()

        guard isFinderFrontmost else {
            removeHotKeyHandler()
            return
        }

        let registrations: [(Action, ShelfGlobalShortcut)] = [
            options.sendEnabled ? (.send, options.sendShortcut) : nil,
            options.basketEnabled ? (.addToBasket, options.basketShortcut) : nil,
        ].compactMap { $0 }

        guard !registrations.isEmpty else {
            removeHotKeyHandler()
            return
        }
        guard installHotKeyHandlerIfNeeded() else { return }

        for (action, shortcut) in registrations {
            register(action: action, shortcut: shortcut)
        }
    }

    @objc private func workspaceDidActivateApplication() {
        let finderIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        guard finderIsFrontmost != isFinderFrontmost else { return }
        isFinderFrontmost = finderIsFrontmost
        applyOptions()
    }

    private func register(action: Action, shortcut: ShelfGlobalShortcut) {
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: action.rawValue)
        var registeredHotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard status == noErr, let registeredHotKey else {
            onError?("无法注册\(action.title)快捷键 \(shortcut.displayText)（错误 \(status)），可能已被其他 App 占用")
            return
        }
        hotKeyRefs[action.rawValue] = registeredHotKey
    }

    private func unregisterHotKeys() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
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
            onError?("无法启用 Finder 全局快捷键（错误 \(status)）")
            return false
        }
        hotKeyHandlerRef = handlerRef
        return true
    }

    private func removeHotKeyHandler() {
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    private nonisolated func handleHotKeyPressed(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr,
              hotKeyID.signature == Self.hotKeySignature,
              let action = Action(rawValue: hotKeyID.id)
        else {
            return OSStatus(eventNotHandledErr)
        }

        Task { @MainActor [weak self] in
            switch action {
            case .send: self?.onSend?()
            case .addToBasket: self?.onAddToBasket?()
            }
        }
        return noErr
    }

    private nonisolated static let hotKeySignature = OSType(
        UInt32(UInt8(ascii: "W")) << 24
            | UInt32(UInt8(ascii: "C")) << 16
            | UInt32(UInt8(ascii: "F")) << 8
            | UInt32(UInt8(ascii: "D"))
    )

    private nonisolated static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<FinderShortcutController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        return controller.handleHotKeyPressed(event)
    }
}
