import CoreServices
import Foundation

/// Events emitted by the folder watcher. The callbacks are invoked on the watcher's
/// private serial queue; callers that update UI should hop to the main actor.
enum FolderWatchServiceStatus: Sendable, Equatable {
    case monitoring
    case stopped
    case rootUnavailable(ruleID: UUID, path: String)
    case rootAvailable(ruleID: UUID, path: String)
    case eventsLost
    case batchLimitExceeded(ruleID: UUID, count: Int)
    case streamCreationFailed
}

/// A single, event-driven watcher shared by all enabled folder rules.
///
/// FSEvents only tells us that a path changed. The service therefore performs a
/// small, targeted readiness check for each candidate instead of scanning a
/// watched directory. The first check happens three seconds after the last
/// event for a path, followed by a one-second size/mtime comparison.
final class FolderWatchService: @unchecked Sendable {
    typealias FileReadyHandler = @Sendable (UUID, URL) -> Void
    typealias StatusHandler = @Sendable (FolderWatchServiceStatus) -> Void

    private struct CandidateKey: Hashable {
        let ruleID: UUID
        let path: String
    }

    private struct FileSignature: Equatable {
        let size: Int64
        let modifiedAt: Date
    }

    private struct PendingCandidate {
        let url: URL
        let token: UUID
        let workItem: DispatchWorkItem
    }

    private let fileReady: FileReadyHandler
    private let status: StatusHandler
    private let queue = DispatchQueue(label: "com.weclawsend.folder-watch", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private var stream: FSEventStreamRef?
    private var rulesByID: [UUID: FolderWatchRule] = [:]
    private var rootsByRuleID: [UUID: URL] = [:]
    private var pending: [CandidateKey: PendingCandidate] = [:]
    private var handled: Set<CandidateKey> = []
    private var unavailableRuleIDs: Set<UUID> = []
    private var isRunning = false

    init(
        onFileReady: @escaping FileReadyHandler,
        onStatus: @escaping StatusHandler = { _ in }
    ) {
        self.fileReady = onFileReady
        self.status = onStatus
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        performOnQueue { [self] in
            stopOnQueue(emitStatus: false)
        }
    }

    /// Starts (or restarts) one shared stream for the supplied rules.
    func start(rules: [FolderWatchRule]) {
        performOnQueue { [self] in
            configureOnQueue(rules: rules, markRunning: true)
        }
    }

    /// Replaces the current rule set and rebuilds the one shared stream.
    func update(rules: [FolderWatchRule]) {
        performOnQueue { [self] in
            configureOnQueue(rules: rules, markRunning: true)
        }
    }

    /// Stops the stream and cancels only the watcher's pending readiness checks.
    func stop() {
        performOnQueue { [self] in
            stopOnQueue(emitStatus: true)
        }
    }

    private func performOnQueue(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private func configureOnQueue(rules: [FolderWatchRule], markRunning: Bool) {
        stopOnQueue(emitStatus: false)
        isRunning = markRunning
        rulesByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        rootsByRuleID = Dictionary(uniqueKeysWithValues: rules.map {
            ($0.id, URL(fileURLWithPath: $0.folderPath).standardizedFileURL)
        })
        handled.removeAll(keepingCapacity: true)
        unavailableRuleIDs.removeAll(keepingCapacity: true)
        reportRootAvailabilityOnQueue()

        let enabledRules = rules.filter(\.enabled)
        guard !enabledRules.isEmpty else {
            if markRunning { status(.monitoring) }
            return
        }

        let paths = Array(Set(enabledRules.compactMap { rootsByRuleID[$0.id]?.path }))
        guard !paths.isEmpty else {
            if markRunning { status(.monitoring) }
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagIgnoreSelf
        )
        guard let createdStream = FSEventStreamCreate(
            nil,
            Self.eventCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else {
            status(.streamCreationFailed)
            return
        }

        stream = createdStream
        FSEventStreamSetDispatchQueue(createdStream, queue)
        guard FSEventStreamStart(createdStream) else {
            FSEventStreamSetDispatchQueue(createdStream, nil)
            FSEventStreamInvalidate(createdStream)
            FSEventStreamRelease(createdStream)
            stream = nil
            status(.streamCreationFailed)
            return
        }
        status(.monitoring)
    }

    private func stopOnQueue(emitStatus: Bool) {
        for candidate in pending.values {
            candidate.workItem.cancel()
        }
        pending.removeAll(keepingCapacity: true)

        if let currentStream = stream {
            FSEventStreamStop(currentStream)
            FSEventStreamSetDispatchQueue(currentStream, nil)
            FSEventStreamInvalidate(currentStream)
            FSEventStreamRelease(currentStream)
            stream = nil
        }
        rulesByID.removeAll(keepingCapacity: true)
        rootsByRuleID.removeAll(keepingCapacity: true)
        handled.removeAll(keepingCapacity: true)
        unavailableRuleIDs.removeAll(keepingCapacity: true)
        isRunning = false
        if emitStatus { status(.stopped) }
    }

    private static let eventCallback: FSEventStreamCallback = {
        _, clientCallBackInfo, numberOfEvents, eventPaths, eventFlags, _ in
        guard let clientCallBackInfo else { return }
        let service = Unmanaged<FolderWatchService>
            .fromOpaque(clientCallBackInfo)
            .takeUnretainedValue()
        service.handle(
            numberOfEvents: numberOfEvents,
            eventPaths: eventPaths,
            eventFlags: eventFlags
        )
    }

    private func handle(
        numberOfEvents: Int,
        eventPaths: UnsafeMutableRawPointer?,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        guard isRunning, numberOfEvents > 0, let eventPaths else { return }
        let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        var batchCounts: [UUID: Int] = [:]
        var reportedBatchLimit = Set<UUID>()
        var batchKeys = Set<CandidateKey>()

        for index in 0..<numberOfEvents {
            let flags = eventFlags[index]
            reportEventLossIfNeeded(flags)
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                reportRootAvailabilityOnQueue()
            }

            let isCreatedOrRenamed = flags & (
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
            ) != 0
            guard isCreatedOrRenamed else { continue }
            let path = String(cString: paths[index])
            let url = URL(fileURLWithPath: path).standardizedFileURL

            for rule in rulesByID.values where rule.enabled {
                guard let root = rootsByRuleID[rule.id], isCandidate(url, in: root, rule: rule) else {
                    continue
                }
                let key = CandidateKey(ruleID: rule.id, path: url.path)
                guard !handled.contains(key), batchKeys.insert(key).inserted else { continue }

                let count = (batchCounts[rule.id] ?? 0) + 1
                batchCounts[rule.id] = count
                guard count <= 20 else {
                    if reportedBatchLimit.insert(rule.id).inserted {
                        status(.batchLimitExceeded(ruleID: rule.id, count: count))
                    }
                    continue
                }
                scheduleCandidate(key: key, url: url)
            }
        }
    }

    private func reportEventLossIfNeeded(_ flags: FSEventStreamEventFlags) {
        let lossFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
        )
        if flags & lossFlags != 0 {
            status(.eventsLost)
        }
    }

    private func isCandidate(_ url: URL, in root: URL, rule: FolderWatchRule) -> Bool {
        let rootPath = root.path
        let candidatePath = url.path
        guard candidatePath != rootPath else { return false }
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath.hasPrefix(rootPrefix) else { return false }

        if !rule.includesSubfolders {
            guard url.deletingLastPathComponent().standardizedFileURL.path == rootPath else {
                return false
            }
        }
        return rule.allowsFile(at: url)
    }

    private func scheduleCandidate(key: CandidateKey, url: URL) {
        pending[key]?.workItem.cancel()
        let token = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            self?.firstStabilityCheck(key: key, token: token)
        }
        pending[key] = PendingCandidate(url: url, token: token, workItem: workItem)
        queue.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }

