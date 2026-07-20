import Foundation

enum BackendError: LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case let .rejected(message):
            message
        }
    }
}

func isSendCancellation(_ error: any Error) -> Bool {
    let nsError = error as NSError
    return error is CancellationError
        || nsError.domain == "Swift.CancellationError"
        || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
}

func sendFailureMessage(_ error: any Error) -> String {
    if isSendCancellation(error) { return "发送已取消" }
    return error.localizedDescription
}

struct SendRequest: Codable, Sendable {
    let filePath: String
    let fileName: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case fileName = "file_name"
    }
}

struct SendResult: Codable, Sendable {
    let ok: Bool
    let status: String
    let mediaType: String
    let filePath: String
    let fileName: String
    let size: Int64
    let queueWaitMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case ok
        case status
        case mediaType = "media_type"
        case filePath = "file_path"
        case fileName = "file_name"
        case size
        case queueWaitMilliseconds = "queue_wait_ms"
    }
}

struct BridgeSnapshot: Sendable {
    let queueDepth: Int
    let weChatConnected: Bool
    let lastSendAt: Date?
}

enum TransferEvent: Sendable {
    case started(TransferRecord)
    case updated(TransferRecord)
    case completed(TransferRecord)
    case failed(TransferRecord)
}

actor SendCoordinator {
    static let maxConcurrentTransfers = 3
    static let sendCooldownMilliseconds = WeChatService.submissionIntervalMilliseconds
    static var maxSendBytes: Int64 { AppSettings.maxSendBytes }

    nonisolated let events: AsyncStream<TransferEvent>

    private let weChat: WeChatService
    private let eventContinuation: AsyncStream<TransferEvent>.Continuation
    private var queueDepth = 0
    private var lastSendAt: Date?
    private var activeSendSlots = 0
    private var sendWaiters: [SendWaiter] = []
    private var activeRecords: [UUID: TransferRecord] = [:]
    private var activeTasks: [UUID: Task<SendResult, Error>] = [:]

    init(weChat: WeChatService) {
        let eventPair = AsyncStream<TransferEvent>.makeStream()
        events = eventPair.stream
        eventContinuation = eventPair.continuation
        self.weChat = weChat
    }

    func snapshot() async -> BridgeSnapshot {
        let validated = await weChat.isConnected()
        return BridgeSnapshot(
            queueDepth: queueDepth,
            weChatConnected: validated,
            lastSendAt: lastSendAt
        )
    }

    func send(_ request: SendRequest) async throws -> SendResult {
        let validated = try validate(request)
        queueDepth += 1
        activeRecords[validated.record.id] = validated.record
        let task = Task { [self] in
            try await executeSend(validated, waitStartedAt: .now)
        }
        activeTasks[validated.record.id] = task
        eventContinuation.yield(.started(validated.record))

        return try await withTaskCancellationHandler {
            defer { activeTasks.removeValue(forKey: validated.record.id) }
            return try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @discardableResult
    func cancel(transferID: UUID) -> Bool {
        guard let task = activeTasks[transferID] else { return false }
        task.cancel()
        return true
    }

    private func executeSend(
        _ validated: ValidatedSend,
        waitStartedAt: Date
    ) async throws -> SendResult {
        do {
            try await acquireSendSlot()
        } catch {
            queueDepth -= 1
            var record = activeRecords.removeValue(forKey: validated.record.id) ?? validated.record
            record.status = .failed
            record.message = sendFailureMessage(error)
            eventContinuation.yield(.failed(record))
            throw error
        }
        let queueWaitMilliseconds = Int64(Date().timeIntervalSince(waitStartedAt) * 1_000)
        updateRecord(id: validated.record.id, status: .sending)

        do {
            let result = try await performSend(validated, queueWaitMilliseconds: queueWaitMilliseconds)
            var record = activeRecords.removeValue(forKey: validated.record.id) ?? validated.record
            record.status = .sent
            record.stage = .finished
            record.progress = 1
            record.sentBytes = record.byteCount
            record.message = nil
            eventContinuation.yield(.completed(record))
            finishSendSlot(sentAt: .now)
            return result
        } catch {
            var record = activeRecords.removeValue(forKey: validated.record.id) ?? validated.record
            record.status = .failed
            record.message = sendFailureMessage(error)
            record.progress = record.progress ?? 0
            eventContinuation.yield(.failed(record))
            finishSendSlot(sentAt: nil)
            throw error
        }
    }

    private func acquireSendSlot() async throws {
        try Task.checkCancellation()
        if activeSendSlots < Self.maxConcurrentTransfers {
            activeSendSlots += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sendWaiters.append(SendWaiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
        if Task.isCancelled {
            releaseSendSlot()
            throw CancellationError()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = sendWaiters.firstIndex(where: { $0.id == id }) else { return }
        sendWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func finishSendSlot(sentAt: Date?) {
        queueDepth -= 1
        if let sentAt {
            lastSendAt = sentAt
        }
        releaseSendSlot()
    }

    private func releaseSendSlot() {
        if sendWaiters.isEmpty {
            activeSendSlots -= 1
        } else {
            sendWaiters.removeFirst().continuation.resume()
        }
    }

    private func performSend(
        _ validated: ValidatedSend,
        queueWaitMilliseconds: Int64
    ) async throws -> SendResult {
        try Task.checkCancellation()
        try await weChat.sendFile(at: validated.fileURL, fileName: validated.fileName) { [weak self] progress in
            await self?.updateRecord(id: validated.record.id, progress: progress)
        }

        return SendResult(
            ok: true,
            status: "sent",
            mediaType: "file",
            filePath: validated.fileURL.path,
            fileName: validated.fileName,
            size: validated.byteCount,
            queueWaitMilliseconds: queueWaitMilliseconds
        )
    }

    private func validate(_ request: SendRequest) throws -> ValidatedSend {
        let fileURL = URL(fileURLWithPath: request.filePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BackendError.rejected("文件不存在：\(fileURL.path)")
        }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw BackendError.rejected("不是普通文件：\(fileURL.path)")
        }

        let byteCount = Int64(values.fileSize ?? 0)
        let maxSendBytes = Self.maxSendBytes
        guard byteCount <= maxSendBytes else {
            throw BackendError.rejected("文件过大：\(formatBytes(byteCount)) > \(formatBytes(maxSendBytes))")
        }

        let resolvedFileName: String
        if let requestedFileName = request.fileName, !requestedFileName.isEmpty {
            resolvedFileName = requestedFileName
        } else {
            resolvedFileName = fileURL.lastPathComponent
        }
        let outgoingFileName = AppSettings.outgoingFileName(resolvedFileName)
        let record = TransferRecord(
            path: fileURL.path,
            fileName: outgoingFileName,
            byteCount: byteCount,
            date: .now,
            status: .queued,
            message: nil,
            stage: nil,
            progress: 0,
            sentBytes: 0
        )
        return ValidatedSend(
            fileURL: fileURL,
            fileName: outgoingFileName,
            byteCount: byteCount,
            record: record
        )
    }

    private func updateRecord(
        id: UUID,
        status: TransferRecord.Status? = nil,
        progress: WeChatSendProgress? = nil
    ) {
        guard var record = activeRecords[id] else { return }
        if let status {
            record.status = status
            if status == .sending, record.stage == nil {
                record.stage = .preparing
                record.progress = max(record.progress ?? 0, 0.01)
            }
        }
        if let progress {
            record.stage = progress.stage
            record.progress = progress.fraction
            record.sentBytes = progress.sentBytes
        }
        activeRecords[id] = record
        eventContinuation.yield(.updated(record))
    }

}

private struct SendWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
}

private struct ValidatedSend: Sendable {
    let fileURL: URL
    let fileName: String
    let byteCount: Int64
    let record: TransferRecord
}
