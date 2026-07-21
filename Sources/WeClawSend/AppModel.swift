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

enum WeChatLoginStep: Int, Equatable, Sendable {
    case scanAndConfirm = 1
    case bindConversation = 2
    case connected = 3
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
    @Published var isDropTargeted = false
    @Published var showsServices = false
    @Published var presentedError: String?
    @Published private(set) var transientNotice: String?
    @Published var loginQRCodeContent: String?
    @Published var loginMessage = ""
    @Published private(set) var loginStep: WeChatLoginStep?
    @Published var needsVerificationCode = false
    @Published var verificationCode = ""
    @Published var isLoggingIn = false
    @Published private(set) var weChatCredentialSource = AppSettings.weChatCredentialSource
    @Published private(set) var openClawAccounts: [OpenClawAccount] = []
    @Published private(set) var selectedOpenClawAccountID = AppSettings.openClawAccountID ?? ""
    @Published private(set) var isLoadingOpenClawAccounts = false
    @Published var autoRenameMP4ToM4V = UserDefaults.standard.bool(forKey: AppSettings.autoRenameMP4Key)
    @Published var sendSizeLimit = AppSettings.sendSizeLimit
    @Published var localAPIEnabled = AppSettings.localAPIEnabled
    @Published var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @Published var launchAtLoginRequiresApproval = LaunchAtLogin.requiresApproval
    @Published var isUpdatingApp = false
    @Published var isInstallingPremierePlugin = false
    @Published var isInstallingDaVinciScripts = false
    @Published private(set) var isCheckingAppUpdate = false
    @Published private(set) var appUpdateAvailability: AppUpdateAvailability?
    @Published private(set) var appUpdateNotice: AppUpdateNotice?
    @Published private(set) var isCheckingPremierePlugin = false
    @Published private(set) var premierePluginUpdateState: PremierePluginUpdateState?
    @Published private(set) var isCheckingDaVinciScripts = false
    @Published private(set) var daVinciScriptsUpdateState: DaVinciScriptsUpdateState?
    @Published var updateMessage = ""
    @Published var premierePluginMessage = ""
    @Published var daVinciScriptsMessage = ""

    var onContextRefreshRequired: (() -> Void)?

