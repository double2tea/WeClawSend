import AppKit

enum FinderServiceAction: Equatable, Sendable {
    case send
    case addToBasket
}

@MainActor
final class FinderServiceProvider: NSObject {
    typealias Handler = (FinderServiceAction, [URL]) -> Void

    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    @objc(sendSelectedFiles:userData:error:)
    func sendSelectedFiles(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        perform(
            action: .send,
            pasteboard: pasteboard,
            includingDirectories: false,
            emptyMessage: "请选择一个或多个文件后再发送",
            error: error
        )
    }

    @objc(addSelectedFilesToBasket:userData:error:)
    func addSelectedFilesToBasket(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        perform(
            action: .addToBasket,
            pasteboard: pasteboard,
            includingDirectories: true,
            emptyMessage: "请选择文件、文件夹或 macOS 包后再放入文件篮",
            error: error
        )
    }

    private func perform(
        action: FinderServiceAction,
        pasteboard: NSPasteboard,
        includingDirectories: Bool,
        emptyMessage: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = fileURLs(from: pasteboard, includingDirectories: includingDirectories)
        guard !urls.isEmpty else {
            error.pointee = emptyMessage as NSString
            return
        }
        handler(action, urls)
    }
}
