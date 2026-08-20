import Foundation

enum BasketTextClipStoreError: LocalizedError {
    case emptyText
    case textTooLarge(limit: Int)
    case storageDirectoryUnavailable(URL)
    case notManagedFile(URL)
    case notRegularFile(URL)
    case invalidUTF8(URL)
    case readFailed(URL)
    case writeFailed(URL)
    case updateFailed(URL)
    case deleteFailed(URL)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "文本内容不能为空。"
        case let .textTooLarge(limit):
            return "文本不能超过 \(limit / 1024) KiB。"
        case let .storageDirectoryUnavailable(url):
            return "无法使用文本便笺目录：\(url.path)"
        case let .notManagedFile(url):
            return "该文件不属于文本便笺目录：\(url.lastPathComponent)"
        case let .notRegularFile(url):
            return "文本便笺不是普通文件：\(url.lastPathComponent)"
        case let .invalidUTF8(url):
            return "文本便笺不是有效的 UTF-8 文件：\(url.lastPathComponent)"
        case let .readFailed(url):
            return "无法读取文本便笺：\(url.lastPathComponent)"
        case let .writeFailed(url):
            return "无法写入文本便笺：\(url.lastPathComponent)"
        case let .updateFailed(url):
            return "无法更新文本便笺：\(url.lastPathComponent)"
        case let .deleteFailed(url):
            return "无法删除文本便笺：\(url.lastPathComponent)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .emptyText:
            return "请输入内容后再保存。"
        case .textTooLarge:
            return "请减少文本内容后再保存。"
        case .storageDirectoryUnavailable:
            return "请检查应用支持目录的访问权限。"
        case .notManagedFile, .notRegularFile, .invalidUTF8, .readFailed, .writeFailed, .updateFailed, .deleteFailed:
            return nil
        }
    }
}

struct BasketTextClipStore {
    static let maximumTextByteCount = 256 * 1024
    static let maximumTextBytes = maximumTextByteCount
    private static let maximumTitleCharacterCount = 64
    private static let fallbackTitle = "文本便笺"

    let storageDirectory: URL

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("WeClawSend", isDirectory: true)
            .appendingPathComponent("Basket Content", isDirectory: true)
        self.init(directory: directory, fileManager: fileManager)
    }

    init(directory: URL, fileManager: FileManager = .default) {
        self.storageDirectory = directory.standardizedFileURL
        self.fileManager = fileManager
    }

    private static var defaultStore: BasketTextClipStore {
        BasketTextClipStore()
    }

    static func create(text: String, preferredTitle: String? = nil, now: Date = Date()) throws -> URL {
        try defaultStore.create(text: text, preferredTitle: preferredTitle, now: now)
    }

    static func isManaged(_ url: URL) -> Bool {
        defaultStore.isManaged(url)
    }

    static func readText(at url: URL) throws -> String {
        try defaultStore.readText(at: url)
    }

    static func readPreview(at url: URL, maxCharacters: Int = 240) -> String? {
        defaultStore.readPreview(at: url, maxCharacters: maxCharacters)
    }

    static func update(text: String, at url: URL) throws {
        try defaultStore.update(text: text, at: url)
    }

    @discardableResult
    static func deleteIfManaged(_ url: URL) -> Bool {
        (try? defaultStore.deleteIfManaged(url)) == true
    }

    func create(text: String, preferredTitle: String? = nil, now: Date = Date()) throws -> URL {
        let data = try validatedData(for: text)
        try ensureStorageDirectory()

        let titleSource: String
        if let preferredTitle = preferredTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !preferredTitle.isEmpty {
            titleSource = preferredTitle
        } else if let firstLine = firstNonEmptyLine(in: text) {
            titleSource = firstLine
        } else {
            titleSource = fallbackTitle(for: now)
        }
        let title = sanitizedTitle(titleSource)
        let resolvedTitle = title.isEmpty ? Self.fallbackTitle : title
        let shortID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let baseName = "\(resolvedTitle)-\(shortID)"
        let fileURL = storageDirectory.appendingPathComponent(baseName, isDirectory: false)
            .appendingPathExtension("txt")

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw BasketTextClipStoreError.writeFailed(fileURL)
        }
        return fileURL
    }

    func isManaged(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let fileURL = normalized(url)
        guard fileURL.pathExtension.lowercased() == "txt" else { return false }
        let directoryPath = normalized(storageDirectory).path
        let filePath = fileURL.path
        guard filePath != directoryPath else { return false }
        let directoryPrefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        guard filePath.hasPrefix(directoryPrefix) else { return false }
        let relative = String(filePath.dropFirst(directoryPrefix.count))
        // Image clips live in a subdirectory of the default text directory.
        return !relative.isEmpty && !relative.contains("/")
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
            throw BasketTextClipStoreError.deleteFailed(managedURL)
        }
        return true
    }

    func readText(at url: URL) throws -> String {
        let managedURL = try managedRegularFileURL(for: url)
        let data: Data
        do {
            data = try Data(contentsOf: managedURL, options: [.mappedIfSafe])
        } catch {
            throw BasketTextClipStoreError.readFailed(managedURL)
        }
        guard data.count <= Self.maximumTextByteCount else {
            throw BasketTextClipStoreError.textTooLarge(limit: Self.maximumTextByteCount)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BasketTextClipStoreError.invalidUTF8(managedURL)
        }
        return text
    }

    func readPreview(at url: URL, maxCharacters: Int = 240) -> String? {
        guard maxCharacters >= 0 else { return nil }
        do {
            return String(try readText(at: url).prefix(maxCharacters))
        } catch {
            return nil
        }
    }

    func update(text: String, at url: URL) throws {
        let managedURL = try managedRegularFileURL(for: url)
        let data = try validatedData(for: text)
        do {
            try data.write(to: managedURL, options: .atomic)
        } catch {
            throw BasketTextClipStoreError.updateFailed(managedURL)
        }
    }

    private func validatedData(for text: String) throws -> Data {
        guard !text.isEmpty else { throw BasketTextClipStoreError.emptyText }
        let data = Data(text.utf8)
        guard data.count <= Self.maximumTextByteCount else {
            throw BasketTextClipStoreError.textTooLarge(limit: Self.maximumTextByteCount)
        }
        return data
    }

    private func ensureStorageDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw BasketTextClipStoreError.storageDirectoryUnavailable(storageDirectory)
        }
    }

    private func managedRegularFileURL(for url: URL) throws -> URL {
        guard isManaged(url) else {
            throw BasketTextClipStoreError.notManagedFile(url)
        }
        let lexicalURL = url.standardizedFileURL
        guard isRegularFile(lexicalURL) else {
            throw BasketTextClipStoreError.notRegularFile(lexicalURL)
        }
        let managedURL = normalized(url)
        guard isRegularFile(managedURL) else {
            throw BasketTextClipStoreError.notRegularFile(managedURL)
        }
        return managedURL
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

    private func firstNonEmptyLine(in text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            .map { String($0) }
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
            if scalar == "/" || scalar == ":" {
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
