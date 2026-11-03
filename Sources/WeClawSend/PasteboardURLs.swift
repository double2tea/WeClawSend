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

enum FileExportURLs {
    static let retentionInterval: TimeInterval = 60 * 60
    @MainActor static var activeDragURLs: [URL] = []

    static func prepare(
        _ urls: [URL],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> [URL] {
        let containerRoots = ["Library/Containers", "Library/Group Containers"].map {
            homeDirectory.appendingPathComponent($0).resolvingSymlinksInPath().path + "/"
        }
        let exportDirectory = temporaryDirectory
            .appendingPathComponent("WeClawSend-Exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var createdExportDirectory = false
        do {
            return try urls.enumerated().map { index, url in
                let source = url.resolvingSymlinksInPath()
                guard containerRoots.contains(where: { source.path.hasPrefix($0) }) else {
                    return url
                }
                let directory = exportDirectory.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                createdExportDirectory = true
                let destination = directory.appendingPathComponent(url.lastPathComponent)
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                try FileManager.default.copyItem(at: url, to: destination)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date()], ofItemAtPath: exportDirectory.path
                )
                return destination
            }
        } catch {
            if createdExportDirectory {
                try FileManager.default.removeItem(at: exportDirectory)
            }
            throw error
        }
    }

    static func removeCopies(
        for urls: [URL],
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws {
        let root = temporaryDirectory.appendingPathComponent("WeClawSend-Exports", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let directories = Set(urls.compactMap { url -> URL? in
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let prefix = root.path + "/"
            guard path.hasPrefix(prefix) else { return nil }
            let relative = path.dropFirst(prefix.count)
            guard let name = relative.split(separator: "/").first,
                  UUID(uuidString: String(name)) != nil else { return nil }
            return root.appendingPathComponent(String(name), isDirectory: true)
        })
        for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    static func cleanupExpired(
        preserving urls: [URL],
        now: Date = Date(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws {
        let root = temporaryDirectory.appendingPathComponent("WeClawSend-Exports", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let retainedPaths = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey]
        )
        for directory in directories {
            guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
            let values = try directory.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true,
                  let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt) >= retentionInterval else { continue }
            let prefix = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard !retainedPaths.contains(where: { $0.hasPrefix(prefix) }) else { continue }
            try FileManager.default.removeItem(at: directory)
        }
    }
}
