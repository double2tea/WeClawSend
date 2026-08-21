import AppKit
import Foundation

var singleSuccessBatch = SendResultNotificationBatch()
singleSuccessBatch.recordSuccess(fileName: "a.mp4")
precondition(singleSuccessBatch.body == "发送完成：a.mp4")

var multiSuccessBatch = SendResultNotificationBatch()
multiSuccessBatch.recordSuccess(fileName: "a.mp4")
multiSuccessBatch.recordSuccess(fileName: "b.mp4")
precondition(multiSuccessBatch.body == "已发送 2 个文件")

var mixedBatch = SendResultNotificationBatch()
mixedBatch.recordSuccess(fileName: "a.mp4")
mixedBatch.recordFailure(fileName: "b.mp4", message: "网络错误")
precondition(mixedBatch.body == "发送完成 1 个，失败 1 个")

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
precondition(isSendCancellation(CancellationError()))
precondition(isSendCancellation(URLError(.cancelled)))
precondition(WeChatRetryPolicy.shouldRetry(WeChatError.http(500, "temporary")))
precondition(WeChatRetryPolicy.shouldRetry(WeChatError.http(503, "temporary")))
precondition(!WeChatRetryPolicy.shouldRetry(WeChatError.http(400, "invalid")))
precondition(WeChatRetryPolicy.shouldRetry(URLError(.networkConnectionLost)))
precondition(!WeChatRetryPolicy.shouldRetry(URLError(.badURL)))
precondition(
    WeChatError.transfer(stage: .uploadingFile, reason: "HTTP 500").localizedDescription
        == "上传微信 CDN 文件失败：HTTP 500"
)
precondition(
    DiagnosticExporter.archiveName(now: Date(timeIntervalSince1970: 0))
        == "WeClawSend-Diagnostics-19700101-000000.zip"
)
let diagnosticOutputDirectory = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-diagnostic-test-\(UUID())", directoryHint: .isDirectory)
let diagnosticExtractDirectory = diagnosticOutputDirectory
    .appending(path: "extracted", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: diagnosticOutputDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: diagnosticOutputDirectory) }
let diagnosticArchive = try DiagnosticExporter.export(
    to: diagnosticOutputDirectory,
    now: Date(timeIntervalSince1970: 0)
)
let diagnosticExtractProcess = Process()
diagnosticExtractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
diagnosticExtractProcess.arguments = [
    "-x", "-k", diagnosticArchive.path, diagnosticExtractDirectory.path
]
try diagnosticExtractProcess.run()
diagnosticExtractProcess.waitUntilExit()
precondition(diagnosticExtractProcess.terminationStatus == 0)
let diagnosticPackage = diagnosticExtractDirectory
    .appending(path: "WeClawSend-Diagnostics", directoryHint: .isDirectory)
for fileName in ["README.txt", "System.txt", "WeClawSend.log"] {
    precondition(
        FileManager.default.fileExists(atPath: diagnosticPackage.appending(path: fileName).path)
    )
}

let loginStart = Date(timeIntervalSince1970: 1_000)
precondition(!WeChatLoginPollingPolicy.hasTimedOut(
    startedAt: loginStart,
    now: loginStart.addingTimeInterval(299)
))
precondition(WeChatLoginPollingPolicy.hasTimedOut(
    startedAt: loginStart,
    now: loginStart.addingTimeInterval(300)
))
precondition(WeChatLoginPollingPolicy.timeoutMessage(hasScanned: true).contains("ClawBot"))
precondition(WeChatLoginPollingPolicy.timeoutMessage(hasScanned: false).contains("重新生成二维码"))

let autoCloseStart = Date(timeIntervalSince1970: 1_000)
var autoClosePolicy = PopoverAutoClosePolicy()
autoClosePolicy.opened(at: autoCloseStart)
precondition(!autoClosePolicy.shouldClose(
    at: autoCloseStart.addingTimeInterval(4),
    hasActiveTransfers: false,
    blocksAutoClose: false
))
precondition(autoClosePolicy.shouldClose(
    at: autoCloseStart.addingTimeInterval(5),
    hasActiveTransfers: false,
    blocksAutoClose: false
))
autoClosePolicy.interacted(at: autoCloseStart.addingTimeInterval(20))
precondition(!autoClosePolicy.shouldClose(
    at: autoCloseStart.addingTimeInterval(24),
    hasActiveTransfers: false,
    blocksAutoClose: false
))
precondition(autoClosePolicy.shouldClose(
    at: autoCloseStart.addingTimeInterval(25),
    hasActiveTransfers: false,
    blocksAutoClose: false
))
precondition(!autoClosePolicy.shouldClose(
    at: autoCloseStart.addingTimeInterval(30),
    hasActiveTransfers: true,
    blocksAutoClose: false
))
precondition(!autoClosePolicy.shouldClose(
    at: autoCloseStart.addingTimeInterval(31),
    hasActiveTransfers: false,
    blocksAutoClose: false
))
precondition(autoClosePolicy.shouldClose(
    at: autoCloseStart.addingTimeInterval(34),
    hasActiveTransfers: false,
    blocksAutoClose: false
))
autoClosePolicy.opened(at: autoCloseStart)
precondition(!autoClosePolicy.shouldClose(
    at: autoCloseStart.addingTimeInterval(60),
    hasActiveTransfers: false,
    blocksAutoClose: true
))
precondition(!autoClosePolicy.shouldClose(
    at: autoCloseStart.addingTimeInterval(61),
    hasActiveTransfers: false,
    blocksAutoClose: false
))
precondition(autoClosePolicy.shouldClose(
    at: autoCloseStart.addingTimeInterval(66),
    hasActiveTransfers: false,
    blocksAutoClose: false
))

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

let previousSendSizeLimit = UserDefaults.standard.object(
    forKey: AppSettings.sendSizeLimitMegabytesKey
)
defer {
    if let previousSendSizeLimit {
        UserDefaults.standard.set(
            previousSendSizeLimit,
            forKey: AppSettings.sendSizeLimitMegabytesKey
        )
    } else {
        UserDefaults.standard.removeObject(forKey: AppSettings.sendSizeLimitMegabytesKey)
    }
}
UserDefaults.standard.removeObject(forKey: AppSettings.sendSizeLimitMegabytesKey)
precondition(AppSettings.sendSizeLimit == .megabytes200)
precondition(AppSettings.maxSendBytes == 200 * 1_024 * 1_024)
UserDefaults.standard.set(500, forKey: AppSettings.sendSizeLimitMegabytesKey)
precondition(AppSettings.sendSizeLimit == .megabytes500)
precondition(SendCoordinator.maxSendBytes == 500 * 1_024 * 1_024)
let dynamicHealthData = try JSONEncoder().encode(
    HealthResponse(
        queueDepth: 0,
        weChatConnected: true,
        maxSendBytes: SendCoordinator.maxSendBytes,
        lastSendAt: nil,
        sendDestination: LocalAPISendBehavior.direct.rawValue
    )
)
let dynamicHealth = try JSONSerialization.jsonObject(with: dynamicHealthData) as! [String: Any]
precondition(
    (dynamicHealth["max_send_bytes"] as? NSNumber)?.int64Value == 500 * 1_024 * 1_024
)
precondition(dynamicHealth["last_send_at"] is NSNull)
precondition(dynamicHealth["scheduled_send_count"] as? Int == 0)
precondition(dynamicHealth["next_scheduled_at"] is NSNull)
precondition(dynamicHealth["send_destination"] as? String == "direct")
UserDefaults.standard.set(999, forKey: AppSettings.sendSizeLimitMegabytesKey)
precondition(AppSettings.sendSizeLimit == .megabytes200)

