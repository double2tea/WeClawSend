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
