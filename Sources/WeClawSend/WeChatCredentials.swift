import Foundation
import Security

enum WeChatCredentialSource: String, CaseIterable, Identifiable, Sendable {
    case weClawSend
    case openClaw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weClawSend: "独立登录"
        case .openClaw: "OpenClaw"
        }
    }
}

struct OpenClawAccount: Identifiable, Equatable, Sendable {
    let id: String
    let userID: String
}

enum OpenClawCredentialsError: LocalizedError {
    case stateNotFound
    case noAccounts
    case accountSelectionRequired
    case accountNotFound(String)
    case invalidAccount(String)
    case contextTokensBeingUpdated
    case credentialsChanged

    var errorDescription: String? {
        switch self {
        case .stateNotFound:
            "未发现 OpenClaw 微信登录，请先在 OpenClaw 中完成登录"
        case .noAccounts:
            "OpenClaw 中没有微信账号"
        case .accountSelectionRequired:
            "OpenClaw 中有多个微信账号，请选择要使用的账号"
        case let .accountNotFound(accountID):
            "OpenClaw 微信账号不存在：\(accountID)"
        case let .invalidAccount(accountID):
            "OpenClaw 微信账号文件无效：\(accountID)"
        case .contextTokensBeingUpdated:
            "OpenClaw 正在更新微信会话"
        case .credentialsChanged:
            "OpenClaw 登录信息已变化，请重新发送文件"
        }
    }
}

/// 只读 OpenClaw 官方微信插件的账号状态；不会复制或修改任何 OpenClaw 文件。
struct OpenClawCredentialStore: Sendable {
    private static let defaultBaseURL = "https://ilinkai.weixin.qq.com"
    private let stateDirectory: URL

