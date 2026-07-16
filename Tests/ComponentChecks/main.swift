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

do {
    try APIResponse(result: -2, errorMessage: nil).validateSendMessage()
    preconditionFailure("ret=-2 must provide an actionable error")
} catch let error as WeChatError {
    precondition(error.localizedDescription.contains("ClawBot"))
}
precondition(sendFailureMessage(CancellationError()) == "发送已取消")
precondition(sendFailureMessage(URLError(.cancelled)) == "发送已取消")

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
let legacyCredentials = try JSONDecoder().decode(
    WeChatCredentials.self,
    from: Data(#"{"botToken":"token","botID":"bot","baseURL":"https:\/\/mock.local","userID":"user"}"#.utf8)
)
precondition(legacyCredentials.contextToken == nil)
precondition(legacyCredentials.getUpdatesBuffer == nil)
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

let concurrencyResult = ResultBox()
let requestConcurrency = RequestConcurrencyTracker()
let transferConcurrency = TransferConcurrencyTracker()

MockURLProtocol.handler = { request in
    switch request.url!.path {
    case "/ilink/bot/getuploadurl":
        return MockURLProtocol.response(
            request,
            body: #"{"ret":0,"upload_full_url":"https://mock.local/upload"}"#
        )
    case "/upload":
        requestConcurrency.beginUpload()
        defer { requestConcurrency.endUpload() }
        Thread.sleep(forTimeInterval: 0.15)
        return MockURLProtocol.response(
            request,
            headers: ["x-encrypted-param": "concurrent-download-reference"],
            body: ""
        )
    case "/ilink/bot/sendmessage":
        requestConcurrency.beginSubmission()
        defer { requestConcurrency.endSubmission() }
        Thread.sleep(forTimeInterval: 0.02)
        return MockURLProtocol.response(request, body: #"{"ret":0}"#)
    default:
        preconditionFailure("Unexpected concurrency request: \(request.url!.absoluteString)")
    }
}

let concurrencyFinished = DispatchSemaphore(value: 0)
Task {
    do {
        let service = WeChatService(
            credentials: mockCredentials,
            session: mockSession,
            submissionIntervalMilliseconds: 50
        )
        let coordinator = SendCoordinator(weChat: service)
        let eventTask = Task {
            for await event in coordinator.events {
                if await transferConcurrency.consume(event) { return }
            }
        }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<4 {
                    group.addTask {
                        _ = try await coordinator.send(
                            SendRequest(filePath: mockFile.path, fileName: "\(index)-\(mockFileName)")
                        )
                    }
                }
                try await group.waitForAll()
            }
            await eventTask.value
        } catch {
            eventTask.cancel()
            await eventTask.value
            throw error
        }
        concurrencyResult.maxActiveTransfers = await transferConcurrency.maximumActive()
        concurrencyResult.maxQueuedTransfers = await transferConcurrency.maximumQueued()
    } catch {
        concurrencyResult.error = error
    }
    concurrencyFinished.signal()
}
precondition(concurrencyFinished.wait(timeout: .now() + 10) == .success)
if let error = concurrencyResult.error { throw error }
let requestConcurrencySnapshot = requestConcurrency.snapshot()
precondition(
    (1...SendCoordinator.maxConcurrentTransfers).contains(requestConcurrencySnapshot.maxUploads),
    "upload concurrency exceeded limit: \(requestConcurrencySnapshot.maxUploads)"
)
precondition(
    requestConcurrencySnapshot.maxSubmissions == 1,
    "expected serialized submissions, got \(requestConcurrencySnapshot.maxSubmissions)"
)
precondition(
    requestConcurrencySnapshot.submissionStarts.count == 4,
    "expected 4 submissions, got \(requestConcurrencySnapshot.submissionStarts.count)"
)
for (previous, next) in zip(
    requestConcurrencySnapshot.submissionStarts,
    requestConcurrencySnapshot.submissionStarts.dropFirst()
) {
    precondition(previous.duration(to: next) >= .milliseconds(45))
}
precondition(concurrencyResult.maxActiveTransfers == SendCoordinator.maxConcurrentTransfers)
precondition(concurrencyResult.maxQueuedTransfers > 0)

