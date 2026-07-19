import Foundation

enum WeChatError: LocalizedError {
    case notLoggedIn
    case invalidResponse
    case http(Int, String)
    case api(String)
    case login(String)
    case contextRefreshTimedOut
    case missingUploadURL
    case missingUploadResult

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "微信尚未登录"
        case .invalidResponse:
            "微信服务返回了无效响应"
        case let .http(status, message):
            "微信服务 HTTP \(status)：\(message)"
        case let .api(message), let .login(message):
            message
        case .contextRefreshTimedOut:
            "等待微信会话刷新超时，请重新发送文件并在提示后给 ClawBot 发一条消息"
        case .missingUploadURL:
            "微信服务未返回文件上传地址"
        case .missingUploadResult:
            "微信 CDN 未返回文件引用"
        }
    }
}

enum WeChatLoginUpdate: Sendable {
    case waiting
    case scanned
    case needsVerification
    case confirmed(WeChatCredentials)
}

enum WeChatSendStage: String, Codable, Sendable {
    case preparing
    case encrypting
    case uploading
    case waitingToSend
    case sending
    case waitingForContext
    case finished
}

struct WeChatSendProgress: Sendable {
    let stage: WeChatSendStage
    let fraction: Double
    let sentBytes: Int64
    let totalBytes: Int64
}

