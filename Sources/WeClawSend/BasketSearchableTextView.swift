import AppKit
import SwiftUI

struct BasketSearchableTextView: NSViewRepresentable {
    let text: String
    let query: String
    let currentMatchIndex: Int
    let onMatchCountChange: @MainActor @Sendable (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMatchCountChange: onMatchCountChange)
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
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.apply(text: text, query: query, currentMatchIndex: currentMatchIndex)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onMatchCountChange = onMatchCountChange
        context.coordinator.apply(text: text, query: query, currentMatchIndex: currentMatchIndex)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.textView = nil
        scrollView.documentView = nil
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        var onMatchCountChange: @MainActor @Sendable (Int) -> Void

        private var lastText = ""
        private var lastQuery = ""
        private var lastMatchIndex = -1
        private var lastMatchCount = -1
        private var matchRanges: [NSRange] = []

        init(onMatchCountChange: @escaping @MainActor @Sendable (Int) -> Void) {
            self.onMatchCountChange = onMatchCountChange
        }

        func apply(text: String, query: String, currentMatchIndex: Int) {
            guard let textView else { return }
            guard text != lastText || query != lastQuery || currentMatchIndex != lastMatchIndex else { return }

            let textChanged = text != lastText
            let contentChanged = textChanged || query != lastQuery
            let previousMatchIndex = lastMatchIndex
            lastText = text
            lastQuery = query
            lastMatchIndex = currentMatchIndex

            if contentChanged {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 5
                let attributed = NSMutableAttributedString(
                    string: text.isEmpty ? "暂无文本内容" : text,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 14),
                        .foregroundColor: text.isEmpty ? NSColor.secondaryLabelColor : NSColor.labelColor,
                        .paragraphStyle: paragraph,
                    ]
                )
                matchRanges = Self.matchRanges(in: text, query: query)
                for range in matchRanges {
                    attributed.addAttribute(
                        .backgroundColor,
                        value: NSColor.systemYellow.withAlphaComponent(0.24),
                        range: range
                    )
                }
                if matchRanges.indices.contains(currentMatchIndex) {
                    attributed.addAttribute(
                        .backgroundColor,
                        value: NSColor.systemOrange.withAlphaComponent(0.5),
                        range: matchRanges[currentMatchIndex]
                    )
                }
                textView.textStorage?.setAttributedString(attributed)
            } else if previousMatchIndex != currentMatchIndex {
                if matchRanges.indices.contains(previousMatchIndex) {
                    textView.textStorage?.addAttribute(
                        .backgroundColor,
                        value: NSColor.systemYellow.withAlphaComponent(0.24),
                        range: matchRanges[previousMatchIndex]
                    )
                }
                if matchRanges.indices.contains(currentMatchIndex) {
                    textView.textStorage?.addAttribute(
                        .backgroundColor,
                        value: NSColor.systemOrange.withAlphaComponent(0.5),
                        range: matchRanges[currentMatchIndex]
                    )
                }
            }

            if matchRanges.indices.contains(currentMatchIndex) {
                let range = matchRanges[currentMatchIndex]
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
            } else if textChanged {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }

            if lastMatchCount != matchRanges.count {
                lastMatchCount = matchRanges.count
                let count = matchRanges.count
                Task { @MainActor [onMatchCountChange] in
                    onMatchCountChange(count)
                }
            }
        }

        private static func matchRanges(in text: String, query: String) -> [NSRange] {
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedQuery.isEmpty, !text.isEmpty else { return [] }
            let source = text as NSString
            var ranges: [NSRange] = []
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.length > 0 {
                let range = source.range(
                    of: normalizedQuery,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                guard range.location != NSNotFound else { break }
                ranges.append(range)
                let nextLocation = range.location + max(range.length, 1)
                guard nextLocation <= source.length else { break }
                searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
            }
            return ranges
        }
    }
}
