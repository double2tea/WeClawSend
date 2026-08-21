import Foundation
import Network

enum EmbeddedServerState: Sendable {
    case starting
    case ready
    case stopped
    case failed(String)
}

struct HealthResponse: Encodable {
    let ok = true
    let service = "weclaw-send"
    let backend = "wechat-ilink"
    let queueDepth: Int
    let weChatConnected: Bool
    let sendCooldownMilliseconds = SendCoordinator.sendCooldownMilliseconds
    let maxConcurrentTransfers = SendCoordinator.maxConcurrentTransfers
    let maxSendBytes: Int64
    let lastSendAt: String?
    let scheduledSendCount: Int
    let nextScheduledAt: String?
    let sendDestination: String

    enum CodingKeys: String, CodingKey {
        case ok
        case service
        case backend
        case queueDepth = "queue_depth"
        case weChatConnected = "wechat_connected"
        case sendCooldownMilliseconds = "send_cooldown_ms"
        case maxConcurrentTransfers = "max_concurrent_transfers"
        case maxSendBytes = "max_send_bytes"
        case lastSendAt = "last_send_at"
        case scheduledSendCount = "scheduled_send_count"
        case nextScheduledAt = "next_scheduled_at"
        case sendDestination = "send_destination"
    }

    init(
        queueDepth: Int,
        weChatConnected: Bool,
        maxSendBytes: Int64,
        lastSendAt: String?,
        scheduledSendCount: Int = 0,
        nextScheduledAt: String? = nil,
        sendDestination: String = AppSettings.localAPISendBehavior.rawValue
    ) {
        self.queueDepth = queueDepth
        self.weChatConnected = weChatConnected
        self.maxSendBytes = maxSendBytes
        self.lastSendAt = lastSendAt
        self.scheduledSendCount = scheduledSendCount
        self.nextScheduledAt = nextScheduledAt
        self.sendDestination = sendDestination
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(service, forKey: .service)
        try container.encode(backend, forKey: .backend)
        try container.encode(queueDepth, forKey: .queueDepth)
        try container.encode(weChatConnected, forKey: .weChatConnected)
        try container.encode(sendCooldownMilliseconds, forKey: .sendCooldownMilliseconds)
        try container.encode(maxConcurrentTransfers, forKey: .maxConcurrentTransfers)
        try container.encode(maxSendBytes, forKey: .maxSendBytes)
        if let lastSendAt {
            try container.encode(lastSendAt, forKey: .lastSendAt)
        } else {
            try container.encodeNil(forKey: .lastSendAt)
        }
        try container.encode(scheduledSendCount, forKey: .scheduledSendCount)
        if let nextScheduledAt {
            try container.encode(nextScheduledAt, forKey: .nextScheduledAt)
        } else {
            try container.encodeNil(forKey: .nextScheduledAt)
        }
        try container.encode(sendDestination, forKey: .sendDestination)
    }
}

struct LocalAPIBasketResult: Encodable, Sendable {
    let ok = true
    let status: String
    let filePath: String
    let fileName: String
    let size: Int64
    let basketID: UUID
    let basketTitle: String

    enum CodingKeys: String, CodingKey {
        case ok
        case status
        case filePath = "file_path"
        case fileName = "file_name"
        case size
        case basketID = "basket_id"
        case basketTitle = "basket_title"
    }
}

enum LocalAPISendOutcome: Sendable {
    case sent(SendResult)
    case addedToBasket(LocalAPIBasketResult)
}

typealias LocalAPISendHandler = @Sendable (SendRequest) async throws -> LocalAPISendOutcome

final class EmbeddedBridgeServer: @unchecked Sendable {
    nonisolated let states: AsyncStream<EmbeddedServerState>

    private let coordinator: SendCoordinator
    private let configuredPort: UInt16
    private let queue = DispatchQueue(label: "com.chacha.WeClawSend.bridge")
    private let stateContinuation: AsyncStream<EmbeddedServerState>.Continuation
    private let sendHandlerLock = NSLock()
    private var sendHandler: LocalAPISendHandler?
    private var listener: NWListener?

