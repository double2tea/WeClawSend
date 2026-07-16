import Foundation
import ServiceManagement

enum AppSettings {
    static let autoRenameMP4Key = "AutoRenameMP4ToM4V"
    static let localAPIEnabledKey = "LocalAPIEnabled"
    static let migrateLaunchAtLoginKey = "MigrateLaunchAtLogin"
    static let launchMigrationCompleteKey = "LaunchAtLoginMigrationComplete"
    static let portfolioSeenVersionKey = "PortfolioSeenVersion"

    static var localAPIEnabled: Bool {
        guard UserDefaults.standard.object(forKey: localAPIEnabledKey) != nil else { return false }
        return UserDefaults.standard.bool(forKey: localAPIEnabledKey)
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
