import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

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
    let body: String?
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }

    var version: ReleaseVersion? {
        ReleaseVersion(tag: tagName)
    }

    func asset(named name: String) -> GitHubReleaseAsset? {
        assets.first { $0.name == name }
    }
}

struct AppUpdateNotice: Equatable, Sendable {
    let version: ReleaseVersion
    let notes: [String]

    init?(release: GitHubRelease, currentVersion: ReleaseVersion, seenVersion: String) {
        guard let version = release.version, currentVersion < version else { return nil }
        guard seenVersion != version.description else { return nil }
        self.version = version
        notes = Self.notes(from: release.body)
    }

    static func notes(from body: String?) -> [String] {
        guard let body else { return [] }
        return body
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .filter { !$0.localizedCaseInsensitiveContains("Full Changelog") }
            .map { line in
                var text = line
                while let first = text.first, "-*•".contains(first) {
                    text.removeFirst()
                    text = text.trimmingCharacters(in: .whitespaces)
                }
                return text.replacingOccurrences(of: "**", with: "")
            }
            .filter { !$0.isEmpty }
            .prefix(4)
            .map { $0 }
    }
}

struct ReleaseComponents: Equatable, Sendable {
    let app: ReleaseVersion
    let premiere: ReleaseVersion
    let daVinci: ReleaseVersion
}

extension ReleaseComponents: Decodable {
    enum CodingKeys: String, CodingKey {
        case app
        case premiere
        case daVinci = "davinci"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let appText = try values.decode(String.self, forKey: .app)
        let premiereText = try values.decode(String.self, forKey: .premiere)
        let daVinciText = try values.decode(String.self, forKey: .daVinci)
        guard
            let app = ReleaseVersion(tag: appText),
            let premiere = ReleaseVersion(tag: premiereText),
            let daVinci = ReleaseVersion(tag: daVinciText)
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "组件版本格式无效")
            )
        }
        self.init(app: app, premiere: premiere, daVinci: daVinci)
    }
}

enum IntegrationUpdateState: Equatable, Sendable {
    case notInstalled(latest: ReleaseVersion)
    case repairRequired(latest: ReleaseVersion)
    case updateAvailable(installed: ReleaseVersion, latest: ReleaseVersion)
    case current(ReleaseVersion)
    case localNewer(installed: ReleaseVersion, latest: ReleaseVersion)
}

typealias PremierePluginUpdateState = IntegrationUpdateState
typealias DaVinciScriptsUpdateState = IntegrationUpdateState

enum AppUpdateAvailability: Equatable, Sendable {
    case current(ReleaseVersion)
    case updateAvailable(ReleaseVersion)
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
    case premierePluginDowngradeNotAllowed(installed: ReleaseVersion, available: ReleaseVersion)
    case daVinciScriptsDowngradeNotAllowed(installed: ReleaseVersion, available: ReleaseVersion)
    case daVinciScriptsInstallIncomplete(String)
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
        case let .premierePluginDowngradeNotAllowed(installed, available):
            "已安装的 Premiere 插件 v\(installed) 高于在线版本 v\(available)，已阻止降级"
        case let .daVinciScriptsDowngradeNotAllowed(installed, available):
            "已安装的 DaVinci 脚本 v\(installed) 高于在线版本 v\(available)，已阻止降级"
        case let .daVinciScriptsInstallIncomplete(path):
            "DaVinci 脚本安装后校验失败，目标目录缺少完整文件：\(path)"
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
    nonisolated static let componentsName = "WeClaw-Send-Components.json"
    nonisolated static let checksumsName = "SHA256SUMS.txt"
    nonisolated static let premiereExtensionID = "com.chacha.WeClawSend.Premiere"
    nonisolated static let premierePanelExtensionID = "com.chacha.WeClawSend.Premiere.panel"
    nonisolated static let premiereRequiredFiles = [
        "CSXS/manifest.xml",
        "index.html",
        "style.css",
        "js/bridge-client.js",
        "js/main.js",
        "js/preset-library.js",
        "js/protocol.js",
        "jsx/host.jsx"
    ]
    nonisolated static let daVinciScriptNames = [
        "自动发送ClawBot_M4V文件.py",
        "自动发送ClawBot_MP4视频.py"
    ]
    nonisolated static let daVinciVersionFileName = "VERSION"
    nonisolated static let daVinciInstalledVersionFileName = ".weclaw-send-version"
    nonisolated static let metadataRequestTimeout: TimeInterval = 20
    nonisolated static let assetRequestTimeout: TimeInterval = 300
    nonisolated static let releaseCacheDuration: TimeInterval = 300

