import Foundation

enum FolderWatchAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case direct
    case basket

    var id: String { rawValue }
}

enum FolderWatchFileType: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case video
    case image
    case audio
    case document
    case archive
    case custom

    var id: String { rawValue }

    fileprivate var extensions: Set<String> {
        switch self {
        case .all, .custom:
            return []
        case .video:
            return ["avi", "m4v", "mkv", "mov", "mp4", "webm"]
        case .image:
            return ["bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp"]
        case .audio:
            return ["aac", "aiff", "flac", "m4a", "mp3", "ogg", "wav"]
        case .document:
            return [
                "csv", "doc", "docx", "htm", "html", "json", "key", "md", "pages", "pdf", "ppt", "pptx",
                "rtf", "txt", "xls", "xlsx", "xml"
            ]
        case .archive:
            return ["7z", "bz2", "gz", "rar", "tar", "xz", "zip"]
        }
    }
}

struct FolderWatchRule: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var folderPath: String
    var includesSubfolders: Bool
    var action: FolderWatchAction
    var basketID: UUID?
    var fileTypeAllowlist: Set<FolderWatchFileType>
    var customExtensions: [String]
    var enabled: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        folderPath: String,
        includesSubfolders: Bool = false,
        action: FolderWatchAction = .direct,
        basketID: UUID? = nil,
        fileTypeAllowlist: Set<FolderWatchFileType> = [.all],
        customExtensions: [String] = [],
        enabled: Bool = true,
        createdAt: Date = .now
    ) {
        self.id = id
        self.folderPath = FolderWatchRule.normalizePath(folderPath)
        self.includesSubfolders = includesSubfolders
        self.action = action
        self.basketID = basketID
        self.fileTypeAllowlist = fileTypeAllowlist
        self.customExtensions = FolderWatchRule.normalizeExtensions(customExtensions)
        self.enabled = enabled
        self.createdAt = createdAt
    }

    var folderURL: URL { URL(fileURLWithPath: folderPath) }

    /// Returns a canonical copy before persistence or path comparisons.
    func normalized() -> FolderWatchRule {
        FolderWatchRule(
            id: id,
            folderPath: folderPath,
            includesSubfolders: includesSubfolders,
            action: action,
            basketID: basketID,
            fileTypeAllowlist: fileTypeAllowlist,
            customExtensions: customExtensions,
            enabled: enabled,
            createdAt: createdAt
        )
    }

    /// Tests the file name only. The watcher remains responsible for checking that the path is a regular file.
    func allowsFile(named fileName: String) -> Bool {
        guard !FolderWatchRule.isIgnoredFileName(fileName) else { return false }
        guard !fileTypeAllowlist.isEmpty else { return false }
        if fileTypeAllowlist.contains(.all) { return true }

        let extensionName = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard !extensionName.isEmpty else { return false }
        if fileTypeAllowlist.contains(.custom), customExtensions.contains(extensionName) {
            return true
        }
        return fileTypeAllowlist.contains { $0 != .all && $0 != .custom && $0.extensions.contains(extensionName) }
    }

    func allowsFile(at url: URL) -> Bool {
        allowsFile(named: url.lastPathComponent)
    }

    static func normalizePath(_ path: String) -> String {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return "" }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard standardized.count > 1 else { return standardized }
        return standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty ? "/" : standardized.trimmingTrailingSlash()
    }

    static func normalizeExtensions(_ extensions: [String]) -> [String] {
        Array(Set(extensions.compactMap { extensionName in
            let normalized = extensionName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            return normalized.isEmpty ? nil : normalized
        })).sorted()
    }

    static func isIgnoredFileName(_ fileName: String) -> Bool {
        let name = URL(fileURLWithPath: fileName).lastPathComponent
        guard !name.isEmpty else { return true }
        if name.hasPrefix(".") || name.hasPrefix("~$") { return true }
        if name == ".DS_Store" || name == "Thumbs.db" { return true }
        return [".crdownload", ".download", ".part", ".partial", ".temp", ".tmp", "~"]
            .contains { name.lowercased().hasSuffix($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case folderPath = "folder_path"
        case includesSubfolders = "includes_subfolders"
        case action
        case basketID = "basket_id"
        case fileTypeAllowlist = "file_type_allowlist"
        case customExtensions = "custom_extensions"
        case enabled
        case createdAt = "created_at"
    }
}

enum FolderWatchRecordStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case discovered
    case waiting
    case processing
    case sent
    case addedToBasket = "added_to_basket"
    case ignored
    case failed

    var id: String { rawValue }
}

struct FolderWatchRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let discoveredAt: Date
    let filePath: String
    let ruleID: UUID
    var status: FolderWatchRecordStatus
    var message: String?

    init(
        id: UUID = UUID(),
        discoveredAt: Date = .now,
        filePath: String,
        ruleID: UUID,
        status: FolderWatchRecordStatus = .discovered,
        message: String? = nil
    ) {
        self.id = id
        self.discoveredAt = discoveredAt
        self.filePath = FolderWatchRule.normalizePath(filePath)
        self.ruleID = ruleID
        self.status = status
        self.message = message
    }

    var fileURL: URL { URL(fileURLWithPath: filePath) }
    var fileName: String { fileURL.lastPathComponent }

    private enum CodingKeys: String, CodingKey {
        case id
        case discoveredAt = "discovered_at"
        case filePath = "file_path"
        case ruleID = "rule_id"
        case status
        case message
    }
}

enum FolderWatchPathCheck: Equatable, Sendable {
    case available
    case invalidPath
    case duplicate(existingRuleID: UUID)
    case overlaps(existingRuleID: UUID)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

enum FolderWatchStoreError: LocalizedError, Equatable {
    case invalidPath
    case duplicate(existingRuleID: UUID)
    case overlaps(existingRuleID: UUID)
    case ruleNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "监控文件夹路径不能为空"
        case let .duplicate(existingRuleID):
            return "监控文件夹已存在：\(existingRuleID.uuidString)"
        case let .overlaps(existingRuleID):
            return "监控文件夹与已有规则重叠：\(existingRuleID.uuidString)"
        case let .ruleNotFound(id):
            return "未找到监控规则：\(id.uuidString)"
        }
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        guard count > 1 else { return self }
        return hasSuffix("/") ? String(dropLast()) : self
    }
}