    init(coordinator: SendCoordinator, port: UInt16 = EmbeddedBridgeServer.port) {
        self.coordinator = coordinator
        configuredPort = port
        let statePair = AsyncStream<EmbeddedServerState>.makeStream()
        states = statePair.stream
        stateContinuation = statePair.continuation
    }

    static let port: UInt16 = 18_790

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if listener != nil { return }
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(
                    host: "127.0.0.1",
                    port: NWEndpoint.Port(rawValue: configuredPort)!
                )
                let listener = try NWListener(using: parameters)
                self.listener = listener
                self.stateContinuation.yield(.starting)
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.stateContinuation.yield(.ready)
                    case let .waiting(error):
                        self.stateContinuation.yield(.failed(error.localizedDescription))
                    case let .failed(error):
                        self.stateContinuation.yield(.failed(error.localizedDescription))
                        self.listener = nil
                    case .cancelled:
                        self.stateContinuation.yield(.stopped)
                        self.listener = nil
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    guard Self.isLoopback(connection.endpoint) else {
                        connection.cancel()
                        return
                    }
                    HTTPConnectionHandler(
                        connection: connection,
                        coordinator: self.coordinator,
                        sendHandler: self.currentSendHandler()
                    ).start(on: self.queue)
                }
                listener.start(queue: self.queue)
            } catch {
                self.stateContinuation.yield(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            let listener = self.listener
            self.listener = nil
            listener?.cancel()
            self.stateContinuation.yield(.stopped)
        }
    }

    func setSendHandler(_ handler: LocalAPISendHandler?) {
        sendHandlerLock.withLock {
            sendHandler = handler
        }
    }

    private func currentSendHandler() -> LocalAPISendHandler? {
        sendHandlerLock.withLock { sendHandler }
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address):
            return address.isLoopback
        case let .ipv6(address):
            return address.isLoopback
        case .name:
            return false
        @unknown default:
            return false
        }
    }
}

private struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let body: Data
}

private struct ScheduledSendCreatePayload: Decodable {
    let items: [SendRequest]
    let scheduledAt: String?
    let delaySeconds: Int64?
    let source: String?
    let idempotencyKey: String?

    enum CodingKeys: String, CodingKey {
        case items
        case scheduledAt = "scheduled_at"
        case delaySeconds = "delay_seconds"
        case source
        case idempotencyKey = "idempotency_key"
    }
}

private struct ScheduledSendUpdatePayload: Decodable {
    let scheduledAt: String?
    let delaySeconds: Int64?

    enum CodingKeys: String, CodingKey {
        case scheduledAt = "scheduled_at"
        case delaySeconds = "delay_seconds"
    }
}

private final class HTTPConnectionHandler: @unchecked Sendable {
    private static let maxRequestBytes = 1_048_576

    private let connection: NWConnection
    private let coordinator: SendCoordinator
    private let sendHandler: LocalAPISendHandler?
    private var buffer = Data()
    private var requestTask: Task<Void, Never>?

    init(
        connection: NWConnection,
        coordinator: SendCoordinator,
        sendHandler: LocalAPISendHandler?
    ) {
        self.connection = connection
        self.coordinator = coordinator
        self.sendHandler = sendHandler
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.requestTask?.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data {
                buffer.append(data)
            }
            if buffer.count > Self.maxRequestBytes {
                sendError(status: 413, message: "request too large")
                return
            }
            if let request = parseRequest() {
                route(request)
                monitorDisconnect()
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            receive()
        }
    }