    init(stateDirectory: URL? = nil) {
        self.stateDirectory = stateDirectory ?? Self.resolveStateDirectory(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func resolveStateDirectory(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        for key in ["OPENCLAW_STATE_DIR", "CLAWDBOT_STATE_DIR"] {
            if let path = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return homeDirectory.appending(path: ".openclaw", directoryHint: .isDirectory)
    }

    func accounts() throws -> [OpenClawAccount] {
        let accountIDs = try loadAccountIDs()
        return try accountIDs.map { accountID in
            let stored = try loadStoredAccount(accountID)
            guard let userID = Self.nonEmpty(stored.userID) else {
                throw OpenClawCredentialsError.invalidAccount(accountID)
            }
            return OpenClawAccount(id: accountID, userID: userID)
        }
    }

    func load(accountID selectedAccountID: String?) throws -> WeChatCredentials {
        let accountIDs = try loadAccountIDs()
        let accountID: String
        if let selectedAccountID, !selectedAccountID.isEmpty {
            guard accountIDs.contains(selectedAccountID) else {
                throw OpenClawCredentialsError.accountNotFound(selectedAccountID)
            }
            accountID = selectedAccountID
        } else if accountIDs.count == 1, let onlyAccountID = accountIDs.first {
            accountID = onlyAccountID
        } else {
            throw OpenClawCredentialsError.accountSelectionRequired
        }

        let stored = try loadStoredAccount(accountID)
        guard let token = Self.nonEmpty(stored.token),
              let userID = Self.nonEmpty(stored.userID) else {
            throw OpenClawCredentialsError.invalidAccount(accountID)
        }
        let baseURLString = Self.nonEmpty(stored.baseURL) ?? Self.defaultBaseURL
        guard let baseURL = URL(string: baseURLString) else {
            throw OpenClawCredentialsError.invalidAccount(accountID)
        }
        let contextToken = try loadContextTokens(accountID)[userID]
        return try WeChatCredentials(
            botToken: token,
            botID: Self.botID(from: accountID),
            baseURL: baseURL,
            userID: userID,
            contextToken: contextToken
        ).validated()
    }

    private var pluginDirectory: URL {
        stateDirectory.appending(path: "openclaw-weixin", directoryHint: .isDirectory)
    }

    private var accountsDirectory: URL {
        pluginDirectory.appending(path: "accounts", directoryHint: .isDirectory)
    }

    private func loadAccountIDs() throws -> [String] {
        let indexURL = pluginDirectory.appending(path: "accounts.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw OpenClawCredentialsError.stateNotFound
        }
        let accountIDs = try JSONDecoder().decode([String].self, from: Data(contentsOf: indexURL))
        guard !accountIDs.isEmpty else { throw OpenClawCredentialsError.noAccounts }
        return accountIDs
    }

    private func loadStoredAccount(_ accountID: String) throws -> StoredOpenClawAccount {
        let accountIDs = [accountID, Self.rawAccountID(from: accountID)].compactMap { $0 }
        for storedAccountID in accountIDs {
            let url = accountsDirectory.appending(path: "\(storedAccountID).json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                return try JSONDecoder().decode(StoredOpenClawAccount.self, from: Data(contentsOf: url))
            } catch {
                throw OpenClawCredentialsError.invalidAccount(accountID)
            }
        }
        throw OpenClawCredentialsError.accountNotFound(accountID)
    }

    private func loadContextTokens(_ accountID: String) throws -> [String: String] {
        let url = accountsDirectory.appending(path: "\(accountID).context-tokens.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        } catch is DecodingError {
            throw OpenClawCredentialsError.contextTokensBeingUpdated
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
    }

    private static func botID(from accountID: String) -> String {
        rawAccountID(from: accountID) ?? accountID
    }

    private static func rawAccountID(from accountID: String) -> String? {
        if accountID.hasSuffix("-im-bot") {
            return String(accountID.dropLast("-im-bot".count)) + "@im.bot"
        }
        if accountID.hasSuffix("-im-wechat") {
            return String(accountID.dropLast("-im-wechat".count)) + "@im.wechat"
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct StoredOpenClawAccount: Decodable {
    let token: String?
    let baseURL: String?
    let userID: String?

    enum CodingKeys: String, CodingKey {
        case token
        case baseURL = "baseUrl"
        case userID = "userId"
    }
}

struct WeChatCredentials: Codable, Equatable, Sendable {
    let botToken: String
    let botID: String
    let baseURL: URL
    let userID: String
    let contextToken: String?
    let getUpdatesBuffer: String?

    init(
        botToken: String,
        botID: String,
        baseURL: URL,
        userID: String,
        contextToken: String? = nil,
        getUpdatesBuffer: String? = nil
    ) {
        self.botToken = botToken
        self.botID = botID
        self.baseURL = baseURL
        self.userID = userID
        self.contextToken = contextToken
        self.getUpdatesBuffer = getUpdatesBuffer
    }

    func refreshingContext(token: String, buffer: String?) -> Self {
        Self(
            botToken: botToken,
            botID: botID,
            baseURL: baseURL,
            userID: userID,
            contextToken: token,
            getUpdatesBuffer: buffer
        )
    }

    func validated() throws -> Self {
        guard
            !botToken.isEmpty,
            !botID.isEmpty,
            !userID.isEmpty,
            baseURL.scheme == "https"
        else {
            throw CredentialsError.invalidLegacyAccount
        }
        return self
    }
}

enum CredentialsError: LocalizedError {
    case keychain(OSStatus)
    case invalidLegacyAccount
    case fileStore(String)

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            "无法访问登录凭据（Keychain：\(status)）"
        case .invalidLegacyAccount:
            "发现旧版登录文件但无法迁移，请重新扫码登录"
        case let .fileStore(message):
            message
        }
    }
}

/// 凭据存储：默认用 Application Support 文件（0600），避免 ad-hoc 重签后 Keychain 反复弹授权。
/// 仍可一次性从旧 Keychain / WeClaw 账号文件迁移。
struct WeChatCredentialStore: Sendable {
    private static let service = "com.chacha.WeClawSend.weixin"
    private static let account = "credentials"
    private let credentialsFileOverride: URL?

    init(credentialsFileOverride: URL? = nil) {
        self.credentialsFileOverride = credentialsFileOverride
    }

    func load() throws -> WeChatCredentials? {
        if let fileCredentials = try loadFromFile() {
            return fileCredentials
        }
        if credentialsFileOverride != nil {
            return nil
        }
        // 一次性迁移：旧 Keychain（禁止 UI）→ 旧 WeClaw 文件
        if let keychainCredentials = loadFromKeychainNonInteractive() {
            try saveToFile(keychainCredentials)
            deleteKeychainItemQuietly()
            return keychainCredentials
        }
        if let migrated = try loadLegacyAccount() {
            try saveToFile(migrated)
            return migrated
        }
        return nil
    }

    /// 仅从文件迁移源加载。
    func loadLegacyOnly() throws -> WeChatCredentials? {
        try loadLegacyAccount()
    }

    func save(_ credentials: WeChatCredentials) throws {
        try saveToFile(credentials)
        // 不再写入 Keychain，避免重装/重签后的 ACL 弹窗。
        if credentialsFileOverride == nil {
            deleteKeychainItemQuietly()
        }
    }

    // MARK: - Application Support file

    private var credentialsFileURL: URL {
        if let credentialsFileOverride {
            return credentialsFileOverride
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return root
            .appending(path: "WeClawSend", directoryHint: .isDirectory)
            .appending(path: "credentials.json")
    }

    private func loadFromFile() throws -> WeChatCredentials? {
        let url = credentialsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WeChatCredentials.self, from: data).validated()
    }

    private func saveToFile(_ credentials: WeChatCredentials) throws {
        let url = credentialsFileURL
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(credentials)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Keychain (migration / cleanup only)

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
    }

    /// 禁止交互；超时则放弃，绝不弹授权窗。
    private func loadFromKeychainNonInteractive() -> WeChatCredentials? {
        final class Box: @unchecked Sendable {
            var value: WeChatCredentials?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let service = Self.service
        let account = Self.account
        DispatchQueue.global(qos: .userInitiated).async {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationUI as String: "fail"
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data {
                box.value = try? JSONDecoder().decode(WeChatCredentials.self, from: data).validated()
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .milliseconds(400))
        return box.value
    }

    private func deleteKeychainItemQuietly() {
        SecItemDelete(keychainQuery as CFDictionary)
    }

    // MARK: - Legacy WeClaw files

    private func loadLegacyAccount() throws -> WeChatCredentials? {
        let accountsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".davinci-weclaw/home/.weclaw/accounts")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: accountsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return nil
        }

        let accountFiles = files
            .filter {
                $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".sync.json")
            }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }

        for file in accountFiles {
            guard let data = try? Data(contentsOf: file),
                  let legacy = try? JSONDecoder().decode(LegacyAccount.self, from: data),
                  let baseURL = URL(string: legacy.baseURL),
                  let credentials = try? WeChatCredentials(
                    botToken: legacy.botToken,
                    botID: legacy.botID,
                    baseURL: baseURL,
                    userID: legacy.userID
                  ).validated()
            else {
                continue
            }
            return credentials
        }
        return nil
    }
}

private struct LegacyAccount: Decodable {
    let botToken: String
    let botID: String
    let baseURL: String
    let userID: String

    enum CodingKeys: String, CodingKey {
        case botToken = "bot_token"
        case botID = "ilink_bot_id"
        case baseURL = "baseurl"
        case userID = "ilink_user_id"
    }
}