actor WeChatService {
    static let submissionIntervalMilliseconds: Int64 = 2_000

    private static let loginBaseURL = URL(string: "https://ilinkai.weixin.qq.com")!
    private static let cdnBaseURL = URL(string: "https://novac2c.cdn.weixin.qq.com/c2c")!
    private static let channelVersion = "2.4.6"
    private static let botAgent = "WeClawSend/1.6.6"
    private static let appClientVersion = "132102"

    private let store: WeChatCredentialStore
    private let session: URLSession
    private let contextRefreshTimeout: Duration
    private let submissionIntervalMilliseconds: Int64
    private var credentials: WeChatCredentials?
    private var bootstrapTask: Task<Void, Never>?
    private var credentialsValidated = false
    private var credentialLoadError: String?
    private var loginQRCode: String?
    private var loginPollingBaseURL = loginBaseURL
    private var submissionSlotLocked = false
    private var submissionWaiters: [SubmissionWaiter] = []

    init(
        store: WeChatCredentialStore = WeChatCredentialStore(),
        session: URLSession = .shared,
        contextRefreshTimeout: Duration = .seconds(300),
        submissionIntervalMilliseconds: Int64 = WeChatService.submissionIntervalMilliseconds
    ) {
        self.store = store
        self.session = session
        self.contextRefreshTimeout = contextRefreshTimeout
        self.submissionIntervalMilliseconds = submissionIntervalMilliseconds
    }

    init(
        credentials: WeChatCredentials,
        session: URLSession,
        store: WeChatCredentialStore = WeChatCredentialStore(),
        contextRefreshTimeout: Duration = .seconds(300),
        submissionIntervalMilliseconds: Int64 = WeChatService.submissionIntervalMilliseconds
    ) {
        self.store = store
        self.session = session
        self.contextRefreshTimeout = contextRefreshTimeout
        self.submissionIntervalMilliseconds = submissionIntervalMilliseconds
        self.credentials = credentials
    }

    /// 在后台线程读凭据，再回到 actor 写入；并发调用会 await 同一次加载。
    func bootstrapCredentials() async {
        if credentials != nil { return }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let store = self.store
        let task = Task { [store] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<WeChatCredentials?, Error> in
                do {
                    if let loaded = try store.load() {
                        return .success(loaded)
                    }
                    return .success(try store.loadLegacyOnly())
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case let .success(loaded):
                self.credentials = loaded
                self.credentialLoadError = nil
            case let .failure(error):
                self.credentialLoadError = error.localizedDescription
            }
        }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
    }

    func accountID() -> String? {
        credentials?.botID
    }

    func isConnected() -> Bool {
        credentialsValidated
    }

    func hasCredentials() -> Bool {
        credentials != nil
    }

    func startupError() -> String? {
        credentialLoadError
    }

    func validateCredentials() async throws {
        await bootstrapCredentials()
        guard let credentials else { throw WeChatError.notLoggedIn }
        if credentialsValidated { return }
        let endpoint = try Self.endpoint(
            baseURL: credentials.baseURL,
            path: "ilink/bot/getconfig"
        )
        let response: APIResponse = try await post(
            endpoint,
            body: GetConfigRequest(
                userID: credentials.userID,
                baseInfo: Self.baseInfo
            ),
            token: credentials.botToken,
            timeout: 10
        )
        try response.validate(action: "微信凭据验证失败")
        credentialsValidated = true
    }

    func startLogin() async throws -> String {
        await bootstrapCredentials()
        let endpoint = try Self.endpoint(
            baseURL: Self.loginBaseURL,
            path: "ilink/bot/get_bot_qrcode",
            queryItems: [URLQueryItem(name: "bot_type", value: "3")]
        )
        let response: QRCodeResponse = try await post(
            endpoint,
            body: QRCodeRequest(localTokenList: credentials.map { [$0.botToken] } ?? []),
            token: nil,
            timeout: 15
        )
        guard !response.qrcode.isEmpty, !response.qrcodeImageContent.isEmpty else {
            throw WeChatError.invalidResponse
        }
        loginQRCode = response.qrcode
        loginPollingBaseURL = Self.loginBaseURL
        return response.qrcodeImageContent
    }

    func pollLogin(verificationCode: String? = nil) async throws -> WeChatLoginUpdate {
        guard let loginQRCode else {
            throw WeChatError.login("当前没有进行中的微信登录")
        }
        var queryItems = [URLQueryItem(name: "qrcode", value: loginQRCode)]
        if let verificationCode, !verificationCode.isEmpty {
            queryItems.append(URLQueryItem(name: "verify_code", value: verificationCode))
        }
        let endpoint = try Self.endpoint(
            baseURL: loginPollingBaseURL,
            path: "ilink/bot/get_qrcode_status",
            queryItems: queryItems
        )
        let response: QRStatusResponse
        do {
            response = try await get(endpoint, timeout: 40)
        } catch let error as URLError where error.code == .timedOut {
            return .waiting
        }

        switch response.status {
        case "wait":
            return .waiting
        case "scaned":
            return .scanned
        case "need_verifycode":
            return .needsVerification
        case "scaned_but_redirect":
            guard let host = response.redirectHost, let redirected = URL(string: "https://\(host)") else {
                throw WeChatError.login("微信登录跳转地址无效")
            }
            loginPollingBaseURL = redirected
            return .scanned
        case "binded_redirect":
            guard let credentials else {
                throw WeChatError.login("微信已绑定，但本机没有可用凭据，请解除旧绑定后重试")
            }
            self.loginQRCode = nil
            return .confirmed(credentials)
        case "expired":
            self.loginQRCode = nil
            throw WeChatError.login("微信登录二维码已过期，请重新生成")
        case "verify_code_blocked":
            throw WeChatError.login("配对码错误次数过多，请稍后重新登录")
        case "confirmed":
            let confirmed = try response.credentials(defaultBaseURL: Self.loginBaseURL)
            try store.save(confirmed)
            credentials = confirmed
            credentialsValidated = false
            credentialLoadError = nil
            self.loginQRCode = nil
            return .confirmed(confirmed)
        default:
            throw WeChatError.login("未知的微信登录状态：\(response.status)")
        }
    }

    func sendFile(
        at fileURL: URL,
        fileName: String,
        progress: @escaping @Sendable (WeChatSendProgress) async -> Void = { _ in }
    ) async throws {
        await bootstrapCredentials()
        guard let credentials else { throw WeChatError.notLoggedIn }
        try Task.checkCancellation()
        await progress(WeChatSendProgress(stage: .preparing, fraction: 0.02, sentBytes: 0, totalBytes: 0))
        let rawSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let totalBytes = Int64(rawSize)
        await progress(
            WeChatSendProgress(
                stage: .encrypting,
                fraction: 0.08,
                sentBytes: 0,
                totalBytes: totalBytes
            )
        )
        let fileKey = try WeChatCrypto.randomBytes(count: 16).lowercaseHex
        let aesKey = try WeChatCrypto.randomBytes(count: 16)
        let aesKeyHex = aesKey.lowercaseHex
        let encryptedURL = FileManager.default.temporaryDirectory
            .appending(path: "weclaw-send-\(UUID().uuidString).encrypted")
        defer { try? FileManager.default.removeItem(at: encryptedURL) }
        let encrypted = try WeChatCrypto.aes128ECBEncryptFile(
            at: fileURL,
            to: encryptedURL,
            key: aesKey,
            checkCancellation: { try Task.checkCancellation() }
        )
        guard encrypted.plaintextSize == rawSize else {
            throw CocoaError(.fileReadUnknown)
        }

        let uploadRequest = GetUploadURLRequest(
            fileKey: fileKey,
            mediaType: 3,
            toUserID: credentials.userID,
            rawSize: rawSize,
            rawFileMD5: encrypted.plaintextMD5,
            fileSize: encrypted.ciphertextSize,
            noNeedThumb: true,
            aesKey: aesKeyHex,
            baseInfo: Self.baseInfo
        )
        let uploadEndpoint = try Self.endpoint(
            baseURL: credentials.baseURL,
            path: "ilink/bot/getuploadurl"
        )
        let uploadResponse: GetUploadURLResponse = try await post(
            uploadEndpoint,
            body: uploadRequest,
            token: credentials.botToken,
            timeout: 15
        )
        try uploadResponse.validate()
        let uploadURL = try Self.uploadURL(from: uploadResponse, fileKey: fileKey)
        await progress(
            WeChatSendProgress(
                stage: .uploading,
                fraction: 0.1,
                sentBytes: 0,
                totalBytes: totalBytes
            )
        )
        let encryptedParameter = try await upload(
            encryptedURL,
            ciphertextSize: encrypted.ciphertextSize,
            plaintextSize: totalBytes,
            to: uploadURL,
            progress: progress
        )

        await progress(
            WeChatSendProgress(
                stage: .waitingToSend,
                fraction: 0.92,
                sentBytes: totalBytes,
                totalBytes: totalBytes
            )
        )
        try await acquireSubmissionSlot()
        defer { finishSubmissionSlot() }
        guard let submissionCredentials = self.credentials,
              submissionCredentials.botID == credentials.botID,
              submissionCredentials.userID == credentials.userID,
              submissionCredentials.botToken == credentials.botToken,
              submissionCredentials.baseURL == credentials.baseURL else {
            throw WeChatError.notLoggedIn
        }

        await progress(
            WeChatSendProgress(
                stage: .sending,
                fraction: 0.95,
                sentBytes: totalBytes,
                totalBytes: totalBytes
            )
        )

        func messageRequest(contextToken: String?) -> SendMessageRequest {
            SendMessageRequest(
                message: WeChatMessage(
                    fromUserID: "",
                    toUserID: submissionCredentials.userID,
                    clientID: "weclaw-send:\(UUID().uuidString.lowercased())",
                    messageType: 2,
                    messageState: 2,
                    items: [
                        MessageItem(
                            type: 4,
                            file: FileItem(
                                media: CDNMedia(
                                    encryptedQueryParameter: encryptedParameter,
                                    aesKey: Data(aesKeyHex.utf8).base64EncodedString(),
                                    encryptionType: 1
                                ),
                                fileName: fileName,
                                length: String(rawSize)
                            )
                        )
                    ],
                    contextToken: contextToken
                ),
                baseInfo: Self.baseInfo
            )
        }
        let sendEndpoint = try Self.endpoint(
            baseURL: submissionCredentials.baseURL,
            path: "ilink/bot/sendmessage"
        )
        var sendResponse: APIResponse = try await post(
            sendEndpoint,
            body: messageRequest(contextToken: submissionCredentials.contextToken),
            token: submissionCredentials.botToken,
            timeout: 15
        )
        if sendResponse.result == -2 {
            await progress(
                WeChatSendProgress(
                    stage: .waitingForContext,
                    fraction: 0.95,
                    sentBytes: totalBytes,
                    totalBytes: totalBytes
                )
            )
            let contextToken = try await waitForFreshContextToken(credentials: submissionCredentials)
            await progress(
                WeChatSendProgress(
                    stage: .sending,
                    fraction: 0.98,
                    sentBytes: totalBytes,
                    totalBytes: totalBytes
                )
            )
            sendResponse = try await post(
                sendEndpoint,
                body: messageRequest(contextToken: contextToken),
                token: submissionCredentials.botToken,
                timeout: 15
            )
        }
        try sendResponse.validateSendMessage()
        credentialsValidated = true
        await progress(
            WeChatSendProgress(
                stage: .finished,
                fraction: 1,
                sentBytes: totalBytes,
                totalBytes: totalBytes
            )
        )
    }

    private func acquireSubmissionSlot() async throws {
        try Task.checkCancellation()
        if !submissionSlotLocked {
            submissionSlotLocked = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                submissionWaiters.append(SubmissionWaiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelSubmissionWaiter(id: id) }
        }
        if Task.isCancelled {
            releaseSubmissionSlot()
            throw CancellationError()
        }
    }

    private func cancelSubmissionWaiter(id: UUID) {
        guard let index = submissionWaiters.firstIndex(where: { $0.id == id }) else { return }
        submissionWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func finishSubmissionSlot() {
        let interval = submissionIntervalMilliseconds
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(interval))
            await self?.releaseSubmissionSlot()
        }
    }

    private func releaseSubmissionSlot() {
        if submissionWaiters.isEmpty {
            submissionSlotLocked = false
        } else {
            submissionWaiters.removeFirst().continuation.resume()
        }
    }

    private func upload(
        _ ciphertextURL: URL,
        ciphertextSize: Int,
        plaintextSize: Int64,
        to url: URL,
        progress: @escaping @Sendable (WeChatSendProgress) async -> Void
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let progressPair = AsyncStream<Int64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let delegate = UploadProgressDelegate { sentBytes in
            progressPair.continuation.yield(sentBytes)
        }
        let progressTask = Task {
            for await sentBytes in progressPair.stream {
                let ratio = min(Double(sentBytes) / Double(max(ciphertextSize, 1)), 1)
                await progress(
                    WeChatSendProgress(
                        stage: .uploading,
                        fraction: 0.1 + ratio * 0.8,
                        sentBytes: min(Int64(Double(plaintextSize) * ratio), plaintextSize),
                        totalBytes: plaintextSize
                    )
                )
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: ciphertextURL, delegate: delegate)
            progressPair.continuation.finish()
            await progressTask.value
        } catch {
            progressPair.continuation.finish()
            await progressTask.value
            throw error
        }
        let http = try Self.validatedHTTPResponse(response, data: data)
        guard http.statusCode == 200 else {
            throw WeChatError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard let parameter = http.value(forHTTPHeaderField: "x-encrypted-param"), !parameter.isEmpty else {
            throw WeChatError.missingUploadResult
        }
        return parameter
    }

    private func waitForFreshContextToken(credentials: WeChatCredentials) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [self] in
                try await pollForFreshContextToken(credentials: credentials)
            }
            group.addTask { [contextRefreshTimeout] in
                try await Task.sleep(for: contextRefreshTimeout)
                throw WeChatError.contextRefreshTimedOut
            }
            defer { group.cancelAll() }
            guard let contextToken = try await group.next() else {
                throw WeChatError.invalidResponse
            }
            return contextToken
        }
    }

    private func pollForFreshContextToken(credentials: WeChatCredentials) async throws -> String {
        let endpoint = try Self.endpoint(
            baseURL: credentials.baseURL,
            path: "ilink/bot/getupdates"
        )
        var buffer = credentials.getUpdatesBuffer ?? ""
        while true {
            try Task.checkCancellation()
            let response: GetUpdatesResponse
            do {
                response = try await post(
                    endpoint,
                    body: GetUpdatesRequest(buffer: buffer, baseInfo: Self.baseInfo),
                    token: credentials.botToken,
                    timeout: 45
                )
            } catch let error as URLError where error.code == .timedOut {
                continue
            }
            try response.validate()
            if let nextBuffer = response.buffer {
                buffer = nextBuffer
            }
            let newestMessage = response.messages?.reduce(nil as InboundMessage?) { newest, message in
                guard message.fromUserID == credentials.userID,
                      let contextToken = message.contextToken,
                      !contextToken.isEmpty,
                      contextToken != credentials.contextToken else {
                    return newest
                }
                guard let newest else { return message }
                return message.isNewer(than: newest) ? message : newest
            }
            guard let contextToken = newestMessage?.contextToken else {
                continue
            }
            let refreshed = credentials.refreshingContext(token: contextToken, buffer: buffer)
            try store.save(refreshed)
            self.credentials = refreshed
            return contextToken
        }
    }

    private func post<Request: Encodable, Response: Decodable>(
        _ url: URL,
        body: Request,
        token: String?,
        timeout: TimeInterval
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ilink_bot_token", forHTTPHeaderField: "AuthorizationType")
        request.setValue(Self.randomWeChatUIN(), forHTTPHeaderField: "X-WECHAT-UIN")
        Self.addAppHeaders(to: &request)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        _ = try Self.validatedHTTPResponse(response, data: data)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func get<Response: Decodable>(_ url: URL, timeout: TimeInterval) async throws -> Response {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        Self.addAppHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        _ = try Self.validatedHTTPResponse(response, data: data)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private static var baseInfo: BaseInfo {
        BaseInfo(channelVersion: channelVersion, botAgent: botAgent)
    }

    private static func addAppHeaders(to request: inout URLRequest) {
        request.setValue("bot", forHTTPHeaderField: "iLink-App-Id")
        request.setValue(appClientVersion, forHTTPHeaderField: "iLink-App-ClientVersion")
    }

    private static func randomWeChatUIN() -> String {
        Data(String(UInt32.random(in: .min ... .max)).utf8).base64EncodedString()
    }

    private static func validatedHTTPResponse(_ response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw WeChatError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WeChatError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return http
    }

    static func endpoint(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        let url = baseURL.appending(path: path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw WeChatError.invalidResponse
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let result = components.url else { throw WeChatError.invalidResponse }
        return result
    }

    static func uploadURL(from response: GetUploadURLResponse, fileKey: String) throws -> URL {
        if let fullURL = response.uploadFullURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fullURL.isEmpty,
           let url = URL(string: fullURL),
           url.scheme == "https" {
            return url
        }
        guard let parameter = response.uploadParameter, !parameter.isEmpty else {
            throw WeChatError.missingUploadURL
        }
        return try endpoint(
            baseURL: cdnBaseURL,
            path: "upload",
            queryItems: [
                URLQueryItem(name: "encrypted_query_param", value: parameter),
                URLQueryItem(name: "filekey", value: fileKey)
            ]
        )
    }
}

private struct SubmissionWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64) -> Void

    init(report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        report(totalBytesSent)
    }
}

