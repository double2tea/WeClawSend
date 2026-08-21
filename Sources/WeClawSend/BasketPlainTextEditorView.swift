import AppKit
import SwiftUI

struct BasketPlainTextEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = false
        scrollView.verticalScroller?.controlSize = .mini

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.apply(selection: selection)
        context.coordinator.requestFocus()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            context.coordinator.replaceText(with: text)
        }
        context.coordinator.apply(selection: selection)
        context.coordinator.requestFocus()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.textView?.delegate = nil
        coordinator.textView = nil
        scrollView.documentView = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BasketPlainTextEditorView
        weak var textView: NSTextView?
        private var hasRequestedFocus = false

        init(parent: BasketPlainTextEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            parent.selection = textView.selectedRange()
        }

        func apply(selection: NSRange) {
            guard let textView else { return }
            let length = (textView.string as NSString).length
            let location = selection.location == NSNotFound
                ? 0
                : min(max(selection.location, 0), length)
            let safeRange = NSRange(
                location: location,
                length: min(max(selection.length, 0), length - location)
            )
            if textView.selectedRange() != safeRange {
                textView.setSelectedRange(safeRange)
                textView.scrollRangeToVisible(safeRange)
            }
        }

        func replaceText(with replacement: String) {
            guard let textView, textView.string != replacement else { return }
            let previousText = textView.string
            let previousSelection = textView.selectedRange()
            textView.undoManager?.registerUndo(withTarget: self) { coordinator in
                coordinator.replaceText(with: previousText)
                coordinator.apply(selection: previousSelection)
            }
            textView.undoManager?.setActionName("文本格式")
            textView.string = replacement
            parent.text = replacement
        }

        func requestFocus() {
            guard !hasRequestedFocus, let textView else { return }
            Task { @MainActor [weak self, weak textView] in
                guard let self, let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
                hasRequestedFocus = true
            }
        }
    }
}
