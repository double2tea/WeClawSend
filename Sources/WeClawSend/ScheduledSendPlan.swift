import Foundation

enum ScheduledSendStatus: String, Codable, Sendable {
    case scheduled
    case sending
    case sent
    case cancelled
    case needsAttention = "needs_attention"
    case failed
}

struct ScheduledSendItem: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let filePath: String
    let fileName: String
    let byteCount: Int64
    let modifiedAt: Date?

    var fileURL: URL { URL(fileURLWithPath: filePath) }

    init(
        id: UUID = UUID(),
        filePath: String,
        fileName: String,
        byteCount: Int64,
        modifiedAt: Date?
    ) {
        self.id = id
        self.filePath = filePath
        self.fileName = fileName
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case filePath = "file_path"
        case fileName = "file_name"
        case byteCount = "byte_count"
        case modifiedAt = "modified_at"
    }
}

struct ScheduledSendPlan: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let items: [ScheduledSendItem]
    let createdAt: Date
    var scheduledAt: Date
    let source: String
    let idempotencyKey: String?
    var status: ScheduledSendStatus
    var message: String?
    var startedAt: Date?
    var completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case items
        case createdAt = "created_at"
        case scheduledAt = "scheduled_at"
        case source
        case idempotencyKey = "idempotency_key"
        case status
        case message
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    init(
        id: UUID = UUID(),
        items: [ScheduledSendItem],
        createdAt: Date = .now,
        scheduledAt: Date,
        source: String,
        idempotencyKey: String?,
        status: ScheduledSendStatus = .scheduled,
        message: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.items = items
        self.createdAt = createdAt
        self.scheduledAt = scheduledAt
        self.source = source
        self.idempotencyKey = idempotencyKey
        self.status = status
        self.message = message
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

struct ScheduledSendCreation: Sendable {
    let plan: ScheduledSendPlan
    let created: Bool
}

enum ScheduledSendEvent: Sendable {
    case updated(ScheduledSendPlan)
}

enum ScheduledSendError: LocalizedError {
    case invalidRequest(String)
    case notFound(UUID)
    case conflict(String)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(message): message
        case let .notFound(id): "未找到发送计划：\(id.uuidString)"
        case let .conflict(message): message
        case let .persistence(message): "保存发送计划失败：\(message)"
        }
    }
}

enum ScheduledSendStore {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WeClawSend", isDirectory: true)
            .appendingPathComponent("scheduled-sends.json")
    }

    static func load(from url: URL) throws -> [ScheduledSendPlan] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ScheduledSendPlan].self, from: data)
    }

    static func save(_ plans: [ScheduledSendPlan], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plans)
        try data.write(to: url, options: .atomic)
    }
}