struct BaseInfo: Codable, Equatable, Sendable {
    let channelVersion: String
    let botAgent: String

    enum CodingKeys: String, CodingKey {
        case channelVersion = "channel_version"
        case botAgent = "bot_agent"
    }
}

private struct QRCodeRequest: Encodable {
    let localTokenList: [String]

    enum CodingKeys: String, CodingKey {
        case localTokenList = "local_token_list"
    }
}

private struct GetConfigRequest: Encodable {
    let userID: String
    let baseInfo: BaseInfo

    enum CodingKeys: String, CodingKey {
        case userID = "ilink_user_id"
        case baseInfo = "base_info"
    }
}

private struct GetUpdatesRequest: Encodable {
    let buffer: String
    let baseInfo: BaseInfo

    enum CodingKeys: String, CodingKey {
        case buffer = "get_updates_buf"
        case baseInfo = "base_info"
    }
}

private struct GetUpdatesResponse: Decodable {
    let result: Int?
    let errorCode: Int?
    let errorMessage: String?
    let messages: [InboundMessage]?
    let buffer: String?

    enum CodingKeys: String, CodingKey {
        case result = "ret"
        case errorCode = "errcode"
        case errorMessage = "errmsg"
        case messages = "msgs"
        case buffer = "get_updates_buf"
    }

