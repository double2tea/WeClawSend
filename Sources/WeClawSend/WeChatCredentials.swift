import Foundation
import Security

struct WeChatCredentials: Codable, Equatable, Sendable {
    let botToken: String
    let botID: String
    let baseURL: URL
    let userID: String

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

    func load() throws -> WeChatCredentials? {
        if let fileCredentials = try loadFromFile() {
            return fileCredentials
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
        deleteKeychainItemQuietly()
    }

    // MARK: - Application Support file

    private var credentialsFileURL: URL {
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
