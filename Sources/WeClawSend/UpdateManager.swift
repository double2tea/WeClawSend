import CryptoKit
import Foundation

struct ReleaseVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(tag: String) {
        let rawValue = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let components = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard
            components.count == 3,
            let major = Int(components[0]),
            let minor = Int(components[1]),
            let patch = Int(components[2]),
            major >= 0,
            minor >= 0,
            patch >= 0
        else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

struct GitHubReleaseAsset: Decodable, Equatable, Sendable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct GitHubRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let htmlURL: URL
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    var version: ReleaseVersion? {
        ReleaseVersion(tag: tagName)
    }

    func asset(named name: String) -> GitHubReleaseAsset? {
        assets.first { $0.name == name }
    }
}

enum UpdateManagerError: LocalizedError {
    case invalidVersion(String)
    case invalidResponse
    case httpStatus(Int)
    case missingAsset(String)
    case missingChecksum(String)
    case invalidChecksum(String)
    case invalidDownloadURL(String)
    case checksumMismatch(String)
    case invalidArchive(String)
    case currentAppNotWritable(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidVersion(tag):
            "无法识别发布版本：\(tag)"
        case .invalidResponse:
            "更新服务器返回了无法识别的数据"
        case let .httpStatus(status):
            "更新服务器请求失败（HTTP \(status)）"
        case let .missingAsset(name):
            "发布包缺少：\(name)"
        case let .missingChecksum(name):
            "校验清单缺少：\(name)"
        case let .invalidChecksum(name):
            "校验清单格式无效：\(name)"
        case let .invalidDownloadURL(name):
            "发布包下载地址无效：\(name)"
        case let .checksumMismatch(name):
            "下载校验失败：\(name)"
        case let .invalidArchive(name):
            "发布包内容无效：\(name)"
        case let .currentAppNotWritable(path):
            "当前 App 所在目录不可写：\(path)。请将 App 移至当前用户可写的“应用程序”目录后重试。"
        case let .commandFailed(message):
            "安装命令失败：\(message)"
        }
    }
}

enum AppUpdateResult: Sendable {
    case alreadyCurrent
    case replacementScheduled(GitHubRelease)
}

