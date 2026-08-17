import Foundation

struct TransferRecord: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case queued
        case sending
        case sent
        case failed
    }

    let transferID: UUID
    let path: String
    let fileName: String
    let byteCount: Int64
    let date: Date
    var status: Status
    var message: String?
    var stage: WeChatSendStage?
    var progress: Double?
    var sentBytes: Int64?

    var fileURL: URL { URL(fileURLWithPath: path) }
    var id: UUID { transferID }
    var isTerminal: Bool { status == .sent || status == .failed }

    init(
        transferID: UUID = UUID(),
        path: String,
        fileName: String,
        byteCount: Int64,
        date: Date,
        status: Status,
        message: String?,
        stage: WeChatSendStage?,
        progress: Double?,
        sentBytes: Int64?
    ) {
        self.transferID = transferID
        self.path = path
        self.fileName = fileName
        self.byteCount = byteCount
        self.date = date
        self.status = status
        self.message = message
        self.stage = stage
        self.progress = progress
        self.sentBytes = sentBytes
    }

    private enum CodingKeys: String, CodingKey {
        case transferID
        case path
        case fileName
        case byteCount
        case date
        case status
        case message
        case stage
        case progress
        case sentBytes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transferID = try container.decodeIfPresent(UUID.self, forKey: .transferID) ?? UUID()
        path = try container.decode(String.self, forKey: .path)
        fileName = try container.decode(String.self, forKey: .fileName)
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        date = try container.decode(Date.self, forKey: .date)
        status = try container.decode(Status.self, forKey: .status)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        stage = try container.decodeIfPresent(WeChatSendStage.self, forKey: .stage)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        sentBytes = try container.decodeIfPresent(Int64.self, forKey: .sentBytes)
    }
}

enum FilePreviewKind: Equatable {
    case image
    case video
    case pdf
    case audio
    case archive
    case document
    case generic

    init(fileName: String) {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg":
            self = .image
        case "m4v", "mp4", "mov", "webm", "mkv", "avi":
            self = .video
        case "pdf":
            self = .pdf
        case "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg":
            self = .audio
        case "zip", "rar", "7z", "tar", "gz":
            self = .archive
        case "doc", "docx", "pages", "txt", "md", "xls", "xlsx", "ppt", "pptx":
            self = .document
        default:
            self = .generic
        }
    }

    var hasVisualContent: Bool {
        switch self {
        case .image, .video, .pdf: true
        default: false
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .pdf: "doc.richtext"
        case .audio: "waveform"
        case .archive: "archivebox"
        case .document, .generic: "doc"
        }
    }
}

enum FilePreviewPolicy: Equatable {
    case always
    case visualContentOnly
}

struct MenuBarActivity: Equatable {
    var isSending: Bool
    var progress: Double?
    var badgeCount: Int

    static let idle = MenuBarActivity(isSending: false, progress: nil, badgeCount: 0)

    var isIndeterminate: Bool { isSending && progress == nil }

    var badgeText: String? {
        switch badgeCount {
        case ...0: nil
        case 1...9: String(badgeCount)
        default: "9"
        }
    }

    static func make(
        sendingProgresses: [Double?],
        queuedCount: Int,
        scheduledCount: Int
    ) -> MenuBarActivity {
        let isSending = !sendingProgresses.isEmpty
        let known = sendingProgresses.compactMap { $0 }
        let progress: Double?
        if isSending, !known.isEmpty, known.count == sendingProgresses.count {
            progress = known.reduce(0, +) / Double(known.count)
        } else {
            progress = nil
        }
        return MenuBarActivity(
            isSending: isSending,
            progress: progress,
            badgeCount: queuedCount + scheduledCount
        )
    }
}
