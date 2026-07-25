import Foundation

enum DiagnosticExportError: LocalizedError {
    case downloadsDirectoryUnavailable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadsDirectoryUnavailable:
            "无法访问下载目录"
        case let .commandFailed(command):
            "生成诊断日志失败：\(command)"
        }
    }
}

enum DiagnosticExporter {
    private static let subsystem = "com.chacha.WeClawSend"
    private static let executableName = "WeClawSend"

    static func export() throws -> URL {
        guard let downloadsDirectory = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first else {
            throw DiagnosticExportError.downloadsDirectoryUnavailable
        }
        return try export(to: downloadsDirectory)
    }

    static func export(to destinationDirectory: URL, now: Date = .now) throws -> URL {
        let fileManager = FileManager.default
        let stagingParent = fileManager.temporaryDirectory
            .appending(path: "WeClawSend-Diagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
        let packageDirectory = stagingParent
            .appending(path: "WeClawSend-Diagnostics", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingParent) }

        try systemReport(now: now).write(
            to: packageDirectory.appending(path: "System.txt"),
            atomically: true,
            encoding: .utf8
        )
        try privacyNotice.write(
            to: packageDirectory.appending(path: "README.txt"),
            atomically: true,
            encoding: .utf8
        )
        try collectUnifiedLog(to: packageDirectory.appending(path: "WeClawSend.log"))
        try copyCrashReports(to: packageDirectory)

        let archiveURL = destinationDirectory.appending(path: archiveName(now: now))
        guard !fileManager.fileExists(atPath: archiveURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try run(
            executable: "/usr/bin/ditto",
            arguments: ["--norsrc", "--noextattr", "-c", "-k", "--keepParent", packageDirectory.path, archiveURL.path]
        )
        return archiveURL
    }

    static func archiveName(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "WeClawSend-Diagnostics-\(formatter.string(from: now)).zip"
    }

    private static func systemReport(now: Date) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let processInfo = ProcessInfo.processInfo
        return """
        WeClaw Send Diagnostics
        Generated: \(ISO8601DateFormatter().string(from: now))
        App: \(version) (\(build))
        macOS: \(processInfo.operatingSystemVersionString)
        Architecture: \(architecture)
        Processor count: \(processInfo.processorCount)
        Active processor count: \(processInfo.activeProcessorCount)
        Physical memory: \(processInfo.physicalMemory)
        """
    }

    private static var architecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    private static let privacyNotice = """
    此诊断包用于排查 WeClaw Send 问题。

    包含：App 与系统版本、最近 24 小时的 WeClaw Send 统一日志、最多 5 份相关崩溃报告。
    不包含：微信凭据、二维码、文件篮内容或文件路径、其他 App 的日志。
    崩溃报告可能包含本机用户名、硬件型号和 App 安装路径，请在提交前自行检查。
    """

    private static func collectUnifiedLog(to destinationURL: URL) throws {
        try run(
            executable: "/usr/bin/log",
            arguments: [
                "show",
                "--last", "24h",
                "--style", "compact",
                "--predicate", "subsystem == \"\(subsystem)\""
            ],
            outputURL: destinationURL
        )
    }

    private static func copyCrashReports(to packageDirectory: URL) throws {
        let fileManager = FileManager.default
        let sourceDirectory = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: sourceDirectory.path) else { return }

        let reports = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
                && name.hasPrefix(executableName)
                && (url.pathExtension == "ips" || url.pathExtension == "crash")
        }
        .sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        .prefix(5)

        guard !reports.isEmpty else { return }
        let destinationDirectory = packageDirectory
            .appending(path: "Crash Reports", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        for report in reports {
            try fileManager.copyItem(
                at: report,
                to: destinationDirectory.appending(path: report.lastPathComponent)
            )
        }
    }

    private static func run(
        executable: String,
        arguments: [String],
        outputURL: URL? = nil
    ) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DiagnosticExportError.commandFailed(URL(fileURLWithPath: executable).lastPathComponent)
        }
        if let outputURL {
            try data.write(to: outputURL, options: .atomic)
        }
    }
}
