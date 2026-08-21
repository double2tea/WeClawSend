import Foundation
import ServiceManagement

enum SendSizeLimit: Int, CaseIterable, Identifiable, Sendable {
    case megabytes100 = 100
    case megabytes200 = 200
    case megabytes500 = 500
    case gigabyte1 = 1_024
    case gigabytes2 = 2_048

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .megabytes100: "100 MB"
        case .megabytes200: "200 MB"
        case .megabytes500: "500 MB"
        case .gigabyte1: "1 GB"
        case .gigabytes2: "2 GB"
        }
    }

    var byteCount: Int64 {
        Int64(rawValue) * 1_024 * 1_024
    }
}

enum ShelfShakeSensitivity: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        }
    }
}

enum SendDefaultBehavior: String, CaseIterable, Identifiable, Sendable {
    case immediate
    case askEveryTime = "ask_every_time"
    case fixedDelay = "fixed_delay"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .immediate: "立即发送"
        case .askEveryTime: "每次询问"
        case .fixedDelay: "固定延时"
        }
    }
}

enum LocalAPISendBehavior: String, CaseIterable, Identifiable, Sendable {
    case direct
    case fileBasket = "file_basket"

    var id: String { rawValue }
}

enum ScheduledSendPreset: Int, CaseIterable, Identifiable, Sendable {
    case tenSeconds = 10
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120
    case threeMinutes = 180
    case fiveMinutes = 300
    case tenMinutes = 600

    var id: Int { rawValue }

    var compactTitle: String {
        switch self {
        case .tenSeconds: "10 秒"
        case .fifteenSeconds: "15 秒"
        case .thirtySeconds: "30 秒"
        case .oneMinute: "1 分钟"
        case .twoMinutes: "2 分钟"
        case .threeMinutes: "3 分钟"
        case .fiveMinutes: "5 分钟"
        case .tenMinutes: "10 分钟"
        }
    }

    var title: String { "\(compactTitle)后" }

    func scheduledAt(relativeTo now: Date = .now) -> Date {
        now.addingTimeInterval(TimeInterval(rawValue))
    }
}

enum ScheduledSendDelay {
    static let minimumSeconds = ScheduledSendPreset.tenSeconds.rawValue
    static let maximumCustomMinutes = 10_080
    static let defaultSeconds = ScheduledSendPreset.oneMinute.rawValue

    static func seconds(customMinutes: Int) -> Int? {
        guard (1...maximumCustomMinutes).contains(customMinutes) else { return nil }
        return customMinutes * 60
    }

    static func isValid(seconds: Int) -> Bool {
        (minimumSeconds...(maximumCustomMinutes * 60)).contains(seconds)
    }

    static func compactTitle(seconds: Int) -> String {
        if let preset = ScheduledSendPreset(rawValue: seconds) {
            return preset.compactTitle
        }
        if seconds.isMultiple(of: 60) {
            return "\(seconds / 60) 分钟"
        }
        return "\(seconds) 秒"
    }
}

enum AppSettings {
    static let autoRenameMP4Key = "AutoRenameMP4ToM4V"
    static let localAPIEnabledKey = "LocalAPIEnabled"
    static let localAPISendBehaviorKey = "LocalAPISendBehavior"
    static let sendResultNotificationsEnabledKey = "SendResultNotificationsEnabled"
    static let sendSizeLimitMegabytesKey = "SendSizeLimitMegabytes"
    static let sendDefaultBehaviorKey = "SendDefaultBehavior"
    static let sendDefaultDelaySecondsKey = "SendDefaultDelaySeconds"
    static let scheduledSendLaunchHintShownKey = "ScheduledSendLaunchHintShown"
    static let migrateLaunchAtLoginKey = "MigrateLaunchAtLogin"
    static let launchMigrationCompleteKey = "LaunchAtLoginMigrationComplete"
    static let portfolioSeenVersionKey = "PortfolioSeenVersion"
    static let appUpdateNoticeSeenVersionKey = "AppUpdateNoticeSeenVersion"
    static let appUpdateChannelKey = "AppUpdateChannel"
    static let updateCheckCountLastReportedAtKey = "UpdateCheckCountLastReportedAt"
    static let weChatCredentialSourceKey = "WeChatCredentialSource"
    static let openClawAccountIDKey = "OpenClawAccountID"
    static let shelfEnabledKey = "ShelfEnabled"
    static let shelfShakeToOpenEnabledKey = "ShelfShakeToOpenEnabled"
    static let shelfShakeSensitivityKey = "ShelfShakeSensitivity"
    static let shelfGlobalShortcutEnabledKey = "ShelfGlobalShortcutEnabled"
    static let shelfGlobalShortcutKeyCodeKey = "ShelfGlobalShortcutKeyCode"
    static let shelfGlobalShortcutModifiersKey = "ShelfGlobalShortcutModifiers"
    static let shelfGlobalShortcutLabelKey = "ShelfGlobalShortcutLabel"
    static let shelfAlwaysOnTopKey = "ShelfAlwaysOnTop"
    static let shelfKeepItemsOnCloseKey = "ShelfKeepItemsOnClose"
    static let shelfRestoreOnLaunchKey = "ShelfRestoreOnLaunch"
    static let shelfClearAfterSendKey = "ShelfClearAfterSend"
    static let shelfStoredItemsKey = "ShelfStoredItems"
    static let shelfWindowOriginKey = "ShelfWindowOrigin"
    static let fileBasketArchiveKey = "FileBasketArchive"
    static let folderWatchEnabledKey = "FolderWatchEnabled"

