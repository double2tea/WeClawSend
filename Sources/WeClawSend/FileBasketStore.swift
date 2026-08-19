import Combine
import Foundation

struct FileBasketWindowState: Codable, Equatable {
    var origin: String?
    var isCollapsed: Bool
    var isAlwaysOnTop: Bool
    var readerWidth: Double? = nil
    var readerHeight: Double? = nil
    var reminderWidth: Double? = nil
    var reminderHeight: Double? = nil
    var reminderItemID: UUID? = nil
}

private struct FileBasketSnapshot: Codable {
    let id: UUID
    let title: String
    let items: [ShelfItem]
    let windowState: FileBasketWindowState
    let color: FileBasketColor?
    let backgroundOpacity: Double?
}

private struct FileBasketArchive: Codable {
    let baskets: [FileBasketSnapshot]
    let recentBasketID: UUID?
}

@MainActor
final class FileBasketStore: ObservableObject {
    @Published private(set) var baskets: [ShelfModel] = []
    @Published private(set) var recentBasketID: UUID?

    var totalItemCount: Int {
        baskets.reduce(0) { $0 + $1.items.count }
    }

    private let defaults: UserDefaults
    private let windowStatePersistenceDelay: Duration
    private var windowStates: [UUID: FileBasketWindowState] = [:]
    private var observations: [UUID: AnyCancellable] = [:]
    private var windowStatePersistenceTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        windowStatePersistenceDelay: Duration = .milliseconds(300)
    ) {
        self.defaults = defaults
        self.windowStatePersistenceDelay = windowStatePersistenceDelay
        guard defaults.bool(forKey: AppSettings.shelfRestoreOnLaunchKey) else { return }
        if let archive = restoreArchive() {
            restore(archive)
        } else {
            migrateLegacyBasket()
        }
    }

    @discardableResult
    func createBasket() -> ShelfModel {
        let basket = ShelfModel(title: nextTitle())
        baskets.append(basket)
        windowStates[basket.id] = FileBasketWindowState(
            origin: nil,
            isCollapsed: false,
            isAlwaysOnTop: defaultAlwaysOnTop
        )
        attach(basket)
        recentBasketID = basket.id
        persistIfNeeded()
        return basket
    }

    func basket(id: UUID) -> ShelfModel? {
        baskets.first { $0.id == id }
    }

    func removeBasket(id: UUID) {
        guard baskets.contains(where: { $0.id == id }) else { return }
        baskets.removeAll { $0.id == id }
        windowStates.removeValue(forKey: id)
        observations.removeValue(forKey: id)
        if recentBasketID == id {
            recentBasketID = baskets.last?.id
        }
        persistIfNeeded()
    }

    func markRecent(id: UUID) {
        guard basket(id: id) != nil, recentBasketID != id else { return }
        recentBasketID = id
        persistIfNeeded()
    }

    func windowState(for id: UUID) -> FileBasketWindowState {
        windowStates[id] ?? FileBasketWindowState(
            origin: nil,
            isCollapsed: false,
            isAlwaysOnTop: defaultAlwaysOnTop
        )
    }

    func updateWindowState(_ state: FileBasketWindowState, for id: UUID) {
        guard basket(id: id) != nil, windowStates[id] != state else { return }
        windowStates[id] = state
        scheduleWindowStatePersistenceIfNeeded()
    }

    func setRestoresItemsOnLaunch(_ enabled: Bool) {
        windowStatePersistenceTask?.cancel()
        windowStatePersistenceTask = nil
        defaults.set(enabled, forKey: AppSettings.shelfRestoreOnLaunchKey)
        if enabled {
            persist()
        } else {
            defaults.removeObject(forKey: AppSettings.fileBasketArchiveKey)
            defaults.removeObject(forKey: AppSettings.shelfStoredItemsKey)
            defaults.removeObject(forKey: AppSettings.shelfWindowOriginKey)
        }
    }

    func flushPendingPersistence() {
        guard windowStatePersistenceTask != nil else { return }
        windowStatePersistenceTask?.cancel()
        windowStatePersistenceTask = nil
        persistIfNeeded()
    }

    private func attach(_ basket: ShelfModel) {
        observations[basket.id] = basket.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        basket.onChange = { [weak self] in
            self?.persistIfNeeded()
        }
    }

    private func nextTitle() -> String {
        let usedTitles = Set(baskets.map(\.title))
        var index = 1
        while usedTitles.contains("文件篮 \(index)") {
            index += 1
        }
        return "文件篮 \(index)"
    }

    private func restoreArchive() -> FileBasketArchive? {
        guard let data = defaults.data(forKey: AppSettings.fileBasketArchiveKey) else { return nil }
        return try? JSONDecoder().decode(FileBasketArchive.self, from: data)
    }

    private func restore(_ archive: FileBasketArchive) {
        for snapshot in archive.baskets {
            let basket = ShelfModel(
                id: snapshot.id,
                title: snapshot.title,
                items: snapshot.items,
                color: snapshot.color ?? .graphite,
                backgroundOpacity: snapshot.backgroundOpacity ?? 0.9
            )
            baskets.append(basket)
            windowStates[basket.id] = snapshot.windowState
            attach(basket)
        }
        if let recentBasketID = archive.recentBasketID, basket(id: recentBasketID) != nil {
            self.recentBasketID = recentBasketID
        } else {
            recentBasketID = baskets.last?.id
        }
        persist()
    }

    private func migrateLegacyBasket() {
        guard
            let data = defaults.data(forKey: AppSettings.shelfStoredItemsKey),
            let items = try? JSONDecoder().decode([ShelfItem].self, from: data)
        else { return }

        let basket = ShelfModel(title: "文件篮 1", items: items)
        baskets = [basket]
        windowStates[basket.id] = FileBasketWindowState(
            origin: defaults.string(forKey: AppSettings.shelfWindowOriginKey),
            isCollapsed: false,
            isAlwaysOnTop: defaultAlwaysOnTop
        )
        attach(basket)
        recentBasketID = basket.id
        persist()
        defaults.removeObject(forKey: AppSettings.shelfStoredItemsKey)
        defaults.removeObject(forKey: AppSettings.shelfWindowOriginKey)
    }

    private func persistIfNeeded() {
        guard defaults.bool(forKey: AppSettings.shelfRestoreOnLaunchKey) else { return }
        windowStatePersistenceTask?.cancel()
        windowStatePersistenceTask = nil
        persist()
    }

    private func scheduleWindowStatePersistenceIfNeeded() {
        guard defaults.bool(forKey: AppSettings.shelfRestoreOnLaunchKey) else { return }
        windowStatePersistenceTask?.cancel()
        windowStatePersistenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: windowStatePersistenceDelay)
            } catch {
                return
            }
            windowStatePersistenceTask = nil
            persist()
        }
    }

    private var defaultAlwaysOnTop: Bool {
        guard defaults.object(forKey: AppSettings.shelfAlwaysOnTopKey) != nil else { return true }
        return defaults.bool(forKey: AppSettings.shelfAlwaysOnTopKey)
    }

    private func persist() {
        let snapshots = baskets.map { basket in
            FileBasketSnapshot(
                id: basket.id,
                title: basket.title,
                items: basket.items,
                windowState: windowState(for: basket.id),
                color: basket.color,
                backgroundOpacity: basket.backgroundOpacity
            )
        }
        let archive = FileBasketArchive(baskets: snapshots, recentBasketID: recentBasketID)
        let data = try? JSONEncoder().encode(archive)
        defaults.set(data, forKey: AppSettings.fileBasketArchiveKey)
    }
}
