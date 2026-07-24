import AppKit

@MainActor
final class FileBasketWindowCoordinator {
    private let model: AppModel
    private let chooseFiles: (UUID) -> Void
    private let sendAll: (UUID) -> FileBasketSendResult
    private var controllers: [UUID: ShelfWindowController] = [:]

    init(
        model: AppModel,
        chooseFiles: @escaping (UUID) -> Void,
        sendAll: @escaping (UUID) -> FileBasketSendResult
    ) {
        self.model = model
        self.chooseFiles = chooseFiles
        self.sendAll = sendAll
    }

    @discardableResult
    func createBasket(near point: CGPoint? = nil) -> UUID {
        createBasket(near: point, cascades: true, appearance: .standard)
    }

    @discardableResult
    func createShakeBasket(near point: CGPoint) -> UUID {
        createBasket(near: point, cascades: false, appearance: .shake)
    }

    private func createBasket(
        near point: CGPoint?,
        cascades: Bool,
        appearance: ShelfWindowAppearance
    ) -> UUID {
        let basket = model.fileBaskets.createBasket()
        let cascadeIndex = cascades ? (model.fileBaskets.baskets.count - 1) % 6 : 0
        let cascadedPoint = point.map {
            CGPoint(
                x: $0.x + CGFloat(cascadeIndex * 18),
                y: $0.y - CGFloat(cascadeIndex * 18)
            )
        }
        controller(for: basket).show(
            near: cascadedPoint,
            expanded: true,
            appearance: appearance
        )
        return basket.id
    }

    func show(id: UUID, near point: CGPoint? = nil, expanded: Bool = false) {
        guard let basket = model.fileBaskets.basket(id: id) else { return }
        controller(for: basket).show(
            near: point,
            expanded: expanded,
            appearance: .standard
        )
    }

    func showAll() {
        for basket in model.fileBaskets.baskets {
            controller(for: basket).show()
        }
    }

    func closeAll() {
        let visibleIDs = controllers.compactMap { id, controller in
            controller.isVisible ? id : nil
        }
        visibleIDs.forEach(close)
    }

    func close(id: UUID) {
        guard model.fileBaskets.basket(id: id) != nil else { return }
        let completion: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.completeClose(id: id)
        }
        if let controller = controllers[id], controller.isVisible {
            controller.dismiss(completion: completion)
        } else {
            completion()
        }
    }

    private func completeClose(id: UUID) {
        guard let basket = model.fileBaskets.basket(id: id) else { return }
        switch FileBasketCloseAction.resolve(
            isEmpty: basket.items.isEmpty,
            keepItemsOnClose: model.shelfKeepItemsOnClose
        ) {
        case .hide:
            controllers[id]?.hide()
        case .delete:
            delete(id: id)
        }
    }

    func delete(id: UUID) {
        delete(id: id, dismissal: .standard)
    }

    func deleteAll() {
        model.fileBaskets.baskets.map(\.id).forEach(delete)
    }

    func discardEmptyShakeBasket(id: UUID, toward point: CGPoint) {
        guard controllers[id]?.containsScreenPoint(point) == true else {
            discardEmptyShakeBasketNow(id: id)
            return
        }
        // 鼠标松开监听早于 SwiftUI dropDestination 提交；等落点回调写入模型后再判断。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.discardEmptyShakeBasketNow(id: id)
        }
    }

    private func discardEmptyShakeBasketNow(id: UUID) {
        guard model.fileBaskets.basket(id: id)?.items.isEmpty == true else { return }
        delete(id: id, dismissal: .shake)
    }

    private func delete(
        id: UUID,
        dismissal: ShelfWindowDismissal
    ) {
        guard let controller = controllers[id], controller.isVisible else {
            deleteImmediately(id: id)
            return
        }
        controller.dismiss(style: dismissal) { [weak self] in
            guard let self else { return }
            self.deleteImmediately(id: id)
        }
    }

    private func deleteImmediately(id: UUID) {
        controllers.removeValue(forKey: id)?.hide()
        model.fileBaskets.removeBasket(id: id)
    }

    func toggleRecent() {
        guard let id = model.fileBaskets.recentBasketID else {
            createBasket(near: NSEvent.mouseLocation)
            return
        }
        guard let basket = model.fileBaskets.basket(id: id) else { return }
        let controller = controller(for: basket)
        if controller.isVisible {
            close(id: id)
        } else {
            controller.show(appearance: .standard)
        }
    }

    func applyPreferences() {
        controllers.values.forEach { $0.applyPreferences() }
    }

    private func controller(for basket: ShelfModel) -> ShelfWindowController {
        if let controller = controllers[basket.id] {
            return controller
        }
        let id = basket.id
        let controller = ShelfWindowController(
            model: model,
            basket: basket,
            initialWindowState: model.fileBaskets.windowState(for: id),
            chooseFiles: { [weak self] in self?.chooseFiles(id) },
            sendAll: { [unowned self] in sendAll(id) },
            requestClose: { [weak self] in self?.close(id: id) },
            requestDelete: { [weak self] in self?.delete(id: id) },
            onActivate: { [weak self] in self?.model.fileBaskets.markRecent(id: id) },
            onWindowStateChange: { [weak self] state in
                self?.model.fileBaskets.updateWindowState(state, for: id)
            }
        )
        controllers[id] = controller
        return controller
    }
}