    private let runtime: AppRuntime
    private var startupTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var serverStateTask: Task<Void, Never>?
    private var serviceMonitorTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var credentialSourceTask: Task<Void, Never>?
    private var credentialSourceRevision: UInt64 = 0
    private var transientNoticeTask: Task<Void, Never>?
    private let updateManager = UpdateManager()
    private let recentTransfersKey = "recentTransfers"
    private let legacyRecentTransferKey = "recentTransfer"
    private var contextRefreshTransfers: Set<UUID> = []
    private var retriedTransferIDs: Set<UUID> = []

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
        startupTask = Task { [weak self, runtime] in
            await runtime.weChat.bootstrapCredentials()
            guard let self else { return }
            if let startupError = await runtime.weChat.startupError() {
                presentedError = "无法读取微信凭据：\(startupError)"
            }
            do {
                try LaunchAtLogin.migrateIfRequested()
            } catch {
                presentedError = "迁移登录时启动设置失败：\(error.localizedDescription)"
            }
            refreshLaunchAtLogin()
            if weChatCredentialSource == .openClaw {
                await refreshOpenClawAccounts()
            } else {
                await refreshServices()
            }
        }
        Task { [weak self] in
            guard let self else { return }
            await refreshAllUpdateStatuses()
        }
    }

    /// 主界面“可用”只看微信登录；本地 HTTP 接口是可选能力。
    var isReady: Bool {
        weChatStatus.isOnline
    }

    var hasActiveTransfers: Bool {
        recentTransfers.contains { $0.status == .queued || $0.status == .sending }
    }

    var blocksPopoverAutoClose: Bool {
        isLoggingIn
            || needsVerificationCode
            || loginQRCodeContent != nil
            || isUpdateOperationInProgress
            || hasPendingContextRefresh
            || appUpdateNotice != nil
            || presentedError != nil
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }

    var isUpdateOperationInProgress: Bool {
        isUpdatingApp || isInstallingPremierePlugin || isInstallingDaVinciScripts
    }

    var appUpdateSubtitle: String {
        if !updateMessage.isEmpty { return updateMessage }
        if isCheckingAppUpdate { return "正在检查新版本…" }
        guard let appUpdateAvailability else { return "无法获取最新版本，请重试" }
        switch appUpdateAvailability {
        case let .current(version):
            return "已是最新版本 v\(version)"
        case let .updateAvailable(version):
            return "发现新版本 v\(version)"
        }
    }

    var appUpdateButtonTitle: String {
        if isCheckingAppUpdate { return "检查中" }
        if case let .updateAvailable(version)? = appUpdateAvailability {
            return "更新到 v\(version)"
        }
        return appUpdateAvailability == nil ? "重试检查" : "重新检查"
    }

    var isAppUpdateBusy: Bool {
        isCheckingAppUpdate
            || isCheckingPremierePlugin
            || isCheckingDaVinciScripts
            || isUpdatingApp
    }

    var hasAppUpdate: Bool {
        if case .updateAvailable? = appUpdateAvailability { true } else { false }
    }

    var premierePluginSubtitle: String {
        if !premierePluginMessage.isEmpty { return premierePluginMessage }
        if isCheckingPremierePlugin { return "正在检查已安装版本…" }
        guard let premierePluginUpdateState else { return "无法获取插件版本，请重试" }
        switch premierePluginUpdateState {
        case let .notInstalled(latest):
            return "未安装 · 可安装 v\(latest)"
        case let .repairRequired(latest):
            return "本地插件无法识别 · 可修复为 v\(latest)"
        case let .updateAvailable(installed, latest):
            return "当前 v\(installed) · 可更新至 v\(latest)"
        case let .current(version):
            return "已是最新版本 v\(version)"
        case let .localNewer(installed, latest):
            return "本地 v\(installed) · 在线最新 v\(latest)，不会降级"
        }
    }

    var premierePluginButtonTitle: String {
        if isCheckingPremierePlugin { return "检查中" }
        guard let premierePluginUpdateState else { return "重试检查" }
        switch premierePluginUpdateState {
        case .notInstalled:
            return "安装"
        case .repairRequired:
            return "修复"
        case .updateAvailable:
            return "更新"
        case .current:
            return "重新安装"
        case .localNewer:
            return "本地版本较新"
        }
    }

    var isPremierePluginBusy: Bool {
        isCheckingPremierePlugin || isInstallingPremierePlugin
    }

    var isPremierePluginActionDisabled: Bool {
        if isUpdateOperationInProgress || isCheckingPremierePlugin { return true }
        if case .localNewer? = premierePluginUpdateState { return true }
        return false
    }

    var daVinciScriptsSubtitle: String {
        if !daVinciScriptsMessage.isEmpty { return daVinciScriptsMessage }
        if isCheckingDaVinciScripts { return "正在检查已安装版本…" }
        guard let daVinciScriptsUpdateState else { return "无法获取脚本版本，请重试" }
        switch daVinciScriptsUpdateState {
        case let .notInstalled(latest):
            return "未安装 · 可安装 v\(latest)"
        case let .repairRequired(latest):
            return "本地脚本无法识别 · 可修复为 v\(latest)"
        case let .updateAvailable(installed, latest):
            return "当前 v\(installed) · 可更新至 v\(latest)"
        case let .current(version):
            return "已是最新版本 v\(version)"
        case let .localNewer(installed, latest):
            return "本地 v\(installed) · 在线最新 v\(latest)，不会降级"
        }
    }

    var daVinciScriptsButtonTitle: String {
        if isCheckingDaVinciScripts { return "检查中" }
        guard let daVinciScriptsUpdateState else { return "重试检查" }
        switch daVinciScriptsUpdateState {
        case .notInstalled:
            return "安装"
        case .repairRequired:
            return "修复"
        case .updateAvailable:
            return "更新"
        case .current:
            return "重新安装"
        case .localNewer:
            return "本地版本较新"
        }
    }

    var isDaVinciScriptsBusy: Bool {
        isCheckingDaVinciScripts || isInstallingDaVinciScripts
    }

    var isDaVinciScriptsActionDisabled: Bool {
        if isUpdateOperationInProgress || isCheckingDaVinciScripts { return true }
        if case .localNewer? = daVinciScriptsUpdateState { return true }
        return false
    }

    var sendingTransferCount: Int {
        recentTransfers.count { $0.status == .sending }
    }

    var queuedTransferCount: Int {
        recentTransfers.count { $0.status == .queued }
    }

    var displayedTransfers: [TransferRecord] {
        recentTransfers.sorted { lhs, rhs in
            let lhsPriority = Self.displayPriority(lhs.status)
            let rhsPriority = Self.displayPriority(rhs.status)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            if lhs.isTerminal { return lhs.date > rhs.date }
            return lhs.date < rhs.date
        }
    }

    var hasPendingContextRefresh: Bool {
        !contextRefreshTransfers.isEmpty
    }

    func setAutoRenameMP4ToM4V(_ enabled: Bool) {
        autoRenameMP4ToM4V = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettings.autoRenameMP4Key)
    }

    func setSendSizeLimit(_ limit: SendSizeLimit) {
        sendSizeLimit = limit
        UserDefaults.standard.set(limit.rawValue, forKey: AppSettings.sendSizeLimitMegabytesKey)
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

    func updateApp() {
        guard
            !isUpdateOperationInProgress,
            !isCheckingAppUpdate,
            !isCheckingPremierePlugin,
            !isCheckingDaVinciScripts
        else { return }
        guard !hasActiveTransfers else {
            presentedError = "当前有正在处理的文件，请发送完成后再更新 App"
            return
        }
        guard let currentVersion = ReleaseVersion(tag: appVersion) else {
            presentedError = "无法识别当前 App 版本：\(appVersion)"
            return
        }
        isUpdatingApp = true
        updateMessage = "正在检查更新…"
        Task { [weak self] in
            guard let self else { return }
            do {
                await updateManager.invalidateReleaseCache()
                let result = try await updateManager.prepareAppUpdate(
                    currentVersion: currentVersion,
                    appURL: Bundle.main.bundleURL,
                    currentProcessID: ProcessInfo.processInfo.processIdentifier
                )
                switch result {
                case .alreadyCurrent:
                    appUpdateAvailability = .current(currentVersion)
                    updateMessage = "已是最新版本 v\(currentVersion)"
                    isUpdatingApp = false
                case let .replacementScheduled(release):
                    updateMessage = "已下载 \(release.tagName)，正在重启…"
                    runtime.server.stop()
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                isUpdatingApp = false
                updateMessage = "更新失败"
                presentedError = "App 更新失败：\(error.localizedDescription)"
            }
        }
    }

    func dismissAppUpdateNotice() {
        guard let appUpdateNotice else { return }
        UserDefaults.standard.set(
            appUpdateNotice.version.description,
            forKey: AppSettings.appUpdateNoticeSeenVersionKey
        )
        self.appUpdateNotice = nil
    }

    func showAppUpdateDetails() {
        dismissAppUpdateNotice()
        showsServices = true
    }

    func refreshAllUpdateStatuses(forceRefresh: Bool = false) async {
        guard
            !isUpdateOperationInProgress,
            !isCheckingAppUpdate,
            !isCheckingPremierePlugin,
            !isCheckingDaVinciScripts
        else { return }
        if forceRefresh {
            await updateManager.invalidateReleaseCache()
        }
        async let appUpdate: Void = refreshAppUpdateStatus()
        async let premiere: Void = refreshPremierePluginStatus()
        async let daVinci: Void = refreshDaVinciScriptsStatus()
        _ = await (appUpdate, premiere, daVinci)
    }

    func refreshAppUpdateStatus() async {
        guard !isUpdatingApp else { return }
        guard let currentVersion = ReleaseVersion(tag: appVersion) else {
            isCheckingAppUpdate = false
            updateMessage = "开发版本不检查在线更新"
            return
        }
        isCheckingAppUpdate = true
        updateMessage = ""
        do {
            appUpdateAvailability = try await updateManager.appUpdateAvailability(
                currentVersion: currentVersion
            )
            let release = try await updateManager.latestRelease()
            appUpdateNotice = AppUpdateNotice(
                release: release,
                currentVersion: currentVersion,
                seenVersion: UserDefaults.standard.string(
                    forKey: AppSettings.appUpdateNoticeSeenVersionKey
                ) ?? ""
            )
        } catch {
            appUpdateAvailability = nil
            appUpdateNotice = nil
            updateMessage = "无法检查更新：\(error.localizedDescription)"
        }
        isCheckingAppUpdate = false
    }

    func installPremierePlugin() {
        guard !isUpdateOperationInProgress, !isCheckingPremierePlugin else { return }
        guard premierePluginUpdateState != nil else {
            Task { [weak self] in
                await self?.refreshPremierePluginStatus()
            }
            return
        }
        if case .localNewer? = premierePluginUpdateState { return }
        isInstallingPremierePlugin = true
        premierePluginMessage = "正在下载、校验并安装…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let version = try await updateManager.installPremierePlugin()
                premierePluginUpdateState = .current(version)
                premierePluginMessage = "已安装 v\(version)，请重启 Premiere Pro"
                isInstallingPremierePlugin = false
            } catch {
                isInstallingPremierePlugin = false
                premierePluginMessage = "安装失败"
                presentedError = "Premiere 插件安装失败：\(error.localizedDescription)"
            }
        }
    }

    func refreshPremierePluginStatus() async {
        guard !isInstallingPremierePlugin else { return }
        isCheckingPremierePlugin = true
        premierePluginMessage = ""
        do {
            premierePluginUpdateState = try await updateManager.premierePluginUpdateState()
        } catch {
            premierePluginUpdateState = nil
            premierePluginMessage = "无法检查插件版本：\(error.localizedDescription)"
        }
        isCheckingPremierePlugin = false
    }

    func installDaVinciScripts() {
        guard !isUpdateOperationInProgress, !isCheckingDaVinciScripts else { return }
        guard daVinciScriptsUpdateState != nil else {
            Task { [weak self] in
                await self?.refreshDaVinciScriptsStatus()
            }
            return
        }
        if case .localNewer? = daVinciScriptsUpdateState { return }
        isInstallingDaVinciScripts = true
        daVinciScriptsMessage = "正在下载、校验并安装…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let version = try await updateManager.installDaVinciScripts()
                let directoryURL = await updateManager.daVinciScriptsDirectoryURL()
                daVinciScriptsUpdateState = .current(version)
                daVinciScriptsMessage =
                    "已安装 v\(version)，请重启 DaVinci Resolve。路径：\(Self.displayPath(directoryURL))"
                isInstallingDaVinciScripts = false
            } catch {
                isInstallingDaVinciScripts = false
                daVinciScriptsMessage = "安装失败"
                presentedError = "DaVinci 脚本安装失败：\(error.localizedDescription)"
            }
        }
    }

    var canRevealDaVinciScripts: Bool {
        if isDaVinciScriptsBusy { return false }
        switch daVinciScriptsUpdateState {
        case .current?, .updateAvailable?, .localNewer?, .repairRequired?:
            return true
        case .notInstalled?, nil:
            return false
        }
    }

    func revealDaVinciScripts() {
        guard canRevealDaVinciScripts else { return }
        Task { [weak self] in
            guard let self else { return }
            let directoryURL = await updateManager.daVinciScriptsDirectoryURL()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                presentedError = "未找到 DaVinci 脚本目录：\(Self.displayPath(directoryURL))"
                return
            }
            let scriptURLs = UpdateManager.daVinciScriptNames.map {
                directoryURL.appendingPathComponent($0)
            }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if scriptURLs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(scriptURLs)
            }
        }
    }

    func refreshDaVinciScriptsStatus() async {
        guard !isInstallingDaVinciScripts else { return }
        isCheckingDaVinciScripts = true
        daVinciScriptsMessage = ""
        do {
            daVinciScriptsUpdateState = try await updateManager.daVinciScriptsUpdateState()
        } catch {
            daVinciScriptsUpdateState = nil
            daVinciScriptsMessage = "无法检查脚本版本：\(error.localizedDescription)"
        }
        isCheckingDaVinciScripts = false
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

    func setWeChatCredentialSource(_ source: WeChatCredentialSource) {
        guard source != weChatCredentialSource else { return }
        credentialSourceTask?.cancel()
        credentialSourceRevision += 1
        let revision = credentialSourceRevision
        cancelWeChatLogin()
        weChatCredentialSource = source
        UserDefaults.standard.set(source.rawValue, forKey: AppSettings.weChatCredentialSourceKey)
        credentialSourceTask = Task { [weak self] in
            guard let self else { return }
            if source == .openClaw {
                await refreshOpenClawAccounts()
                return
            }
            await runtime.weChat.setCredentialSource(
                .weClawSend,
                openClawAccountID: nil,
                revision: revision
            )
            guard !Task.isCancelled,
                  credentialSourceRevision == revision,
                  weChatCredentialSource == source else { return }
            await refreshServices()
        }
    }

    func selectOpenClawAccount(_ accountID: String) {
        guard weChatCredentialSource == .openClaw,
              accountID != selectedOpenClawAccountID else { return }
        credentialSourceTask?.cancel()
        credentialSourceRevision += 1
        let revision = credentialSourceRevision
        selectedOpenClawAccountID = accountID
        UserDefaults.standard.set(accountID, forKey: AppSettings.openClawAccountIDKey)
        credentialSourceTask = Task { [weak self] in
            guard let self else { return }
            await runtime.weChat.setCredentialSource(
                .openClaw,
                openClawAccountID: accountID,
                revision: revision
            )
            guard !Task.isCancelled,
                  credentialSourceRevision == revision,
                  weChatCredentialSource == .openClaw,
                  selectedOpenClawAccountID == accountID else { return }
            await refreshServices()
        }
    }

    func refreshOpenClawAccounts() async {
        guard weChatCredentialSource == .openClaw else { return }
        let revision = credentialSourceRevision
        isLoadingOpenClawAccounts = true
        defer { isLoadingOpenClawAccounts = false }
        do {
            let accounts = try await runtime.weChat.availableOpenClawAccounts()
            guard !Task.isCancelled,
                  credentialSourceRevision == revision,
                  weChatCredentialSource == .openClaw else { return }
            openClawAccounts = accounts
            if !accounts.contains(where: { $0.id == selectedOpenClawAccountID }) {
                if accounts.count == 1, let accountID = accounts.first?.id {
                    selectedOpenClawAccountID = accountID
                    UserDefaults.standard.set(accountID, forKey: AppSettings.openClawAccountIDKey)
                } else {
                    selectedOpenClawAccountID = ""
                    UserDefaults.standard.removeObject(forKey: AppSettings.openClawAccountIDKey)
                }
            }
            await runtime.weChat.setCredentialSource(
                .openClaw,
                openClawAccountID: selectedOpenClawAccountID.isEmpty ? nil : selectedOpenClawAccountID,
                revision: revision
            )
            guard !Task.isCancelled,
                  credentialSourceRevision == revision,
                  weChatCredentialSource == .openClaw else { return }
            await refreshServices()
        } catch {
            guard !Task.isCancelled,
                  credentialSourceRevision == revision,
                  weChatCredentialSource == .openClaw else { return }
            openClawAccounts = []
            weChatStatus = .offline
            presentedError = error.localizedDescription
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

    func sendOpened(urls: [URL]) async {
        await startupTask?.value
        send(urls: urls)
    }

    private func enqueue(_ requests: [SendRequest]) {
        for request in requests {
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await runtime.coordinator.send(request)
                } catch {
                    if !isSendCancellation(error) {
                        presentedError = sendFailureMessage(error)
                    }
                }
                await refreshServices()
            }
        }
    }

    func cancel(_ transfer: TransferRecord) {
        guard transfer.status == .queued || transfer.status == .sending else { return }
        Task {
            _ = await runtime.coordinator.cancel(transferID: transfer.id)
        }
    }

    func beginWeChatLogin() {
        guard loginTask == nil else { return }
        isLoggingIn = true
        loginStep = .scanAndConfirm
        weChatStatus = .checking
        needsVerificationCode = false
        verificationCode = ""
        loginQRCodeContent = nil
        loginMessage = "① 正在生成微信登录二维码…"
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                loginQRCodeContent = try await runtime.weChat.startLogin()
                loginMessage = "① 使用微信扫码并在手机上确认"
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
        loginStep = nil
        Task { [weak self] in await self?.refreshServices() }
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
        loginMessage = "① 正在验证手机配对码…"
        loginTask = Task { [weak self] in
            guard let self else { return }
            await pollLogin(runtime: runtime, verificationCode: code)
        }
    }

    func revealTransfer(_ transfer: TransferRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([transfer.fileURL])
    }

    private static func displayPath(_ url: URL) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }

    func retry(_ transfer: TransferRecord) {
        guard transfer.status == .failed else { return }
        guard weChatStatus.isOnline else {
            showsServices = true
            presentedError = "请先登录微信后再重新发送"
            return
        }
        guard retriedTransferIDs.insert(transfer.id).inserted else { return }
        objectWillChange.send()
        enqueue([SendRequest(filePath: transfer.path, fileName: transfer.fileName)])
    }

    func wasRetried(_ transfer: TransferRecord) -> Bool {
        retriedTransferIDs.contains(transfer.id)
    }

    func clearFinishedTransfers() {
        recentTransfers.removeAll(where: \.isTerminal)
        retriedTransferIDs.removeAll()
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
                        showTransientNotice("请给 ClawBot 发送任意消息，收到后会自动继续发送")
                        onContextRefreshRequired?()
                    }
                case let .completed(record):
                    insertTransfer(record)
                    persistTransfers()
                    if contextRefreshTransfers.remove(record.id) != nil {
                        showTransientNotice("微信会话已刷新，文件已自动重新发送")
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
        var terminalCount = 0
        recentTransfers.removeAll { transfer in
            guard transfer.isTerminal else { return false }
            terminalCount += 1
            return terminalCount > Self.maxRecentTransfers
        }
        retriedTransferIDs.formIntersection(recentTransfers.map(\.id))
    }

    private func updateTransfer(_ record: TransferRecord) {
        if let index = recentTransfers.firstIndex(where: { $0.id == record.id }) {
            recentTransfers[index] = record
        } else {
            insertTransfer(record)
        }
    }

    private func showTransientNotice(_ message: String) {
        transientNoticeTask?.cancel()
        transientNotice = message
        transientNoticeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard let self, transientNotice == message else { return }
            transientNotice = nil
            transientNoticeTask = nil
        }
    }

    private static func displayPriority(_ status: TransferRecord.Status) -> Int {
        switch status {
        case .sending: 0
        case .queued: 1
        case .failed: 2
        case .sent: 3
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
        let startedAt = Date()
        var hasScanned = false
        do {
            while !Task.isCancelled {
                if WeChatLoginPollingPolicy.hasTimedOut(startedAt: startedAt) {
                    throw WeChatError.login(
                        WeChatLoginPollingPolicy.timeoutMessage(hasScanned: hasScanned)
                    )
                }
                let update = try await runtime.weChat.pollLogin(verificationCode: code)
                switch update {
                case .waiting:
                    loginMessage = hasScanned
                        ? "① 已扫码，等待手机确认"
                        : "① 等待微信扫码并确认"
                case .scanned:
                    hasScanned = true
                    code = nil
                    loginMessage = "① 已扫码，请在手机上确认"
                case .needsVerification:
                    needsVerificationCode = true
                    loginMessage = "请输入手机微信显示的配对码"
                    isLoggingIn = false
                    loginTask = nil
                    return
                case let .confirmed(credentials):
                    loginQRCodeContent = nil
                    loginStep = .bindConversation
                    loginMessage = "② 打开 ClawBot，发送任意一条消息完成会话绑定"
                    weChatStatus = .checking
                    needsVerificationCode = false
                    try await runtime.weChat.waitForLoginBinding(credentials: credentials)
                    loginStep = .connected
                    loginMessage = "③ 已连接，可以发送文件"
                    isLoggingIn = false
                    loginTask = nil
                    await refreshServices()
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
        } catch is CancellationError {
            // cancelled by user
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            // URLSession can surface task cancellation as URLError.cancelled.
        } catch {
            finishLogin(error: error)
        }
    }

    private func finishLogin(error: Error) {
        isLoggingIn = false
        loginTask = nil
        loginQRCodeContent = nil
        loginMessage = ""
        loginStep = nil
        needsVerificationCode = false
        presentedError = error.localizedDescription
        Task { [weak self] in await self?.refreshServices() }
    }
}
