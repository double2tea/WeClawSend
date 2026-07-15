import AppKit
import Foundation

precondition(WeChatCrypto.md5Hex(Data("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72")

let aesKey = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")!
let aesPlaintext = Data(hex: "6bc1bee22e409f96e93d7e117393172a")!
let aesCiphertext = try WeChatCrypto.aes128ECBEncrypt(aesPlaintext, key: aesKey)
precondition(aesCiphertext.count == 32)
precondition(aesCiphertext.prefix(16).lowercaseHex == "3ad77bb40d7a3660a89ecaf32466ef97")
for byteCount in [0, 1, 15, 16, 17] {
    let encrypted = try WeChatCrypto.aes128ECBEncrypt(
        Data(repeating: 7, count: byteCount),
        key: Data(repeating: 3, count: 16)
    )
    precondition(encrypted.count == ((byteCount / 16) + 1) * 16)
}

let streamingPlaintext = Data(repeating: 0x5a, count: 1_048_593)
let streamingSource = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-stream-source-\(UUID()).bin")
let streamingDestination = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-stream-destination-\(UUID()).bin")
try streamingPlaintext.write(to: streamingSource)
defer {
    try? FileManager.default.removeItem(at: streamingSource)
    try? FileManager.default.removeItem(at: streamingDestination)
}
let streamingMetadata = try WeChatCrypto.aes128ECBEncryptFile(
    at: streamingSource,
    to: streamingDestination,
    key: aesKey,
    checkCancellation: {}
)
let expectedStreamingCiphertext = try WeChatCrypto.aes128ECBEncrypt(streamingPlaintext, key: aesKey)
precondition(streamingMetadata.plaintextSize == streamingPlaintext.count)
precondition(streamingMetadata.ciphertextSize == expectedStreamingCiphertext.count)
precondition(streamingMetadata.plaintextMD5 == WeChatCrypto.md5Hex(streamingPlaintext))
let streamingCiphertext = try Data(contentsOf: streamingDestination)
precondition(streamingCiphertext == expectedStreamingCiphertext)

let aesKeyHex = "00112233445566778899aabbccddeeff"
let messageRequest = SendMessageRequest(
    message: WeChatMessage(
        fromUserID: "",
        toUserID: "user@im.wechat",
        clientID: "weclaw-send:test",
        messageType: 2,
        messageState: 2,
        items: [
            MessageItem(
                type: 4,
                file: FileItem(
                    media: CDNMedia(
                        encryptedQueryParameter: "encrypted",
                        aesKey: Data(aesKeyHex.utf8).base64EncodedString(),
                        encryptionType: 1
                    ),
                    fileName: "0714_一饭封神_成片 v05.m4v",
                    length: "19"
                )
            )
        ]
    ),
    baseInfo: BaseInfo(channelVersion: "2.4.6", botAgent: "WeClawSend/1.0.0")
)
let messageObject = try JSONSerialization.jsonObject(
    with: JSONEncoder().encode(messageRequest)
) as! [String: Any]
let message = messageObject["msg"] as! [String: Any]
let item = (message["item_list"] as! [[String: Any]])[0]
let file = item["file_item"] as! [String: Any]
let media = file["media"] as! [String: Any]
precondition(file["file_name"] as? String == "0714_一饭封神_成片 v05.m4v")
precondition(media["aes_key"] as? String == "MDAxMTIyMzM0NDU1NjY3Nzg4OTlhYWJiY2NkZGVlZmY=")
precondition(message["context_token"] == nil)

let uploadURL = try WeChatService.uploadURL(
    from: GetUploadURLResponse(
        result: 0,
        errorMessage: nil,
        uploadParameter: "参数 +/?",
        uploadFullURL: nil
    ),
    fileKey: "abc123"
)
let uploadComponents = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false)!
precondition(uploadURL.host == "novac2c.cdn.weixin.qq.com")
precondition(uploadComponents.queryItems?.first { $0.name == "encrypted_query_param" }?.value == "参数 +/?")
precondition(uploadComponents.queryItems?.first { $0.name == "filekey" }?.value == "abc123")

let previousRenameSetting = UserDefaults.standard.object(forKey: AppSettings.autoRenameMP4Key)
defer {
    if let previousRenameSetting {
        UserDefaults.standard.set(previousRenameSetting, forKey: AppSettings.autoRenameMP4Key)
    } else {
        UserDefaults.standard.removeObject(forKey: AppSettings.autoRenameMP4Key)
    }
}
UserDefaults.standard.set(true, forKey: AppSettings.autoRenameMP4Key)
precondition(AppSettings.outgoingFileName("成片.MP4") == "成片.m4v")
precondition(AppSettings.outgoingFileName("成片.m4v") == "成片.m4v")
UserDefaults.standard.set(false, forKey: AppSettings.autoRenameMP4Key)
precondition(AppSettings.outgoingFileName("成片.mp4") == "成片.mp4")

let previousLocalAPISetting = UserDefaults.standard.object(forKey: AppSettings.localAPIEnabledKey)
defer {
    if let previousLocalAPISetting {
        UserDefaults.standard.set(previousLocalAPISetting, forKey: AppSettings.localAPIEnabledKey)
    } else {
        UserDefaults.standard.removeObject(forKey: AppSettings.localAPIEnabledKey)
    }
}
UserDefaults.standard.removeObject(forKey: AppSettings.localAPIEnabledKey)
precondition(!AppSettings.localAPIEnabled)
UserDefaults.standard.set(false, forKey: AppSettings.localAPIEnabledKey)
precondition(!AppSettings.localAPIEnabled)
UserDefaults.standard.set(true, forKey: AppSettings.localAPIEnabledKey)
precondition(AppSettings.localAPIEnabled)

precondition(LaunchAtLogin.transition(for: .notFound, enabled: true) == .register)
precondition(LaunchAtLogin.transition(for: .notRegistered, enabled: true) == .register)
precondition(LaunchAtLogin.transition(for: .enabled, enabled: true) == .none)
precondition(LaunchAtLogin.transition(for: .enabled, enabled: false) == .unregister)
precondition(LaunchAtLogin.transition(for: .requiresApproval, enabled: false) == .unregister)

let legacyRecordData = Data(#"{"path":"/tmp/a","fileName":"a.txt","byteCount":1,"date":0,"status":"sent"}"#.utf8)
let legacyRecord = try JSONDecoder().decode(TransferRecord.self, from: legacyRecordData)
precondition(legacyRecord.status == .sent)
precondition(legacyRecord.progress == nil)

let mockConfiguration = URLSessionConfiguration.ephemeral
mockConfiguration.protocolClasses = [MockURLProtocol.self]
let mockSession = URLSession(configuration: mockConfiguration)
let mockCredentials = WeChatCredentials(
    botToken: "secret-token",
    botID: "bot@im.bot",
    baseURL: URL(string: "https://mock.local")!,
    userID: "user@im.wechat"
)
let mockFileName = "0714_一饭封神_成片 v05.m4v"
let mockFile = FileManager.default.temporaryDirectory.appending(path: mockFileName)
try Data("integration-file".utf8).write(to: mockFile)
defer { try? FileManager.default.removeItem(at: mockFile) }
let integrationResult = ResultBox()

MockURLProtocol.handler = { request in
    switch request.url!.path {
    case "/ilink/bot/getconfig":
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
        precondition(body["ilink_user_id"] as? String == "user@im.wechat")
        return MockURLProtocol.response(request, body: #"{"ret":0}"#)
    case "/ilink/bot/getuploadurl":
        precondition(request.value(forHTTPHeaderField: "iLink-App-Id") == "bot")
        precondition(request.value(forHTTPHeaderField: "AuthorizationType") == "ilink_bot_token")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        precondition(request.value(forHTTPHeaderField: "X-WECHAT-UIN") != nil)
        let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
        precondition(body["media_type"] as? Int == 3)
        precondition(body["to_user_id"] as? String == "user@im.wechat")
        precondition(body["rawfilemd5"] as? String == WeChatCrypto.md5Hex(Data("integration-file".utf8)))
        integrationResult.aesKeyHex = body["aeskey"] as? String
        return MockURLProtocol.response(
            request,
            body: #"{"ret":0,"upload_full_url":"https://mock.local/upload"}"#
        )
    case "/upload":
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        precondition(requestBody(request) != Data("integration-file".utf8))
        Thread.sleep(forTimeInterval: 0.25)
        return MockURLProtocol.response(
            request,
            headers: ["x-encrypted-param": "download-reference"],
            body: ""
        )
    case "/ilink/bot/sendmessage":
        precondition(request.value(forHTTPHeaderField: "iLink-App-Id") == "bot")
        let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
        let message = body["msg"] as! [String: Any]
        let item = (message["item_list"] as! [[String: Any]])[0]
        let file = item["file_item"] as! [String: Any]
        let media = file["media"] as! [String: Any]
        precondition(file["file_name"] as? String == mockFileName)
        precondition(media["encrypt_query_param"] as? String == "download-reference")
        precondition((media["aes_key"] as? String)?.base64DecodedUTF8 == integrationResult.aesKeyHex)
        precondition(message["context_token"] == nil)
        return MockURLProtocol.response(request, body: #"{"ret":0}"#)
    default:
        preconditionFailure("Unexpected mock request: \(request.url!.absoluteString)")
    }
}

let integrationFinished = DispatchSemaphore(value: 0)
Task {
    do {
        let integrationService = WeChatService(credentials: mockCredentials, session: mockSession)
        let integrationCoordinator = SendCoordinator(weChat: integrationService)
        let disconnectedSnapshot = await integrationCoordinator.snapshot()
        precondition(disconnectedSnapshot.weChatConnected == false)
        try await integrationService.validateCredentials()
        let connectedSnapshot = await integrationCoordinator.snapshot()
        precondition(connectedSnapshot.weChatConnected)
        try await integrationService.sendFile(at: mockFile, fileName: mockFileName) { progress in
            integrationResult.progress.append(progress)
        }

        let coordinatorService = WeChatService(credentials: mockCredentials, session: mockSession)
        let coordinator = SendCoordinator(weChat: coordinatorService)
        let startedAt = Date()
        let sendResult = try await coordinator.send(
            SendRequest(filePath: mockFile.path, fileName: mockFileName)
        )
        precondition(Date().timeIntervalSince(startedAt) >= 0.25)
        precondition(sendResult.queueWaitMilliseconds < 200)
        precondition(sendResult.fileName == mockFileName)
    } catch {
        integrationResult.error = error
    }
    integrationFinished.signal()
}
precondition(integrationFinished.wait(timeout: .now() + 10) == .success)
if let error = integrationResult.error { throw error }
precondition(integrationResult.progress.first?.stage == .preparing)
precondition(integrationResult.progress.contains { $0.stage == .uploading })
precondition(integrationResult.progress.last?.stage == .finished)
precondition(integrationResult.progress.last?.fraction == 1)

let pasteboard = NSPasteboard(name: .init("WeClawSendComponentChecks"))
let fileURL = FileManager.default.temporaryDirectory
    .appending(path: "WeClawSend-中文文件-\(UUID()).m4v")
precondition(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))
defer { try? FileManager.default.removeItem(at: fileURL) }
pasteboard.clearContents()
pasteboard.writeObjects([fileURL as NSURL, FileManager.default.temporaryDirectory as NSURL])
precondition(fileURLs(from: pasteboard) == [fileURL])
pasteboard.clearContents()

print("Component checks passed")

func formatBytes(_ byteCount: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

private extension String {
    var base64DecodedUTF8: String? {
        Data(base64Encoded: self).flatMap { String(data: $0, encoding: .utf8) }
    }
}

final class ResultBox: @unchecked Sendable {
    var error: Error?
    var aesKeyHex: String?
    var progress: [WeChatSendProgress] = []
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func response(
        _ request: URLRequest,
        headers: [String: String] = [:],
        body: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!,
            Data(body.utf8)
        )
    }
}

private func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        result.append(contentsOf: buffer[0..<count])
    }
    return result
}
