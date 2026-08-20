import AppKit
import QuickLookUI
import SwiftUI

/// An embedded Quick Look surface for formats that do not need a specialised
/// reader.  It owns a QLPreviewView instead of the process-wide
/// QLPreviewPanel, so the file basket's Space-bar preview remains independent.
struct BasketQuickLookReaderView: View {
    let url: URL
    let onOpenExternal: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state: BasketQuickLookLoadState = .idle

    init(url: URL, onOpenExternal: (() -> Void)? = nil) {
        self.url = url
        self.onOpenExternal = onOpenExternal
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                BasketReaderLoadingView(
                    title: "正在准备预览…",
                    detail: url.lastPathComponent,
                    systemImage: "eye"
                )
            case .ready:
                BasketEmbeddedQuickLookView(url: url)
                    .background(Color(nsColor: .textBackgroundColor))
            case let .failed(message):
                BasketReaderErrorView(
                    title: "无法预览此项目",
                    message: message,
                    systemImage: "eye.slash",
                    actionTitle: "在原应用中打开",
                    action: openExternal
                )
            }
        }
        .task(id: url) {
            await validatePreviewItem()
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("快速预览：\(url.lastPathComponent)")
    }

    private func validatePreviewItem() async {
        state = .loading
        await Task.yield()
        guard !Task.isCancelled else { return }
        guard url.isFileURL else {
            state = .failed("阅读器只支持本地项目。")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            state = .failed("文件不存在或已被移动。")
            return
        }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard values.isRegularFile == true || values.isDirectory == true else {
                state = .failed("该项目不是可预览的文件。")
                return
            }
        } catch {
            state = .failed("无法读取项目文件信息。")
            return
        }
        guard !Task.isCancelled else { return }
        state = .ready
    }

    private var openExternal: () -> Void {
        onOpenExternal ?? { NSWorkspace.shared.open(url) }
    }
}

private enum BasketQuickLookLoadState {
    case idle
    case loading
    case ready
    case failed(String)
}

private struct BasketEmbeddedQuickLookView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        guard let previewView = QLPreviewView(frame: .zero, style: .normal) else {
            let label = NSTextField(labelWithString: "系统无法创建内嵌预览")
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            return container
        }
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.autostarts = true
        previewView.shouldCloseWithWindow = true
        previewView.previewItem = url as NSURL
        container.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: container.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.previewView = previewView
        context.coordinator.currentURL = url
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let previewView = context.coordinator.previewView else { return }
        guard context.coordinator.currentURL != url else { return }
        // Clear first so a reused representable cannot hold the old preview
        // item while Quick Look prepares the replacement.
        previewView.previewItem = nil
        previewView.previewItem = url as NSURL
        context.coordinator.currentURL = url
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        if let previewView = coordinator.previewView {
            previewView.autostarts = false
            previewView.previewItem = nil
            previewView.removeFromSuperview()
        }
        coordinator.previewView = nil
        container.subviews.forEach { $0.removeFromSuperview() }
        coordinator.currentURL = nil
    }

    final class Coordinator {
        var currentURL: URL?
        weak var previewView: QLPreviewView?
    }
}
