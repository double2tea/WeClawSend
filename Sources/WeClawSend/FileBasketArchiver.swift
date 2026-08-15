import Foundation

struct FileBasketArchiveArtifact: Sendable {
    let fileURL: URL
}

enum FileBasketArchiveError: LocalizedError {
    case empty
    case invalidName
    case invalidFile(String)
    case archiveFailed(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            "文件篮为空"
        case .invalidName:
            "压缩包名称不能为空，也不能包含 / 或 :"
        case let .invalidFile(name):
            "无法读取“\(name)”"
        case let .archiveFailed(message):
            "压缩失败：\(message)"
        }
    }
}

enum FileBasketArchiver {
    private static let directoryName = "FileBasketArchives"

    static func createArchive(urls: [URL], archiveName: String) throws -> FileBasketArchiveArtifact {
        guard !urls.isEmpty else { throw FileBasketArchiveError.empty }
        guard let archiveName = normalizedArchiveName(archiveName) else {
            throw FileBasketArchiveError.invalidName
        }

        let fileManager = FileManager.default
        let workDirectory = rootDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let contentsDirectory = workDirectory.appending(path: "contents", directoryHint: .isDirectory)
        let archiveURL = workDirectory.appending(path: archiveName)

        do {
            try fileManager.createDirectory(at: contentsDirectory, withIntermediateDirectories: true)
            var usedNames = Set<String>()
            for sourceURL in urls {
                let standardizedURL = sourceURL.standardizedFileURL
                guard let kind = ShelfItem.kind(for: standardizedURL) else {
                    throw FileBasketArchiveError.invalidFile(sourceURL.lastPathComponent)
                }
                let name = uniqueName(for: sourceURL.lastPathComponent, usedNames: &usedNames)
                let destinationURL = contentsDirectory.appending(path: name)
                if kind.isDirectory {
                    try fileManager.copyItem(at: standardizedURL, to: destinationURL)
                } else {
                    do {
                        try fileManager.linkItem(at: standardizedURL, to: destinationURL)
                    } catch {
                        try fileManager.copyItem(at: standardizedURL, to: destinationURL)
                    }
                }
            }
            try runDitto(source: contentsDirectory, destination: archiveURL)
            return FileBasketArchiveArtifact(fileURL: archiveURL)
        } catch {
            try? fileManager.removeItem(at: workDirectory)
            throw error
        }
    }

    @discardableResult
    static func cleanup(_ archiveURL: URL) -> Bool {
        guard let directory = managedDirectory(for: archiveURL) else { return false }
        try? FileManager.default.removeItem(at: directory)
        return true
    }

    static func cleanupOrphans(preserving archiveURLs: [URL]) {
        let fileManager = FileManager.default
        let preservedDirectories = Set(archiveURLs.compactMap(managedDirectory(for:)).map(\.path))
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for directory in directories where !preservedDirectories.contains(directory.path) {
            try? fileManager.removeItem(at: directory)
        }
    }

    static func normalizedArchiveName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare(".zip") != .orderedSame,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains(":")
        else { return nil }
        return trimmed.lowercased().hasSuffix(".zip") ? trimmed : "\(trimmed).zip"
    }

    private static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "WeClawSend", directoryHint: .isDirectory)
            .appending(path: directoryName, directoryHint: .isDirectory)
    }

    private static func managedDirectory(for archiveURL: URL) -> URL? {
        let rootPath = rootDirectory.standardizedFileURL.path + "/"
        let standardizedURL = archiveURL.standardizedFileURL
        guard standardizedURL.path.hasPrefix(rootPath) else { return nil }
        let directory = standardizedURL.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == rootDirectory.standardizedFileURL else {
            return nil
        }
        return directory
    }

    private static func uniqueName(for fileName: String, usedNames: inout Set<String>) -> String {
        if usedNames.insert(fileName.lowercased()).inserted {
            return fileName
        }

        let url = URL(fileURLWithPath: fileName)
        let fileExtension = url.pathExtension
        let stem = fileExtension.isEmpty
            ? fileName
            : url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
            let candidate = "\(stem) \(index)\(suffix)"
            if usedNames.insert(candidate.lowercased()).inserted {
                return candidate
            }
            index += 1
        }
    }

    private static func runDitto(source: URL, destination: URL) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--norsrc", "--noextattr", "--noacl",
            source.path,
            destination.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw FileBasketArchiveError.archiveFailed(message.isEmpty ? "ditto 退出码 \(process.terminationStatus)" : message)
        }
    }
}
