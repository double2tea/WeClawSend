import AppKit
import ImageIO
import SwiftUI

enum BasketImageScaleMode: String, CaseIterable, Identifiable {
    case fit
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: "适应"
        case .original: "原始"
        }
    }
}

/// An in-window image reader.  Fit mode keeps the complete image visible;
/// original mode uses the image's native point size inside a two-axis scroll
/// view, preserving the aspect ratio in both cases.
struct BasketImageReaderView: View {
    nonisolated static let maximumEmbeddedFileSize: Int64 = 100 * 1024 * 1024
    nonisolated static let maximumEmbeddedDimension: Int = 30_000
    nonisolated static let maximumDecodedDimension: Int = 4_096

    let url: URL
    let onOpenExternal: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state: BasketImageLoadState = .idle
    @State private var scaleMode: BasketImageScaleMode = .fit

    init(url: URL, onOpenExternal: (() -> Void)? = nil) {
        self.url = url
        self.onOpenExternal = onOpenExternal
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            readerContent

            if case let .ready(image, nativeSize) = state {
                scaleControls(image: image, nativeSize: nativeSize)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: url) {
            await loadImage()
        }
        .onDisappear {
            // NSImage can retain decoded bitmap representations.  Clearing
            // state when leaving the reader keeps that memory scoped to the
            // current reader session.
            state = .idle
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("图片阅读器：\(url.lastPathComponent)")
    }

    @ViewBuilder
    private var readerContent: some View {
        switch state {
        case .idle, .loading:
            BasketReaderLoadingView(
                title: "正在打开图片…",
                detail: url.lastPathComponent,
                systemImage: "photo"
            )
        case let .ready(image, _):
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    imageContent(image, viewport: geometry.size)
                        .frame(
                            minWidth: geometry.size.width,
                            minHeight: geometry.size.height,
                            alignment: .center
                        )
                }
                .scrollIndicators(.automatic)
            }
        case let .failed(message):
            BasketReaderErrorView(
                title: "无法打开图片",
                message: message,
                systemImage: "photo",
                actionTitle: "在预览中打开",
                action: openExternal
            )
        }
    }

    @ViewBuilder
    private func imageContent(
        _ image: NSImage,
        viewport: CGSize
    ) -> some View {
        let inset: CGFloat = 24
        switch scaleMode {
        case .fit:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    maxWidth: max(viewport.width - inset, 1),
                    maxHeight: max(viewport.height - inset, 1)
                )
                .padding(inset / 2)
        case .original:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    width: max(image.size.width, 1),
                    height: max(image.size.height, 1)
                )
                .padding(inset / 2)
        }
    }

    private func scaleControls(image: NSImage, nativeSize: CGSize) -> some View {
        HStack(spacing: 8) {
            BasketReaderInfoBadge(
                title: imageSizeLabel(image: image, nativeSize: nativeSize),
                systemImage: "ruler"
            )

            Spacer(minLength: 4)

            Picker("显示比例", selection: $scaleMode) {
                ForEach(BasketImageScaleMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 112)
            .help("适应窗口，或按解码后的像素尺寸显示")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .padding(12)
    }

    private func imageSizeLabel(image: NSImage, nativeSize: CGSize) -> String {
        let nativeWidth = Int(nativeSize.width.rounded())
        let nativeHeight = Int(nativeSize.height.rounded())
        let decodedWidth = Int(image.size.width.rounded())
        let decodedHeight = Int(image.size.height.rounded())
        if decodedWidth == nativeWidth, decodedHeight == nativeHeight {
            return "\(nativeWidth) × \(nativeHeight)"
        }
        return "\(decodedWidth) × \(decodedHeight)（原图 \(nativeWidth)×\(nativeHeight)）"
    }

    private func loadImage() async {
        state = .loading
        scaleMode = .fit
        await Task.yield()
        guard !Task.isCancelled else { return }
        let result = await Task.detached(priority: .userInitiated) { [url] in
            Self.decodeImage(at: url)
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case let .success(payload):
            state = .ready(payload.image, payload.nativeSize)
        case let .failure(message):
            state = .failed(message)
        }
    }

    private nonisolated static func decodeImage(at url: URL) -> BasketImageDecodeResult {
        guard url.isFileURL else {
            return .failure("阅读器只支持本地图片。")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure("文件不存在或已被移动。")
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                return .failure("该项目不是可读取的图片文件。")
            }
            if let byteCount = values.fileSize, Int64(byteCount) > maximumEmbeddedFileSize {
                return .failure("图片文件超过 100 MiB，请使用系统预览打开。")
            }
        } catch {
            return .failure("无法读取文件信息。")
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return .failure("系统无法解码这张图片，请使用系统预览打开。")
        }
        let nativeSize = CGSize(width: width.doubleValue, height: height.doubleValue)
        guard nativeSize.width > 0, nativeSize.height > 0 else {
            return .failure("图片没有有效的尺寸信息。")
        }
        guard nativeSize.width <= CGFloat(maximumEmbeddedDimension),
              nativeSize.height <= CGFloat(maximumEmbeddedDimension) else {
            return .failure("图片尺寸过大，请使用系统预览打开。")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDecodedDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .failure("系统无法解码这张图片，请使用系统预览打开。")
        }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        return .success(BasketDecodedImage(image: image, nativeSize: nativeSize))
    }

    private var openExternal: () -> Void {
        onOpenExternal ?? { NSWorkspace.shared.open(url) }
    }
}

private struct BasketDecodedImage: @unchecked Sendable {
    let image: NSImage
    let nativeSize: CGSize
}

private enum BasketImageDecodeResult: @unchecked Sendable {
    case success(BasketDecodedImage)
    case failure(String)
}

private enum BasketImageLoadState {
    case idle
    case loading
    case ready(NSImage, CGSize)
    case failed(String)
}
