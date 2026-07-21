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

enum AppSettings {
    static let autoRenameMP4Key = "AutoRenameMP4ToM4V"
    static let localAPIEnabledKey = "LocalAPIEnabled"
    static let sendResultNotificationsEnabledKey = "SendResultNotificationsEnabled"
    static let sendSizeLimitMegabytesKey = "SendSizeLimitMegabytes"
    static let migrateLaunchAtLoginKey = "MigrateLaunchAtLogin"
    static let launchMigrationCompleteKey = "LaunchAtLoginMigrationComplete"
    static let portfolioSeenVersionKey = "PortfolioSeenVersion"
    static let appUpdateNoticeSeenVersionKey = "AppUpdateNoticeSeenVersion"
    static let weChatCredentialSourceKey = "WeChatCredentialSource"
    static let openClawAccountIDKey = "OpenClawAccountID"

    static var localAPIEnabled: Bool {
        guard UserDefaults.standard.object(forKey: localAPIEnabledKey) != nil else { return false }
        return UserDefaults.standard.bool(forKey: localAPIEnabledKey)
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

    static var maxSendBytes: Int64 {
        sendSizeLimit.byteCount
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
