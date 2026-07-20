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
    }
}

final class EmbeddedBridgeServer: @unchecked Sendable {
    nonisolated let states: AsyncStream<EmbeddedServerState>

    private let coordinator: SendCoordinator
    private let queue = DispatchQueue(label: "com.chacha.WeClawSend.bridge")
    private let stateContinuation: AsyncStream<EmbeddedServerState>.Continuation
    private var listener: NWListener?

    init(coordinator: SendCoordinator) {
        self.coordinator = coordinator
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
                    port: NWEndpoint.Port(rawValue: Self.port)!
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
                    HTTPConnectionHandler(connection: connection, coordinator: self.coordinator).start(on: self.queue)
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

private final class HTTPConnectionHandler: @unchecked Sendable {
    private static let maxRequestBytes = 1_048_576

    private let connection: NWConnection
    private let coordinator: SendCoordinator
    private var buffer = Data()
    private var requestTask: Task<Void, Never>?

    init(connection: NWConnection, coordinator: SendCoordinator) {
        self.connection = connection
        self.coordinator = coordinator
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
                        lastSendAt: snapshot.lastSendAt.map(formatter.string(from:))
                    )
                )
            }
            return
        }

        if request.method == "POST", request.path == "/send" {
            requestTask = Task { [self] in
                do {
                    let payload = try JSONDecoder().decode(SendRequest.self, from: request.body)
                    let result = try await coordinator.send(payload)
                    sendJSON(status: 200, value: result)
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
            let body = try JSONEncoder().encode(value)
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
}

private func httpStatus(for error: Error) -> Int {
    if error is DecodingError { return 400 }
    if case let BackendError.rejected(message) = error {
        if message.hasPrefix("文件不存在") { return 404 }
        if message.hasPrefix("不是普通文件") { return 400 }
        if message.hasPrefix("文件过大") { return 413 }
    }
    if error is WeChatError { return 503 }
    return 500
}

private func reasonPhrase(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 400: "Bad Request"
    case 404: "Not Found"
    case 413: "Payload Too Large"
    case 503: "Service Unavailable"
    default: "Internal Server Error"
    }
}
