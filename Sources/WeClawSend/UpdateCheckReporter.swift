import Foundation

struct UpdateCheckCountPayload: Codable, Equatable, Sendable {
    let version: String
    let build: String
    let channel: String
}

actor UpdateCheckReporter {
    nonisolated static let minimumInterval: TimeInterval = 86_400

    private let endpoint: URL?
    private let payload: UpdateCheckCountPayload?
    private let userDefaults: UserDefaults
    private let session: URLSession
    private var isReporting = false

    init(
        bundle: Bundle = .main,
        userDefaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        if let value = bundle.object(forInfoDictionaryKey: "WeClawUpdateCountEndpoint") as? String {
            endpoint = URL(string: value)
        } else {
            endpoint = nil
        }
        payload = Self.payload(from: bundle)
        self.userDefaults = userDefaults
        self.session = session
    }

    init(
        endpoint: URL?,
        payload: UpdateCheckCountPayload?,
        userDefaults: UserDefaults,
        session: URLSession
    ) {
        self.endpoint = endpoint
        self.payload = payload
        self.userDefaults = userDefaults
        self.session = session
    }

    @discardableResult
    func reportIfNeeded(now: Date = .now) async -> Bool {
        guard !isReporting, let endpoint, let payload else { return false }
        if let lastReportedAt = userDefaults.object(
            forKey: AppSettings.updateCheckCountLastReportedAtKey
        ) as? Date,
           now.timeIntervalSince(lastReportedAt) < Self.minimumInterval {
            return false
        }

        isReporting = true
        defer { isReporting = false }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WeClawSend-UpdateCheck", forHTTPHeaderField: "User-Agent")
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
            userDefaults.set(now, forKey: AppSettings.updateCheckCountLastReportedAtKey)
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func payload(from bundle: Bundle) -> UpdateCheckCountPayload? {
        guard
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            let channel = bundle.object(forInfoDictionaryKey: "WeClawReleaseChannel") as? String,
            ReleaseVersion(tag: version) != nil,
            Int(build).map({ $0 >= 0 }) == true,
            AppUpdateChannel(rawValue: channel) != nil
        else {
            return nil
        }
        return UpdateCheckCountPayload(version: version, build: build, channel: channel)
    }
}