let contextRefreshResult = ContextRefreshResultBox()
let contextStoreURL = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-context-\(UUID()).json")
let contextStore = WeChatCredentialStore(credentialsFileOverride: contextStoreURL)
defer { try? FileManager.default.removeItem(at: contextStoreURL) }
let staleCredentials = WeChatCredentials(
    botToken: "secret-token",
    botID: "bot@im.bot",
    baseURL: URL(string: "https://mock.local")!,
    userID: "user@im.wechat",
    contextToken: "stale-context",
    getUpdatesBuffer: "old-buffer"
)

MockURLProtocol.handler = { request in
    switch request.url!.path {
    case "/ilink/bot/getuploadurl":
        return MockURLProtocol.response(
            request,
            body: #"{"ret":0,"upload_full_url":"https://mock.local/upload"}"#
        )
    case "/upload":
        return MockURLProtocol.response(
            request,
            headers: ["x-encrypted-param": "refresh-download-reference"],
            body: ""
        )
    case "/ilink/bot/sendmessage":
        contextRefreshResult.sendCount += 1
        let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
        let message = body["msg"] as! [String: Any]
        if contextRefreshResult.sendCount == 1 {
            precondition(message["context_token"] as? String == "stale-context")
            return MockURLProtocol.response(request, body: #"{"ret":-2}"#)
        }
        precondition(message["context_token"] as? String == "fresh-context")
        return MockURLProtocol.response(request, body: #"{"ret":0}"#)
    case "/ilink/bot/getupdates":
        let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
        contextRefreshResult.updateCount += 1
        if contextRefreshResult.updateCount == 1 {
            precondition(body["get_updates_buf"] as? String == "old-buffer")
            return MockURLProtocol.response(
                request,
                body: #"{"ret":0,"get_updates_buf":"mid-buffer","msgs":[{"seq":1,"from_user_id":"user@im.wechat","create_time_ms":0,"context_token":"stale-context"}]}"#
            )
        }
        precondition(contextRefreshResult.updateCount == 2)
        precondition(body["get_updates_buf"] as? String == "mid-buffer")
        return MockURLProtocol.response(
            request,
            body: #"{"ret":0,"get_updates_buf":"new-buffer","msgs":[{"seq":2,"from_user_id":"user@im.wechat","create_time_ms":0,"context_token":"older-context"},{"seq":3,"from_user_id":"user@im.wechat","create_time_ms":0,"context_token":"fresh-context"}]}"#
        )
    default:
        preconditionFailure("Unexpected context refresh request: \(request.url!.absoluteString)")
    }
}

let contextRefreshFinished = DispatchSemaphore(value: 0)
Task {
    do {
        let service = WeChatService(
            credentials: staleCredentials,
            session: mockSession,
            store: contextStore
        )
        try await service.sendFile(at: mockFile, fileName: mockFileName) { progress in
            contextRefreshResult.progress.append(progress)
        }
    } catch {
        contextRefreshResult.error = error
    }
    contextRefreshFinished.signal()
}
precondition(contextRefreshFinished.wait(timeout: .now() + 10) == .success)
if let error = contextRefreshResult.error { throw error }
precondition(contextRefreshResult.sendCount == 2)
precondition(contextRefreshResult.updateCount == 2)
precondition(contextRefreshResult.progress.contains { $0.stage == .waitingForContext })
precondition(contextRefreshResult.progress.last?.stage == .finished)
let refreshedCredentials = try contextStore.load()
precondition(refreshedCredentials?.contextToken == "fresh-context")
precondition(refreshedCredentials?.getUpdatesBuffer == "new-buffer")
let contextStorePermissions = try FileManager.default.attributesOfItem(atPath: contextStoreURL.path)[.posixPermissions]
precondition((contextStorePermissions as? NSNumber)?.intValue == 0o600)

let timeoutResult = ContextRefreshResultBox()
let timeoutStoreURL = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-context-timeout-\(UUID()).json")
let timeoutStore = WeChatCredentialStore(credentialsFileOverride: timeoutStoreURL)
defer { try? FileManager.default.removeItem(at: timeoutStoreURL) }

MockURLProtocol.handler = { request in
    switch request.url!.path {
    case "/ilink/bot/getuploadurl":
        return MockURLProtocol.response(
            request,
            body: #"{"ret":0,"upload_full_url":"https://mock.local/upload"}"#
        )
    case "/upload":
        return MockURLProtocol.response(
            request,
            headers: ["x-encrypted-param": "timeout-download-reference"],
            body: ""
        )
    case "/ilink/bot/sendmessage":
        return MockURLProtocol.response(request, body: #"{"ret":-2}"#)
    case "/ilink/bot/getupdates":
        throw URLError(.timedOut)
    default:
        preconditionFailure("Unexpected context timeout request: \(request.url!.absoluteString)")
    }
}

let contextTimeoutFinished = DispatchSemaphore(value: 0)
Task {
    do {
        let service = WeChatService(
            credentials: staleCredentials,
            session: mockSession,
            store: timeoutStore,
            contextRefreshTimeout: .milliseconds(20)
        )
        try await service.sendFile(at: mockFile, fileName: mockFileName)
    } catch {
        timeoutResult.error = error
    }
    contextTimeoutFinished.signal()
}
precondition(contextTimeoutFinished.wait(timeout: .now() + 10) == .success)
if let timeoutError = timeoutResult.error as? WeChatError,
   case .contextRefreshTimedOut = timeoutError {
    // Expected.
} else {
    preconditionFailure("context refresh must time out explicitly")
}

let version140 = ReleaseVersion(tag: "v1.4.0")!
let version150 = ReleaseVersion(tag: "1.5.0")!
precondition(version140 < version150)
precondition(ReleaseVersion(tag: "v1.5") == nil)
let version160 = ReleaseVersion(tag: "1.6.0")!
precondition(
    UpdateManager.premierePluginUpdateState(installed: nil, latest: version150)
        == .notInstalled(latest: version150)
)
precondition(
    UpdateManager.premierePluginUpdateState(installed: version140, latest: version150)
        == .updateAvailable(installed: version140, latest: version150)
)
precondition(
    UpdateManager.premierePluginUpdateState(installed: version150, latest: version150)
        == .current(version150)
)
precondition(
    UpdateManager.premierePluginUpdateState(installed: version160, latest: version150)
        == .localNewer(installed: version160, latest: version150)
)
let release = try JSONDecoder().decode(
    GitHubRelease.self,
    from: Data(
        #"{"tag_name":"v1.5.0","html_url":"https://github.com/double2tea/WeClawSend/releases/tag/v1.5.0","assets":[{"name":"WeClaw-Send.zip","browser_download_url":"https://example.test/WeClaw-Send.zip"}]}"#.utf8
    )
)
precondition(release.version == version150)
precondition(release.asset(named: UpdateManager.appArchiveName)?.browserDownloadURL.host == "example.test")
let checksumManifest = """
0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  WeClaw-Send.zip
"""
let releaseChecksum = try UpdateManager.checksum(
    for: UpdateManager.appArchiveName,
    in: checksumManifest
)
precondition(releaseChecksum == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
do {
    _ = try UpdateManager.checksum(for: "missing.zip", in: checksumManifest)
    preconditionFailure("missing release checksum must fail")
} catch let error as UpdateManagerError {
    guard case .missingChecksum = error else {
        preconditionFailure("unexpected checksum error")
    }
}
let updateChecksumFile = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-update-checksum-\(UUID()).txt")
try Data("abc".utf8).write(to: updateChecksumFile)
defer { try? FileManager.default.removeItem(at: updateChecksumFile) }
let updateChecksum = try UpdateManager.sha256(of: updateChecksumFile)
precondition(updateChecksum == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
let updateConfiguration = URLSessionConfiguration.ephemeral
updateConfiguration.protocolClasses = [MockURLProtocol.self]
let updateSession = URLSession(configuration: updateConfiguration)
let updateEndpoint = URL(string: "https://mock.local/releases/latest")!
MockURLProtocol.handler = { request in
    precondition(request.url == updateEndpoint)
    precondition(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    precondition(request.value(forHTTPHeaderField: "User-Agent") == "WeClawSend")
    return MockURLProtocol.response(
        request,
        body: #"{"tag_name":"v1.5.0","html_url":"https://github.com/double2tea/WeClawSend/releases/tag/v1.5.0","assets":[]}"#
    )
}
let updateManager = UpdateManager(session: updateSession, latestReleaseURL: updateEndpoint)
let updateResult = UpdateResultBox()
let updateFinished = DispatchSemaphore(value: 0)
Task {
    do {
        updateResult.release = try await updateManager.latestRelease()
    } catch {
        updateResult.error = error
    }
    updateFinished.signal()
}
precondition(updateFinished.wait(timeout: .now() + 10) == .success)
if let error = updateResult.error { throw error }
precondition(updateResult.release?.tagName == "v1.5.0")

let installerRoot = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-installer-\(UUID())", directoryHint: .isDirectory)
let installerHome = installerRoot.appending(path: "home", directoryHint: .isDirectory)
let installerFixtures = installerRoot.appending(path: "fixtures", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: installerHome, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: installerFixtures, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: installerRoot) }

let premiereFixture = installerFixtures.appending(path: "premiere", directoryHint: .isDirectory)
try writePremiereFixture(at: premiereFixture, version: "9.0.0")
let premiereArchive = installerFixtures.appending(path: UpdateManager.premiereArchiveName)
try zipDirectory(premiereFixture, to: premiereArchive)

let invalidPremiereFixture = installerFixtures.appending(path: "invalid-premiere", directoryHint: .isDirectory)
try writePremiereFixture(at: invalidPremiereFixture, version: "9.0.0")
let deceptiveManifest = """
<ExtensionManifest ExtensionBundleId="wrong.extension" ExtensionBundleVersion="9.0.0">
    <!-- ExtensionBundleId="com.chacha.WeClawSend.Premiere" -->
</ExtensionManifest>
"""
try Data(deceptiveManifest.utf8).write(
    to: invalidPremiereFixture.appending(path: "CSXS/manifest.xml")
)
do {
    _ = try UpdateManager.validatePremierePlugin(at: invalidPremiereFixture)
    preconditionFailure("Premiere manifest identity must be parsed as XML")
} catch let error as UpdateManagerError {
    guard case .invalidArchive = error else {
        preconditionFailure("unexpected Premiere manifest validation error")
    }
}

let incompletePremiereFixture = installerFixtures.appending(path: "incomplete-premiere", directoryHint: .isDirectory)
try writePremiereFixture(at: incompletePremiereFixture, version: "9.0.0")
try FileManager.default.removeItem(at: incompletePremiereFixture.appending(path: "js/main.js"))
do {
    _ = try UpdateManager.validatePremierePlugin(at: incompletePremiereFixture)
    preconditionFailure("Premiere plugin missing a required file must fail")
} catch let error as UpdateManagerError {
    guard case .invalidArchive = error else {
        preconditionFailure("unexpected Premiere required-file validation error")
    }
}

let missingBridgeFixture = installerFixtures.appending(path: "missing-bridge", directoryHint: .isDirectory)
try writePremiereFixture(at: missingBridgeFixture, version: "1.6.1")
try FileManager.default.removeItem(at: missingBridgeFixture.appending(path: "js/bridge-client.js"))
do {
    _ = try UpdateManager.validatePremierePlugin(at: missingBridgeFixture)
    preconditionFailure("Premiere 1.6.1+ package missing bridge client must fail")
} catch let error as UpdateManagerError {
    guard case .invalidArchive = error else {
        preconditionFailure("unexpected Premiere bridge-client validation error")
    }
}

let legacyPremiereFixture = installerFixtures.appending(path: "legacy-premiere", directoryHint: .isDirectory)
try writePremiereFixture(at: legacyPremiereFixture, version: "1.6.0")
try FileManager.default.removeItem(at: legacyPremiereFixture.appending(path: "js/bridge-client.js"))
let legacyPremiereVersion = try UpdateManager.validatePremierePlugin(at: legacyPremiereFixture)
precondition(legacyPremiereVersion == ReleaseVersion(tag: "1.6.0")!)

let daVinciFixture = installerFixtures.appending(path: "davinci", directoryHint: .isDirectory)
let daVinciSource = daVinciFixture.appending(path: "davinci-resolve/Deliver", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: daVinciSource, withIntermediateDirectories: true)
for name in UpdateManager.daVinciScriptNames {
    try Data("new \(name)".utf8).write(to: daVinciSource.appending(path: name))
}
let daVinciArchive = installerFixtures.appending(path: UpdateManager.daVinciArchiveName)
try zipDirectory(daVinciFixture, to: daVinciArchive)

let existingPremiere = installerHome
    .appending(path: "Library/Application Support/Adobe/CEP/extensions/com.chacha.WeClawSend.Premiere", directoryHint: .isDirectory)
try writePremiereManifest(at: existingPremiere, version: "8.0.0")
try Data("old".utf8).write(to: existingPremiere.appending(path: "old.txt"))
let existingDaVinci = installerHome.appending(
    path: "Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Deliver",
    directoryHint: .isDirectory
)
try FileManager.default.createDirectory(at: existingDaVinci, withIntermediateDirectories: true)
try Data("old".utf8).write(
    to: existingDaVinci.appending(path: UpdateManager.daVinciScriptNames[0])
)

let premiereChecksum = try UpdateManager.sha256(of: premiereArchive)
let daVinciChecksum = try UpdateManager.sha256(of: daVinciArchive)
let installerChecksumManifest = """
\(premiereChecksum)  \(UpdateManager.premiereArchiveName)
\(daVinciChecksum)  \(UpdateManager.daVinciArchiveName)
"""
let installerEndpoint = URL(string: "https://mock.local/releases/latest")!
let installerConfiguration = URLSessionConfiguration.ephemeral
installerConfiguration.protocolClasses = [MockURLProtocol.self]
let installerSession = URLSession(configuration: installerConfiguration)
MockURLProtocol.handler = { request in
    switch request.url!.path {
    case "/releases/latest":
        return MockURLProtocol.response(
            request,
            body: #"{"tag_name":"v9.0.0","html_url":"https://github.com/double2tea/WeClawSend/releases/tag/v9.0.0","assets":[{"name":"SHA256SUMS.txt","browser_download_url":"https://mock.local/SHA256SUMS.txt"},{"name":"WeClaw-Send-Premiere-CEP12.zip","browser_download_url":"https://mock.local/WeClaw-Send-Premiere-CEP12.zip"},{"name":"WeClaw-Send-DaVinci-Resolve.zip","browser_download_url":"https://mock.local/WeClaw-Send-DaVinci-Resolve.zip"}]}"#
        )
    case "/SHA256SUMS.txt":
        return MockURLProtocol.response(request, body: installerChecksumManifest)
    case "/WeClaw-Send-Premiere-CEP12.zip":
        return MockURLProtocol.response(request, data: try Data(contentsOf: premiereArchive))
    case "/WeClaw-Send-DaVinci-Resolve.zip":
        return MockURLProtocol.response(request, data: try Data(contentsOf: daVinciArchive))
    default:
        preconditionFailure("Unexpected installer request: \(request.url!.absoluteString)")
    }
}
let installerManager = UpdateManager(
    session: installerSession,
    latestReleaseURL: installerEndpoint,
    homeDirectory: installerHome,
    defaultsExecutablePath: "/usr/bin/true"
)
let installerResult = UpdateInstallResultBox()
let installerFinished = DispatchSemaphore(value: 0)
Task {
    do {
        installerResult.installedPremiereVersion = try await installerManager.installedPremierePluginVersion()
        installerResult.premiereState = try await installerManager.premierePluginUpdateState()
        installerResult.premiereVersion = try await installerManager.installPremierePlugin()
        installerResult.daVinciVersion = try await installerManager.installDaVinciScripts()
    } catch {
        installerResult.error = error
    }
    installerFinished.signal()
}
precondition(installerFinished.wait(timeout: .now() + 10) == .success)
if let error = installerResult.error { throw error }
precondition(installerResult.installedPremiereVersion?.description == "8.0.0")
precondition(
    installerResult.premiereState
        == .updateAvailable(
            installed: ReleaseVersion(tag: "8.0.0")!,
            latest: ReleaseVersion(tag: "9.0.0")!
        )
)
precondition(installerResult.premiereVersion?.description == "9.0.0")
precondition(installerResult.daVinciVersion?.description == "9.0.0")
precondition(!FileManager.default.fileExists(atPath: existingPremiere.appending(path: "old.txt").path))
let installedManifest = try String(
    contentsOf: existingPremiere.appending(path: "CSXS/manifest.xml"),
    encoding: .utf8
)
precondition(installedManifest.contains("ExtensionBundleVersion=\"9.0.0\""))
let validatedInstalledPremiereVersion = try UpdateManager.validatePremierePlugin(at: existingPremiere)
precondition(validatedInstalledPremiereVersion.description == "9.0.0")
for name in UpdateManager.daVinciScriptNames {
    let installedScript = try String(contentsOf: existingDaVinci.appending(path: name), encoding: .utf8)
    precondition(installedScript == "new \(name)")
}

try writePremiereFixture(at: existingPremiere, version: "10.0.0")
let downgradeResult = UpdateInstallResultBox()
let downgradeFinished = DispatchSemaphore(value: 0)
Task {
    do {
        downgradeResult.premiereVersion = try await installerManager.installPremierePlugin()
    } catch {
        downgradeResult.error = error
    }
    downgradeFinished.signal()
}
precondition(downgradeFinished.wait(timeout: .now() + 10) == .success)
if let error = downgradeResult.error as? UpdateManagerError,
   case let .premierePluginDowngradeNotAllowed(installed, available) = error {
    precondition(installed.description == "10.0.0")
    precondition(available.description == "9.0.0")
} else {
    preconditionFailure("Premiere plugin downgrade must be blocked by default")
}
let retainedPremiereVersion = try UpdateManager.validatePremierePlugin(at: existingPremiere)
precondition(retainedPremiereVersion.description == "10.0.0")

try Data("<broken>".utf8).write(to: existingPremiere.appending(path: "CSXS/manifest.xml"))
let repairResult = UpdateInstallResultBox()
let repairFinished = DispatchSemaphore(value: 0)
Task {
    do {
        repairResult.premiereState = try await installerManager.premierePluginUpdateState()
        repairResult.premiereVersion = try await installerManager.installPremierePlugin()
    } catch {
        repairResult.error = error
    }
    repairFinished.signal()
}
precondition(repairFinished.wait(timeout: .now() + 10) == .success)
if let error = repairResult.error { throw error }
precondition(
    repairResult.premiereState
        == .repairRequired(latest: ReleaseVersion(tag: "9.0.0")!)
)
precondition(repairResult.premiereVersion?.description == "9.0.0")

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

private func zipDirectory(_ source: URL, to archive: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", source.path, archive.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func writePremiereFixture(at directory: URL, version: String) throws {
    for relativePath in UpdateManager.premiereRequiredFiles where relativePath != "CSXS/manifest.xml" {
        let fileURL = directory.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: fileURL)
    }
    try writePremiereManifest(at: directory, version: version)
}

private func writePremiereManifest(at directory: URL, version: String) throws {
    let manifestURL = directory.appending(path: "CSXS/manifest.xml")
    try FileManager.default.createDirectory(
        at: manifestURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let manifest = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ExtensionManifest
        ExtensionBundleId="com.chacha.WeClawSend.Premiere"
        ExtensionBundleVersion="\(version)">
        <ExtensionList>
            <Extension Id="com.chacha.WeClawSend.Premiere.panel" Version="\(version)"/>
        </ExtensionList>
        <DispatchInfoList>
            <Extension Id="com.chacha.WeClawSend.Premiere.panel"/>
        </DispatchInfoList>
    </ExtensionManifest>
    """
    try Data(manifest.utf8).write(to: manifestURL)
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
    var maxActiveTransfers = 0
    var maxQueuedTransfers = 0
}

final class ContextRefreshResultBox: @unchecked Sendable {
    var error: Error?
    var sendCount = 0
    var updateCount = 0
    var progress: [WeChatSendProgress] = []
}

final class UpdateResultBox: @unchecked Sendable {
    var error: Error?
    var release: GitHubRelease?
}

final class UpdateInstallResultBox: @unchecked Sendable {
    var error: Error?
    var installedPremiereVersion: ReleaseVersion?
    var premiereState: PremierePluginUpdateState?
    var premiereVersion: ReleaseVersion?
    var daVinciVersion: ReleaseVersion?
}

final class RequestConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var activeUploads = 0
    private var maxUploads = 0
    private var activeSubmissions = 0
    private var maxSubmissions = 0
    private var submissionStarts: [ContinuousClock.Instant] = []

    func beginUpload() {
        lock.lock()
        defer { lock.unlock() }
        activeUploads += 1
        maxUploads = max(maxUploads, activeUploads)
    }

    func endUpload() {
        lock.lock()
        defer { lock.unlock() }
        activeUploads -= 1
    }

    func beginSubmission() {
        lock.lock()
        defer { lock.unlock() }
        activeSubmissions += 1
        maxSubmissions = max(maxSubmissions, activeSubmissions)
        submissionStarts.append(ContinuousClock.now)
    }

    func endSubmission() {
        lock.lock()
        defer { lock.unlock() }
        activeSubmissions -= 1
    }

    func snapshot() -> (
        maxUploads: Int,
        maxSubmissions: Int,
        submissionStarts: [ContinuousClock.Instant]
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (maxUploads, maxSubmissions, submissionStarts)
    }
}

actor TransferConcurrencyTracker {
    private var queued: Set<UUID> = []
    private var active: Set<UUID> = []
    private var maxActive = 0
    private var maxQueued = 0
    private var terminalCount = 0

    func consume(_ event: TransferEvent) -> Bool {
        switch event {
        case let .started(record):
            precondition(record.status == .queued)
            queued.insert(record.id)
            maxQueued = max(maxQueued, queued.count)
        case let .updated(record):
            if record.status == .sending {
                if active.insert(record.id).inserted {
                    precondition(queued.remove(record.id) != nil)
                    maxActive = max(maxActive, active.count)
                }
            }
        case let .completed(record), let .failed(record):
            queued.remove(record.id)
            active.remove(record.id)
            terminalCount += 1
        }
        return terminalCount == 4
    }

    func maximumActive() -> Int {
        maxActive
    }

    func maximumQueued() -> Int {
        maxQueued
    }
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
        response(request, headers: headers, data: Data(body.utf8))
    }

    static func response(
        _ request: URLRequest,
        headers: [String: String] = [:],
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!,
            data
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
