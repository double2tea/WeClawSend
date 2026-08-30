import CryptoKit
import Foundation

struct AccountPresencePayload: Codable, Equatable, Sendable {
    let accountHash: String
    let version: String
    let build: String
    let channel: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case accountHash = "account_hash"
        case version
        case build
        case channel
        case source
    }
}

actor AccountPresenceReporter {
    nonisolated static let minimumInterval: TimeInterval = 86_400
    nonisolated static let failedAttemptInterval: TimeInterval = 3_600

    private let endpoint: URL?
    private let version: String?
    private let build: String?
    private let channel: String?
    private let userDefaults: UserDefaults
    private let session: URLSession
    private var lastAttemptedAt: [String: Date] = [:]
    private var reportingHashes = Set<String>()

    init(
        bundle: Bundle = .main,
        userDefaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        endpoint = (bundle.object(forInfoDictionaryKey: "WeClawAccountPresenceEndpoint") as? String)
            .flatMap(URL.init(string:))
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        channel = bundle.object(forInfoDictionaryKey: "WeClawReleaseChannel") as? String
        self.userDefaults = userDefaults
        self.session = session
    }

    init(
        endpoint: URL?,
        version: String?,
        build: String?,
        channel: String?,
        userDefaults: UserDefaults,
        session: URLSession
    ) {
        self.endpoint = endpoint
        self.version = version
        self.build = build
        self.channel = channel
        self.userDefaults = userDefaults
        self.session = session
    }

    @discardableResult
    func reportIfNeeded(
        userID: String,
        source: WeChatCredentialSource,
        now: Date = .now
    ) async -> Bool {
        guard
            let endpoint,
            let version,
            let build,
            let channel,
            !userID.isEmpty
        else {
            return false
        }

        let accountHash = Self.anonymousAccountHash(userID: userID)
        guard !reportingHashes.contains(accountHash) else { return false }

        let defaultsKey = "AccountPresenceLastReportedAt.\(accountHash)"
        if let lastReportedAt = userDefaults.object(forKey: defaultsKey) as? Date,
           now.timeIntervalSince(lastReportedAt) >= 0,
           now.timeIntervalSince(lastReportedAt) < Self.minimumInterval {
            return false
        }
        if let attemptedAt = lastAttemptedAt[accountHash],
           now.timeIntervalSince(attemptedAt) >= 0,
           now.timeIntervalSince(attemptedAt) < Self.failedAttemptInterval {
            return false
        }

        lastAttemptedAt[accountHash] = now
        reportingHashes.insert(accountHash)
        defer { reportingHashes.remove(accountHash) }

        let payload = AccountPresencePayload(
            accountHash: accountHash,
            version: version,
            build: build,
            channel: channel,
            source: source.rawValue
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WeClawSend-AccountPresence", forHTTPHeaderField: "User-Agent")
        guard let body = try? JSONEncoder().encode(payload) else { return false }
        request.httpBody = body

        do {
            let (_, response) = try await session.data(for: request)
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200...299).contains(httpResponse.statusCode)
            else {
                return false
            }
            userDefaults.set(now, forKey: defaultsKey)
            return true
        } catch {
            return false
        }
    }

    nonisolated static func anonymousAccountHash(userID: String) -> String {
        SHA256.hash(data: Data("weclaw-account-presence-v1\u{0}\(userID)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
