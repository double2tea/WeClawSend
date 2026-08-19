import AppKit
import PDFKit
import SwiftUI

/// A PDF reader that stays inside the reader window.  It deliberately avoids
/// `QLPreviewPanel.shared()` so it cannot take ownership of the file basket's
/// system Quick Look panel.
struct BasketPDFReaderView: View {
    nonisolated static let maximumEmbeddedFileSize: Int64 = 100 * 1024 * 1024

    let url: URL
    let onOpenExternal: (() -> Void)?
    let onPageChange: ((Int, Int) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state: BasketPDFLoadState = .idle
    @State private var zoomRevision = 0
    @State private var zoomAction: BasketPDFZoomAction = .fit
    @State private var currentPage = 0
    @State private var pageCount = 0
    @State private var searchQuery = ""
    @State private var searchMatches: [PDFSelection] = []
    @State private var searchMatchIndex = 0
    @State private var searchRevision = 0
    @FocusState private var isSearchFocused: Bool

    init(
        url: URL,
        onOpenExternal: (() -> Void)? = nil,
        onPageChange: ((Int, Int) -> Void)? = nil
    ) {
        self.url = url
        self.onOpenExternal = onOpenExternal
        self.onPageChange = onPageChange
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            readerContent

            if case .ready = state {
                pdfControls
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: url) {
            await loadPDF()
        }
        .onDisappear {
            // Releasing the document here matters for large PDFs.  The
            // representable also clears its PDFView in dismantleNSView.
            state = .idle
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PDF 阅读器：\(url.lastPathComponent)")
    }

    @ViewBuilder
    private var readerContent: some View {
        switch state {
        case .idle, .loading:
            BasketReaderLoadingView(
                title: "正在打开 PDF…",
                detail: url.lastPathComponent,
                systemImage: "doc.richtext"
            )
        case let .ready(document):
            BasketPDFDocumentView(
                document: document,
                zoomAction: zoomAction,
                zoomRevision: zoomRevision,
                searchSelection: currentSearchSelection,
                searchRevision: searchRevision,
                onPageChange: { page, pages in
                    currentPage = page
                    pageCount = pages
                    onPageChange?(page, pages)
                }
            )
            .overlay(alignment: .topLeading) {
                if pageCount > 0 {
                    BasketReaderInfoBadge(
                        title: "第 \(max(currentPage, 1)) / \(pageCount) 页",
                        systemImage: "doc.text"
                    )
                    .padding(12)
                }
            }
        case let .fallback(message):
            BasketReaderErrorView(
                title: "PDF 暂不适合内嵌阅读",
                message: message,
                systemImage: "arrow.up.right.square",
                actionTitle: "在预览中打开",
                action: openExternal
            )
        case let .failed(message):
            BasketReaderErrorView(
                title: "无法打开 PDF",
                message: message,
                systemImage: "doc.richtext",
                actionTitle: "在预览中打开",
                action: openExternal
            )
        }
    }

    private var pdfControls: some View {
        HStack(spacing: 4) {
            Button {
                isSearchFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: [.command])
            .help("搜索 PDF")
            TextField("搜索 PDF", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .frame(width: 110)
                .onSubmit(performSearch)
            if !searchQuery.isEmpty {
                Text(searchResultLabel)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button { moveSearch(by: -1) } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(searchMatches.isEmpty)
                Button { moveSearch(by: 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(searchMatches.isEmpty)
            }

            Divider().frame(height: 16).padding(.horizontal, 3)

            Button {
                issueZoom(.out)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("缩小")

            Button {
                issueZoom(.fit)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("适应页面")

            Button {
                issueZoom(.in)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("放大")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .padding(12)
        // The view contains no transition or repeating animation.  Keeping
        // this explicit prevents an ancestor animation from animating the
        // controls when Reduce Motion is enabled.
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
    }

    private func issueZoom(_ action: BasketPDFZoomAction) {
        zoomAction = action
        zoomRevision &+= 1
    }

    private func loadPDF() async {
        state = .loading
        currentPage = 0
        pageCount = 0
        searchQuery = ""
        searchMatches = []
        searchMatchIndex = 0

        await Task.yield()
        guard !Task.isCancelled else { return }
        let result = await Task.detached(priority: .userInitiated) { [url] in
            Self.openPDF(at: url)
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case let .ready(document):
            state = .ready(document)
        case let .fallback(message):
            state = .fallback(message)
        case let .failed(message):
            state = .failed(message)
        }
    }

    private nonisolated static func openPDF(at url: URL) -> BasketPDFOpenResult {
        guard url.isFileURL else {
            return .failed("阅读器只支持本地文件。")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failed("文件不存在或已被移动。")
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                return .failed("该项目不是可读取的 PDF 文件。")
            }
            if let byteCount = values.fileSize, Int64(byteCount) > maximumEmbeddedFileSize {
                return .fallback("文件超过 100 MiB。为了保持文件篮流畅，请使用系统预览打开。")
            }
        } catch {
            return .failed("无法读取文件信息。")
        }
        guard let document = PDFDocument(url: url) else {
            return .failed("PDF 内容损坏，或系统暂时无法解析该文件。")
        }
        guard document.pageCount > 0 else {
            return .failed("该 PDF 没有可显示的页面。")
        }
        return .ready(document)
    }

    private var currentSearchSelection: PDFSelection? {
        guard searchMatches.indices.contains(searchMatchIndex) else { return nil }
        return searchMatches[searchMatchIndex]
    }

    private var searchResultLabel: String {
        guard !searchMatches.isEmpty else { return "无匹配" }
        return "\(searchMatchIndex + 1)/\(searchMatches.count)"
    }

    private func performSearch() {
        guard case let .ready(document) = state else { return }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchMatches = []
            searchMatchIndex = 0
            searchRevision &+= 1
            return
        }
        searchMatches = document.findString(query, withOptions: .caseInsensitive)
        searchMatchIndex = 0
        searchRevision &+= 1
    }

    private func moveSearch(by offset: Int) {
        guard !searchMatches.isEmpty else { return }
        searchMatchIndex = (searchMatchIndex + offset + searchMatches.count) % searchMatches.count
        searchRevision &+= 1
    }

    private var openExternal: () -> Void {
        onOpenExternal ?? { NSWorkspace.shared.open(url) }
    }
}

private enum BasketPDFOpenResult: @unchecked Sendable {
    case ready(PDFDocument)
    case fallback(String)
    case failed(String)
}

private enum BasketPDFLoadState {
    case idle
    case loading
    case ready(PDFDocument)
    case fallback(String)
    case failed(String)
}

private enum BasketPDFZoomAction {
    case `in`
    case out
    case fit
}

private struct BasketPDFDocumentView: NSViewRepresentable {
    let document: PDFDocument
    let zoomAction: BasketPDFZoomAction
    let zoomRevision: Int
    let searchSelection: PDFSelection?
    let searchRevision: Int
    let onPageChange: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChange: onPageChange)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView(frame: .zero)
        configure(pdfView)
        context.coordinator.attach(to: pdfView)
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
        if let firstPage = document.page(at: 0) {
            pdfView.go(to: firstPage)
        }
        context.coordinator.fitAfterLayout(pdfView, document: document)
        context.coordinator.reportCurrentPage(in: pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document !== document {
            pdfView.document = document
            pdfView.autoScales = true
            pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
            if let firstPage = document.page(at: 0) {
                pdfView.go(to: firstPage)
            }
            context.coordinator.fitAfterLayout(pdfView, document: document)
            context.coordinator.reportCurrentPage(in: pdfView)
        }
        context.coordinator.apply(
            zoomAction: zoomAction,
            revision: zoomRevision,
            to: pdfView
        )
        context.coordinator.apply(
            searchSelection: searchSelection,
            revision: searchRevision,
            to: pdfView
        )
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.detach()
        pdfView.document = nil
        pdfView.delegate = nil
        pdfView.removeFromSuperview()
    }

    private func configure(_ pdfView: PDFView) {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 6
        pdfView.backgroundColor = .clear
        pdfView.pageBreakMargins = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        pdfView.wantsLayer = true
        pdfView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    @MainActor
    final class Coordinator: NSObject {
        private let onPageChange: (Int, Int) -> Void
        private weak var pdfView: PDFView?
        private var pageObserver: NSObjectProtocol?
        private var lastZoomRevision = -1
        private var lastSearchRevision = 0

        init(onPageChange: @escaping (Int, Int) -> Void) {
            self.onPageChange = onPageChange
        }

        func attach(to pdfView: PDFView) {
            self.pdfView = pdfView
            pageObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self, weak pdfView] _ in
                Task { @MainActor [weak self, weak pdfView] in
                    guard let self, let pdfView else { return }
                    self.reportCurrentPage(in: pdfView)
                }
            }
        }

        func detach() {
            if let pageObserver {
                NotificationCenter.default.removeObserver(pageObserver)
                self.pageObserver = nil
            }
            pdfView = nil
        }

        func reportCurrentPage(in pdfView: PDFView) {
            guard let document = pdfView.document,
                  let page = pdfView.currentPage else {
                return
            }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return }
            onPageChange(pageIndex + 1, document.pageCount)
        }

        func fitAfterLayout(_ pdfView: PDFView, document: PDFDocument) {
            Task { @MainActor [weak pdfView] in
                await Task.yield()
                guard let pdfView, pdfView.document === document else { return }
                pdfView.layoutSubtreeIfNeeded()
                pdfView.autoScales = true
                let scale = pdfView.scaleFactorForSizeToFit
                if scale.isFinite, scale > 0 {
                    pdfView.scaleFactor = scale
                }
            }
        }

        func apply(
            zoomAction: BasketPDFZoomAction,
            revision: Int,
            to pdfView: PDFView
        ) {
            guard revision != lastZoomRevision else { return }
            lastZoomRevision = revision

            switch zoomAction {
            case .in:
                pdfView.autoScales = false
                pdfView.scaleFactor = min(pdfView.maxScaleFactor, pdfView.scaleFactor * 1.2)
            case .out:
                pdfView.autoScales = false
                pdfView.scaleFactor = max(pdfView.minScaleFactor, pdfView.scaleFactor / 1.2)
            case .fit:
                pdfView.autoScales = true
                pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
            }
        }

        func apply(
            searchSelection: PDFSelection?,
            revision: Int,
            to pdfView: PDFView
        ) {
            guard revision != lastSearchRevision else { return }
            lastSearchRevision = revision
            pdfView.setCurrentSelection(searchSelection, animate: true)
            if let searchSelection {
                pdfView.go(to: searchSelection)
            }
        }

    }
}
