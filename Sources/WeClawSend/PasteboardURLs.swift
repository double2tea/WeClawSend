import AppKit

func fileURLs(from pasteboard: NSPasteboard, includingDirectories: Bool = false) -> [URL] {
    let objects = pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
    ) ?? []
    return objects
        .compactMap { ($0 as? NSURL) as URL? }
        .filter { url in
            guard let kind = ShelfItem.kind(for: url) else { return false }
            return includingDirectories || kind == .file
        }
}