    private let session: URLSession
    private let fileManager: FileManager
    private let latestReleaseURL: URL
    private let homeDirectory: URL
    private let defaultsExecutablePath: String
    private var cachedRelease: (release: GitHubRelease, date: Date)?
    private var releaseCacheGeneration = 0
    private var ignoresCacheForNextMetadataRequest = false
    private var latestReleaseTask: (generation: Int, task: Task<GitHubRelease, Error>)?
    private var cachedComponents: [String: ReleaseComponents] = [:]

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

    func invalidateReleaseCache() {
        releaseCacheGeneration &+= 1
        cachedRelease = nil
        cachedComponents.removeAll()
        ignoresCacheForNextMetadataRequest = true
        latestReleaseTask?.task.cancel()
        latestReleaseTask = nil
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

    func appUpdateAvailability(currentVersion: ReleaseVersion) async throws -> AppUpdateAvailability {
        let release = try await latestRelease()
        guard let latestVersion = release.version else {
            throw UpdateManagerError.invalidVersion(release.tagName)
        }
        return currentVersion < latestVersion ? .updateAvailable(latestVersion) : .current(currentVersion)
    }

    func premierePluginUpdateState() async throws -> PremierePluginUpdateState {
        let installedVersion: ReleaseVersion?
        let requiresRepair: Bool
        do {
            installedVersion = try installedPremierePluginVersion()
            requiresRepair = false
        } catch let error as UpdateManagerError {
            guard case .invalidArchive = error else { throw error }
            installedVersion = nil
            requiresRepair = true
        }
        let release = try await latestRelease()
        let latestVersion = try await releaseComponents(in: release).premiere
        if requiresRepair { return .repairRequired(latest: latestVersion) }
        return Self.premierePluginUpdateState(installed: installedVersion, latest: latestVersion)
    }

    func installedPremierePluginVersion() throws -> ReleaseVersion? {
        let target = premierePluginURL
        guard fileManager.fileExists(atPath: target.path) else { return nil }
        return try Self.premierePluginVersion(at: target)
    }

    func installPremierePlugin() async throws -> ReleaseVersion {
        let release = try await latestRelease()
        let releaseVersion = try await releaseComponents(in: release).premiere
        let installedVersion: ReleaseVersion?
        do {
            installedVersion = try installedPremierePluginVersion()
        } catch let error as UpdateManagerError {
            guard case .invalidArchive = error else { throw error }
            installedVersion = nil
        }
        if let installedVersion, installedVersion > releaseVersion {
            throw UpdateManagerError.premierePluginDowngradeNotAllowed(
                installed: installedVersion,
                available: releaseVersion
            )
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
        let archiveVersion = try Self.validatePremierePlugin(
            at: extractedDirectory,
            fileManager: fileManager
        )
        guard archiveVersion == releaseVersion else {
            throw UpdateManagerError.invalidArchive(Self.premiereArchiveName)
        }

        let target = premierePluginURL
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try runCommand(
            defaultsExecutablePath,
            arguments: ["write", "com.adobe.CSXS.12", "PlayerDebugMode", "1"]
        )
        try replaceItem(at: target, with: extractedDirectory)
        return try Self.validatePremierePlugin(at: target, fileManager: fileManager)
    }

    func daVinciScriptsUpdateState() async throws -> DaVinciScriptsUpdateState {
        let installedVersion: ReleaseVersion?
        let requiresRepair: Bool
        do {
            installedVersion = try installedDaVinciScriptsVersion()
            requiresRepair = false
        } catch let error as UpdateManagerError {
            guard case .invalidArchive = error else { throw error }
            installedVersion = nil
            requiresRepair = true
        }
        let release = try await latestRelease()
        let latestVersion = try await releaseComponents(in: release).daVinci
        if requiresRepair { return .repairRequired(latest: latestVersion) }
        return Self.integrationUpdateState(installed: installedVersion, latest: latestVersion)
    }

    func installedDaVinciScriptsVersion() throws -> ReleaseVersion? {
        let target = daVinciScriptsURL
        let existingScripts = Self.daVinciScriptNames.filter {
            fileManager.fileExists(atPath: target.appendingPathComponent($0).path)
        }
        guard !existingScripts.isEmpty else { return nil }
        guard existingScripts.count == Self.daVinciScriptNames.count else {
            throw UpdateManagerError.invalidArchive(Self.daVinciArchiveName)
        }
        let versionURL = target.appendingPathComponent(Self.daVinciInstalledVersionFileName)
        guard
            let versionText = try? String(contentsOf: versionURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let version = ReleaseVersion(tag: versionText)
        else {
            throw UpdateManagerError.invalidArchive(Self.daVinciArchiveName)
        }
        return version
    }

    func installDaVinciScripts() async throws -> ReleaseVersion {
        let release = try await latestRelease()
        let releaseVersion = try await releaseComponents(in: release).daVinci
        let installedVersion: ReleaseVersion?
        do {
            installedVersion = try installedDaVinciScriptsVersion()
        } catch let error as UpdateManagerError {
            guard case .invalidArchive = error else { throw error }
            installedVersion = nil
        }
        if let installedVersion, installedVersion > releaseVersion {
            throw UpdateManagerError.daVinciScriptsDowngradeNotAllowed(
                installed: installedVersion,
                available: releaseVersion
            )
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
        let sourceRoot = extractedDirectory.appendingPathComponent("davinci-resolve", isDirectory: true)
        try validateDaVinciScripts(at: sourceRoot, version: releaseVersion)
        let sourceDirectory = sourceRoot.appendingPathComponent("Deliver", isDirectory: true)
        let targetDirectory = daVinciScriptsURL
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        for name in Self.daVinciScriptNames {
            let source = sourceDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else {
                throw UpdateManagerError.invalidArchive(Self.daVinciArchiveName)
            }
            try replaceItem(at: targetDirectory.appendingPathComponent(name), with: source)
        }
        try Data("\(releaseVersion)\n".utf8).write(
            to: targetDirectory.appendingPathComponent(Self.daVinciInstalledVersionFileName),
            options: .atomic
        )
        try verifyInstalledDaVinciScripts(expectedVersion: releaseVersion)
        return releaseVersion
    }

    func daVinciScriptsDirectoryURL() -> URL {
        daVinciScriptsURL
    }

    func latestRelease() async throws -> GitHubRelease {
        if let cachedRelease,
           Date().timeIntervalSince(cachedRelease.date) < Self.releaseCacheDuration {
            return cachedRelease.release
        }
        let generation = releaseCacheGeneration
        if let latestReleaseTask, latestReleaseTask.generation == generation {
            return try await latestReleaseTask.task.value
        }

        let session = self.session
        let ignoresCache = ignoresCacheForNextMetadataRequest
        ignoresCacheForNextMetadataRequest = false
        let request = request(
            for: latestReleaseURL,
            timeoutInterval: Self.metadataRequestTimeout,
            ignoresCache: ignoresCache
        )
        let task = Task<GitHubRelease, Error> {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw UpdateManagerError.invalidResponse
            }
            guard (200...299).contains(response.statusCode) else {
                throw UpdateManagerError.httpStatus(response.statusCode)
            }
            do {
                return try JSONDecoder().decode(GitHubRelease.self, from: data)
            } catch {
                throw UpdateManagerError.invalidResponse
            }
        }
        latestReleaseTask = (generation, task)
        do {
            let release = try await task.value
            if generation == releaseCacheGeneration {
                cachedRelease = (release, Date())
                if latestReleaseTask?.generation == generation {
                    latestReleaseTask = nil
                }
            }
            return release
        } catch {
            if latestReleaseTask?.generation == generation {
                latestReleaseTask = nil
            }
            throw error
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

    nonisolated static func premierePluginUpdateState(
        installed: ReleaseVersion?,
        latest: ReleaseVersion
    ) -> PremierePluginUpdateState {
        integrationUpdateState(installed: installed, latest: latest)
    }

    nonisolated static func integrationUpdateState(
        installed: ReleaseVersion?,
        latest: ReleaseVersion
    ) -> IntegrationUpdateState {
        guard let installed else { return .notInstalled(latest: latest) }
        if installed < latest {
            return .updateAvailable(installed: installed, latest: latest)
        }
        if installed == latest {
            return .current(installed)
        }
        return .localNewer(installed: installed, latest: latest)
    }

    nonisolated static func validatePremierePlugin(
        at directory: URL,
        fileManager: FileManager = .default
    ) throws -> ReleaseVersion {
        let version = try premierePluginVersion(at: directory)
        let requiredFiles = version < ReleaseVersion(tag: "1.6.1")!
            ? Self.premiereRequiredFiles.filter { $0 != "js/bridge-client.js" }
            : Self.premiereRequiredFiles
        for relativePath in requiredFiles {
            var isDirectory: ObjCBool = false
            let path = directory.appendingPathComponent(relativePath).path
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw UpdateManagerError.invalidArchive(Self.premiereArchiveName)
            }
        }
        return version
    }

    nonisolated static func premierePluginVersion(at directory: URL) throws -> ReleaseVersion {
        let manifestURL = directory.appendingPathComponent("CSXS/manifest.xml")
        let document: XMLDocument
        do {
            document = try XMLDocument(contentsOf: manifestURL, options: [])
        } catch {
            throw UpdateManagerError.invalidArchive(Self.premiereArchiveName)
        }
        guard
            let root = document.rootElement(),
            root.name == "ExtensionManifest",
            root.attribute(forName: "ExtensionBundleId")?.stringValue == Self.premiereExtensionID,
            let versionText = root.attribute(forName: "ExtensionBundleVersion")?.stringValue,
            let version = ReleaseVersion(tag: versionText),
            let extensionList = root.elements(forName: "ExtensionList").first,
            let panelExtension = extensionList.elements(forName: "Extension").first(where: {
                $0.attribute(forName: "Id")?.stringValue == Self.premierePanelExtensionID
            }),
            panelExtension.attribute(forName: "Version")?.stringValue == versionText,
            let dispatchInfoList = root.elements(forName: "DispatchInfoList").first,
            dispatchInfoList.elements(forName: "Extension").contains(where: {
                $0.attribute(forName: "Id")?.stringValue == Self.premierePanelExtensionID
            })
        else {
            throw UpdateManagerError.invalidArchive(Self.premiereArchiveName)
        }
        return version
    }

    private var premierePluginURL: URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Adobe/CEP/extensions", isDirectory: true)
            .appendingPathComponent(Self.premiereExtensionID, isDirectory: true)
    }

    private var daVinciScriptsURL: URL {
        homeDirectory.appendingPathComponent(
            "Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Deliver",
            isDirectory: true
        )
    }

    private func releaseComponents(in release: GitHubRelease) async throws -> ReleaseComponents {
        if let cached = cachedComponents[release.tagName] { return cached }
        guard let appVersion = release.version else {
            throw UpdateManagerError.invalidVersion(release.tagName)
        }
        guard release.asset(named: Self.componentsName) != nil else {
            let legacy = ReleaseComponents(
                app: appVersion,
                premiere: appVersion,
                daVinci: appVersion
            )
            cachedComponents[release.tagName] = legacy
            return legacy
        }

        let workDirectory = try makeWorkDirectory()
        defer { try? fileManager.removeItem(at: workDirectory) }
        let componentsURL = try await verifiedAsset(
            named: Self.componentsName,
            in: release,
            workDirectory: workDirectory
        )
        let components: ReleaseComponents
        do {
            components = try JSONDecoder().decode(
                ReleaseComponents.self,
                from: Data(contentsOf: componentsURL)
            )
        } catch {
            throw UpdateManagerError.invalidArchive(Self.componentsName)
        }
        guard components.app == appVersion else {
            throw UpdateManagerError.invalidArchive(Self.componentsName)
        }
        cachedComponents[release.tagName] = components
        return components
    }

    private func validateDaVinciScripts(at root: URL, version: ReleaseVersion) throws {
        let versionURL = root.appendingPathComponent(Self.daVinciVersionFileName)
        guard
            let versionText = try? String(contentsOf: versionURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            ReleaseVersion(tag: versionText) == version
        else {
            throw UpdateManagerError.invalidArchive(Self.daVinciArchiveName)
        }
        let deliver = root.appendingPathComponent("Deliver", isDirectory: true)
        for name in Self.daVinciScriptNames {
            var isDirectory: ObjCBool = false
            let path = deliver.appendingPathComponent(name).path
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw UpdateManagerError.invalidArchive(Self.daVinciArchiveName)
            }
        }
    }

    private func verifyInstalledDaVinciScripts(expectedVersion: ReleaseVersion) throws {
        let target = daVinciScriptsURL
        for name in Self.daVinciScriptNames {
            var isDirectory: ObjCBool = false
            let path = target.appendingPathComponent(name).path
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw UpdateManagerError.daVinciScriptsInstallIncomplete(target.path)
            }
        }
        let versionURL = target.appendingPathComponent(Self.daVinciInstalledVersionFileName)
        guard
            let versionText = try? String(contentsOf: versionURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            ReleaseVersion(tag: versionText) == expectedVersion
        else {
            throw UpdateManagerError.daVinciScriptsInstallIncomplete(target.path)
        }
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
            for: request(
                for: checksumAsset.browserDownloadURL,
                timeoutInterval: Self.metadataRequestTimeout
            )
        )
        try validate(checksumResponse)
        guard let checksumManifest = String(data: checksumData, encoding: .utf8) else {
            throw UpdateManagerError.invalidChecksum(Self.checksumsName)
        }
        let expectedChecksum = try Self.checksum(for: name, in: checksumManifest)

        let (temporaryURL, response) = try await session.download(
            for: request(for: asset.browserDownloadURL, timeoutInterval: Self.assetRequestTimeout)
        )
        try validate(response)
        let destinationURL = workDirectory.appendingPathComponent(name)
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        guard try Self.sha256(of: destinationURL) == expectedChecksum else {
            throw UpdateManagerError.checksumMismatch(name)
        }
        return destinationURL
    }

    private func request(
        for url: URL,
        timeoutInterval: TimeInterval,
        ignoresCache: Bool = false
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutInterval
        if ignoresCache {
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
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