    private func monitorDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [self] _, _, isComplete, error in
            if isComplete || error != nil {
                requestTask?.cancel()
                return
            }
            monitorDisconnect()
        }
    }

    private func parseRequest() -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else { return nil }
        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            sendError(status: 400, message: "invalid headers")
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count == 3 else {
            sendError(status: 400, message: "invalid request line")
            return nil
        }

        let contentLength: Int
        if let line = lines.dropFirst().first(where: {
            $0.lowercased().hasPrefix("content-length:")
        }) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard
                parts.count == 2,
                let parsed = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                (0...Self.maxRequestBytes).contains(parsed)
            else {
                sendError(status: 400, message: "invalid content length")
                return nil
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }

        let bodyStart = headerRange.upperBound
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(method: requestParts[0], path: requestParts[1], body: body)
    }

    private func route(_ request: HTTPRequest) {
        if request.method == "GET", request.path == "/health" {
            requestTask = Task { [self] in
                let snapshot = await coordinator.snapshot()
                let formatter = ISO8601DateFormatter()
                sendJSON(
                    status: 200,
                    value: HealthResponse(
                        queueDepth: snapshot.queueDepth,
                        weChatConnected: snapshot.weChatConnected,
                        maxSendBytes: SendCoordinator.maxSendBytes,
                        lastSendAt: snapshot.lastSendAt.map(formatter.string(from:)),
                        scheduledSendCount: snapshot.scheduledSendCount,
                        nextScheduledAt: snapshot.nextScheduledAt.map(formatter.string(from:))
                    )
                )
            }
            return
        }

        if request.method == "GET", request.path == "/scheduled-sends" {
            requestTask = Task { [self] in
                sendJSON(status: 200, value: await coordinator.scheduledPlans())
            }
            return
        }

        if request.method == "POST", request.path == "/scheduled-sends" {
            requestTask = Task { [self] in
                do {
                    let payload = try JSONDecoder().decode(
                        ScheduledSendCreatePayload.self,
                        from: request.body
                    )
                    let scheduledAt = try Self.scheduledDate(
                        scheduledAt: payload.scheduledAt,
                        delaySeconds: payload.delaySeconds
                    )
                    let creation = try await coordinator.createScheduledSend(
                        requests: payload.items,
                        scheduledAt: scheduledAt,
                        source: payload.source ?? "local-api",
                        idempotencyKey: payload.idempotencyKey
                    )
                    sendJSON(status: creation.created ? 201 : 200, value: creation.plan)
                } catch {
                    sendError(status: httpStatus(for: error), message: error.localizedDescription)
                }
            }
            return
        }

        if let id = Self.scheduledSendID(path: request.path), request.method == "GET" {
            requestTask = Task { [self] in
                if let plan = await coordinator.scheduledPlan(id: id) {
                    sendJSON(status: 200, value: plan)
                } else {
                    sendError(status: 404, message: ScheduledSendError.notFound(id).localizedDescription)
                }
            }
            return
        }

        if let id = Self.scheduledSendID(path: request.path), request.method == "PATCH" {
            requestTask = Task { [self] in
                do {
                    let payload = try JSONDecoder().decode(
                        ScheduledSendUpdatePayload.self,
                        from: request.body
                    )
                    let scheduledAt = try Self.scheduledDate(
                        scheduledAt: payload.scheduledAt,
                        delaySeconds: payload.delaySeconds
                    )
                    let plan = try await coordinator.rescheduleScheduledSend(
                        id: id,
                        to: scheduledAt
                    )
                    sendJSON(status: 200, value: plan)
                } catch {
                    sendError(status: httpStatus(for: error), message: error.localizedDescription)
                }
            }
            return
        }

        if let id = Self.scheduledSendID(path: request.path), request.method == "DELETE" {
            requestTask = Task { [self] in
                do {
                    let plan = try await coordinator.cancelScheduledSend(id: id)
                    sendJSON(status: 200, value: plan)
                } catch {
                    sendError(status: httpStatus(for: error), message: error.localizedDescription)
                }
            }
            return
        }

        if let id = Self.scheduledSendActionID(path: request.path, action: "send-now"),
           request.method == "POST" {
            requestTask = Task { [self] in
                do {
                    let plan = try await coordinator.sendScheduledNow(id: id)
                    let status = plan.status == .sending ? 202 : 200
                    sendJSON(status: status, value: plan)
                } catch {
                    sendError(status: httpStatus(for: error), message: error.localizedDescription)
                }
            }
            return
        }

        if request.method == "POST", request.path == "/send" {
            requestTask = Task { [self] in
                do {
                    let payload = try JSONDecoder().decode(SendRequest.self, from: request.body)
                    let outcome: LocalAPISendOutcome
                    if let sendHandler {
                        outcome = try await sendHandler(payload)
                    } else {
                        outcome = .sent(try await coordinator.send(payload))
                    }
                    switch outcome {
                    case let .sent(result):
                        sendJSON(status: 200, value: result)
                    case let .addedToBasket(result):
                        sendJSON(status: 200, value: result)
                    }
                } catch {
                    let status = httpStatus(for: error)
                    sendError(status: status, message: error.localizedDescription)
                }
            }
            return
        }

        sendError(status: 404, message: "not found")
    }

    private func sendJSON<T: Encodable>(status: Int, value: T) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let body = try encoder.encode(value)
            sendResponse(status: status, contentType: "application/json; charset=utf-8", body: body)
        } catch {
            sendError(status: 500, message: error.localizedDescription)
        }
    }

    private func sendError(status: Int, message: String) {
        let body = (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message])) ?? Data()
        sendResponse(status: status, contentType: "application/json; charset=utf-8", body: body)
    }

    private func sendResponse(status: Int, contentType: String, body: Data) {
        let header = responseHeader(
            status: status,
            fields: [
                "Content-Type": contentType,
                "Content-Length": String(body.count)
            ]
        )
        connection.send(content: header + body, completion: .contentProcessed { [self] _ in
            connection.cancel()
        })
    }

    private func responseHeader(status: Int, fields: [String: String]) -> Data {
        let fieldLines = fields.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        let text = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n\(fieldLines)\r\nConnection: close\r\n\r\n"
        return Data(text.utf8)
    }

    private static func scheduledSendID(path: String) -> UUID? {
        let parts = path.split(separator: "/")
        guard parts.count == 2, parts[0] == "scheduled-sends" else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    private static func scheduledSendActionID(path: String, action: String) -> UUID? {
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == "scheduled-sends", parts[2] == Substring(action) else {
            return nil
        }
        return UUID(uuidString: String(parts[1]))
    }

    private static func scheduledDate(
        scheduledAt: String?,
        delaySeconds: Int64?
    ) throws -> Date {
        guard (scheduledAt == nil) != (delaySeconds == nil) else {
            throw ScheduledSendError.invalidRequest(
                "scheduled_at 和 delay_seconds 必须二选一"
            )
        }
        if let delaySeconds {
            guard delaySeconds > 0 else {
                throw ScheduledSendError.invalidRequest("delay_seconds 必须大于 0")
            }
            return Date().addingTimeInterval(TimeInterval(delaySeconds))
        }
        guard let scheduledAt, let date = Self.parseISO8601Date(scheduledAt) else {
            throw ScheduledSendError.invalidRequest("scheduled_at 必须是 ISO 8601 时间")
        }
        return date
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private func httpStatus(for error: Error) -> Int {
    if error is DecodingError { return 400 }
    if case .notFound = error as? ScheduledSendError { return 404 }
    if case .conflict = error as? ScheduledSendError { return 409 }
    if case .invalidRequest = error as? ScheduledSendError { return 400 }
    if case .persistence = error as? ScheduledSendError { return 500 }
    if error is ScheduledSendError {
        return 500
    }
    if case let BackendError.rejected(message) = error {
        if message.hasPrefix("文件不存在") { return 404 }
        if message.hasPrefix("不是普通文件") { return 400 }
        if message.hasPrefix("文件过大") { return 413 }
        if message.hasPrefix("文件篮功能未启用") || message.hasPrefix("无法加入文件篮") {
            return 409
        }
    }
    if error is WeChatError { return 503 }
    return 500
}

private func reasonPhrase(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 201: "Created"
    case 202: "Accepted"
    case 400: "Bad Request"
    case 404: "Not Found"
    case 409: "Conflict"
    case 413: "Payload Too Large"
    case 503: "Service Unavailable"
    default: "Internal Server Error"
    }
}
