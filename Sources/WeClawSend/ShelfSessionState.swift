import AppKit
import Foundation
import SwiftUI

enum ShelfKeyModifiers {
    static let ignored: NSEvent.ModifierFlags = [.capsLock, .numericPad, .help, .function]

    static func significant(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask).subtracting(ignored)
    }
}

enum FileBasketCloseAction: Equatable {
    case hide
    case delete

    static func resolve(isEmpty: Bool, keepItemsOnClose: Bool) -> Self {
        isEmpty || !keepItemsOnClose ? .delete : .hide
    }
}

enum ShelfMarqueeSelection {
    static func intersectingItemIDs(
        in rect: CGRect,
        itemFrames: [UUID: CGRect]
    ) -> Set<UUID> {
        Set(
            itemFrames.compactMap { id, frame in
                frame.intersects(rect) ? id : nil
            }
        )
    }
}

enum ShelfDisplayMode: Equatable {
    case grid
    case list
}

/// 文件篮窗口会话态：折叠、选中、置顶与短暂反馈。
@MainActor
final class ShelfSessionState: ObservableObject {
    @Published var isCollapsed: Bool
    @Published var isAlwaysOnTop: Bool
    @Published var displayMode: ShelfDisplayMode
    @Published var presentationMode: ShelfPresentationMode = .collection
    @Published private(set) var isPresentationReady = true
    @Published private(set) var selectedItemID: UUID?
    @Published private(set) var selectedItemIDs: Set<UUID> = []
    @Published private(set) var focusedItemID: UUID?
    @Published private(set) var requestedTextEditorItemID: UUID?
    @Published private(set) var statusMessage: String?
    @Published private(set) var removalRequestGeneration = 0

    private var statusClearTask: Task<Void, Never>?
    private var selectionAnchorID: UUID?
    private var collectionSelectionSnapshot: Set<UUID> = []
    private var pendingRemovedURLs: [URL] = []

