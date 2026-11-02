import Foundation

enum CLIInstallStatus: Equatable, Sendable {
    case installed
    case needsAuthorization
    case conflict
    case unavailable
    case failed
    case cancelled

    var description: String {
        switch self {
        case .installed: "已安装"
        case .needsAuthorization: "需要授权安装"
        case .conflict: "命令已被占用"
        case .unavailable: "App 未安装或缺少命令"
        case .failed: "安装失败，请重试"
        case .cancelled: "已取消授权"
        }
    }
}

enum CLIInstaller {
    static let binDirectory = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)

    static func install(appURL: URL, binDirectory: URL, replaceExisting: Bool = false, fileManager: FileManager = .default) -> CLIInstallStatus {
        let binary = appURL.appendingPathComponent("Contents/MacOS/weclaw")
        let link = binDirectory.appendingPathComponent("weclaw")
        guard fileManager.isExecutableFile(atPath: binary.path) else { return .unavailable }
        if let existing = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
            if URL(fileURLWithPath: existing, relativeTo: binDirectory).standardizedFileURL == binary.standardizedFileURL {
                return .installed
            }
            if !replaceExisting { return .conflict }
        } else if fileManager.fileExists(atPath: link.path) {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: link.path, isDirectory: &isDirectory)
            if !replaceExisting || isDirectory.boolValue { return .conflict }
        }
        do {
            if replaceExisting,
               fileManager.fileExists(atPath: link.path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try fileManager.removeItem(at: link)
            }
            try fileManager.createSymbolicLink(at: link, withDestinationURL: binary)
            return .installed
        } catch {
            return .needsAuthorization
        }
    }

    static func applicationURL() -> URL? {
        let app = Bundle.main.bundleURL.standardizedFileURL
        let installedPaths = [
            "/Applications/WeClaw Send.app",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/WeClaw Send.app").path
        ]
        return installedPaths.contains(app.path) ? app : nil
    }

    static func installFromApplication() -> CLIInstallStatus {
        guard let app = applicationURL() else { return .unavailable }
        return install(appURL: app, binDirectory: binDirectory)
    }

    static func installWithAuthorization(appURL: URL, binDirectory: URL, replaceExisting: Bool = false) -> CLIInstallStatus {
        let initial = install(appURL: appURL, binDirectory: binDirectory, replaceExisting: replaceExisting)
        guard initial == .needsAuthorization else { return initial }
        let binary = appURL.appendingPathComponent("Contents/MacOS/weclaw").path
        let link = binDirectory.appendingPathComponent("weclaw").path
        let script = """
        on run argv
            set sourcePath to item 1 of argv
            set linkPath to item 2 of argv
            if item 3 of argv is "replace" then
                set preparation to "/bin/rm -f " & quoted form of linkPath
            else
                set preparation to "test ! -e " & quoted form of linkPath & " && test ! -L " & quoted form of linkPath
            end if
            do shell script preparation & " && /bin/ln -s " & quoted form of sourcePath & " " & quoted form of linkPath with administrator privileges
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--", binary, link, replaceExisting ? "replace" : "create"]
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failed
        }
        if process.terminationStatus != 0 {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if message.contains("(-128)") { return .cancelled }
            let status = install(appURL: appURL, binDirectory: binDirectory)
            return status == .needsAuthorization ? .failed : status
        }
        return install(appURL: appURL, binDirectory: binDirectory)
    }
}
