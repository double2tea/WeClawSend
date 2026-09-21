import AppKit

let filenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

func fileURLs(from pasteboard: NSPasteboard, includingDirectories: Bool = false) -> [URL] {
    let objects = pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
    ) ?? []
    var urls = objects.compactMap { ($0 as? NSURL) as URL? }
    if urls.isEmpty, let names = pasteboard.propertyList(forType: filenamesPasteboardType) as? [String] {
        urls = names.map { URL(fileURLWithPath: $0) }
    }
    return urls.filter { url in
        guard let kind = ShelfItem.kind(for: url) else { return false }
        return includingDirectories || kind == .file
    }
}
