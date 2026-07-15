import AppKit
import Foundation

enum ServiceStatus: Equatable {
    case checking
    case online(String?)
    case offline

    var isOnline: Bool {
        if case .online = self { true } else { false }
    }
}

private final class AppRuntime: Sendable {
    let weChat: WeChatService
    let coordinator: SendCoordinator
    let server: EmbeddedBridgeServer

    init() {
        weChat = WeChatService()
        coordinator = SendCoordinator(weChat: weChat)
        server = EmbeddedBridgeServer(coordinator: coordinator)
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let maxRecentTransfers = 20

    @Published var bridgeStatus: ServiceStatus = .checking
    @Published var weChatStatus: ServiceStatus = .checking
    @Published var recentTransfers: [TransferRecord] = []
    @Published var isSending = false
    @Published var isDropTargeted = false
    @Published var showsServices = false
    @Published var presentedError: String?
    @Published var loginQRCodeContent: String?
    @Published var loginMessage = ""
    @Published var needsVerificationCode = false
    @Published var verificationCode = ""
    @Published var isLoggingIn = false
    @Published var autoRenameMP4ToM4V = UserDefaults.standard.bool(forKey: AppSettings.autoRenameMP4Key)
    @Published var localAPIEnabled = AppSettings.localAPIEnabled
    @Published var premiereIntegrationCode = AppSettings.premiereIntegrationToken
    @Published var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @Published var launchAtLoginRequiresApproval = LaunchAtLogin.requiresApproval

    var onContextRefreshRequired: (() -> Void)?

    private let runtime: AppRuntime
    private var activeSendCount = 0
    private var eventTask: Task<Void, Never>?
    private var serverStateTask: Task<Void, Never>?
    private var serviceMonitorTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private let recentTransfersKey = "recentTransfers"
    private let legacyRecentTransferKey = "recentTransfer"
    private var contextRefreshTransfers: Set<UUID> = []

    init() {
        var shouldPersistLegacyTransfers = false
        if let data = UserDefaults.standard.data(forKey: recentTransfersKey) {
            recentTransfers = ((try? JSONDecoder().decode([TransferRecord].self, from: data)) ?? [])
                .filter(\.isTerminal)
        } else if let data = UserDefaults.standard.data(forKey: legacyRecentTransferKey),
                  let record = try? JSONDecoder().decode(TransferRecord.self, from: data) {
            recentTransfers = [record]
            UserDefaults.standard.removeObject(forKey: legacyRecentTransferKey)
            shouldPersistLegacyTransfers = true
        }

        let runtime = AppRuntime()
        self.runtime = runtime
        if shouldPersistLegacyTransfers {
            persistTransfers()
        }
        observe(runtime)
        if localAPIEnabled {
            runtime.server.start()
        } else {
            bridgeStatus = .offline
        }
        Task { [runtime] in
            await runtime.weChat.bootstrapCredentials()
            if let startupError = await runtime.weChat.startupError() {
                presentedError = "无法读取微信凭据：\(startupError)。请重新扫码登录。"
            }
            do {
                try LaunchAtLogin.migrateIfRequested()
            } catch {
                presentedError = "迁移登录时启动设置失败：\(error.localizedDescription)"
            }
            refreshLaunchAtLogin()
            await refreshServices()
        }
    }

    /// 主界面“可用”只看微信登录；本地 HTTP 接口是可选能力。
    var isReady: Bool {
        weChatStatus.isOnline
    }

    var hasActiveTransfers: Bool {
        recentTransfers.contains { $0.status == .queued || $0.status == .sending }
    }

    var activeTransferCount: Int {
        recentTransfers.filter { $0.status == .queued || $0.status == .sending }.count
    }

    var hasPendingContextRefresh: Bool {
        !contextRefreshTransfers.isEmpty
    }

    func setAutoRenameMP4ToM4V(_ enabled: Bool) {
        autoRenameMP4ToM4V = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettings.autoRenameMP4Key)
    }