    init(
        isCollapsed: Bool = false,
        isAlwaysOnTop: Bool,
        displayMode: ShelfDisplayMode = .grid
    ) {
        self.isCollapsed = isCollapsed
        self.isAlwaysOnTop = isAlwaysOnTop
        self.displayMode = displayMode
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

    func requestSelectedItemRemoval() {
        removalRequestGeneration &+= 1
    }

    func select(_ id: UUID?) {
        selectedItemID = id
        selectedItemIDs = id.map { [$0] } ?? []
        selectionAnchorID = id
    }

    func select(
        _ id: UUID,
        in items: [ShelfItem],
        extending: Bool,
        toggling: Bool
    ) {
        guard items.contains(where: { $0.id == id }) else { return }
        if extending,
           let anchorID = selectionAnchorID ?? selectedItemID,
           let anchorIndex = items.firstIndex(where: { $0.id == anchorID }),
           let targetIndex = items.firstIndex(where: { $0.id == id })
        {
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            selectedItemIDs = Set(range.map { items[$0].id })
            selectedItemID = id
            return
        }
        if toggling {
            if selectedItemIDs.contains(id) {
                selectedItemIDs.remove(id)
                selectedItemID = items.first(where: { selectedItemIDs.contains($0.id) })?.id
                selectionAnchorID = selectedItemID
            } else {
                selectedItemIDs.insert(id)
                selectedItemID = id
                selectionAnchorID = id
            }
            return
        }
        select(id)
    }

    func setSelection(_ ids: Set<UUID>, in items: [ShelfItem]) {
        let availableIDs = Set(items.map(\.id))
        selectedItemIDs = ids.intersection(availableIDs)
        if selectedItemID.map(selectedItemIDs.contains) != true {
            selectedItemID = items.first(where: { selectedItemIDs.contains($0.id) })?.id
        }
        selectionAnchorID = selectedItemID
    }

    func selectAll(in items: [ShelfItem]) {
        selectedItemIDs = Set(items.map(\.id))
        if let selectedItemID, selectedItemIDs.contains(selectedItemID) {
            selectionAnchorID = selectedItemID
        } else {
            selectedItemID = items.first?.id
            selectionAnchorID = selectedItemID
        }
    }

    func ensureSelection(in items: [ShelfItem]) {
        let availableIDs = Set(items.map(\.id))
        selectedItemIDs.formIntersection(availableIDs)
        if !selectedItemIDs.isEmpty {
            if let selectedItemID, selectedItemIDs.contains(selectedItemID) {
                if selectionAnchorID.map(availableIDs.contains) != true {
                    selectionAnchorID = selectedItemID
                }
                return
            }
            selectedItemID = items.first(where: { selectedItemIDs.contains($0.id) })?.id
            selectionAnchorID = selectedItemID
            return
        }
        select(items.first?.id)
    }

    func moveSelection(by offset: Int, in items: [ShelfItem]) {
        guard !items.isEmpty else {
            select(nil)
            return
        }
        guard let selectedItemID,
              let index = items.firstIndex(where: { $0.id == selectedItemID })
        else {
            select(items.first?.id)
            return
        }
        let next = min(max(index + offset, 0), items.count - 1)
        select(items[next].id)
    }

    func selectedItem(in items: [ShelfItem]) -> ShelfItem? {
        guard let selectedItemID else { return nil }
        return items.first(where: { $0.id == selectedItemID })
    }

    func selectedItems(in items: [ShelfItem]) -> [ShelfItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    func focusedItem(in items: [ShelfItem]) -> ShelfItem? {
        guard let focusedItemID else { return nil }
        return items.first { $0.id == focusedItemID }
    }

    @discardableResult
    func enterReader(itemID: UUID, in items: [ShelfItem]) -> Bool {
        guard items.contains(where: { $0.id == itemID }) else { return false }
        let changesMode = presentationMode != .reader
        if presentationMode == .collection {
            collectionSelectionSnapshot = selectedItemIDs
        }
        focusedItemID = itemID
        if changesMode {
            isPresentationReady = false
        }
        presentationMode = .reader
        isCollapsed = false
        return true
    }

    @discardableResult
    func enterReminder(itemID: UUID, in items: [ShelfItem]) -> Bool {
        guard items.contains(where: { $0.id == itemID }) else { return false }
        let changesMode = presentationMode != .reminder
        if presentationMode == .collection {
            collectionSelectionSnapshot = selectedItemIDs
        }
        focusedItemID = itemID
        if changesMode {
            isPresentationReady = false
        }
        presentationMode = .reminder
        isCollapsed = false
        return true
    }

    @discardableResult
    func requestTextEditing(itemID: UUID, in items: [ShelfItem]) -> Bool {
        guard enterReader(itemID: itemID, in: items) else { return false }
        requestedTextEditorItemID = itemID
        return true
    }

    func consumeTextEditingRequest(for itemID: UUID) {
        guard requestedTextEditorItemID == itemID else { return }
        requestedTextEditorItemID = nil
    }

    func returnToCollection(in items: [ShelfItem]) {
        if presentationMode != .collection {
            isPresentationReady = false
        }
        presentationMode = .collection
        focusedItemID = nil
        requestedTextEditorItemID = nil
        let availableIDs = Set(items.map(\.id))
        let restoredSelection = collectionSelectionSnapshot.intersection(availableIDs)
        collectionSelectionSnapshot = []
        if restoredSelection.isEmpty {
            ensureSelection(in: items)
        } else {
            setSelection(restoredSelection, in: items)
        }
    }

    func completePresentationTransition() {
        isPresentationReady = true
    }

    @discardableResult
    func moveFocus(by offset: Int, in items: [ShelfItem]) -> ShelfItem? {
        guard !items.isEmpty else { return nil }
        let currentIndex = focusedItemID.flatMap { id in
            items.firstIndex { $0.id == id }
        } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), items.count - 1)
        focusedItemID = items[nextIndex].id
        return items[nextIndex]
    }

    @discardableResult
    func ensureFocusedItem(in items: [ShelfItem]) -> Bool {
        guard presentationMode != .collection else { return true }
        guard let focusedItemID, items.contains(where: { $0.id == focusedItemID }) else {
            returnToCollection(in: items)
            return false
        }
        return true
    }

    func markPendingRemoval(urls: [URL]) {
        pendingRemovedURLs = urls
    }

    func clearPendingRemoval() {
        pendingRemovedURLs = []
    }

    @discardableResult
    func consumePendingRemovalURLs() -> [URL] {
        let urls = pendingRemovedURLs
        pendingRemovedURLs = []
        return urls
    }

    func dragItems(startingAt id: UUID, in items: [ShelfItem]) -> [ShelfItem] {
        if selectedItemIDs.contains(id) {
            return selectedItems(in: items)
        }
        select(id)
        return items.filter { $0.id == id }
    }
}