    func validate() throws {
        guard (result == nil || result == 0), (errorCode == nil || errorCode == 0) else {
            let detail = errorMessage ?? "ret=\(result ?? 0), errcode=\(errorCode ?? 0)"
            throw WeChatError.api("刷新微信会话失败：\(detail)")
        }
    }
}

private struct InboundMessage: Decodable {
    let fromUserID: String?
    let sequence: Int64?
    let createTimeMilliseconds: Int64?
    let contextToken: String?

    enum CodingKeys: String, CodingKey {
        case fromUserID = "from_user_id"
        case sequence = "seq"
        case createTimeMilliseconds = "create_time_ms"
        case contextToken = "context_token"
    }

    func isNewer(than other: Self) -> Bool {
        if sequence != other.sequence {
            return (sequence ?? .min) > (other.sequence ?? .min)
        }
        if createTimeMilliseconds != other.createTimeMilliseconds {
            return (createTimeMilliseconds ?? .min) > (other.createTimeMilliseconds ?? .min)
        }
        return true
    }
}

private struct QRCodeResponse: Decodable {
    let qrcode: String
    let qrcodeImageContent: String

    enum CodingKeys: String, CodingKey {
        case qrcode
        case qrcodeImageContent = "qrcode_img_content"
    }
}

private struct QRStatusResponse: Decodable {
    let status: String
    let botToken: String?
    let botID: String?
    let baseURL: String?
    let userID: String?
    let redirectHost: String?

