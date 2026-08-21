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

    var extensions: Set<String> {
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

enum FolderWatchStabilityDelay: Int, Codable, CaseIterable, Identifiable, Sendable {
    case seconds10 = 10
    case seconds30 = 30
    case seconds60 = 60

    var id: Int { rawValue }
    var title: String { "\(rawValue) 秒" }
}

struct FolderWatchRoute: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var action: FolderWatchAction
    var basketID: UUID?
    var fileTypeAllowlist: Set<FolderWatchFileType>
    var customExtensions: [String]

    init(
        id: UUID = UUID(),
        action: FolderWatchAction = .basket,
        basketID: UUID? = nil,
        fileTypeAllowlist: Set<FolderWatchFileType> = [.all],
        customExtensions: [String] = []
    ) {
        self.id = id
        self.action = action
        self.basketID = basketID
        self.fileTypeAllowlist = fileTypeAllowlist
        self.customExtensions = FolderWatchRule.normalizeExtensions(customExtensions)
    }

    func normalized() -> FolderWatchRoute {
        FolderWatchRoute(
            id: id,
            action: action,
            basketID: basketID,
            fileTypeAllowlist: fileTypeAllowlist.isEmpty ? [.all] : fileTypeAllowlist,
            customExtensions: customExtensions
        )
    }

    func allowsFile(named fileName: String) -> Bool {
        guard !FolderWatchRule.isIgnoredFileName(fileName), !fileTypeAllowlist.isEmpty else {
            return false
        }
        if fileTypeAllowlist.contains(.all) { return true }
        let extensionName = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard !extensionName.isEmpty else { return false }
        if fileTypeAllowlist.contains(.custom), customExtensions.contains(extensionName) {
            return true
        }
        return fileTypeAllowlist.contains {
            $0 != .all && $0 != .custom && $0.extensions.contains(extensionName)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case action
        case basketID = "basket_id"
        case fileTypeAllowlist = "file_type_allowlist"
        case customExtensions = "custom_extensions"
    }
}

struct FolderWatchRule: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var folderPath: String
    var includesSubfolders: Bool
    var stabilityDelay: FolderWatchStabilityDelay
    var routes: [FolderWatchRoute]
    var enabled: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        folderPath: String,
        includesSubfolders: Bool = false,
        stabilityDelay: FolderWatchStabilityDelay = .seconds10,
        action: FolderWatchAction = .direct,
        basketID: UUID? = nil,
        fileTypeAllowlist: Set<FolderWatchFileType> = [.all],
        customExtensions: [String] = [],
        routes: [FolderWatchRoute]? = nil,
        enabled: Bool = true,
        createdAt: Date = .now
    ) {
        self.id = id
        self.folderPath = FolderWatchRule.normalizePath(folderPath)
        self.includesSubfolders = includesSubfolders
        self.stabilityDelay = stabilityDelay
        if let routes, !routes.isEmpty {
            self.routes = routes.map { $0.normalized() }
        } else {
            self.routes = [FolderWatchRoute(
                action: action,
                basketID: basketID,
                fileTypeAllowlist: fileTypeAllowlist,
                customExtensions: customExtensions
            )]
        }
        self.enabled = enabled
        self.createdAt = createdAt
    }

    var folderURL: URL { URL(fileURLWithPath: folderPath) }

    var action: FolderWatchAction {
        get { routes.first?.action ?? .direct }
        set { mutateFirstRoute { $0.action = newValue } }
    }

    var basketID: UUID? {
        get { routes.first?.basketID }
        set { mutateFirstRoute { $0.basketID = newValue } }
    }

    var fileTypeAllowlist: Set<FolderWatchFileType> {
        get { routes.first?.fileTypeAllowlist ?? [] }
        set { mutateFirstRoute { $0.fileTypeAllowlist = newValue } }
    }

    var customExtensions: [String] {
        get { routes.first?.customExtensions ?? [] }
        set { mutateFirstRoute { $0.customExtensions = FolderWatchRule.normalizeExtensions(newValue) } }
    }

    /// Returns a canonical copy before persistence or path comparisons.
    func normalized() -> FolderWatchRule {
        FolderWatchRule(
            id: id,
            folderPath: folderPath,
            includesSubfolders: includesSubfolders,
            stabilityDelay: stabilityDelay,
            routes: routes,
            enabled: enabled,
            createdAt: createdAt
        )
    }

    /// Tests the file name only. The watcher remains responsible for checking that the path is a regular file.
    func allowsFile(named fileName: String) -> Bool {
        routes.contains { $0.allowsFile(named: fileName) }
    }

    func allowsFile(at url: URL) -> Bool {
        allowsFile(named: url.lastPathComponent)
    }

    func matchingRoute(for url: URL) -> FolderWatchRoute? {
        routes.first { $0.allowsFile(named: url.lastPathComponent) }
    }

    private mutating func mutateFirstRoute(_ mutation: (inout FolderWatchRoute) -> Void) {
        if routes.isEmpty { routes = [FolderWatchRoute(action: .direct)] }
        mutation(&routes[0])
    }

    static func normalizePath(_ path: String) -> String {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return "" }
        let standardized = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
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
        case stabilityDelay = "stability_delay"
        case routes
        case action
        case basketID = "basket_id"
        case fileTypeAllowlist = "file_type_allowlist"
        case customExtensions = "custom_extensions"
        case enabled
        case createdAt = "created_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        folderPath = FolderWatchRule.normalizePath(try container.decode(String.self, forKey: .folderPath))
        includesSubfolders = try container.decodeIfPresent(Bool.self, forKey: .includesSubfolders) ?? false
        stabilityDelay = try container.decodeIfPresent(
            FolderWatchStabilityDelay.self,
            forKey: .stabilityDelay
        ) ?? .seconds10
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        if let decodedRoutes = try container.decodeIfPresent([FolderWatchRoute].self, forKey: .routes),
           !decodedRoutes.isEmpty {
            routes = decodedRoutes.map { $0.normalized() }
        } else {
            routes = [FolderWatchRoute(
                action: try container.decodeIfPresent(FolderWatchAction.self, forKey: .action) ?? .direct,
                basketID: try container.decodeIfPresent(UUID.self, forKey: .basketID),
                fileTypeAllowlist: try container.decodeIfPresent(
                    Set<FolderWatchFileType>.self,
                    forKey: .fileTypeAllowlist
                ) ?? [.all],
                customExtensions: try container.decodeIfPresent(
                    [String].self,
                    forKey: .customExtensions
                ) ?? []
            )]
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(folderPath, forKey: .folderPath)
        try container.encode(includesSubfolders, forKey: .includesSubfolders)
        try container.encode(stabilityDelay, forKey: .stabilityDelay)
        try container.encode(routes, forKey: .routes)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(createdAt, forKey: .createdAt)
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
    case duplicateID(UUID)
    case duplicateRouteID(UUID)
    case overlappingRoutes
    case duplicate(existingRuleID: UUID)
    case overlaps(existingRuleID: UUID)
    case ruleNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "监控文件夹路径不能为空"
        case let .duplicateID(id):
            return "监控规则标识重复：\(id.uuidString)"
        case let .duplicateRouteID(id):
            return "类型分流标识重复：\(id.uuidString)"
        case .overlappingRoutes:
            return "同一文件类型只能配置一个处理目标"
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
