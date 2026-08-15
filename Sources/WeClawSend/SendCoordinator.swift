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
    let scheduledSendCount: Int
    let nextScheduledAt: Date?
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
    nonisolated let scheduledEvents: AsyncStream<ScheduledSendEvent>

    private let weChat: WeChatService
    private let eventContinuation: AsyncStream<TransferEvent>.Continuation
    private let scheduledEventContinuation: AsyncStream<ScheduledSendEvent>.Continuation
    private let scheduledStoreURL: URL
    private var scheduledPersistenceError: String?
    private var storedScheduledPlans: [ScheduledSendPlan]
    private var scheduledTasks: [UUID: Task<Void, Never>] = [:]
    private var scheduledLoopTask: Task<Void, Never>?
    private var queueDepth = 0
    private var lastSendAt: Date?
    private var activeSendSlots = 0
    private var sendWaiters: [SendWaiter] = []
    private var activeRecords: [UUID: TransferRecord] = [:]
    private var activeTasks: [UUID: Task<SendResult, Error>] = [:]

    init(
        weChat: WeChatService,
        scheduledStoreURL: URL = ScheduledSendStore.defaultURL
    ) {
        let eventPair = AsyncStream<TransferEvent>.makeStream()
        let scheduledEventPair = AsyncStream<ScheduledSendEvent>.makeStream()
        events = eventPair.stream
        eventContinuation = eventPair.continuation
        scheduledEvents = scheduledEventPair.stream
        scheduledEventContinuation = scheduledEventPair.continuation
        self.weChat = weChat
        self.scheduledStoreURL = scheduledStoreURL
        var loadedPlans = [ScheduledSendPlan]()
        var loadError: String?
        do {
            loadedPlans = try ScheduledSendStore.load(from: scheduledStoreURL)
        } catch {
            loadError = error.localizedDescription
        }
        self.scheduledPersistenceError = loadError
        var didRecoverPlan = false
        let launchDate = Date()
        for index in loadedPlans.indices {
            if loadedPlans[index].status == .sending {
                loadedPlans[index].status = .needsAttention
                loadedPlans[index].message = "应用上次退出时未完成发送，请确认后立即发送"
                loadedPlans[index].startedAt = nil
                didRecoverPlan = true
            } else if loadedPlans[index].status == .scheduled,
                      loadedPlans[index].scheduledAt <= launchDate {
                loadedPlans[index].status = .needsAttention
                loadedPlans[index].message = "应用未运行期间已到发送时间，请确认后立即发送"
                didRecoverPlan = true
            }
        }
        if didRecoverPlan {
            do {
                try ScheduledSendStore.save(loadedPlans, to: scheduledStoreURL)
            } catch {
                loadError = error.localizedDescription
                self.scheduledPersistenceError = loadError
            }
        }
        self.storedScheduledPlans = loadedPlans
    }

    func snapshot() async -> BridgeSnapshot {
        ensureScheduledSendLoop()
        let validated = await weChat.isConnected()
        let pendingPlans = storedScheduledPlans.filter {
            $0.status == .scheduled || $0.status == .needsAttention
        }
        return BridgeSnapshot(
            queueDepth: queueDepth,
            weChatConnected: validated,
            lastSendAt: lastSendAt,
            scheduledSendCount: pendingPlans.count,
            nextScheduledAt: pendingPlans.map(\.scheduledAt).min()
        )
    }

    func scheduledPlans() -> [ScheduledSendPlan] {
        ensureScheduledSendLoop()
        return storedScheduledPlans.sorted {
            if $0.status != $1.status {
                return scheduledStatusPriority($0.status) < scheduledStatusPriority($1.status)
            }
            return $0.scheduledAt < $1.scheduledAt
        }
    }

    func scheduledPlan(id: UUID) -> ScheduledSendPlan? {
        ensureScheduledSendLoop()
        return storedScheduledPlans.first { $0.id == id }
    }

    func scheduledPersistenceFailure() -> String? {
        scheduledPersistenceError
    }

    func createScheduledSend(
        requests: [SendRequest],
        scheduledAt: Date,
        source: String,
        idempotencyKey: String?
    ) throws -> ScheduledSendCreation {
        ensureScheduledSendLoop()
        if let scheduledPersistenceError {
            throw ScheduledSendError.persistence(scheduledPersistenceError)
        }
        guard !requests.isEmpty else {
            throw ScheduledSendError.invalidRequest("发送计划至少需要一个文件")
        }
        guard scheduledAt > .now else {
            throw ScheduledSendError.invalidRequest("scheduled_at 必须是未来时间")
        }
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty else {
            throw ScheduledSendError.invalidRequest("source 不能为空")
        }
        guard normalizedSource.count <= 128 else {
            throw ScheduledSendError.invalidRequest("source 不能超过 128 个字符")
        }
        let normalizedKey = idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedKey, !normalizedKey.isEmpty,
           let existing = storedScheduledPlans.first(where: { $0.idempotencyKey == normalizedKey }) {
            return ScheduledSendCreation(plan: existing, created: false)
        }

        let items = try requests.map { request -> ScheduledSendItem in
            let validated = try validate(request)
            let modifiedAt = try validated.fileURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            return ScheduledSendItem(
                filePath: validated.fileURL.path,
                fileName: validated.fileName,
                byteCount: validated.byteCount,
                modifiedAt: modifiedAt
            )
        }
        let plan = ScheduledSendPlan(
            items: items,
            scheduledAt: scheduledAt,
            source: normalizedSource,
            idempotencyKey: normalizedKey?.isEmpty == true ? nil : normalizedKey
        )
        var updatedPlans = storedScheduledPlans
        updatedPlans.append(plan)
        try commitScheduledPlans(updatedPlans)
        scheduledEventContinuation.yield(.updated(plan))
        return ScheduledSendCreation(plan: plan, created: true)
    }

    func rescheduleScheduledSend(id: UUID, to scheduledAt: Date) throws -> ScheduledSendPlan {
        ensureScheduledSendLoop()
        guard scheduledAt > .now else {
            throw ScheduledSendError.invalidRequest("scheduled_at 必须是未来时间")
        }
        guard let index = storedScheduledPlans.firstIndex(where: { $0.id == id }) else {
            throw ScheduledSendError.notFound(id)
        }
        guard storedScheduledPlans[index].status == .scheduled
            || storedScheduledPlans[index].status == .needsAttention
        else {
            throw ScheduledSendError.conflict("当前状态不能修改发送时间")
        }
        var updatedPlans = storedScheduledPlans
        updatedPlans[index].scheduledAt = scheduledAt
        updatedPlans[index].status = .scheduled
        updatedPlans[index].message = nil
        updatedPlans[index].startedAt = nil
        updatedPlans[index].completedAt = nil
        try commitScheduledPlans(updatedPlans)
        let plan = updatedPlans[index]
        scheduledEventContinuation.yield(.updated(plan))
        return plan
    }

    func cancelScheduledSend(id: UUID) throws -> ScheduledSendPlan {
        ensureScheduledSendLoop()
        guard let index = storedScheduledPlans.firstIndex(where: { $0.id == id }) else {
            throw ScheduledSendError.notFound(id)
        }
        guard storedScheduledPlans[index].status == .scheduled
            || storedScheduledPlans[index].status == .needsAttention
        else {
            if storedScheduledPlans[index].status == .cancelled { return storedScheduledPlans[index] }
            throw ScheduledSendError.conflict("当前状态不能取消发送计划")
        }
        var updatedPlans = storedScheduledPlans
        updatedPlans[index].status = .cancelled
        updatedPlans[index].message = "已取消发送"
        updatedPlans[index].completedAt = .now
        try commitScheduledPlans(updatedPlans)
        let plan = updatedPlans[index]
        scheduledEventContinuation.yield(.updated(plan))
        return plan
    }

    func sendScheduledNow(id: UUID) async throws -> ScheduledSendPlan {
        ensureScheduledSendLoop()
        guard let existing = storedScheduledPlans.first(where: { $0.id == id }) else {
            throw ScheduledSendError.notFound(id)
        }
        switch existing.status {
        case .sent, .cancelled:
            return existing
        case .sending:
            return existing
        case .failed:
            return existing
        case .scheduled, .needsAttention:
            break
        }

        let isConnected = await weChat.isConnected()
        guard let current = storedScheduledPlans.first(where: { $0.id == id }) else {
            throw ScheduledSendError.notFound(id)
        }
        guard (current.status == .scheduled || current.status == .needsAttention),
              current.scheduledAt == existing.scheduledAt
        else {
            return current
        }

        guard isConnected else {
            return try markScheduledPlan(
                id: id,
                status: .needsAttention,
                message: "微信未连接，请登录后点击立即发送",
                completedAt: nil
            )
        }

        guard let index = storedScheduledPlans.firstIndex(where: { $0.id == id }) else {
            throw ScheduledSendError.notFound(id)
        }
        guard storedScheduledPlans[index].status == .scheduled
            || storedScheduledPlans[index].status == .needsAttention
        else {
            return storedScheduledPlans[index]
        }
        var updatedPlans = storedScheduledPlans
        updatedPlans[index].status = .sending
        updatedPlans[index].message = nil
        updatedPlans[index].startedAt = .now
        updatedPlans[index].completedAt = nil
        try commitScheduledPlans(updatedPlans)
        let plan = updatedPlans[index]
        scheduledEventContinuation.yield(.updated(plan))
        launchScheduledSend(id: id)
        return plan
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

    private func runScheduledSendLoop() async {
        while !Task.isCancelled {
            let dueIDs = storedScheduledPlans
                .filter { $0.status == .scheduled && $0.scheduledAt <= .now }
                .map(\.id)
            for id in dueIDs {
                _ = try? await sendScheduledNow(id: id)
            }

            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
        }
    }

    private func ensureScheduledSendLoop() {
        guard scheduledLoopTask == nil else { return }
        scheduledLoopTask = Task { [weak self] in
            await self?.runScheduledSendLoop()
        }
    }

    private func launchScheduledSend(id: UUID) {
        guard scheduledTasks[id] == nil else { return }
        scheduledTasks[id] = Task { [weak self] in
            await self?.executeScheduledSend(id: id)
        }
    }

    private func executeScheduledSend(id: UUID) async {
        defer { scheduledTasks.removeValue(forKey: id) }
        guard let plan = storedScheduledPlans.first(where: { $0.id == id }), plan.status == .sending else {
            return
        }

        do {
            for item in plan.items {
                try validateScheduledItem(item)
            }
            for item in plan.items {
                _ = try await send(SendRequest(filePath: item.filePath, fileName: item.fileName))
            }
            _ = try markScheduledPlan(
                id: id,
                status: .sent,
                message: nil,
                completedAt: .now
            )
        } catch {
            let isNeedsAttention = await scheduledSendNeedsAttention(error)
            _ = try? markScheduledPlan(
                id: id,
                status: isNeedsAttention ? .needsAttention : .failed,
                message: sendFailureMessage(error),
                completedAt: isNeedsAttention ? nil : .now
            )
        }
    }

    private func validateScheduledItem(_ item: ScheduledSendItem) throws {
        let validated = try validate(
            SendRequest(filePath: item.filePath, fileName: item.fileName)
        )
        guard validated.byteCount == item.byteCount else {
            throw ScheduledSendError.invalidRequest("文件已发生变化：\(item.fileName)")
        }
        if let expectedModifiedAt = item.modifiedAt,
           let currentModifiedAt = try validated.fileURL.resourceValues(
               forKeys: [.contentModificationDateKey]
           ).contentModificationDate,
           abs(currentModifiedAt.timeIntervalSince(expectedModifiedAt)) > 1.1 {
            throw ScheduledSendError.invalidRequest("文件已发生变化：\(item.fileName)")
        }
    }

    private func scheduledSendNeedsAttention(_ error: any Error) async -> Bool {
        if error is ScheduledSendError || error is BackendError { return true }
        return !(await weChat.isConnected())
    }

    private func markScheduledPlan(
        id: UUID,
        status: ScheduledSendStatus,
        message: String?,
        completedAt: Date?
    ) throws -> ScheduledSendPlan {
        guard let index = storedScheduledPlans.firstIndex(where: { $0.id == id }) else {
            throw ScheduledSendError.notFound(id)
        }
        var updatedPlans = storedScheduledPlans
        updatedPlans[index].status = status
        updatedPlans[index].message = message
        updatedPlans[index].completedAt = completedAt
        try commitScheduledPlans(updatedPlans)
        let plan = updatedPlans[index]
        scheduledEventContinuation.yield(.updated(plan))
        return plan
    }

    private func commitScheduledPlans(_ plans: [ScheduledSendPlan]) throws {
        if let scheduledPersistenceError {
            throw ScheduledSendError.persistence(scheduledPersistenceError)
        }
        do {
            try ScheduledSendStore.save(plans, to: scheduledStoreURL)
        } catch {
            scheduledPersistenceError = error.localizedDescription
            throw ScheduledSendError.persistence(error.localizedDescription)
        }
        storedScheduledPlans = plans
    }

    private func scheduledStatusPriority(_ status: ScheduledSendStatus) -> Int {
        switch status {
        case .sending: 0
        case .scheduled: 1
        case .needsAttention: 2
        case .failed: 3
        case .sent: 4
        case .cancelled: 5
        }
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
