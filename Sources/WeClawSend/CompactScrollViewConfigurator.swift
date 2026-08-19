import AppKit
import SwiftUI

struct CompactScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> CompactScrollObserverView {
        CompactScrollObserverView()
    }

    func updateNSView(_ nsView: CompactScrollObserverView, context: Context) {
        nsView.applyScrollerStyle()
    }
}

final class CompactScrollObserverView: NSView {
    private weak var configuredScrollView: NSScrollView?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyScrollerStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScrollerStyle()
    }

    func applyScrollerStyle() {
        guard let scrollView = enclosingScrollView else { return }
        guard configuredScrollView !== scrollView else { return }
        configuredScrollView = scrollView
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 3)
        scrollView.verticalScroller?.controlSize = .mini
        scrollView.verticalScroller?.alphaValue = 0.58
    }
}