    private func firstStabilityCheck(key: CandidateKey, token: UUID) {
        guard let pendingCandidate = pending[key], pendingCandidate.token == token else { return }
        guard let rule = rulesByID[key.ruleID], rule.enabled,
              let signature = fileSignature(for: pendingCandidate.url),
              rule.allowsFile(at: pendingCandidate.url) else {
            pending.removeValue(forKey: key)
            return
        }

        let verifyWorkItem = DispatchWorkItem { [weak self] in
            self?.secondStabilityCheck(key: key, token: token, initial: signature)
        }
        pending[key] = PendingCandidate(
            url: pendingCandidate.url,
            token: token,
            workItem: verifyWorkItem
        )
        queue.asyncAfter(deadline: .now() + 1.0, execute: verifyWorkItem)
    }

    private func secondStabilityCheck(
        key: CandidateKey,
        token: UUID,
        initial: FileSignature
    ) {
        guard let pendingCandidate = pending[key], pendingCandidate.token == token else { return }
        guard let rule = rulesByID[key.ruleID], rule.enabled,
              let latest = fileSignature(for: pendingCandidate.url),
              rule.allowsFile(at: pendingCandidate.url) else {
            pending.removeValue(forKey: key)
            return
        }

        guard latest == initial else {
            scheduleCandidate(key: key, url: pendingCandidate.url)
            return
        }

        pending.removeValue(forKey: key)
        guard handled.insert(key).inserted else { return }
        fileReady(rule.id, pendingCandidate.url)
    }

    private func fileSignature(for url: URL) -> FileSignature? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              let modifiedAt = values.contentModificationDate else {
            return nil
        }
        return FileSignature(size: Int64(size), modifiedAt: modifiedAt)
    }

    private func reportRootAvailabilityOnQueue() {
        for rule in rulesByID.values where rule.enabled {
            guard let root = rootsByRuleID[rule.id] else { continue }
            let isAvailable = isDirectory(at: root)
            if isAvailable {
                if unavailableRuleIDs.remove(rule.id) != nil {
                    status(.rootAvailable(ruleID: rule.id, path: root.path))
                }
            } else if unavailableRuleIDs.insert(rule.id).inserted {
                status(.rootUnavailable(ruleID: rule.id, path: root.path))
            }
        }
    }

    private func isDirectory(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
