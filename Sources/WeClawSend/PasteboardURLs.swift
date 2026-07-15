import AppKit

func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
    let objects = pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
    ) ?? []
    return objects
        .compactMap { ($0 as? NSURL) as URL? }
        .filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
}