let sendTimingSettingKeys = [
    AppSettings.sendDefaultBehaviorKey,
    AppSettings.sendDefaultDelaySecondsKey
]
let previousSendTimingSettings = Dictionary(
    uniqueKeysWithValues: sendTimingSettingKeys.map {
        ($0, UserDefaults.standard.object(forKey: $0))
    }
)
defer {
    for key in sendTimingSettingKeys {
        if let value = previousSendTimingSettings[key] {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
for key in sendTimingSettingKeys {
    UserDefaults.standard.removeObject(forKey: key)
}
precondition(AppSettings.sendDefaultBehavior == .immediate)
precondition(AppSettings.sendDefaultDelaySeconds == 60)
precondition(SendDefaultBehavior.allCases.map(\.title) == ["立即发送", "每次询问", "固定延时"])
precondition(ScheduledSendPreset.allCases.map(\.rawValue) == [10, 15, 30, 60, 120, 180, 300, 600])
precondition(ScheduledSendPreset.tenMinutes.title == "10 分钟后")
precondition(ScheduledSendDelay.seconds(customMinutes: 1) == 60)
precondition(ScheduledSendDelay.seconds(customMinutes: 10_080) == 604_800)
precondition(ScheduledSendDelay.seconds(customMinutes: 0) == nil)
precondition(ScheduledSendDelay.compactTitle(seconds: 180) == "3 分钟")
precondition(ScheduledSendDelay.compactTitle(seconds: 660) == "11 分钟")
UserDefaults.standard.set(
    SendDefaultBehavior.askEveryTime.rawValue,
    forKey: AppSettings.sendDefaultBehaviorKey
)
UserDefaults.standard.set(15, forKey: AppSettings.sendDefaultDelaySecondsKey)
precondition(AppSettings.sendDefaultBehavior == .askEveryTime)
precondition(AppSettings.sendDefaultDelaySeconds == 15)
UserDefaults.standard.set("invalid", forKey: AppSettings.sendDefaultBehaviorKey)
UserDefaults.standard.set(0, forKey: AppSettings.sendDefaultDelaySecondsKey)
precondition(AppSettings.sendDefaultBehavior == .immediate)
precondition(AppSettings.sendDefaultDelaySeconds == 60)

let previousAppUpdateChannel = UserDefaults.standard.object(forKey: AppSettings.appUpdateChannelKey)
defer {
    if let previousAppUpdateChannel {
        UserDefaults.standard.set(previousAppUpdateChannel, forKey: AppSettings.appUpdateChannelKey)
    } else {
        UserDefaults.standard.removeObject(forKey: AppSettings.appUpdateChannelKey)
    }
}
UserDefaults.standard.removeObject(forKey: AppSettings.appUpdateChannelKey)
precondition(AppSettings.appUpdateChannel(default: .stable) == .stable)
precondition(AppSettings.appUpdateChannel(default: .beta) == .beta)
UserDefaults.standard.set(AppUpdateChannel.beta.rawValue, forKey: AppSettings.appUpdateChannelKey)
precondition(AppSettings.appUpdateChannel(default: .stable) == .beta)

let shelfSettingKeys: [String] = [
    AppSettings.shelfEnabledKey,
    AppSettings.shelfShakeToOpenEnabledKey,
    AppSettings.shelfShakeSensitivityKey,
    AppSettings.shelfGlobalShortcutEnabledKey,
    AppSettings.shelfGlobalShortcutKeyCodeKey,
    AppSettings.shelfGlobalShortcutModifiersKey,
    AppSettings.shelfGlobalShortcutLabelKey,
    AppSettings.shelfAlwaysOnTopKey,
    AppSettings.shelfKeepItemsOnCloseKey,
    AppSettings.shelfRestoreOnLaunchKey,
    AppSettings.shelfClearAfterSendKey,
    AppSettings.shelfStoredItemsKey,
    AppSettings.shelfWindowOriginKey,
    AppSettings.fileBasketArchiveKey
]
let previousShelfSettings = Dictionary(
    uniqueKeysWithValues: shelfSettingKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
)
defer {
    for key in shelfSettingKeys {
        if let value = previousShelfSettings[key] {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
for key in shelfSettingKeys {
    UserDefaults.standard.removeObject(forKey: key)
}
precondition(AppSettings.shelfEnabled)
precondition(AppSettings.shelfShakeToOpenEnabled)
precondition(AppSettings.shelfShakeSensitivity == .medium)
precondition(AppSettings.shelfShakeSensitivity.title == "中")
precondition(AppSettings.shelfGlobalShortcutEnabled)
precondition(AppSettings.shelfGlobalShortcut == .default)
precondition(ShelfGlobalShortcut.default.displayText == "⌥⌘S")
precondition(ShelfGlobalShortcut(keyCode: 1, modifiers: 0, keyLabel: "S") == nil)
let customShelfShortcut = ShelfGlobalShortcut(
    keyCode: 40,
    modifiers: ShelfGlobalShortcut.default.modifiers,
    keyLabel: "K"
)!
UserDefaults.standard.set(Int(customShelfShortcut.keyCode), forKey: AppSettings.shelfGlobalShortcutKeyCodeKey)
UserDefaults.standard.set(Int(customShelfShortcut.modifiers), forKey: AppSettings.shelfGlobalShortcutModifiersKey)
UserDefaults.standard.set(customShelfShortcut.keyLabel, forKey: AppSettings.shelfGlobalShortcutLabelKey)
precondition(AppSettings.shelfGlobalShortcut == customShelfShortcut)
precondition(AppSettings.shelfGlobalShortcut.displayText == "⌥⌘K")
let customShortcutEvent = NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: [.command, .option],
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    characters: "k",
    charactersIgnoringModifiers: "k",
    isARepeat: false,
    keyCode: 40
)!
precondition(ShelfGlobalShortcut(event: customShortcutEvent) == customShelfShortcut)
let invalidShortcutEvent = NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: [.shift],
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    characters: "k",
    charactersIgnoringModifiers: "k",
    isARepeat: false,
    keyCode: 40
)!
precondition(ShelfGlobalShortcut(event: invalidShortcutEvent) == nil)
precondition(AppSettings.shelfAlwaysOnTop)
precondition(AppSettings.shelfKeepItemsOnClose)
precondition(!AppSettings.shelfRestoreOnLaunch)
precondition(AppSettings.shelfClearAfterSend)
UserDefaults.standard.set(ShelfShakeSensitivity.high.rawValue, forKey: AppSettings.shelfShakeSensitivityKey)
precondition(AppSettings.shelfShakeSensitivity == .high)
UserDefaults.standard.set("invalid", forKey: AppSettings.shelfShakeSensitivityKey)
precondition(AppSettings.shelfShakeSensitivity == .medium)

var shakeDetector = DragShakeDetector(sensitivity: .medium)
precondition(!shakeDetector.observe(point: CGPoint(x: 0, y: 0), at: 0))
precondition(!shakeDetector.observe(point: CGPoint(x: 60, y: 0), at: 0.1))
precondition(!shakeDetector.observe(point: CGPoint(x: 0, y: 0), at: 0.2))
precondition(!shakeDetector.observe(point: CGPoint(x: 60, y: 0), at: 0.3))
precondition(shakeDetector.observe(point: CGPoint(x: 0, y: 0), at: 0.4))
precondition(!shakeDetector.observe(point: CGPoint(x: 60, y: 0), at: 0.5))
shakeDetector.reset()
precondition(!shakeDetector.observe(point: CGPoint(x: 0, y: 0), at: 2))
precondition(!shakeDetector.observe(point: CGPoint(x: 0, y: 80), at: 2.1))
precondition(!shakeDetector.observe(point: CGPoint(x: 0, y: 0), at: 2.2))

var shakeSession = DragShakeSession(sensitivity: .medium)
precondition(!shakeSession.observe(point: CGPoint(x: 0, y: 0), at: 3, containsFiles: true))
precondition(!shakeSession.observe(point: CGPoint(x: 60, y: 0), at: 3.1, containsFiles: true))
precondition(!shakeSession.observe(point: CGPoint(x: 0, y: 0), at: 3.2, containsFiles: true))
precondition(!shakeSession.observe(point: CGPoint(x: 60, y: 0), at: 3.3, containsFiles: true))
precondition(shakeSession.observe(point: CGPoint(x: 0, y: 0), at: 3.4, containsFiles: true))
precondition(!shakeSession.observe(point: CGPoint(x: 60, y: 0), at: 3.5, containsFiles: true))
precondition(shakeSession.endDrag())
precondition(!shakeSession.endDrag())
precondition(!shakeSession.observe(point: CGPoint(x: 0, y: 0), at: 5, containsFiles: true))
precondition(!shakeSession.observe(point: CGPoint(x: 60, y: 0), at: 5.1, containsFiles: true))
precondition(!shakeSession.observe(point: CGPoint(x: 0, y: 0), at: 5.2, containsFiles: true))
precondition(!shakeSession.observe(point: CGPoint(x: 60, y: 0), at: 5.3, containsFiles: true))
precondition(shakeSession.observe(point: CGPoint(x: 0, y: 0), at: 5.4, containsFiles: true))
precondition(!shakeSession.observe(point: CGPoint(x: 60, y: 0), at: 5.5, containsFiles: false))
precondition(!shakeSession.observe(point: CGPoint(x: 0, y: 0), at: 5.6, containsFiles: true))
precondition(!shakeSession.observe(point: CGPoint(x: 60, y: 0), at: 5.7, containsFiles: true))
precondition(shakeSession.endDrag())

var fileDragPasteboardSession = FileDragPasteboardSession()
precondition(!fileDragPasteboardSession.containsCurrentFiles(changeCount: 10, containsFiles: true))
fileDragPasteboardSession.begin(changeCount: 10)
precondition(!fileDragPasteboardSession.containsCurrentFiles(changeCount: 10, containsFiles: true))
precondition(!fileDragPasteboardSession.containsCurrentFiles(changeCount: 11, containsFiles: false))
precondition(fileDragPasteboardSession.containsCurrentFiles(changeCount: 11, containsFiles: true))
precondition(fileDragPasteboardSession.containsCurrentFiles(changeCount: 11, containsFiles: false))
fileDragPasteboardSession.reset()
precondition(!fileDragPasteboardSession.containsCurrentFiles(changeCount: 11, containsFiles: true))

precondition(FileBasketCloseAction.resolve(isEmpty: true, keepItemsOnClose: true) == .delete)
precondition(FileBasketCloseAction.resolve(isEmpty: true, keepItemsOnClose: false) == .delete)
precondition(FileBasketCloseAction.resolve(isEmpty: false, keepItemsOnClose: false) == .delete)
precondition(FileBasketCloseAction.resolve(isEmpty: false, keepItemsOnClose: true) == .hide)

let marqueeFirstID = UUID()
let marqueeSecondID = UUID()
let marqueeThirdID = UUID()
let marqueeFrames = [
    marqueeFirstID: CGRect(x: 10, y: 10, width: 100, height: 36),
    marqueeSecondID: CGRect(x: 10, y: 50, width: 100, height: 36),
    marqueeThirdID: CGRect(x: 10, y: 90, width: 100, height: 36),
]
precondition(
    ShelfMarqueeSelection.intersectingItemIDs(
        in: CGRect(x: 0, y: 30, width: 120, height: 45),
        itemFrames: marqueeFrames
    ) == [marqueeFirstID, marqueeSecondID]
)
precondition(
    ShelfMarqueeSelection.intersectingItemIDs(
        in: CGRect(x: 130, y: 0, width: 20, height: 140),
        itemFrames: marqueeFrames
    ).isEmpty
)

MainActor.assumeIsolated {
    let first = ShelfItem(path: "/tmp/shelf-first")
    let second = ShelfItem(path: "/tmp/shelf-second")
    let third = ShelfItem(path: "/tmp/shelf-third")
    let items = [first, second, third]
    let session = ShelfSessionState(isCollapsed: true, isAlwaysOnTop: true)

    precondition(session.isCollapsed)
    precondition(session.isAlwaysOnTop)
    precondition(session.displayMode == .grid)
    session.displayMode = .list
    precondition(session.displayMode == .list)
    session.displayMode = .grid
    session.ensureSelection(in: items)
    precondition(session.selectedItemID == first.id)
    session.moveSelection(by: 1, in: items)
    precondition(session.selectedItemID == second.id)
    session.moveSelection(by: 10, in: items)
    precondition(session.selectedItemID == third.id)
    session.moveSelection(by: -10, in: items)
    precondition(session.selectedItemID == first.id)

    session.select(UUID())
    precondition(session.selectedItem(in: items) == nil)
    session.ensureSelection(in: items)
    precondition(session.selectedItemID == first.id)
    session.ensureSelection(in: [])
    precondition(session.selectedItemID == nil)

    session.select(second.id)
    session.selectAll(in: items)
    precondition(session.selectedItemID == second.id)
    precondition(session.selectedItemIDs == Set(items.map(\.id)))
    precondition(session.selectedItems(in: items).map(\.id) == items.map(\.id))
    precondition(session.dragItems(startingAt: third.id, in: items).map(\.id) == items.map(\.id))

    let fourth = ShelfItem(path: "/tmp/shelf-fourth")
    let expandedItems = items + [fourth]
    session.select(first.id)
    session.moveSelection(by: 3, in: expandedItems)
    precondition(session.selectedItemID == fourth.id)
    session.moveSelection(by: -3, in: expandedItems)
    precondition(session.selectedItemID == first.id)
    precondition(session.dragItems(startingAt: fourth.id, in: expandedItems).map(\.id) == [fourth.id])
    precondition(session.selectedItemIDs == [fourth.id])
    session.select(fourth.id, in: expandedItems, extending: false, toggling: true)
    precondition(session.selectedItemIDs.isEmpty)
    precondition(session.selectedItem(in: expandedItems) == nil)

    session.setSelection([second.id, third.id, UUID()], in: items)
    precondition(session.selectedItems(in: items).map(\.id) == [second.id, third.id])
    precondition(session.selectedItemID == second.id)

    session.select(first.id)
    session.select(third.id, in: items, extending: true, toggling: false)
    precondition(session.selectedItems(in: items).map(\.id) == items.map(\.id))
    session.select(second.id, in: items, extending: false, toggling: true)
    precondition(session.selectedItems(in: items).map(\.id) == [first.id, third.id])

    session.select(third.id)
    session.select(first.id, in: items, extending: true, toggling: false)
    precondition(session.selectedItems(in: items).map(\.id) == items.map(\.id))

    session.ensureSelection(in: [first, second])
    precondition(session.selectedItemIDs == [first.id, second.id])
    precondition(session.selectedItemID == first.id)
    session.selectAll(in: items)
    session.moveSelection(by: 1, in: items)
    precondition(session.selectedItemIDs == [second.id])
    precondition(session.selectedItemID == second.id)
    let removalGeneration = session.removalRequestGeneration
    session.requestSelectedItemRemoval()
    precondition(session.removalRequestGeneration == removalGeneration + 1)

    session.setSelection([first.id, third.id], in: items)
    precondition(session.enterReader(itemID: second.id, in: items))
    precondition(session.presentationMode == .reader)
    precondition(session.focusedItem(in: items)?.id == second.id)
    session.completePresentationTransition()
    precondition(session.enterReader(itemID: third.id, in: items))
    precondition(session.isPresentationReady)
    precondition(session.moveFocus(by: 1, in: items)?.id == third.id)
    precondition(session.requestTextEditing(itemID: third.id, in: items))
    precondition(session.requestedTextEditorItemID == third.id)
    session.consumeTextEditingRequest(for: third.id)
    precondition(session.requestedTextEditorItemID == nil)
    precondition(session.enterReminder(itemID: third.id, in: items))
    precondition(session.presentationMode == .reminder)
    session.returnToCollection(in: items)
    precondition(session.presentationMode == .collection)
    precondition(session.focusedItemID == nil)
    precondition(session.selectedItemIDs == [first.id, third.id])
    session.markPendingRemoval(urls: [first.url, third.url])
    precondition(session.consumePendingRemovalURLs() == [first.url, third.url])
    precondition(session.consumePendingRemovalURLs().isEmpty)

    precondition(ShelfKeyModifiers.significant(.capsLock).isEmpty)
    precondition(ShelfKeyModifiers.significant(.function).isEmpty)
    precondition(ShelfKeyModifiers.significant([.capsLock, .numericPad, .help, .function]).isEmpty)
    precondition(ShelfKeyModifiers.significant([.command, .capsLock]) == .command)
    precondition(ShelfKeyModifiers.significant([.shift, .function]) == .shift)
    precondition(!ShelfKeyModifiers.significant(.option).isEmpty)
}

let shelfFile = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-shelf-\(UUID()).txt")
let shelfDirectory = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-shelf-dir-\(UUID())", directoryHint: .isDirectory)
let shelfPackage = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-shelf-package-\(UUID()).app", directoryHint: .isDirectory)
let shelfSymlink = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-shelf-link-\(UUID()).txt")
try Data("shelf-file".utf8).write(to: shelfFile)
try FileManager.default.createDirectory(at: shelfDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: shelfPackage, withIntermediateDirectories: true)
try FileManager.default.createSymbolicLink(at: shelfSymlink, withDestinationURL: shelfFile)
defer {
    try? FileManager.default.removeItem(at: shelfFile)
    try? FileManager.default.removeItem(at: shelfDirectory)
    try? FileManager.default.removeItem(at: shelfPackage)
    try? FileManager.default.removeItem(at: shelfSymlink)
}
try MainActor.assumeIsolated {
    let shelfModel = ShelfModel(title: "文件篮测试")
    precondition(shelfModel.title == "文件篮测试")
    precondition(shelfModel.color == .graphite)
    precondition(shelfModel.backgroundOpacity == 0.9)
    precondition(shelfModel.rename(to: "  客户交付  "))
    precondition(shelfModel.title == "客户交付")
    precondition(!shelfModel.rename(to: "  "))
    precondition(shelfModel.title == "客户交付")
    shelfModel.setAppearance(color: .blue, backgroundOpacity: 0.2)
    precondition(shelfModel.color == .blue)
    precondition(shelfModel.backgroundOpacity == 0.55)
    precondition(shelfModel.add(urls: [shelfFile, shelfDirectory, shelfPackage, shelfSymlink]) == 3)
    precondition(shelfModel.add(urls: [shelfFile, shelfDirectory, shelfPackage]) == 0)
    precondition(shelfModel.items.count == 3)
    precondition(
        shelfModel.urls
            == [
                shelfFile.standardizedFileURL,
                shelfDirectory.standardizedFileURL,
                shelfPackage.standardizedFileURL,
            ]
    )
    precondition(shelfModel.items[0].fileName == shelfFile.lastPathComponent)
    precondition(shelfModel.items[0].kind == .file)
    precondition(shelfModel.items[1].kind == .folder)
    precondition(shelfModel.items[1].isDirectory)
    precondition(shelfModel.items[2].kind == .package)
    precondition(shelfModel.items[2].isDirectory)
    shelfModel.remove(ids: Set(shelfModel.items.prefix(2).map(\.id)))
    precondition(shelfModel.items.map(\.url) == [shelfPackage.standardizedFileURL])
    shelfModel.remove(id: shelfModel.items[0].id)
    precondition(shelfModel.items.isEmpty)
    precondition(shelfModel.add(urls: [shelfFile]) == 1)
    let undoSnapshot = shelfModel.items
    shelfModel.clear()
    precondition(shelfModel.items.isEmpty)
    precondition(shelfModel.add(urls: [shelfDirectory]) == 1)
    shelfModel.restore(items: undoSnapshot, at: [0])
    precondition(shelfModel.items.map(\.url) == [
        shelfFile.standardizedFileURL,
        shelfDirectory.standardizedFileURL,
    ])

    UserDefaults.standard.set(false, forKey: AppSettings.shelfRestoreOnLaunchKey)
    let store = FileBasketStore()
    let firstBasket = store.createBasket()
    let secondBasket = store.createBasket()
    precondition(firstBasket.title == "文件篮 1")
    precondition(secondBasket.title == "文件篮 2")
    precondition(firstBasket.add(urls: [shelfFile]) == 1)
    precondition(firstBasket.rename(to: "交付文件"))
    firstBasket.setAppearance(color: .purple, backgroundOpacity: 0.7)
    precondition(secondBasket.items.isEmpty)
    precondition(store.totalItemCount == 1)
    precondition(store.recentBasketID == secondBasket.id)
    store.markRecent(id: firstBasket.id)
    precondition(store.recentBasketID == firstBasket.id)

    let firstState = FileBasketWindowState(
        origin: "{120, 240}",
        isCollapsed: true,
        isAlwaysOnTop: false
    )
    store.updateWindowState(firstState, for: firstBasket.id)
    precondition(store.windowState(for: firstBasket.id) == firstState)
    precondition(store.windowState(for: secondBasket.id).isAlwaysOnTop)
    precondition(UserDefaults.standard.data(forKey: AppSettings.fileBasketArchiveKey) == nil)

    store.setRestoresItemsOnLaunch(true)
    precondition(AppSettings.shelfRestoreOnLaunch)
    precondition(UserDefaults.standard.data(forKey: AppSettings.fileBasketArchiveKey) != nil)

    let archiveBeforeWindowMove = UserDefaults.standard.data(forKey: AppSettings.fileBasketArchiveKey)
    let movedState = FileBasketWindowState(
        origin: "{180, 300}",
        isCollapsed: false,
        isAlwaysOnTop: true,
        readerWidth: 680,
        readerHeight: 760,
        reminderWidth: 460,
        reminderHeight: 260,
        reminderItemID: firstBasket.items.first?.id
    )
    store.updateWindowState(movedState, for: firstBasket.id)
    precondition(UserDefaults.standard.data(forKey: AppSettings.fileBasketArchiveKey) == archiveBeforeWindowMove)
    store.flushPendingPersistence()

    let restoredStore = FileBasketStore()
    precondition(restoredStore.baskets.count == 2)
    precondition(restoredStore.baskets[0].title == "交付文件")
    precondition(restoredStore.baskets[0].color == .purple)
    precondition(restoredStore.baskets[0].backgroundOpacity == 0.7)
    precondition(restoredStore.baskets[0].items.map(\.path) == [shelfFile.standardizedFileURL.path])
    precondition(restoredStore.windowState(for: firstBasket.id) == movedState)
    precondition(restoredStore.recentBasketID == firstBasket.id)
    restoredStore.removeBasket(id: firstBasket.id)
    precondition(restoredStore.baskets.map(\.title) == ["文件篮 2"])
    precondition(restoredStore.recentBasketID == secondBasket.id)
    precondition(restoredStore.createBasket().title == "文件篮 1")

    restoredStore.setRestoresItemsOnLaunch(false)
    precondition(!AppSettings.shelfRestoreOnLaunch)
    precondition(UserDefaults.standard.data(forKey: AppSettings.fileBasketArchiveKey) == nil)

    UserDefaults.standard.removeObject(forKey: AppSettings.fileBasketArchiveKey)
    UserDefaults.standard.set(true, forKey: AppSettings.shelfRestoreOnLaunchKey)
    let legacyItems = [ShelfItem(path: shelfFile.path)]
    UserDefaults.standard.set(
        try JSONEncoder().encode(legacyItems),
        forKey: AppSettings.shelfStoredItemsKey
    )
    UserDefaults.standard.set("{40, 80}", forKey: AppSettings.shelfWindowOriginKey)
    let migratedStore = FileBasketStore()
    precondition(migratedStore.baskets.count == 1)
    precondition(migratedStore.baskets[0].title == "文件篮 1")
    precondition(migratedStore.baskets[0].items.map(\.path) == [shelfFile.standardizedFileURL.path])
    precondition(migratedStore.windowState(for: migratedStore.baskets[0].id).origin == "{40, 80}")
    precondition(UserDefaults.standard.data(forKey: AppSettings.shelfStoredItemsKey) == nil)
    precondition(UserDefaults.standard.string(forKey: AppSettings.shelfWindowOriginKey) == nil)

    let customDefaultsName = "WeClawSend.FileBasketStore.\(UUID())"
    guard let customDefaults = UserDefaults(suiteName: customDefaultsName) else {
        preconditionFailure("无法创建测试 UserDefaults")
    }
    customDefaults.removePersistentDomain(forName: customDefaultsName)
    customDefaults.set(false, forKey: AppSettings.shelfAlwaysOnTopKey)
    let customStore = FileBasketStore(defaults: customDefaults)
    let customBasket = customStore.createBasket()
    precondition(!customStore.windowState(for: customBasket.id).isAlwaysOnTop)
    customDefaults.removePersistentDomain(forName: customDefaultsName)

    let legacyArchiveDefaultsName = "WeClawSend.FileBasketArchive.Legacy.\(UUID())"
    guard let legacyArchiveDefaults = UserDefaults(suiteName: legacyArchiveDefaultsName) else {
        preconditionFailure("无法创建旧版文件篮测试 UserDefaults")
    }
    legacyArchiveDefaults.removePersistentDomain(forName: legacyArchiveDefaultsName)
    let legacyArchiveBasketID = UUID()
    let legacyArchiveItemID = UUID()
    let legacyArchiveData = try JSONSerialization.data(withJSONObject: [
        "baskets": [[
            "id": legacyArchiveBasketID.uuidString,
            "title": "旧版文件篮",
            "items": [[
                "id": legacyArchiveItemID.uuidString,
                "path": shelfFile.standardizedFileURL.path,
            ]],
            "windowState": [
                "isCollapsed": false,
                "isAlwaysOnTop": true,
            ],
        ]],
        "recentBasketID": legacyArchiveBasketID.uuidString,
    ])
    legacyArchiveDefaults.set(true, forKey: AppSettings.shelfRestoreOnLaunchKey)
    legacyArchiveDefaults.set(legacyArchiveData, forKey: AppSettings.fileBasketArchiveKey)
    let legacyArchiveStore = FileBasketStore(defaults: legacyArchiveDefaults)
    precondition(legacyArchiveStore.baskets.count == 1)
    precondition(legacyArchiveStore.baskets[0].color == .graphite)
    precondition(legacyArchiveStore.baskets[0].backgroundOpacity == 0.9)
    legacyArchiveDefaults.removePersistentDomain(forName: legacyArchiveDefaultsName)

    try FileManager.default.removeItem(at: shelfFile)
    precondition(migratedStore.baskets[0].removeUnavailableItems() == 1)
    precondition(migratedStore.baskets[0].items.isEmpty)
    let filteredStore = FileBasketStore()
    precondition(filteredStore.baskets[0].items.isEmpty)
}

let textClipDirectory = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-text-clips-\(UUID())", directoryHint: .isDirectory)
let textClipStore = BasketTextClipStore(directory: textClipDirectory)
defer { try? FileManager.default.removeItem(at: textClipDirectory) }
let textClipURL = try textClipStore.create(
    text: "第一行提醒\n第二行内容",
    preferredTitle: "提醒/客户:反馈",
    now: Date(timeIntervalSince1970: 0)
)
precondition(textClipStore.isManaged(textClipURL))
precondition(!textClipURL.lastPathComponent.contains("/"))
precondition(!textClipURL.lastPathComponent.contains(":"))
let originalTextClip = try textClipStore.readText(at: textClipURL)
precondition(originalTextClip == "第一行提醒\n第二行内容")
precondition(textClipStore.readPreview(at: textClipURL, maxCharacters: 4) == "第一行提")
try textClipStore.update(text: "更新后的便笺", at: textClipURL)
let updatedTextClip = try textClipStore.readText(at: textClipURL)
precondition(updatedTextClip == "更新后的便笺")
let outsideTextClipURL = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-outside-text-\(UUID()).txt")
try Data("外部文本".utf8).write(to: outsideTextClipURL)
defer { try? FileManager.default.removeItem(at: outsideTextClipURL) }
precondition(!textClipStore.isManaged(outsideTextClipURL))
let deletedOutsideTextClip = try textClipStore.deleteIfManaged(outsideTextClipURL)
precondition(!deletedOutsideTextClip)
do {
    _ = try textClipStore.create(text: "")
    preconditionFailure("empty text clip must fail")
} catch BasketTextClipStoreError.emptyText {
    // Expected.
}
do {
    _ = try textClipStore.create(text: String(repeating: "a", count: BasketTextClipStore.maximumTextBytes + 1))
    preconditionFailure("oversized text clip must fail")
} catch BasketTextClipStoreError.textTooLarge {
    // Expected.
}
precondition(BasketReaderRouter.route(for: textClipURL, isManagedText: true) == .reader(.managedText))
precondition(BasketReaderRouter.route(for: outsideTextClipURL) == .reader(.externalText))
precondition(BasketReaderRouter.route(for: shelfDirectory) == .reader(.fileInfo))
let mediaReaderURL = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-media-reader-\(UUID()).mp4")
try Data([0]).write(to: mediaReaderURL)
defer { try? FileManager.default.removeItem(at: mediaReaderURL) }
precondition(BasketReaderRouter.route(for: mediaReaderURL) == .reader(.media))
let audioReaderURL = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-audio-reader-\(UUID()).mp3")
try Data([0]).write(to: audioReaderURL)
defer { try? FileManager.default.removeItem(at: audioReaderURL) }
precondition(BasketReaderRouter.route(for: audioReaderURL) == .reader(.media))
precondition(BasketReaderRouter.isMediaFile(mediaReaderURL))
precondition(BasketReaderRouter.isMediaFile(audioReaderURL))
precondition(BasketReaderRouter.isAudioFile(audioReaderURL))
precondition(!BasketReaderRouter.isAudioFile(mediaReaderURL))
let missingReaderURL = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-missing-reader-\(UUID()).txt")
precondition(BasketReaderRouter.route(for: missingReaderURL) == .failure(.missingPath))
precondition(
    ReaderWindowSizing.resolvedSize(
        for: ShelfPresentationMode.reader,
        visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
    ) == CGSize(width: 640, height: 720)
)
precondition(
    ReaderWindowSizing.resolvedSize(
        for: ShelfPresentationMode.reader,
        storedWidth: .nan,
        storedHeight: 700,
        visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
    ) == CGSize(width: 640, height: 720)
)
precondition(
    ReaderWindowSizing.resolvedSize(
        for: ShelfPresentationMode.reminder,
        storedSize: CGSize(width: 1_000, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 700)
    ) == CGSize(width: 760, height: 500)
)
precondition(
    ReaderWindowSizing.resolvedSize(
        for: ShelfWindowSizingMode.audio,
        visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
    ) == ReaderWindowSizing.audioPreferredSize
)
let deletedTextClip = try textClipStore.deleteIfManaged(textClipURL)
precondition(deletedTextClip)
precondition(!FileManager.default.fileExists(atPath: textClipURL.path))

let checklist = "准备素材\n联络客户\n\n结尾"
precondition(
    BasketTextFormatting.makeChecklist(checklist)
        == "- [ ] 准备素材\n- [ ] 联络客户\n\n- [ ] 结尾"
)
let completedChecklist = BasketTextFormatting.toggleTodo(
    "- [ ] 准备素材\n- [ ] 联络客户\n说明\n- [ ] 单独项目",
    lineIndex: 0
)
precondition(completedChecklist == "- [ ] 联络客户\n- [x] 准备素材\n说明\n- [ ] 单独项目")
precondition(BasketTextFormatting.makeNumbered("甲\n\n乙") == "1. 甲\n\n2. 乙")

let trailingNewlineLines = BasketTextFormatting.parsedLines("- [ ] 准备素材\n- [ ] 联络客户\n")
precondition(trailingNewlineLines.count == 2)
precondition(trailingNewlineLines[0].isChecked == false)
precondition(trailingNewlineLines[1].body == "联络客户")
precondition(BasketTextFormatting.parsedLines("\n").count == 1)
precondition(BasketTextFormatting.parseLine("  - [ ] 缩进") == .unchecked)
precondition(BasketTextFormatting.parseLine("- [ ]无空格") == .plain)
precondition(BasketTextFormatting.parsedLines("  - [x] 完成")[0].isChecked == true)
precondition(BasketTextFormatting.parsedLines("- [ ] 甲\r\n- [ ] 乙").count == 2)
precondition(
    BasketTextFormatting.toggleTodo("- [ ] 甲\r\n- [ ] 乙", lineIndex: 0)
        == "- [ ] 乙\r\n- [x] 甲"
)
precondition(
    BasketTextFormatting.toggleTodo("- [ ] 准备素材\n- [ ] 联络客户\n", lineIndex: 1)
        == "- [ ] 准备素材\n- [x] 联络客户\n"
)
precondition(
    BasketTextFormatting.sortChecklist("- [x] 完成\n- [ ] 未完成\n说明")
        == "- [ ] 未完成\n- [x] 完成\n说明"
)

let imageClipDirectory = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-image-clips-\(UUID())", directoryHint: .isDirectory)
let imageClipStore = BasketImageClipStore(directory: imageClipDirectory)
defer { try? FileManager.default.removeItem(at: imageClipDirectory) }
let imageRep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 2,
    pixelsHigh: 2,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
let basketImage = NSImage(size: NSSize(width: 2, height: 2))
basketImage.addRepresentation(imageRep)
let imageClipURL = try imageClipStore.create(image: basketImage, preferredTitle: "截图/重点")
precondition(imageClipStore.isManaged(imageClipURL))
precondition(imageClipURL.pathExtension == "png")
precondition(FileManager.default.fileExists(atPath: imageClipURL.path))
let deletedImageClip = try imageClipStore.deleteIfManaged(imageClipURL)
precondition(deletedImageClip)

let sharedClipRoot = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-shared-clips-\(UUID())", directoryHint: .isDirectory)
let nestedTextStore = BasketTextClipStore(directory: sharedClipRoot)
let nestedImageStore = BasketImageClipStore(
    directory: sharedClipRoot.appending(path: "Images", directoryHint: .isDirectory)
)
defer { try? FileManager.default.removeItem(at: sharedClipRoot) }
let nestedTextURL = try nestedTextStore.create(text: "共享目录便笺")
let nestedImageURL = try nestedImageStore.create(image: basketImage, preferredTitle: "截图")
precondition(nestedTextStore.isManaged(nestedTextURL))
precondition(!nestedTextStore.isManaged(nestedImageURL))
precondition(nestedImageStore.isManaged(nestedImageURL))
precondition(!nestedImageStore.isManaged(nestedTextURL))
precondition(
    BasketReaderRouter.route(
        for: nestedImageURL,
        isManagedText: nestedTextStore.isManaged(nestedImageURL)
    ) == .reader(.image)
)

let archiveInputDirectory = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-archive-input-\(UUID())", directoryHint: .isDirectory)
let firstArchiveDirectory = archiveInputDirectory.appending(path: "first", directoryHint: .isDirectory)
let secondArchiveDirectory = archiveInputDirectory.appending(path: "second", directoryHint: .isDirectory)
let firstArchiveFile = firstArchiveDirectory.appending(path: "clip.txt")
let secondArchiveFile = secondArchiveDirectory.appending(path: "clip.txt")
try FileManager.default.createDirectory(at: firstArchiveDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: secondArchiveDirectory, withIntermediateDirectories: true)
try Data("first".utf8).write(to: firstArchiveFile)
try Data("second".utf8).write(to: secondArchiveFile)
defer { try? FileManager.default.removeItem(at: archiveInputDirectory) }

let fileBasketArchive = try FileBasketArchiver.createArchive(
    urls: [firstArchiveFile, secondArchiveFile, firstArchiveDirectory],
    archiveName: "我的文件"
)
precondition(fileBasketArchive.fileURL.lastPathComponent == "我的文件.zip")
precondition(FileBasketArchiver.normalizedArchiveName(" 成片.ZIP ") == "成片.ZIP")
precondition(FileBasketArchiver.normalizedArchiveName(".zip") == nil)
precondition(FileBasketArchiver.normalizedArchiveName("错误/名字") == nil)
let zipListProcess = Process()
let zipListOutput = Pipe()
zipListProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
zipListProcess.arguments = ["-Z1", fileBasketArchive.fileURL.path]
zipListProcess.standardOutput = zipListOutput
zipListProcess.standardError = FileHandle.nullDevice
try zipListProcess.run()
zipListProcess.waitUntilExit()
precondition(zipListProcess.terminationStatus == 0)
let zipEntries = String(
    decoding: zipListOutput.fileHandleForReading.readDataToEndOfFile(),
    as: UTF8.self
).split(separator: "\n").map(String.init)
precondition(zipEntries.contains("clip.txt"))
precondition(zipEntries.contains("clip 2.txt"))
precondition(zipEntries.contains("first/"))
precondition(zipEntries.contains("first/clip.txt"))
let archiveWorkDirectory = fileBasketArchive.fileURL.deletingLastPathComponent()
precondition(FileBasketArchiver.cleanup(fileBasketArchive.fileURL))
precondition(!FileManager.default.fileExists(atPath: archiveWorkDirectory.path))
precondition(!FileBasketArchiver.cleanup(firstArchiveFile))

let previousLocalAPISetting = UserDefaults.standard.object(forKey: AppSettings.localAPIEnabledKey)
let previousLocalAPISendBehavior = UserDefaults.standard.object(
    forKey: AppSettings.localAPISendBehaviorKey
)
defer {
    if let previousLocalAPISetting {
        UserDefaults.standard.set(previousLocalAPISetting, forKey: AppSettings.localAPIEnabledKey)
    } else {
        UserDefaults.standard.removeObject(forKey: AppSettings.localAPIEnabledKey)
    }
    if let previousLocalAPISendBehavior {
        UserDefaults.standard.set(previousLocalAPISendBehavior, forKey: AppSettings.localAPISendBehaviorKey)
    } else {
        UserDefaults.standard.removeObject(forKey: AppSettings.localAPISendBehaviorKey)
    }
}
UserDefaults.standard.removeObject(forKey: AppSettings.localAPIEnabledKey)
precondition(!AppSettings.localAPIEnabled)
UserDefaults.standard.set(false, forKey: AppSettings.localAPIEnabledKey)
precondition(!AppSettings.localAPIEnabled)
UserDefaults.standard.set(true, forKey: AppSettings.localAPIEnabledKey)
precondition(AppSettings.localAPIEnabled)
UserDefaults.standard.removeObject(forKey: AppSettings.localAPISendBehaviorKey)
precondition(AppSettings.localAPISendBehavior == .direct)
UserDefaults.standard.set(
    LocalAPISendBehavior.fileBasket.rawValue,
    forKey: AppSettings.localAPISendBehaviorKey
)
precondition(AppSettings.localAPISendBehavior == .fileBasket)

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
    userID: "user@im.wechat",
    contextToken: "initial-context"
)
let oversizedFile = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-oversized-\(UUID()).mov")
FileManager.default.createFile(atPath: oversizedFile.path, contents: nil)
let oversizedHandle = try FileHandle(forWritingTo: oversizedFile)
try oversizedHandle.truncate(atOffset: 101 * 1_024 * 1_024)
try oversizedHandle.close()
defer { try? FileManager.default.removeItem(at: oversizedFile) }
UserDefaults.standard.set(100, forKey: AppSettings.sendSizeLimitMegabytesKey)
let oversizedResult = ResultBox()
let oversizedFinished = DispatchSemaphore(value: 0)
Task {
    do {
        let service = WeChatService(credentials: mockCredentials, session: mockSession)
        let coordinator = SendCoordinator(weChat: service)
        _ = try await coordinator.send(
            SendRequest(filePath: oversizedFile.path, fileName: oversizedFile.lastPathComponent)
        )
    } catch {
        oversizedResult.error = error
    }
    oversizedFinished.signal()
}
precondition(oversizedFinished.wait(timeout: .now() + 5) == .success)
if case let BackendError.rejected(message)? = oversizedResult.error {
    precondition(message.contains(formatBytes(100 * 1_024 * 1_024)))
} else {
    preconditionFailure("configured send size limit must reject an oversized file")
}
UserDefaults.standard.set(999, forKey: AppSettings.sendSizeLimitMegabytesKey)
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
        precondition(message["context_token"] as? String == "initial-context")
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

let retryResult = RetryResultBox()
MockURLProtocol.handler = { request in
    switch request.url!.path {
    case "/ilink/bot/getuploadurl":
        retryResult.uploadURLRequestCount += 1
        if retryResult.uploadURLRequestCount == 1 {
            return MockURLProtocol.response(request, statusCode: 503, body: "temporary")
        }
        return MockURLProtocol.response(
            request,
            body: #"{"ret":0,"upload_full_url":"https://mock.local/upload"}"#
        )
    case "/upload":
        retryResult.uploadRequestCount += 1
        if retryResult.uploadRequestCount == 1 {
            return MockURLProtocol.response(request, statusCode: 500, body: "temporary")
        }
        return MockURLProtocol.response(
            request,
            headers: ["x-encrypted-param": "retry-download-reference"],
            body: ""
        )
    case "/ilink/bot/sendmessage":
        retryResult.sendRequestCount += 1
        let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
        let message = body["msg"] as! [String: Any]
        let clientID = message["client_id"] as! String
        if let previousClientID = retryResult.clientID {
            precondition(clientID == previousClientID)
        } else {
            retryResult.clientID = clientID
        }
        if retryResult.sendRequestCount == 1 {
            return MockURLProtocol.response(request, statusCode: 502, body: "temporary")
        }
        return MockURLProtocol.response(request, body: #"{"ret":0}"#)
    default:
        preconditionFailure("Unexpected retry request: \(request.url!.absoluteString)")
    }
}

let retryFinished = DispatchSemaphore(value: 0)
Task {
    do {
        let service = WeChatService(credentials: mockCredentials, session: mockSession)
        try await service.sendFile(at: mockFile, fileName: mockFileName)
    } catch {
        retryResult.error = error
    }
    retryFinished.signal()
}
precondition(retryFinished.wait(timeout: .now() + 10) == .success)
if let error = retryResult.error { throw error }
precondition(retryResult.uploadURLRequestCount == 2)
precondition(retryResult.uploadRequestCount == 2)
precondition(retryResult.sendRequestCount == 2)
precondition(retryResult.clientID?.hasPrefix("weclaw-send:") == true)

let cancellationResult = CancellationResultBox()
let cancellationFinished = DispatchSemaphore(value: 0)
Task {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CancellableURLProtocol.self]
    let service = WeChatService(
        credentials: mockCredentials,
        session: URLSession(configuration: configuration)
    )
    let coordinator = SendCoordinator(weChat: service)
    let eventTask = Task {
        for await event in coordinator.events {
            switch event {
            case let .started(record):
                precondition(CancellableURLProtocol.uploadStarted.wait(timeout: .now() + 2) == .success)
                cancellationResult.cancelAccepted = await coordinator.cancel(transferID: record.id)
            case let .failed(record):
                cancellationResult.record = record
                return
            case .updated, .completed:
                break
            }
        }
    }
    do {
        _ = try await coordinator.send(
            SendRequest(filePath: mockFile.path, fileName: mockFileName)
        )
        preconditionFailure("cancelled transfer must not complete")
    } catch {
        cancellationResult.error = error
    }
    await eventTask.value
    cancellationFinished.signal()
}
precondition(cancellationFinished.wait(timeout: .now() + 3) == .success)
precondition(cancellationResult.cancelAccepted)
precondition(cancellationResult.error.map(isSendCancellation) == true)
precondition(cancellationResult.record?.status == .failed)
precondition(cancellationResult.record?.message == "发送已取消")

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

let openClawStateDirectory = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-openclaw-\(UUID())", directoryHint: .isDirectory)
let resolvedOpenClawStateDirectory = OpenClawCredentialStore.resolveStateDirectory(
    environment: [
        "OPENCLAW_STATE_DIR": openClawStateDirectory.path,
        "CLAWDBOT_STATE_DIR": "/ignored-legacy-state"
    ],
    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
)
precondition(resolvedOpenClawStateDirectory.standardizedFileURL == openClawStateDirectory.standardizedFileURL)
let resolvedLegacyStateDirectory = OpenClawCredentialStore.resolveStateDirectory(
    environment: ["CLAWDBOT_STATE_DIR": openClawStateDirectory.path],
    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
)
precondition(resolvedLegacyStateDirectory.standardizedFileURL == openClawStateDirectory.standardizedFileURL)
let openClawAccountsDirectory = openClawStateDirectory
    .appending(path: "openclaw-weixin/accounts", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: openClawAccountsDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: openClawStateDirectory) }
let openClawAccountID = "abc123-im-bot"
let openClawIndexURL = openClawStateDirectory.appending(path: "openclaw-weixin/accounts.json")
let openClawAccountURL = openClawAccountsDirectory.appending(path: "\(openClawAccountID).json")
let openClawContextURL = openClawAccountsDirectory
    .appending(path: "\(openClawAccountID).context-tokens.json")
try Data(#"["abc123-im-bot"]"#.utf8).write(to: openClawIndexURL)
let openClawAccountData = Data(
    #"{"token":"openclaw-token","savedAt":"2026-07-20T00:00:00.000Z","baseUrl":"https://mock.local","userId":"openclaw-user@im.wechat"}"#.utf8
)
try openClawAccountData.write(to: openClawAccountURL)
try Data(#"{"openclaw-user@im.wechat":"stale-openclaw-context"}"#.utf8)
    .write(to: openClawContextURL)

let openClawStore = OpenClawCredentialStore(stateDirectory: openClawStateDirectory)
let openClawAccounts = try openClawStore.accounts()
precondition(openClawAccounts == [OpenClawAccount(id: openClawAccountID, userID: "openclaw-user@im.wechat")])
let openClawCredentials = try openClawStore.load(accountID: nil)
precondition(openClawCredentials.botToken == "openclaw-token")
precondition(openClawCredentials.botID == "abc123@im.bot")
precondition(openClawCredentials.contextToken == "stale-openclaw-context")
let loadedOpenClawAccountData = try Data(contentsOf: openClawAccountURL)
precondition(loadedOpenClawAccountData == openClawAccountData)

let legacyOpenClawAccountURL = openClawAccountsDirectory.appending(path: "abc123@im.bot.json")
try FileManager.default.removeItem(at: openClawAccountURL)
try Data(#"{"token":"legacy-openclaw-token","userId":"openclaw-user@im.wechat"}"#.utf8)
    .write(to: legacyOpenClawAccountURL)
let legacyOpenClawCredentials = try openClawStore.load(accountID: openClawAccountID)
precondition(legacyOpenClawCredentials.botToken == "legacy-openclaw-token")
precondition(legacyOpenClawCredentials.baseURL.absoluteString == "https://ilinkai.weixin.qq.com")
try FileManager.default.removeItem(at: legacyOpenClawAccountURL)
try openClawAccountData.write(to: openClawAccountURL)

try Data(#"["abc123-im-bot","second-im-bot"]"#.utf8).write(to: openClawIndexURL)
do {
    _ = try openClawStore.load(accountID: nil)
    preconditionFailure("multiple OpenClaw accounts must require an explicit selection")
} catch OpenClawCredentialsError.accountSelectionRequired {
    // Expected.
}
try Data(#"["abc123-im-bot"]"#.utf8).write(to: openClawIndexURL)

let openClawRefreshResult = ContextRefreshResultBox()
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
            headers: ["x-encrypted-param": "openclaw-download-reference"],
            body: ""
        )
    case "/ilink/bot/sendmessage":
        openClawRefreshResult.sendCount += 1
        let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
        let message = body["msg"] as! [String: Any]
        if openClawRefreshResult.sendCount == 1 {
            precondition(message["context_token"] as? String == "stale-openclaw-context")
            try Data("{".utf8).write(to: openClawContextURL)
            let freshContextData = Data(
                #"{"openclaw-user@im.wechat":"fresh-openclaw-context"}"#.utf8
            )
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500)) {
                try! freshContextData.write(to: openClawContextURL)
            }
            return MockURLProtocol.response(request, body: #"{"ret":-2}"#)
        }
        precondition(message["context_token"] as? String == "fresh-openclaw-context")
        return MockURLProtocol.response(request, body: #"{"ret":0}"#)
    case "/ilink/bot/getupdates":
        preconditionFailure("OpenClaw mode must never poll getupdates")
    default:
        preconditionFailure("Unexpected OpenClaw request: \(request.url!.absoluteString)")
    }
}

let openClawRefreshFinished = DispatchSemaphore(value: 0)
Task {
    do {
        let service = WeChatService(
            openClawStore: openClawStore,
            credentialSource: .openClaw,
            openClawAccountID: openClawAccountID,
            session: mockSession
        )
        await service.setCredentialSource(
            .openClaw,
            openClawAccountID: openClawAccountID,
            revision: 2
        )
        await service.setCredentialSource(.weClawSend, openClawAccountID: nil, revision: 1)
        let accountIDAfterStaleSwitch = await service.accountID()
        precondition(accountIDAfterStaleSwitch == "abc123@im.bot")
        try await service.sendFile(at: mockFile, fileName: mockFileName) { progress in
            openClawRefreshResult.progress.append(progress)
        }
    } catch {
        openClawRefreshResult.error = error
    }
    openClawRefreshFinished.signal()
}
precondition(openClawRefreshFinished.wait(timeout: .now() + 10) == .success)
if let error = openClawRefreshResult.error { throw error }
precondition(openClawRefreshResult.sendCount == 2)
precondition(openClawRefreshResult.updateCount == 0)
precondition(openClawRefreshResult.progress.contains { $0.stage == .waitingForContext })
let refreshedOpenClawAccountData = try Data(contentsOf: openClawAccountURL)
precondition(refreshedOpenClawAccountData == openClawAccountData)

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

let loginBindingResult = ResultBox()
let loginBindingStoreURL = FileManager.default.temporaryDirectory
    .appending(path: "weclaw-send-login-binding-\(UUID()).json")
let loginBindingStore = WeChatCredentialStore(credentialsFileOverride: loginBindingStoreURL)
defer { try? FileManager.default.removeItem(at: loginBindingStoreURL) }
let pendingLoginCredentials = WeChatCredentials(
    botToken: "login-token",
    botID: "login-bot@im.bot",
    baseURL: URL(string: "https://mock.local")!,
    userID: "login-user@im.wechat",
    contextToken: "login-context"
)

MockURLProtocol.handler = { request in
    precondition(request.url!.path == "/ilink/bot/getupdates")
    return MockURLProtocol.response(
        request,
        body: #"{"ret":0,"get_updates_buf":"login-buffer","msgs":[{"seq":1,"from_user_id":"login-user@im.wechat","create_time_ms":0,"context_token":"login-context"}]}"#
    )
}

let loginBindingFinished = DispatchSemaphore(value: 0)
Task {
    do {
        let service = WeChatService(
            credentials: pendingLoginCredentials,
            session: mockSession,
            store: loginBindingStore
        )
        try await service.waitForLoginBinding(credentials: pendingLoginCredentials)
    } catch {
        loginBindingResult.error = error
    }
    loginBindingFinished.signal()
}
precondition(loginBindingFinished.wait(timeout: .now() + 10) == .success)
if let error = loginBindingResult.error { throw error }
let boundLoginCredentials = try loginBindingStore.load()
precondition(boundLoginCredentials?.contextToken == "login-context")
precondition(boundLoginCredentials?.getUpdatesBuffer == "login-buffer")

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
let stable140 = AppBuildVersion(version: version140, build: 10, channel: .stable)
let stable150 = AppBuildVersion(version: version150, build: 11, channel: .stable)
let beta150Build12 = AppBuildVersion(version: version150, build: 12, channel: .beta)
let beta150Build13 = AppBuildVersion(releaseTag: "v1.5.0-beta.13", isPrerelease: true)!
precondition(beta150Build13.description == "1.5.0 测试版（构建 13）")
precondition(NSImage(systemSymbolName: "clock.badge.checkmark", accessibilityDescription: nil) != nil)
precondition(beta150Build12 < beta150Build13)
precondition(beta150Build13 < stable150)
precondition(beta150Build13.identifier == "1.5.0-beta.13")
precondition(AppBuildVersion(releaseTag: "v1.5.0-beta", isPrerelease: true) == nil)
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
        ###"{"tag_name":"v1.5.0","html_url":"https://github.com/double2tea/WeClawSend/releases/tag/v1.5.0","body":"## 更新内容\n- 支持批量发送\n- 修复登录问题\n\n**Full Changelog**: https://example.test","assets":[{"name":"WeClaw-Send.zip","browser_download_url":"https://example.test/WeClaw-Send.zip"}]}"###.utf8
    )
)
precondition(release.version == version150)
precondition(release.appVersion == AppBuildVersion(version: version150, build: 0, channel: .stable))
precondition(!release.isPrerelease)
precondition(release.asset(named: UpdateManager.appArchiveName)?.browserDownloadURL.host == "example.test")
precondition(AppUpdateNotice.notes(from: release.body) == ["支持批量发送", "修复登录问题"])
precondition(AppUpdateNotice(release: release, currentVersion: stable140, seenVersion: "") != nil)
precondition(AppUpdateNotice(release: release, currentVersion: stable140, seenVersion: "1.5.0") == nil)
precondition(AppUpdateNotice(release: release, currentVersion: stable150, seenVersion: "") == nil)
let releaseComponents = try JSONDecoder().decode(
    ReleaseComponents.self,
    from: Data(#"{"app":"1.5.0","app_build":11,"premiere":"2.0.0","davinci":"3.0.0"}"#.utf8)
)
precondition(releaseComponents.app == version150)
precondition(releaseComponents.appBuild == 11)
precondition(releaseComponents.premiere == ReleaseVersion(tag: "2.0.0")!)
precondition(releaseComponents.daVinci == ReleaseVersion(tag: "3.0.0")!)
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
let updateResult = UpdateResultBox()
MockURLProtocol.handler = { request in
    precondition(request.url == updateEndpoint)
    precondition(request.timeoutInterval == UpdateManager.metadataRequestTimeout)
    precondition(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    precondition(request.value(forHTTPHeaderField: "User-Agent") == "WeClawSend")
    updateResult.metadataRequestCount += 1
    if updateResult.metadataRequestCount == 1 {
        precondition(request.value(forHTTPHeaderField: "Cache-Control") == nil)
        precondition(request.value(forHTTPHeaderField: "Pragma") == nil)
        return MockURLProtocol.response(
            request,
            body: #"{"tag_name":"v1.5.0","html_url":"https://github.com/double2tea/WeClawSend/releases/tag/v1.5.0","assets":[]}"#
        )
    }
    precondition(updateResult.metadataRequestCount == 2)
    precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
    precondition(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    precondition(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
    return MockURLProtocol.response(
        request,
        body: #"{"tag_name":"v1.6.0","html_url":"https://github.com/double2tea/WeClawSend/releases/tag/v1.6.0","assets":[]}"#
    )
}
let updateManager = UpdateManager(session: updateSession, latestReleaseURL: updateEndpoint)
let updateFinished = DispatchSemaphore(value: 0)
Task {
    do {
        updateResult.release = try await updateManager.latestRelease()
        updateResult.appAvailability = try await updateManager.appUpdateAvailability(
            currentVersion: stable140
        )
        await updateManager.invalidateReleaseCache()
        updateResult.refreshedRelease = try await updateManager.latestRelease()
    } catch {
        updateResult.error = error
    }
    updateFinished.signal()
}
precondition(updateFinished.wait(timeout: .now() + 10) == .success)
if let error = updateResult.error { throw error }
precondition(updateResult.release?.tagName == "v1.5.0")
precondition(
    updateResult.appAvailability
        == .updateAvailable(AppBuildVersion(version: version150, build: 0, channel: .stable))
)
precondition(updateResult.refreshedRelease?.tagName == "v1.6.0")
precondition(updateResult.metadataRequestCount == 2)

let stablePrimaryEndpoint = URL(string: "https://mock.local/releases/unavailable")!
let stableFallbackEndpoint = URL(string: "https://cdn.mock/downloads/release.json")!
let stableFallbackResult = UpdateResultBox()
MockURLProtocol.handler = { request in
    stableFallbackResult.metadataRequestCount += 1
    if request.url == stablePrimaryEndpoint {
        return MockURLProtocol.response(request, statusCode: 503, body: "Unavailable")
    }
    precondition(request.url == stableFallbackEndpoint)
    return MockURLProtocol.response(
        request,
        body: #"{"tag_name":"v1.6.0","html_url":"https://github.com/double2tea/WeClawSend/releases/tag/v1.6.0","draft":false,"prerelease":false,"assets":[]}"#
    )
}
let stableFallbackManager = UpdateManager(
    session: updateSession,
    latestReleaseURL: stablePrimaryEndpoint,
    stableReleaseFallbackURL: stableFallbackEndpoint
)
let stableFallbackFinished = DispatchSemaphore(value: 0)
Task {
    do {
        stableFallbackResult.release = try await stableFallbackManager.latestRelease()
    } catch {
        stableFallbackResult.error = error
    }
    stableFallbackFinished.signal()
}
precondition(stableFallbackFinished.wait(timeout: .now() + 10) == .success)
if let error = stableFallbackResult.error { throw error }
precondition(stableFallbackResult.release?.tagName == "v1.6.0")
precondition(stableFallbackResult.metadataRequestCount == 2)

let betaEndpoint = URL(string: "https://mock.local/releases?per_page=100")!
let betaResult = UpdateResultBox()
MockURLProtocol.handler = { request in
    precondition(request.url == betaEndpoint)
    betaResult.metadataRequestCount += 1
    return MockURLProtocol.response(
        request,
        body: #"[{"tag_name":"v1.5.0-beta.13","html_url":"https://example.test/v1.5.0-beta.13","draft":false,"prerelease":true,"assets":[]},{"tag_name":"v1.5.0-beta.14","html_url":"https://example.test/v1.5.0-beta.14","draft":true,"prerelease":true,"assets":[]},{"tag_name":"v1.5.0-beta.15","html_url":"https://example.test/v1.5.0-beta.15","draft":false,"prerelease":false,"assets":[]},{"tag_name":"v1.4.0","html_url":"https://example.test/v1.4.0","draft":false,"prerelease":false,"assets":[]}]"#
    )
}
let betaManager = UpdateManager(session: updateSession, betaReleasesURL: betaEndpoint)
let betaFinished = DispatchSemaphore(value: 0)
Task {
    do {
        betaResult.release = try await betaManager.latestRelease(channel: .beta)
        betaResult.appAvailability = try await betaManager.appUpdateAvailability(
            currentVersion: beta150Build12,
            channel: .beta
        )
    } catch {
        betaResult.error = error
    }
    betaFinished.signal()
}
precondition(betaFinished.wait(timeout: .now() + 10) == .success)
if let error = betaResult.error { throw error }
precondition(betaResult.release?.tagName == "v1.5.0-beta.13")
precondition(betaResult.appAvailability == .updateAvailable(beta150Build13))

let updateCountDefaultsName = "WeClawSend.UpdateCountChecks.\(UUID())"
let updateCountDefaults = UserDefaults(suiteName: updateCountDefaultsName)!
defer { UserDefaults.standard.removePersistentDomain(forName: updateCountDefaultsName) }
let updateCountEndpoint = URL(string: "https://mock.local/api/update-check")!
let updateCountPayload = UpdateCheckCountPayload(
    version: "2.2.0",
    build: "38",
    channel: "stable"
)
let updateCountResult = UpdateCheckReportBox()
MockURLProtocol.handler = { request in
    precondition(request.url == updateCountEndpoint)
    precondition(request.httpMethod == "POST")
    precondition(request.timeoutInterval == 3)
    precondition(request.value(forHTTPHeaderField: "User-Agent") == "WeClawSend-UpdateCheck")
    updateCountResult.payload = try JSONDecoder().decode(
        UpdateCheckCountPayload.self,
        from: requestBody(request)
    )
    updateCountResult.requestCount += 1
    return MockURLProtocol.response(request, statusCode: 204, body: "")
}
let updateCountReporter = UpdateCheckReporter(
    endpoint: updateCountEndpoint,
    payload: updateCountPayload,
    userDefaults: updateCountDefaults,
    session: updateSession
)
let updateCountFinished = DispatchSemaphore(value: 0)
let updateCountStart = Date(timeIntervalSince1970: 1_800_000_000)
Task {
    updateCountResult.firstSent = await updateCountReporter.reportIfNeeded(now: updateCountStart)
    updateCountResult.secondSent = await updateCountReporter.reportIfNeeded(
        now: updateCountStart.addingTimeInterval(3_600)
    )
    updateCountResult.thirdSent = await updateCountReporter.reportIfNeeded(
        now: updateCountStart.addingTimeInterval(UpdateCheckReporter.minimumInterval + 1)
    )
    updateCountResult.clockRollbackSent = await updateCountReporter.reportIfNeeded(
        now: updateCountStart.addingTimeInterval(-1)
    )
    updateCountFinished.signal()
}
precondition(updateCountFinished.wait(timeout: .now() + 10) == .success)
precondition(updateCountResult.firstSent)
precondition(!updateCountResult.secondSent)
precondition(updateCountResult.thirdSent)
precondition(updateCountResult.clockRollbackSent)
precondition(updateCountResult.requestCount == 3)
precondition(updateCountResult.payload == updateCountPayload)
precondition(betaResult.metadataRequestCount == 1)

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
let daVinciRoot = daVinciFixture.appending(path: "davinci-resolve", directoryHint: .isDirectory)
let daVinciSource = daVinciRoot.appending(path: "Deliver", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: daVinciSource, withIntermediateDirectories: true)
for name in UpdateManager.daVinciScriptNames {
    try Data("new \(name)".utf8).write(to: daVinciSource.appending(path: name))
}
try Data("9.1.0\n".utf8).write(
    to: daVinciRoot.appending(path: UpdateManager.daVinciVersionFileName)
)
let daVinciArchive = installerFixtures.appending(path: UpdateManager.daVinciArchiveName)
try zipDirectory(daVinciFixture, to: daVinciArchive)

let componentsFile = installerFixtures.appending(path: UpdateManager.componentsName)
try Data(#"{"app":"9.0.0","premiere":"9.0.0","davinci":"9.1.0"}"#.utf8).write(
    to: componentsFile
)

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
let componentsChecksum = try UpdateManager.sha256(of: componentsFile)
let installerChecksumManifest = """
\(premiereChecksum)  \(UpdateManager.premiereArchiveName)
\(daVinciChecksum)  \(UpdateManager.daVinciArchiveName)
\(componentsChecksum)  \(UpdateManager.componentsName)
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
            body: #"{"tag_name":"v9.0.0","html_url":"https://github.com/double2tea/WeClawSend/releases/tag/v9.0.0","assets":[{"name":"SHA256SUMS.txt","browser_download_url":"https://github.mock/SHA256SUMS.txt"},{"name":"WeClaw-Send-Components.json","browser_download_url":"https://github.mock/WeClaw-Send-Components.json"},{"name":"WeClaw-Send-Premiere-CEP12.zip","browser_download_url":"https://github.mock/WeClaw-Send-Premiere-CEP12.zip"},{"name":"WeClaw-Send-DaVinci-Resolve.zip","browser_download_url":"https://github.mock/WeClaw-Send-DaVinci-Resolve.zip"}]}"#
        )
    case "/SHA256SUMS.txt", "/WeClaw-Send-Premiere-CEP12.zip",
         "/WeClaw-Send-DaVinci-Resolve.zip", "/WeClaw-Send-Components.json":
        precondition(request.url!.host == "github.mock")
        return MockURLProtocol.response(request, statusCode: 503, body: "Unavailable")
    case "/downloads/SHA256SUMS.txt":
        return MockURLProtocol.response(request, body: installerChecksumManifest)
    case "/downloads/WeClaw-Send-Premiere-CEP12.zip":
        return MockURLProtocol.response(request, data: try Data(contentsOf: premiereArchive))
    case "/downloads/WeClaw-Send-DaVinci-Resolve.zip":
        return MockURLProtocol.response(request, data: try Data(contentsOf: daVinciArchive))
    case "/downloads/WeClaw-Send-Components.json":
        return MockURLProtocol.response(request, data: try Data(contentsOf: componentsFile))
    default:
        preconditionFailure("Unexpected installer request: \(request.url!.absoluteString)")
    }
}
let installerManager = UpdateManager(
    session: installerSession,
    latestReleaseURL: installerEndpoint,
    cdnDownloadsBaseURL: URL(string: "https://cdn.mock/downloads/")!,
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
        installerResult.daVinciState = try await installerManager.daVinciScriptsUpdateState()
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
precondition(installerResult.daVinciState == .repairRequired(latest: ReleaseVersion(tag: "9.1.0")!))
precondition(installerResult.daVinciVersion?.description == "9.1.0")
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
let installedDaVinciVersion = try String(
    contentsOf: existingDaVinci.appending(path: UpdateManager.daVinciInstalledVersionFileName),
    encoding: .utf8
).trimmingCharacters(in: .whitespacesAndNewlines)
precondition(installedDaVinciVersion == "9.1.0")
let verifiedDaVinciBox = UpdateInstallResultBox()
let verifiedDaVinciFinished = DispatchSemaphore(value: 0)
Task {
    do {
        verifiedDaVinciBox.daVinciVersion = try await installerManager.installedDaVinciScriptsVersion()
        verifiedDaVinciBox.daVinciDirectory = await installerManager.daVinciScriptsDirectoryURL()
    } catch {
        verifiedDaVinciBox.error = error
    }
    verifiedDaVinciFinished.signal()
}
precondition(verifiedDaVinciFinished.wait(timeout: .now() + 10) == .success)
precondition(verifiedDaVinciBox.error == nil)
precondition(verifiedDaVinciBox.daVinciVersion?.description == "9.1.0")
precondition(verifiedDaVinciBox.daVinciDirectory?.path == existingDaVinci.path)

let uninstallBox = UpdateInstallResultBox()
let uninstallFinished = DispatchSemaphore(value: 0)
Task {
    do {
        try await installerManager.uninstallDaVinciScripts()
        try await installerManager.uninstallPremierePlugin()
        uninstallBox.daVinciVersion = try await installerManager.installedDaVinciScriptsVersion()
        uninstallBox.installedPremiereVersion = try await installerManager.installedPremierePluginVersion()
    } catch {
        uninstallBox.error = error
    }
    uninstallFinished.signal()
}
precondition(uninstallFinished.wait(timeout: .now() + 10) == .success)
precondition(uninstallBox.error == nil)
precondition(uninstallBox.daVinciVersion == nil)
precondition(uninstallBox.installedPremiereVersion == nil)
for name in UpdateManager.daVinciScriptNames {
    precondition(!FileManager.default.fileExists(atPath: existingDaVinci.appending(path: name).path))
}
precondition(!FileManager.default.fileExists(atPath: existingPremiere.path))

// reinstall for subsequent downgrade/repair checks
let reinstallBox = UpdateInstallResultBox()
let reinstallFinished = DispatchSemaphore(value: 0)
Task {
    do {
        reinstallBox.premiereVersion = try await installerManager.installPremierePlugin()
        reinstallBox.daVinciVersion = try await installerManager.installDaVinciScripts()
    } catch {
        reinstallBox.error = error
    }
    reinstallFinished.signal()
}
precondition(reinstallFinished.wait(timeout: .now() + 10) == .success)
precondition(reinstallBox.error == nil)
precondition(reinstallBox.premiereVersion?.description == "9.0.0")
precondition(reinstallBox.daVinciVersion?.description == "9.1.0")

try Data("10.0.0\n".utf8).write(
    to: existingDaVinci.appending(path: UpdateManager.daVinciInstalledVersionFileName),
    options: .atomic
)
let daVinciDowngradeResult = UpdateInstallResultBox()
let daVinciDowngradeFinished = DispatchSemaphore(value: 0)
Task {
    do {
        daVinciDowngradeResult.daVinciVersion = try await installerManager.installDaVinciScripts()
    } catch {
        daVinciDowngradeResult.error = error
    }
    daVinciDowngradeFinished.signal()
}
precondition(daVinciDowngradeFinished.wait(timeout: .now() + 10) == .success)
if let error = daVinciDowngradeResult.error as? UpdateManagerError,
   case let .daVinciScriptsDowngradeNotAllowed(installed, available) = error {
    precondition(installed.description == "10.0.0")
    precondition(available.description == "9.1.0")
} else {
    preconditionFailure("DaVinci scripts downgrade must be blocked by default")
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
let secondFileURL = FileManager.default.temporaryDirectory
    .appending(path: "WeClawSend-second-\(UUID()).mov")
precondition(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))
precondition(FileManager.default.createFile(atPath: secondFileURL.path, contents: Data()))
defer {
    try? FileManager.default.removeItem(at: fileURL)
    try? FileManager.default.removeItem(at: secondFileURL)
}
pasteboard.clearContents()
pasteboard.writeObjects([
    fileURL as NSURL,
    secondFileURL as NSURL,
    FileManager.default.temporaryDirectory as NSURL,
])
precondition(fileURLs(from: pasteboard) == [fileURL, secondFileURL])
precondition(
    fileURLs(from: pasteboard, includingDirectories: true)
        == [fileURL, secondFileURL, FileManager.default.temporaryDirectory]
)
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

final class CancellationResultBox: @unchecked Sendable {
    var cancelAccepted = false
    var error: Error?
    var record: TransferRecord?
}

final class ContextRefreshResultBox: @unchecked Sendable {
    var error: Error?
    var sendCount = 0
    var updateCount = 0
    var progress: [WeChatSendProgress] = []
}

final class RetryResultBox: @unchecked Sendable {
    var error: Error?
    var uploadURLRequestCount = 0
    var uploadRequestCount = 0
    var sendRequestCount = 0
    var clientID: String?
}

final class UpdateResultBox: @unchecked Sendable {
    var error: Error?
    var release: GitHubRelease?
    var refreshedRelease: GitHubRelease?
    var appAvailability: AppUpdateAvailability?
    var metadataRequestCount = 0
}

final class UpdateCheckReportBox: @unchecked Sendable {
    var requestCount = 0
    var payload: UpdateCheckCountPayload?
    var firstSent = false
    var secondSent = false
    var thirdSent = false
    var clockRollbackSent = false
}

final class UpdateInstallResultBox: @unchecked Sendable {
    var error: Error?
    var installedPremiereVersion: ReleaseVersion?
    var premiereState: PremierePluginUpdateState?
    var premiereVersion: ReleaseVersion?
    var daVinciState: DaVinciScriptsUpdateState?
    var daVinciVersion: ReleaseVersion?
    var daVinciDirectory: URL?
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
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: String
    ) -> (HTTPURLResponse, Data) {
        response(request, statusCode: statusCode, headers: headers, data: Data(body.utf8))
    }

    static func response(
        _ request: URLRequest,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!,
            data
        )
    }
}

final class CancellableURLProtocol: URLProtocol, @unchecked Sendable {
    static let uploadStarted = DispatchSemaphore(value: 0)

    private let stateLock = NSLock()
    private var stopped = false
    private var responseWorkItem: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch request.url!.path {
        case "/ilink/bot/getuploadurl":
            respond(body: #"{"ret":0,"upload_full_url":"https://cancel.mock/upload"}"#)
        case "/upload":
            Self.uploadStarted.signal()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, !self.isStopped else { return }
                self.respond(headers: ["x-encrypted-param": "must-not-complete"], body: "")
            }
            responseWorkItem = workItem
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: workItem)
        default:
            preconditionFailure("Unexpected cancellation request: \(request.url!.absoluteString)")
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        responseWorkItem?.cancel()
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func respond(headers: [String: String] = [:], body: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
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

let scheduledStoreDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("weclaw-scheduled-plan-check-\(UUID())", isDirectory: true)
let scheduledStoreURL = scheduledStoreDirectory.appendingPathComponent("plans.json")
defer { try? FileManager.default.removeItem(at: scheduledStoreDirectory) }
let scheduledItem = ScheduledSendItem(
    filePath: "/tmp/render.mp4",
    fileName: "render.m4v",
    byteCount: 42,
    modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
)
let scheduledPlan = ScheduledSendPlan(
    id: UUID(),
    items: [scheduledItem],
    createdAt: Date(timeIntervalSince1970: 1_700_000_001),
    scheduledAt: Date(timeIntervalSince1970: 1_700_000_600),
    source: "component-check",
    idempotencyKey: "component-check-key"
)
try ScheduledSendStore.save([scheduledPlan], to: scheduledStoreURL)
let restoredScheduledPlans = try ScheduledSendStore.load(from: scheduledStoreURL)
precondition(restoredScheduledPlans == [scheduledPlan])
precondition(ScheduledSendStatus.needsAttention.rawValue == "needs_attention")
let queuedTransfer = TransferRecord(
    transferID: UUID(),
    path: "/tmp/preview.png",
    fileName: "preview.png",
    byteCount: 12,
    date: Date(timeIntervalSince1970: 1_700_000_100),
    status: .sent,
    message: nil,
    stage: nil,
    progress: nil,
    sentBytes: nil
)
precondition(
    QueueSelection.scheduled(scheduledPlan.id)
        .previewURLs(plans: [scheduledPlan], transfers: [queuedTransfer])
        == [scheduledItem.fileURL]
)
precondition(
    QueueSelection.transfer(queuedTransfer.id)
        .previewURLs(plans: [scheduledPlan], transfers: [queuedTransfer])
        == [queuedTransfer.fileURL]
)
precondition(
    QueueSelection.scheduled(UUID())
        .previewURLs(plans: [scheduledPlan], transfers: [queuedTransfer])
        .isEmpty
)
precondition(NSImage(systemSymbolName: "clock", accessibilityDescription: nil) != nil)
precondition(FilePreviewKind(fileName: "talk.mp4").hasVisualContent)
precondition(FilePreviewKind(fileName: "talk.m4v").hasVisualContent)
precondition(FilePreviewKind(fileName: "page.pdf").hasVisualContent)
precondition(FilePreviewKind(fileName: "cover.png").hasVisualContent)
precondition(!FilePreviewKind(fileName: "note.txt").hasVisualContent)
precondition(!FilePreviewKind(fileName: "hit.mp3").hasVisualContent)
precondition(FilePreviewKind(fileName: "talk.mp4").symbol == "film")
precondition(FilePreviewKind(fileName: "hit.mp3").symbol == "waveform")
precondition(MenuBarActivity.idle.badgeText == nil)
precondition(
    MenuBarActivity.make(
        sendingProgresses: [0.5],
        queuedCount: 0,
        scheduledCount: 0
    ) == MenuBarActivity(isSending: true, progress: 0.5, badgeCount: 0)
)
precondition(
    MenuBarActivity.make(
        sendingProgresses: [0.2, 0.8],
        queuedCount: 1,
        scheduledCount: 2
    ).badgeCount == 3
)
precondition(
    MenuBarActivity.make(
        sendingProgresses: [0.2, nil],
        queuedCount: 0,
        scheduledCount: 0
    ).isIndeterminate
)
precondition(MenuBarActivity(isSending: false, progress: nil, badgeCount: 12).badgeText == "9")
let scheduledPlanJSONEncoder = JSONEncoder()
scheduledPlanJSONEncoder.dateEncodingStrategy = .iso8601
let scheduledPlanObject = try JSONSerialization.jsonObject(
    with: scheduledPlanJSONEncoder.encode(scheduledPlan)
) as! [String: Any]
precondition(scheduledPlanObject["scheduled_at"] != nil)
precondition(scheduledPlanObject["created_at"] != nil)
precondition(scheduledPlanObject["idempotency_key"] as? String == "component-check-key")
precondition(scheduledPlanObject["scheduledAt"] == nil)

let scheduledRuntimeDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("weclaw-scheduled-runtime-check-\(UUID())", isDirectory: true)
let scheduledRuntimeStoreURL = scheduledRuntimeDirectory.appendingPathComponent("plans.json")
let scheduledRuntimeFile = scheduledRuntimeDirectory.appendingPathComponent("runtime.txt")
try FileManager.default.createDirectory(at: scheduledRuntimeDirectory, withIntermediateDirectories: true)
try Data("runtime-plan".utf8).write(to: scheduledRuntimeFile)
defer { try? FileManager.default.removeItem(at: scheduledRuntimeDirectory) }

let scheduledRuntimeError = ResultBox()
let scheduledRuntimeFinished = DispatchSemaphore(value: 0)
Task {
    do {
        let coordinator = SendCoordinator(
            weChat: WeChatService(),
            scheduledStoreURL: scheduledRuntimeStoreURL
        )
        let request = SendRequest(
            filePath: scheduledRuntimeFile.path,
            fileName: scheduledRuntimeFile.lastPathComponent
        )
        let first = try await coordinator.createScheduledSend(
            requests: [request],
            scheduledAt: Date().addingTimeInterval(600),
            source: "component-check",
            idempotencyKey: "runtime-idempotency"
        )
        precondition(first.created)
        let repeated = try await coordinator.createScheduledSend(
            requests: [request],
            scheduledAt: Date().addingTimeInterval(900),
            source: "component-check",
            idempotencyKey: "runtime-idempotency"
        )
        precondition(!repeated.created)
        precondition(repeated.plan.id == first.plan.id)

        let rescheduled = try await coordinator.rescheduleScheduledSend(
            id: first.plan.id,
            to: Date().addingTimeInterval(1_200)
        )
        precondition(rescheduled.scheduledAt > Date())

        let concurrentA = Task {
            try await coordinator.sendScheduledNow(id: first.plan.id)
        }
        let concurrentB = Task {
            try await coordinator.sendScheduledNow(id: first.plan.id)
        }
        let concurrentResults = try await (concurrentA.value, concurrentB.value)
        precondition(concurrentResults.0.status == .needsAttention)
        precondition(concurrentResults.1.status == .needsAttention)

        let cancelled = try await coordinator.cancelScheduledSend(id: first.plan.id)
        precondition(cancelled.status == .cancelled)

        let due = try await coordinator.createScheduledSend(
            requests: [request],
            scheduledAt: Date().addingTimeInterval(0.05),
            source: "component-check",
            idempotencyKey: "runtime-due"
        )
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let dueStatus = await coordinator.scheduledPlan(id: due.plan.id)?.status
        precondition(dueStatus == .needsAttention)

        let missing = SendRequest(
            filePath: scheduledRuntimeDirectory.appendingPathComponent("missing.txt").path,
            fileName: "missing.txt"
        )
        do {
            _ = try await coordinator.createScheduledSend(
                requests: [missing],
                scheduledAt: Date().addingTimeInterval(600),
                source: "component-check",
                idempotencyKey: "runtime-missing"
            )
            preconditionFailure("a missing scheduled file must be rejected")
        } catch is BackendError {
            // Expected validation failure.
        }

        let overdueID = UUID()
        let overduePlan = ScheduledSendPlan(
            id: overdueID,
            items: [ScheduledSendItem(
                filePath: scheduledRuntimeFile.path,
                fileName: scheduledRuntimeFile.lastPathComponent,
                byteCount: 12,
                modifiedAt: nil
            )],
            scheduledAt: Date().addingTimeInterval(-60),
            source: "component-check",
            idempotencyKey: "runtime-overdue"
        )
        try ScheduledSendStore.save([overduePlan], to: scheduledRuntimeStoreURL)
        let recoveredCoordinator = SendCoordinator(
            weChat: WeChatService(),
            scheduledStoreURL: scheduledRuntimeStoreURL
        )
        let recovered = await recoveredCoordinator.scheduledPlan(id: overdueID)
        precondition(recovered?.status == .needsAttention)
    } catch {
        scheduledRuntimeError.error = error
    }
    scheduledRuntimeFinished.signal()
}
precondition(scheduledRuntimeFinished.wait(timeout: .now() + 6) == .success)
if let error = scheduledRuntimeError.error { throw error }

let changedFileDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("weclaw-scheduled-change-check-\(UUID())", isDirectory: true)
let changedFile = changedFileDirectory.appendingPathComponent("changed.txt")
try FileManager.default.createDirectory(at: changedFileDirectory, withIntermediateDirectories: true)
try Data("before".utf8).write(to: changedFile)
defer { try? FileManager.default.removeItem(at: changedFileDirectory) }
let changedResult = ResultBox()
let changedFinished = DispatchSemaphore(value: 0)
MockURLProtocol.handler = { request in
    guard request.url?.path == "/ilink/bot/getconfig" else {
        preconditionFailure("file-change preflight must not send network requests")
    }
    return MockURLProtocol.response(request, body: #"{"ret":0}"#)
}
Task {
    do {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let service = WeChatService(
            credentials: mockCredentials,
            session: URLSession(configuration: configuration)
        )
        try await service.validateCredentials()
        let coordinator = SendCoordinator(weChat: service, scheduledStoreURL: changedFileDirectory.appendingPathComponent("plans.json"))
        let creation = try await coordinator.createScheduledSend(
            requests: [SendRequest(filePath: changedFile.path, fileName: changedFile.lastPathComponent)],
            scheduledAt: Date().addingTimeInterval(600),
            source: "component-check",
            idempotencyKey: "runtime-changed"
        )
        try Data("after-and-longer".utf8).write(to: changedFile)
        _ = try await coordinator.sendScheduledNow(id: creation.plan.id)
        for _ in 0..<20 {
            if let plan = await coordinator.scheduledPlan(id: creation.plan.id),
               plan.status == .needsAttention {
                precondition(plan.message?.contains("变化") == true)
                changedFinished.signal()
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        preconditionFailure("a changed file must put the plan in needs_attention")
    } catch {
        changedResult.error = error
        changedFinished.signal()
    }
}
precondition(changedFinished.wait(timeout: .now() + 5) == .success)
if let error = changedResult.error { throw error }

let apiDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("weclaw-scheduled-api-check-\(UUID())", isDirectory: true)
let apiFile = apiDirectory.appendingPathComponent("api.txt")
try FileManager.default.createDirectory(at: apiDirectory, withIntermediateDirectories: true)
try Data("api-plan".utf8).write(to: apiFile)
defer { try? FileManager.default.removeItem(at: apiDirectory) }
let apiResult = ResultBox()
let apiFinished = DispatchSemaphore(value: 0)
let apiPort = UInt16(30_000 + ProcessInfo.processInfo.processIdentifier % 10_000)
let apiBasketID = UUID()
Task {
    let server = EmbeddedBridgeServer(
        coordinator: SendCoordinator(
            weChat: WeChatService(),
            scheduledStoreURL: apiDirectory.appendingPathComponent("plans.json")
        ),
        port: apiPort
    )
    server.setSendHandler { request in
        .addedToBasket(
            LocalAPIBasketResult(
                status: "added_to_basket",
                filePath: request.filePath,
                fileName: request.fileName ?? apiFile.lastPathComponent,
                size: Int64((try? apiFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                basketID: apiBasketID,
                basketTitle: "文件篮 1"
            )
        )
    }
    server.start()
    defer { server.stop() }
    do {
        try await Task.sleep(nanoseconds: 200_000_000)
        let session = URLSession(configuration: .ephemeral)
        var createRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(apiPort)/scheduled-sends")!)
        createRequest.httpMethod = "POST"
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "items": [["file_path": apiFile.path, "file_name": apiFile.lastPathComponent]],
            "delay_seconds": 120,
            "source": "component-check",
            "idempotency_key": "api-idempotency"
        ])
        let (createData, createResponse) = try await session.data(for: createRequest)
        precondition((createResponse as? HTTPURLResponse)?.statusCode == 201)
        let createdObject = try JSONSerialization.jsonObject(with: createData) as! [String: Any]
        let planID = createdObject["id"] as! String
        precondition(createdObject["scheduled_at"] != nil)
        precondition(createdObject["created_at"] != nil)
        precondition(createdObject["scheduledAt"] == nil)

        let getURL = URL(string: "http://127.0.0.1:\(apiPort)/scheduled-sends/\(planID)")!
        let (_, getResponse) = try await session.data(from: getURL)
        precondition((getResponse as? HTTPURLResponse)?.statusCode == 200)

        var deleteRequest = URLRequest(url: getURL)
        deleteRequest.httpMethod = "DELETE"
        let (deleteData, deleteResponse) = try await session.data(for: deleteRequest)
        precondition((deleteResponse as? HTTPURLResponse)?.statusCode == 200)
        let deletedObject = try JSONSerialization.jsonObject(with: deleteData) as! [String: Any]
        precondition(deletedObject["status"] as? String == "cancelled")

        var sendRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(apiPort)/send")!)
        sendRequest.httpMethod = "POST"
        sendRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sendRequest.httpBody = try JSONEncoder().encode(
            SendRequest(filePath: apiFile.path, fileName: apiFile.lastPathComponent)
        )
        let (sendData, sendResponse) = try await session.data(for: sendRequest)
        precondition((sendResponse as? HTTPURLResponse)?.statusCode == 200)
        let sendObject = try JSONSerialization.jsonObject(with: sendData) as! [String: Any]
        precondition(sendObject["ok"] as? Bool == true)
        precondition(sendObject["status"] as? String == "added_to_basket")
        precondition(sendObject["basket_id"] as? String == apiBasketID.uuidString)
    } catch {
        apiResult.error = error
    }
    apiFinished.signal()
}
precondition(apiFinished.wait(timeout: .now() + 8) == .success)
if let error = apiResult.error { throw error }
