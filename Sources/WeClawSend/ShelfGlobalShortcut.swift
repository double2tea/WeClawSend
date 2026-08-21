import AppKit
import Carbon
import SwiftUI

struct ShelfGlobalShortcut: Equatable, Sendable {
    nonisolated static let `default` = ShelfGlobalShortcut(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(cmdKey | optionKey),
        keyLabel: "S"
    )!

    nonisolated static let supportedModifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    nonisolated static let primaryModifierMask = UInt32(cmdKey | optionKey | controlKey)

    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    nonisolated init?(keyCode: UInt32, modifiers: UInt32, keyLabel: String? = nil) {
        let normalizedModifiers = modifiers & Self.supportedModifierMask
        guard normalizedModifiers & Self.primaryModifierMask != 0,
              !Self.modifierKeyCodes.contains(keyCode),
              let resolvedLabel = Self.normalizedKeyLabel(keyLabel) ?? Self.label(for: keyCode)
        else {
            return nil
        }
        self.keyCode = keyCode
        self.modifiers = normalizedModifiers
        self.keyLabel = resolvedLabel
    }

    nonisolated init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers,
            keyLabel: event.charactersIgnoringModifiers
        )
    }

    nonisolated var displayText: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + keyLabel
    }

    private nonisolated static let modifierKeyCodes: Set<UInt32> = [
        54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    ]

    private nonisolated static func normalizedKeyLabel(_ label: String?) -> String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      && scalar.properties.generalCategory != .privateUse
              })
        else { return nil }
        return String(trimmed.uppercased().prefix(3))
    }

    private nonisolated static func label(for keyCode: UInt32) -> String? {
        switch Int(keyCode) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Home: "Home"
        case kVK_End: "End"
        case kVK_PageUp: "PgUp"
        case kVK_PageDown: "PgDn"
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5,
             kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
             kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
             kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20:
            "F\(Self.functionKeyNumber(for: Int(keyCode)))"
        default: nil
        }
    }

    private nonisolated static func functionKeyNumber(for keyCode: Int) -> Int {
        let mapping: [Int: Int] = [
            kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5,
            kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
            kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15,
            kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
        ]
        return mapping[keyCode] ?? 0
    }
}

struct ShelfShortcutRecorder: View {
    let shortcut: ShelfGlobalShortcut
    let onChange: (ShelfGlobalShortcut) -> Void

    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isRecording = true
            } label: {
                Text(isRecording ? "请按快捷键" : shortcut.displayText)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .frame(minWidth: isRecording ? 68 : 48)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("点击后按下新快捷键；Esc 取消，Delete 恢复默认")
            .accessibilityLabel(isRecording ? "正在录入全局快捷键" : "全局快捷键 \(shortcut.displayText)")

            if shortcut != .default {
                Button {
                    onChange(.default)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("恢复默认快捷键 ⌥⌘S")
                .accessibilityLabel("恢复默认快捷键")
            }
        }
        .background {
            ShelfShortcutCaptureView(
                isRecording: $isRecording,
                onShortcut: onChange,
                onReset: { onChange(.default) }
            )
        }
        .onDisappear { isRecording = false }
    }
}

private struct ShelfShortcutCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onShortcut: (ShelfGlobalShortcut) -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> ShelfShortcutCaptureNSView {
        let view = ShelfShortcutCaptureNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ShelfShortcutCaptureNSView, context: Context) {
        configure(view)
        guard isRecording else {
            if view.window?.firstResponder === view {
                view.window?.makeFirstResponder(nil)
            }
            return
        }
        Task { @MainActor [weak view] in
            guard let view, view.isRecording else { return }
            view.window?.makeFirstResponder(view)
        }
    }

    private func configure(_ view: ShelfShortcutCaptureNSView) {
        view.isRecording = isRecording
        view.onShortcut = { shortcut in
            onShortcut(shortcut)
            isRecording = false
        }
        view.onCancel = { isRecording = false }
        view.onReset = {
            onReset()
            isRecording = false
        }
    }
}

@MainActor
private final class ShelfShortcutCaptureNSView: NSView {
    var isRecording = false
    var onShortcut: ((ShelfGlobalShortcut) -> Void)?
    var onCancel: (() -> Void)?
    var onReset: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { .zero }

    override func keyDown(with event: NSEvent) {
        if !capture(event) {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        isRecording ? capture(event) : super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        guard isRecording else {
            super.cancelOperation(sender)
            return
        }
        onCancel?()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isRecording {
            onCancel?()
        }
        return resigned
    }

    private func capture(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return true
        }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            onReset?()
            return true
        }
        guard let shortcut = ShelfGlobalShortcut(event: event) else {
            NSSound.beep()
            return true
        }
        onShortcut?(shortcut)
        return true
    }
}
