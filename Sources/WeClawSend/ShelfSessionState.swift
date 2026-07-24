import Foundation
import SwiftUI

enum FileBasketCloseAction: Equatable {
    case hide
    case delete

    static func resolve(isEmpty: Bool, keepItemsOnClose: Bool) -> Self {
        isEmpty || !keepItemsOnClose ? .delete : .hide
    }
}

/// 文件篮窗口会话态：折叠、选中、置顶与短暂反馈。
@MainActor
final class ShelfSessionState: ObservableObject {
    @Published var isCollapsed: Bool
    @Published var isAlwaysOnTop: Bool
    @Published var selectedItemID: UUID?
    @Published private(set) var statusMessage: String?

    private var statusClearTask: Task<Void, Never>?

    init(isCollapsed: Bool = false, isAlwaysOnTop: Bool) {
        self.isCollapsed = isCollapsed
        self.isAlwaysOnTop = isAlwaysOnTop
    }

    func flash(_ message: String, duration: TimeInterval = 1.35) {
        statusClearTask?.cancel()
        statusMessage = message
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    func showStatus(_ message: String) {
        statusClearTask?.cancel()
        statusMessage = message
    }

    func clearStatus() {
        statusClearTask?.cancel()
        statusMessage = nil
    }

    func select(_ id: UUID?) {
        selectedItemID = id
    }

    func ensureSelection(in items: [ShelfItem]) {
        if let selectedItemID, items.contains(where: { $0.id == selectedItemID }) {
            return
        }
        selectedItemID = items.first?.id
    }

    func moveSelection(by offset: Int, in items: [ShelfItem]) {
        guard !items.isEmpty else {
            selectedItemID = nil
            return
        }
        guard let selectedItemID,
              let index = items.firstIndex(where: { $0.id == selectedItemID })
        else {
            self.selectedItemID = items.first?.id
            return
        }
        let next = min(max(index + offset, 0), items.count - 1)
        self.selectedItemID = items[next].id
    }

    func selectedItem(in items: [ShelfItem]) -> ShelfItem? {
        guard let selectedItemID else { return items.first }
        return items.first(where: { $0.id == selectedItemID }) ?? items.first
    }
}
