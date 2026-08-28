import Foundation

enum FileIntakeSource: String, Sendable {
    case localAPI
    case folderWatch

    fileprivate var priority: Int {
        switch self {
        case .localAPI: 2
        case .folderWatch: 1
        }
    }

    var displayName: String {
        switch self {
        case .localAPI: "本地 API"
        case .folderWatch: "文件夹监控"
        }
    }
}

struct FileIntakeClaim: Equatable, Sendable {
    fileprivate let key: String
    fileprivate let id: UUID
    let source: FileIntakeSource
}

enum FileIntakeClaimDecision: Equatable, Sendable {
    case granted(FileIntakeClaim)
    case denied(existingSource: FileIntakeSource)
}

struct FileIntakeConflictError: LocalizedError, Sendable {
    let existingSource: FileIntakeSource

    var errorDescription: String? {
        "同一文件已由\(existingSource.displayName)处理，本次请求已跳过"
    }
}

actor FileIntakeArbiter {
    static let completionCooldown: TimeInterval = 60
    static let pendingLifetime: TimeInterval = 30
    static let maximumEntries = 256

    private enum State: Sendable {
        case pending(expiresAt: Date)
        case committed
        case completed(expiresAt: Date)
    }

    private struct Entry: Sendable {
        let claim: FileIntakeClaim
        var state: State
        var updatedAt: Date
    }

    private var entries: [String: Entry] = [:]

    func claim(
        fileURL: URL,
        source: FileIntakeSource,
        now: Date = .now
    ) -> FileIntakeClaimDecision {
        prune(now: now)
        let key = Self.identityKey(for: fileURL)
        if let existing = entries[key] {
            switch existing.state {
            case .pending where source.priority > existing.claim.source.priority:
                break
            case .pending, .committed, .completed:
                return .denied(existingSource: existing.claim.source)
            }
        }

        let claim = FileIntakeClaim(key: key, id: UUID(), source: source)
        entries[key] = Entry(
            claim: claim,
            state: .pending(expiresAt: now.addingTimeInterval(Self.pendingLifetime)),
            updatedAt: now
        )
        trimIfNeeded()
        return .granted(claim)
    }

    func commit(_ claim: FileIntakeClaim, now: Date = .now) -> Bool {
        prune(now: now)
        guard var entry = entries[claim.key], entry.claim == claim else { return false }
        entry.state = .committed
        entry.updatedAt = now
        entries[claim.key] = entry
        return true
    }

    func complete(_ claim: FileIntakeClaim, now: Date = .now) {
        guard var entry = entries[claim.key], entry.claim == claim else { return }
        entry.state = .completed(expiresAt: now.addingTimeInterval(Self.completionCooldown))
        entry.updatedAt = now
        entries[claim.key] = entry
    }

    func release(_ claim: FileIntakeClaim) {
        guard entries[claim.key]?.claim == claim else { return }
        entries.removeValue(forKey: claim.key)
    }

    private func prune(now: Date) {
        entries = entries.filter { _, entry in
            switch entry.state {
            case let .pending(expiresAt), let .completed(expiresAt):
                return expiresAt > now
            case .committed:
                return true
            }
        }
    }

    private func trimIfNeeded() {
        guard entries.count > Self.maximumEntries else { return }
        let removableKeys = entries
            .filter { _, entry in
                if case .completed = entry.state { return true }
                return false
            }
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
            .prefix(entries.count - Self.maximumEntries)
            .map(\.key)
        removableKeys.forEach { entries.removeValue(forKey: $0) }
    }

    private static func identityKey(for fileURL: URL) -> String {
        let canonicalURL = fileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let supportsCaseSensitiveNames = try? canonicalURL.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames
        return supportsCaseSensitiveNames == false
            ? canonicalURL.path.lowercased()
            : canonicalURL.path
    }
}