    func setLocalAPIEnabled(_ enabled: Bool) {
        guard enabled != localAPIEnabled else { return }
        localAPIEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettings.localAPIEnabledKey)
        if enabled {
            bridgeStatus = .checking
            runtime.server.start()
        } else {
            bridgeStatus = .offline
            runtime.server.stop()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled, launchAtLoginRequiresApproval {
            LaunchAtLogin.openSystemSettings()
            return
        }
        do {
            try LaunchAtLogin.setEnabled(enabled)
            refreshLaunchAtLogin()
        } catch {
            refreshLaunchAtLogin()
            presentedError = "无法修改登录时启动：\(error.localizedDescription)"
        }
    }

    func refreshLaunchAtLogin() {
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
        launchAtLoginRequiresApproval = LaunchAtLogin.requiresApproval
    }

    func openLoginItemsSettings() {
        LaunchAtLogin.openSystemSettings()
    }

    func startMonitoringServices() {
        guard serviceMonitorTask == nil else { return }
        serviceMonitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await refreshServices()
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
            }
        }
    }

    func stopMonitoringServices() {
        serviceMonitorTask?.cancel()
        serviceMonitorTask = nil
    }

    func refreshServices() async {
        let snapshot = await runtime.coordinator.snapshot()
        if bridgeStatus.isOnline {
            bridgeStatus = .online(snapshot.queueDepth == 0 ? nil : "队列 \(snapshot.queueDepth)")
        }

        do {
            try await runtime.weChat.validateCredentials()
            weChatStatus = .online(await runtime.weChat.accountID())
        } catch {
            weChatStatus = .offline
        }
    }

    func send(urls: [URL]) {
        let requests = urls.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        .map { url in
            SendRequest(filePath: url.path, fileName: url.lastPathComponent)
        }
        guard !requests.isEmpty else { return }

        if !weChatStatus.isOnline {
            showsServices = true
            presentedError = "请先登录微信后再发送文件"
            return
        }
        enqueue(requests)
    }

    func send(integrationURL: URL) {
        do {
            enqueue([
                try IntegrationURL.sendRequest(
                    from: integrationURL,
                    authorizationToken: premiereIntegrationCode
                )
            ])
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func copyPremiereIntegrationCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(premiereIntegrationCode, forType: .string)
    }

    func regeneratePremiereIntegrationCode() {
        premiereIntegrationCode = AppSettings.regeneratePremiereIntegrationToken()
    }

    private func enqueue(_ requests: [SendRequest]) {
        for request in requests {
            activeSendCount += 1
            isSending = true
            Task { [weak self] in
                guard let self else { return }
                defer {
                    activeSendCount = max(0, activeSendCount - 1)
                    isSending = activeSendCount > 0
                }
                do {
                    _ = try await runtime.coordinator.send(request)
                } catch {
                    presentedError = error.localizedDescription
                }
                await refreshServices()
            }
        }
    }

    func beginWeChatLogin() {
        guard loginTask == nil else { return }
        isLoggingIn = true
        needsVerificationCode = false
        verificationCode = ""
        loginQRCodeContent = nil
        loginMessage = "正在生成二维码…"
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                loginQRCodeContent = try await runtime.weChat.startLogin()
                loginMessage = "请使用微信扫描二维码，并在手机上确认"
                await pollLogin(runtime: runtime, verificationCode: nil)
            } catch {
                finishLogin(error: error)
            }
        }
    }

    func cancelWeChatLogin() {
        loginTask?.cancel()
        loginTask = nil
        isLoggingIn = false
        needsVerificationCode = false
        verificationCode = ""
        loginQRCodeContent = nil
        loginMessage = ""
    }

    func submitVerificationCode() {
        guard loginTask == nil else { return }
        let code = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            presentedError = "请输入手机微信显示的配对码"
            return
        }
        isLoggingIn = true
        needsVerificationCode = false
        loginMessage = "正在验证配对码…"
        loginTask = Task { [weak self] in
            guard let self else { return }
            await pollLogin(runtime: runtime, verificationCode: code)
        }
    }

    func revealTransfer(_ transfer: TransferRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([transfer.fileURL])
    }

    func clearFinishedTransfers() {
        recentTransfers.removeAll(where: \.isTerminal)
        persistTransfers()
    }

    func quit() {
        runtime.server.stop()
        NSApplication.shared.terminate(nil)
    }

    private func observe(_ runtime: AppRuntime) {
        eventTask = Task { [weak self, events = runtime.coordinator.events] in
            for await event in events {
                guard let self else { return }
                switch event {
                case let .started(record):
                    insertTransfer(record)
                case let .updated(record):
                    updateTransfer(record)
                    if record.stage == .waitingForContext,
                       contextRefreshTransfers.insert(record.id).inserted {
                        presentedError = "微信会话需要刷新。请在微信里给 ClawBot 发送任意消息，App 收到后会自动继续发送。"
                        onContextRefreshRequired?()
                    }
                case let .completed(record):
                    insertTransfer(record)
                    persistTransfers()
                    if contextRefreshTransfers.remove(record.id) != nil {
                        presentedError = "微信会话已刷新，文件已自动重新发送。"
                    }
                case let .failed(record):
                    insertTransfer(record)
                    persistTransfers()
                    contextRefreshTransfers.remove(record.id)
                }
            }
        }

        serverStateTask = Task { [weak self, states = runtime.server.states] in
            for await state in states {
                guard let self else { return }
                switch state {
                case .starting:
                    if localAPIEnabled {
                        bridgeStatus = .checking
                    }
                case .ready:
                    if localAPIEnabled {
                        bridgeStatus = .online(nil)
                    }
                case .stopped:
                    bridgeStatus = .offline
                case let .failed(message):
                    bridgeStatus = .offline
                    if localAPIEnabled, !message.isEmpty {
                        presentedError = "本地接口：\(message)"
                    }
                }
            }
        }
    }

    private func insertTransfer(_ record: TransferRecord) {
        recentTransfers.removeAll { $0.id == record.id }
        recentTransfers.insert(record, at: 0)
        if recentTransfers.count > Self.maxRecentTransfers {
            recentTransfers.removeLast(recentTransfers.count - Self.maxRecentTransfers)
        }
    }

    private func updateTransfer(_ record: TransferRecord) {
        if let index = recentTransfers.firstIndex(where: { $0.id == record.id }) {
            recentTransfers[index] = record
        } else {
            insertTransfer(record)
        }
    }

    private func persistTransfers() {
        let finished = Array(recentTransfers.filter(\.isTerminal).prefix(Self.maxRecentTransfers))
        guard let data = try? JSONEncoder().encode(finished) else { return }
        UserDefaults.standard.set(data, forKey: recentTransfersKey)
        UserDefaults.standard.removeObject(forKey: legacyRecentTransferKey)
    }

    private func pollLogin(runtime: AppRuntime, verificationCode: String?) async {
        var code = verificationCode
        do {
            while !Task.isCancelled {
                let update = try await runtime.weChat.pollLogin(verificationCode: code)
                switch update {
                case .waiting:
                    loginMessage = "等待扫码确认…"
                case .scanned:
                    code = nil
                    loginMessage = "已扫码，等待手机确认…"
                case .needsVerification:
                    needsVerificationCode = true
                    loginMessage = "请输入手机微信显示的配对码"
                    isLoggingIn = false
                    loginTask = nil
                    return
                case .confirmed:
                    loginQRCodeContent = nil
                    loginMessage = "微信已登录"
                    needsVerificationCode = false
                    isLoggingIn = false
                    loginTask = nil
                    await refreshServices()
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
        } catch is CancellationError {
            // cancelled by user
        } catch {
            finishLogin(error: error)
        }
    }

    private func finishLogin(error: Error) {
        isLoggingIn = false
        loginTask = nil
        loginQRCodeContent = nil
        loginMessage = ""
        needsVerificationCode = false
        presentedError = error.localizedDescription
    }
}