    enum CodingKeys: String, CodingKey {
        case status
        case botToken = "bot_token"
        case botID = "ilink_bot_id"
        case baseURL = "baseurl"
        case userID = "ilink_user_id"
        case redirectHost = "redirect_host"
    }

    func credentials(defaultBaseURL: URL) throws -> WeChatCredentials {
        guard
            let botToken, !botToken.isEmpty,
            let botID, !botID.isEmpty,
            let userID, !userID.isEmpty
        else {
            throw WeChatError.login("微信登录成功响应缺少凭据")
        }
        let resolvedBaseURL = baseURL.flatMap(URL.init(string:)) ?? defaultBaseURL
        guard resolvedBaseURL.scheme == "https" else {
            throw WeChatError.login("微信登录服务地址无效")
        }
        return WeChatCredentials(
            botToken: botToken,
            botID: botID,
            baseURL: resolvedBaseURL,
            userID: userID
        )
    }
}

struct GetUploadURLRequest: Encodable, Equatable, Sendable {
    let fileKey: String
    let mediaType: Int
    let toUserID: String
    let rawSize: Int
    let rawFileMD5: String
    let fileSize: Int
    let noNeedThumb: Bool
    let aesKey: String
    let baseInfo: BaseInfo

    enum CodingKeys: String, CodingKey {
        case fileKey = "filekey"
        case mediaType = "media_type"
        case toUserID = "to_user_id"
        case rawSize = "rawsize"
        case rawFileMD5 = "rawfilemd5"
        case fileSize = "filesize"
        case noNeedThumb = "no_need_thumb"
        case aesKey = "aeskey"
        case baseInfo = "base_info"
    }
}

