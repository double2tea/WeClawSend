import AppKit

@MainActor
final class StatusItemDropView: NSView {
    var onClick: () -> Void = {}
    var onRightClick: (NSEvent) -> Void = { _ in }
    var onDrop: ([URL]) -> Void = { _ in }
    var onDraggingChanged: (Bool) -> Void = { _ in }
    weak var iconView: NSView?

    private var activity = MenuBarActivity.idle
    private var spinAngle: CGFloat = 90
    private var spinTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, filenamesPasteboardType])
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if NSEvent.modifierFlags.contains(.command),
           NSApp.currentEvent?.type == .leftMouseDown {
            return nil
        }
        return super.hitTest(point)
    }

    func setActivity(_ activity: MenuBarActivity) {
        let changed = activity != self.activity
        self.activity = activity
        if activity.isIndeterminate {
            startSpin()
        } else {
            stopSpin()
        }
        if changed || activity.isIndeterminate {
            needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // 状态栏按下即响应，不依赖成对的 mouseUp 或全局拖放剪贴板。
        guard !event.modifierFlags.contains(.command) else { return }
        onClick()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick(event)
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

    override func draw(_ dirtyRect: NSRect) {
        guard activity.isSending || activity.badgeCount > 0 else { return }
        if activity.isSending {
            drawProgressRing()
        }
        if let text = activity.badgeText {
            drawBadge(text)
        }
    }

    private var glyphBounds: NSRect {
        guard let iconView else { return bounds }
        let frame = convert(iconView.bounds, from: iconView)
        let side = min(frame.width, frame.height)
        return NSRect(
            x: frame.midX - side / 2,
            y: frame.midY - side / 2,
            width: side,
            height: side
        )
    }

    private func drawProgressRing() {
        let lineWidth: CGFloat = 1.3
        let center: CGPoint = {
            guard let iconView else { return CGPoint(x: bounds.midX, y: bounds.midY) }
            let frame = convert(iconView.bounds, from: iconView)
            return CGPoint(x: frame.midX, y: frame.midY)
        }()
        let radius = min(bounds.width, bounds.height) / 2 - lineWidth / 2 - 0.5
        let track = NSBezierPath()
        track.appendOval(in: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        track.lineWidth = lineWidth
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        track.stroke()

        let arc = NSBezierPath()
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        if let progress = activity.progress {
            let sweep = max(8, 360 * min(max(progress, 0), 1))
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - sweep,
                clockwise: true
            )
        } else {
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: spinAngle,
                endAngle: spinAngle - 92,
                clockwise: true
            )
        }
        Self.progressColor.setStroke()
        arc.stroke()
    }

    private func drawBadge(_ text: String) {
        let size: CGFloat = text.count > 1 ? 10 : 8.5
        let glyph = glyphBounds
        let rect = NSRect(
            x: glyph.maxX - size - 0.4,
            y: glyph.maxY - size - 0.2,
            width: size,
            height: size
        )
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: rect).fill()

        let font = NSFont.systemFont(ofSize: text.count > 1 ? 6 : 6.5, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Self.badgeTextColor
        ]
        let drawn = text.size(withAttributes: attributes)
        let point = NSPoint(
            x: rect.midX - drawn.width / 2,
            y: rect.midY - drawn.height / 2 - 0.4
        )
        text.draw(at: point, withAttributes: attributes)
    }

    private func startSpin() {
        guard spinTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.spinAngle -= 14
                if self.spinAngle < 0 { self.spinAngle += 360 }
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        spinTimer = timer
    }

    private func stopSpin() {
        spinTimer?.invalidate()
        spinTimer = nil
    }

    private static var progressColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.52, green: 0.84, blue: 0.64, alpha: 1)
                : NSColor(srgbRed: 0.22, green: 0.52, blue: 0.36, alpha: 1)
        }
    }

    private static var badgeTextColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
                : NSColor.white
        }
    }
}