    private static func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }

    static var localAPIEnabled: Bool {
        guard UserDefaults.standard.object(forKey: localAPIEnabledKey) != nil else { return false }
        return UserDefaults.standard.bool(forKey: localAPIEnabledKey)
    }

    static var localAPISendBehavior: LocalAPISendBehavior {
        guard let stored = UserDefaults.standard.string(forKey: localAPISendBehaviorKey) else {
            return .direct
        }
        return LocalAPISendBehavior(rawValue: stored) ?? .direct
    }

    static var folderWatchEnabled: Bool {
        bool(forKey: folderWatchEnabledKey, default: false)
    }

    /// Default on: users can turn off system banners for send results.
    static var sendResultNotificationsEnabled: Bool {
        guard UserDefaults.standard.object(forKey: sendResultNotificationsEnabledKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: sendResultNotificationsEnabledKey)
    }

    static var sendSizeLimit: SendSizeLimit {
        let stored = UserDefaults.standard.integer(forKey: sendSizeLimitMegabytesKey)
        return SendSizeLimit(rawValue: stored) ?? .megabytes200
    }

    static var sendDefaultBehavior: SendDefaultBehavior {
        guard let stored = UserDefaults.standard.string(forKey: sendDefaultBehaviorKey) else {
            return .immediate
        }
        return SendDefaultBehavior(rawValue: stored) ?? .immediate
    }

    static var sendDefaultDelaySeconds: Int {
        let stored = UserDefaults.standard.integer(forKey: sendDefaultDelaySecondsKey)
        return ScheduledSendDelay.isValid(seconds: stored)
            ? stored
            : ScheduledSendDelay.defaultSeconds
    }

    static var maxSendBytes: Int64 {
        sendSizeLimit.byteCount
    }

    static func appUpdateChannel(default defaultChannel: AppUpdateChannel) -> AppUpdateChannel {
        guard let stored = UserDefaults.standard.string(forKey: appUpdateChannelKey) else {
            return defaultChannel
        }
        return AppUpdateChannel(rawValue: stored) ?? defaultChannel
    }

    static var shelfEnabled: Bool {
        bool(forKey: shelfEnabledKey, default: true)
    }

    static var shelfShakeToOpenEnabled: Bool {
        bool(forKey: shelfShakeToOpenEnabledKey, default: true)
    }

    static var shelfShakeSensitivity: ShelfShakeSensitivity {
        guard let stored = UserDefaults.standard.string(forKey: shelfShakeSensitivityKey) else {
            return .medium
        }
        return ShelfShakeSensitivity(rawValue: stored) ?? .medium
    }

    static var shelfGlobalShortcutEnabled: Bool {
        bool(forKey: shelfGlobalShortcutEnabledKey, default: true)
    }

    static var shelfGlobalShortcut: ShelfGlobalShortcut {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: shelfGlobalShortcutKeyCodeKey) != nil,
              defaults.object(forKey: shelfGlobalShortcutModifiersKey) != nil,
              let shortcut = ShelfGlobalShortcut(
                  keyCode: UInt32(defaults.integer(forKey: shelfGlobalShortcutKeyCodeKey)),
                  modifiers: UInt32(defaults.integer(forKey: shelfGlobalShortcutModifiersKey)),
                  keyLabel: defaults.string(forKey: shelfGlobalShortcutLabelKey)
              )
        else {
            return .default
        }
        return shortcut
    }

    static var shelfAlwaysOnTop: Bool {
        bool(forKey: shelfAlwaysOnTopKey, default: true)
    }

    static var shelfKeepItemsOnClose: Bool {
        bool(forKey: shelfKeepItemsOnCloseKey, default: true)
    }

    static var shelfRestoreOnLaunch: Bool {
        bool(forKey: shelfRestoreOnLaunchKey, default: false)
    }

    static var shelfClearAfterSend: Bool {
        bool(forKey: shelfClearAfterSendKey, default: true)
    }

    static var weChatCredentialSource: WeChatCredentialSource {
        guard let rawValue = UserDefaults.standard.string(forKey: weChatCredentialSourceKey) else {
            return .weClawSend
        }
        return WeChatCredentialSource(rawValue: rawValue) ?? .weClawSend
    }

    static var openClawAccountID: String? {
        UserDefaults.standard.string(forKey: openClawAccountIDKey)
    }

    static func outgoingFileName(_ fileName: String) -> String {
        guard
            UserDefaults.standard.bool(forKey: autoRenameMP4Key),
            (fileName as NSString).pathExtension.caseInsensitiveCompare("mp4") == .orderedSame
        else {
            return fileName
        }
        return (fileName as NSString).deletingPathExtension + ".m4v"
    }
}

@MainActor
enum LaunchAtLogin {
    enum Transition: Equatable {
        case none
        case register
        case unregister
        case unsupported
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        switch transition(for: service.status, enabled: enabled) {
        case .register:
            try service.register()
        case .unregister:
            try service.unregister()
        case .none:
            break
        case .unsupported:
            throw CocoaError(.featureUnsupported)
        }
    }

    nonisolated static func transition(for status: SMAppService.Status, enabled: Bool) -> Transition {
        if enabled {
            switch status {
            case .notRegistered, .notFound: .register
            case .enabled, .requiresApproval: .none
            @unknown default: .unsupported
            }
        } else {
            switch status {
            case .enabled, .requiresApproval: .unregister
            case .notRegistered, .notFound: .none
            @unknown default: .unsupported
            }
        }
    }

    static func migrateIfRequested() throws {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppSettings.migrateLaunchAtLoginKey) else { return }
        defer { defaults.removeObject(forKey: AppSettings.migrateLaunchAtLoginKey) }
        try setEnabled(true)
        guard isEnabled else {
            throw CocoaError(.featureUnsupported)
        }
        defaults.set(true, forKey: AppSettings.launchMigrationCompleteKey)
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