struct GetUploadURLResponse: Decodable, Equatable, Sendable {
    let result: Int?
    let errorMessage: String?
    let uploadParameter: String?
    let uploadFullURL: String?

    enum CodingKeys: String, CodingKey {
        case result = "ret"
        case errorMessage = "errmsg"
        case uploadParameter = "upload_param"
        case uploadFullURL = "upload_full_url"
    }

    func validate() throws {
        guard result == nil || result == 0 else {
            throw WeChatError.api("获取微信上传地址失败：\(errorMessage ?? "ret=\(result!)")")
        }
    }
}

struct APIResponse: Decodable, Equatable, Sendable {
    let result: Int?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case result = "ret"
        case errorMessage = "errmsg"
    }

    func validate(action: String) throws {
        guard result == nil || result == 0 else {
            throw WeChatError.api("\(action)：\(errorMessage ?? "ret=\(result!)")")
        }
    }

    func validateSendMessage() throws {
        guard result != -2 else {
            throw WeChatError.api(
                "微信限制了本次发送，可能是会话过期或发送额度已用完。请先给 ClawBot 发一条消息，再重试。"
            )
        }
        try validate(action: "微信发送失败")
    }
}

struct SendMessageRequest: Encodable, Equatable, Sendable {
    let message: WeChatMessage
    let baseInfo: BaseInfo

    enum CodingKeys: String, CodingKey {
        case message = "msg"
        case baseInfo = "base_info"
    }
}

struct WeChatMessage: Encodable, Equatable, Sendable {
    let fromUserID: String
    let toUserID: String
    let clientID: String
    let messageType: Int
    let messageState: Int
    let items: [MessageItem]
    let contextToken: String?

    init(
        fromUserID: String,
        toUserID: String,
        clientID: String,
        messageType: Int,
        messageState: Int,
        items: [MessageItem],
        contextToken: String? = nil
    ) {
        self.fromUserID = fromUserID
        self.toUserID = toUserID
        self.clientID = clientID
        self.messageType = messageType
        self.messageState = messageState
        self.items = items
        self.contextToken = contextToken
    }

    enum CodingKeys: String, CodingKey {
        case fromUserID = "from_user_id"
        case toUserID = "to_user_id"
        case clientID = "client_id"
        case messageType = "message_type"
        case messageState = "message_state"
        case items = "item_list"
        case contextToken = "context_token"
    }
}

struct MessageItem: Encodable, Equatable, Sendable {
    let type: Int
    let file: FileItem

    enum CodingKeys: String, CodingKey {
        case type
        case file = "file_item"
    }
}

struct FileItem: Encodable, Equatable, Sendable {
    let media: CDNMedia
    let fileName: String
    let length: String

    enum CodingKeys: String, CodingKey {
        case media
        case fileName = "file_name"
        case length = "len"
    }
}

struct CDNMedia: Encodable, Equatable, Sendable {
    let encryptedQueryParameter: String
    let aesKey: String
    let encryptionType: Int

    enum CodingKeys: String, CodingKey {
        case encryptedQueryParameter = "encrypt_query_param"
        case aesKey = "aes_key"
        case encryptionType = "encrypt_type"
    }
}