actor UpdateManager {
    nonisolated static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/double2tea/WeClawSend/releases/latest"
    )!
    nonisolated static let appArchiveName = "WeClaw-Send.zip"
    nonisolated static let premiereArchiveName = "WeClaw-Send-Premiere-CEP12.zip"
    nonisolated static let daVinciArchiveName = "WeClaw-Send-DaVinci-Resolve.zip"
    nonisolated static let checksumsName = "SHA256SUMS.txt"
    nonisolated static let premiereExtensionID = "com.chacha.WeClawSend.Premiere"
    nonisolated static let daVinciScriptNames = [
        "自动发送ClawBot_M4V文件.py",
        "自动发送ClawBot_MP4视频.py"
    ]

    private let session: URLSession
    private let fileManager: FileManager
    private let latestReleaseURL: URL
    private let homeDirectory: URL
    private let defaultsExecutablePath: String

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        latestReleaseURL: URL = UpdateManager.latestReleaseURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaultsExecutablePath: String = "/usr/bin/defaults"
    ) {
        self.session = session
        self.fileManager = fileManager
        self.latestReleaseURL = latestReleaseURL
        self.homeDirectory = homeDirectory
        self.defaultsExecutablePath = defaultsExecutablePath
    }

    func prepareAppUpdate(
        currentVersion: ReleaseVersion,
        appURL: URL,
        currentProcessID: Int32
    ) async throws -> AppUpdateResult {
        let release = try await latestRelease()
        guard let releaseVersion = release.version else {
            throw UpdateManagerError.invalidVersion(release.tagName)
        }
        guard currentVersion < releaseVersion else {
            return .alreadyCurrent
        }

        let currentAppURL = try writableAppURL(appURL)
        let workDirectory = try makeWorkDirectory()
        var replacementDirectory: URL?
        do {
            let archive = try await verifiedAsset(
                named: Self.appArchiveName,
                in: release,
                workDirectory: workDirectory
            )
            let directory = try fileManager.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: currentAppURL,
                create: true
            )
            replacementDirectory = directory
            try unzip(archive, to: directory)
            let replacementAppURL = directory.appendingPathComponent("WeClaw Send.app", isDirectory: true)
            try validateApp(at: replacementAppURL, version: releaseVersion)
            try fileManager.removeItem(at: workDirectory)
            try launchReplacementHelper(
                currentAppURL: currentAppURL,
                replacementAppURL: replacementAppURL,
                replacementDirectory: directory,
                currentProcessID: currentProcessID
            )
            return .replacementScheduled(release)
        } catch {
            try? fileManager.removeItem(at: workDirectory)
            if let replacementDirectory {
                try? fileManager.removeItem(at: replacementDirectory)
            }
            throw error
        }
    }

    func installPremierePlugin() async throws -> ReleaseVersion {
        let release = try await latestRelease()
        guard let releaseVersion = release.version else {
            throw UpdateManagerError.invalidVersion(release.tagName)
        }
        let workDirectory = try makeWorkDirectory()
        defer { try? fileManager.removeItem(at: workDirectory) }

        let archive = try await verifiedAsset(
            named: Self.premiereArchiveName,
            in: release,
            workDirectory: workDirectory
        )
        let extractedDirectory = workDirectory.appendingPathComponent("premiere", isDirectory: true)
        try unzip(archive, to: extractedDirectory)
        let manifest = extractedDirectory.appendingPathComponent("CSXS/manifest.xml")
        guard
            fileManager.fileExists(atPath: manifest.path),
            let contents = try? String(contentsOf: manifest, encoding: .utf8),
            contents.contains("ExtensionBundleId=\"\(Self.premiereExtensionID)\"")
        else {
            throw UpdateManagerError.invalidArchive(Self.premiereArchiveName)
        }

        let target = homeDirectory
            .appendingPathComponent("Library/Application Support/Adobe/CEP/extensions", isDirectory: true)
            .appendingPathComponent(Self.premiereExtensionID, isDirectory: true)
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try runCommand(
            defaultsExecutablePath,
            arguments: ["write", "com.adobe.CSXS.12", "PlayerDebugMode", "1"]
        )
        try replaceItem(at: target, with: extractedDirectory)
        return releaseVersion
    }

    func installDaVinciScripts() async throws -> ReleaseVersion {
        let release = try await latestRelease()
        guard let releaseVersion = release.version else {
            throw UpdateManagerError.invalidVersion(release.tagName)
        }
        let workDirectory = try makeWorkDirectory()
        defer { try? fileManager.removeItem(at: workDirectory) }

        let archive = try await verifiedAsset(
            named: Self.daVinciArchiveName,
            in: release,
            workDirectory: workDirectory
        )
        let extractedDirectory = workDirectory.appendingPathComponent("davinci", isDirectory: true)
        try unzip(archive, to: extractedDirectory)
        let sourceDirectory = extractedDirectory.appendingPathComponent(
            "davinci-resolve/Deliver",
            isDirectory: true
        )
        let targetDirectory = homeDirectory.appendingPathComponent(
            "Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Deliver",
            isDirectory: true
        )
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        for name in Self.daVinciScriptNames {
            let source = sourceDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else {
                throw UpdateManagerError.invalidArchive(Self.daVinciArchiveName)
            }
            try replaceItem(at: targetDirectory.appendingPathComponent(name), with: source)
        }
        return releaseVersion
    }

    func latestRelease() async throws -> GitHubRelease {
        let (data, response) = try await session.data(for: request(for: latestReleaseURL))
        try validate(response)
        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateManagerError.invalidResponse
        }
    }

    nonisolated static func checksum(for assetName: String, in manifest: String) throws -> String {
        for line in manifest.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == assetName else { continue }
            let checksum = String(fields[0]).lowercased()
            guard checksum.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw UpdateManagerError.invalidChecksum(assetName)
            }
            return checksum
        }
        throw UpdateManagerError.missingChecksum(assetName)
    }

    nonisolated static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func verifiedAsset(
        named name: String,
        in release: GitHubRelease,
        workDirectory: URL
    ) async throws -> URL {
        guard let asset = release.asset(named: name) else {
            throw UpdateManagerError.missingAsset(name)
        }
        guard let checksumAsset = release.asset(named: Self.checksumsName) else {
            throw UpdateManagerError.missingAsset(Self.checksumsName)
        }
        guard
            asset.browserDownloadURL.scheme == "https",
            checksumAsset.browserDownloadURL.scheme == "https"
        else {
            throw UpdateManagerError.invalidDownloadURL(name)
        }
        let (checksumData, checksumResponse) = try await session.data(
            for: request(for: checksumAsset.browserDownloadURL)
        )
        try validate(checksumResponse)
        guard let checksumManifest = String(data: checksumData, encoding: .utf8) else {
            throw UpdateManagerError.invalidChecksum(Self.checksumsName)
        }
        let expectedChecksum = try Self.checksum(for: name, in: checksumManifest)

        let (temporaryURL, response) = try await session.download(for: request(for: asset.browserDownloadURL))
        try validate(response)
        let destinationURL = workDirectory.appendingPathComponent(name)
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        guard try Self.sha256(of: destinationURL) == expectedChecksum else {
            throw UpdateManagerError.checksumMismatch(name)
        }
        return destinationURL
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WeClawSend", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw UpdateManagerError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw UpdateManagerError.httpStatus(response.statusCode)
        }
    }

    private func makeWorkDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "WeClawSend-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writableAppURL(_ appURL: URL) throws -> URL {
        let resolvedURL = appURL.resolvingSymlinksInPath()
        guard
            resolvedURL.pathExtension == "app",
            Bundle(url: resolvedURL)?.bundleIdentifier == "com.chacha.WeClawSend"
        else {
            throw UpdateManagerError.invalidArchive(resolvedURL.lastPathComponent)
        }
        let parent = resolvedURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw UpdateManagerError.currentAppNotWritable(parent.path)
        }
        return resolvedURL
    }

    private func validateApp(at appURL: URL, version: ReleaseVersion) throws {
        guard
            let bundle = Bundle(url: appURL),
            bundle.bundleIdentifier == "com.chacha.WeClawSend",
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version.description
        else {
            throw UpdateManagerError.invalidArchive(Self.appArchiveName)
        }
    }

    private func unzip(_ archive: URL, to directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try runCommand("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, directory.path])
    }

    private func replaceItem(at target: URL, with source: URL) throws {
        let staging = target.deletingLastPathComponent().appendingPathComponent(
            ".\(target.lastPathComponent).install-\(UUID().uuidString)"
        )
        do {
            try fileManager.copyItem(at: source, to: staging)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: target)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func runCommand(_ executablePath: String, arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? executablePath
            throw UpdateManagerError.commandFailed(message)
        }
    }

    private func launchReplacementHelper(
        currentAppURL: URL,
        replacementAppURL: URL,
        replacementDirectory: URL,
        currentProcessID: Int32
    ) throws {
        let script = #"""
        current_app="$1"
        replacement_app="$2"
        replacement_directory="$3"
        current_pid="$4"
        while kill -0 "$current_pid" 2>/dev/null; do sleep 1; done
        backup_app="${current_app}.weclaw-backup"
        rm -rf "$backup_app"
        if ! mv "$current_app" "$backup_app"; then exit 1; fi
        if ! mv "$replacement_app" "$current_app"; then
          mv "$backup_app" "$current_app"
          exit 1
        fi
        rm -rf "$backup_app" "$replacement_directory"
        open "$current_app"
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            script,
            "weclaw-send-update",
            currentAppURL.path,
            replacementAppURL.path,
            replacementDirectory.path,
            String(currentProcessID)
        ]
        try process.run()
    }
}
