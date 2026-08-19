import AppKit
import Foundation

enum BasketImageClipStoreError: LocalizedError {
    case imageEncodingFailed
    case pngTooLarge(limit: Int)
    case storageDirectoryUnavailable(URL)
    case notManagedFile(URL)
    case notRegularFile(URL)
    case writeFailed(URL)
    case deleteFailed(URL)

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "无法将图片保存为 PNG。"
        case let .pngTooLarge(limit):
            return "图片 PNG 文件不能超过 \(limit / 1024 / 1024) MiB。"
        case let .storageDirectoryUnavailable(url):
            return "无法使用图片便笺目录：\(url.path)"
        case let .notManagedFile(url):
            return "该文件不属于图片便笺目录：\(url.lastPathComponent)"
        case let .notRegularFile(url):
            return "图片便笺不是普通文件：\(url.lastPathComponent)"
        case let .writeFailed(url):
            return "无法写入图片便笺：\(url.lastPathComponent)"
        case let .deleteFailed(url):
            return "无法删除图片便笺：\(url.lastPathComponent)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .imageEncodingFailed:
            return "请换一张图片后重试。"
        case .pngTooLarge:
            return "请使用尺寸更小的图片后重试。"
        case .storageDirectoryUnavailable:
            return "请检查应用支持目录的访问权限。"
        case .notManagedFile, .notRegularFile, .writeFailed, .deleteFailed:
            return nil
        }
    }
}

struct BasketImageClipStore {
    static let maximumPNGByteCount = 20 * 1024 * 1024
    static let maximumPNGBytes = maximumPNGByteCount

    private static let maximumTitleCharacterCount = 64
    private static let fallbackTitle = "图片便笺"

    let storageDirectory: URL

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("WeClawSend", isDirectory: true)
            .appendingPathComponent("Basket Content", isDirectory: true)
            .appendingPathComponent("Images", isDirectory: true)
        self.init(directory: directory, fileManager: fileManager)
    }

    init(directory: URL, fileManager: FileManager = .default) {
        self.storageDirectory = directory.standardizedFileURL
        self.fileManager = fileManager
    }

    private static var defaultStore: BasketImageClipStore {
        BasketImageClipStore()
    }

    static func create(
        image: NSImage,
        preferredTitle: String? = nil,
        now: Date = Date()
    ) throws -> URL {
        try defaultStore.create(image: image, preferredTitle: preferredTitle, now: now)
    }

    static func isManaged(_ url: URL) -> Bool {
        defaultStore.isManaged(url)
    }

    @discardableResult
    static func deleteIfManaged(_ url: URL) -> Bool {
        (try? defaultStore.deleteIfManaged(url)) == true
    }

    func create(
        image: NSImage,
        preferredTitle: String? = nil,
        now: Date = Date()
    ) throws -> URL {
        let pngData = try pngData(for: image)
        guard pngData.count <= Self.maximumPNGByteCount else {
            throw BasketImageClipStoreError.pngTooLarge(limit: Self.maximumPNGByteCount)
        }

        try ensureStorageDirectory()

        let titleSource: String
        if let preferredTitle = preferredTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferredTitle.isEmpty {
            titleSource = preferredTitle
        } else {
            titleSource = fallbackTitle(for: now)
        }

        let title = sanitizedTitle(titleSource)
        let resolvedTitle = title.isEmpty ? Self.fallbackTitle : title
        let shortID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let baseName = "\(resolvedTitle)-\(shortID)"
        let fileURL = storageDirectory
            .appendingPathComponent(baseName, isDirectory: false)
            .appendingPathExtension("png")

        do {
            try pngData.write(to: fileURL, options: .atomic)
        } catch {
            throw BasketImageClipStoreError.writeFailed(fileURL)
        }
        return fileURL
    }

    func isManaged(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let directoryPath = normalized(storageDirectory).path
        let filePath = normalized(url).path
        guard filePath != directoryPath else { return false }
        let directoryPrefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return filePath.hasPrefix(directoryPrefix)
    }

    @discardableResult
    func deleteIfManaged(_ url: URL) throws -> Bool {
        guard isManaged(url) else { return false }
        let lexicalURL = url.standardizedFileURL
        guard isRegularFile(lexicalURL) else { return false }
        let managedURL = normalized(url)
        guard isRegularFile(managedURL) else { return false }

        do {
            try fileManager.removeItem(at: managedURL)
        } catch {
            throw BasketImageClipStoreError.deleteFailed(managedURL)
        }
        return true
    }

    private func pngData(for image: NSImage) throws -> Data {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw BasketImageClipStoreError.imageEncodingFailed
        }
        return pngData
    }

    private func ensureStorageDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw BasketImageClipStoreError.storageDirectoryUnavailable(storageDirectory)
        }
    }

    private func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func fallbackTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "HH-mm"
        return "\(Self.fallbackTitle) \(formatter.string(from: date))"
    }

    private func sanitizedTitle(_ title: String) -> String {
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(title.unicodeScalars.count)
        for scalar in title.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\\" {
                scalars.append("-")
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                scalars.append(scalar)
            }
        }
        let sanitized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(sanitized.prefix(Self.maximumTitleCharacterCount))
    }
}
