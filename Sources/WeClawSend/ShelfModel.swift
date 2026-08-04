import Foundation
import SwiftUI

enum ShelfItemKind: Equatable, Sendable {
    case file
    case folder
    case package

    var isDirectory: Bool {
        self == .folder || self == .package
    }
}

struct ShelfItem: Codable, Equatable, Identifiable {
    let id: UUID
    let path: String

    init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }

    var fileName: String {
        url.lastPathComponent
    }

    var kind: ShelfItemKind? {
        Self.kind(for: url)
    }

    var isDirectory: Bool {
        kind?.isDirectory == true
    }

    static func kind(for url: URL) -> ShelfItemKind? {
        guard url.isFileURL else { return nil }
        let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        )
        guard values?.isSymbolicLink != true else { return nil }
        if values?.isRegularFile == true {
            return .file
        }
        if values?.isDirectory == true {
            return values?.isPackage == true ? .package : .folder
        }
        return nil
    }
}

@MainActor
final class ShelfModel: ObservableObject {
    let id: UUID
    let title: String
    @Published private(set) var items: [ShelfItem]
    var onChange: (() -> Void)?

    var urls: [URL] {
        items.map(\.url)
    }

    init(id: UUID = UUID(), title: String = "文件篮", items: [ShelfItem] = []) {
        self.id = id
        self.title = title
        self.items = items.filter { Self.isSupportedItem($0.url) }
    }

    @discardableResult
    func add(urls: [URL]) -> Int {
        var knownPaths = Set(items.map(\.path))
        let newItems = urls.compactMap { url -> ShelfItem? in
            let standardizedURL = url.standardizedFileURL
            guard Self.isSupportedItem(standardizedURL) else { return nil }
            let path = standardizedURL.path
            guard knownPaths.insert(path).inserted else { return nil }
            return ShelfItem(path: path)
        }
        guard !newItems.isEmpty else { return 0 }
        items.append(contentsOf: newItems)
        onChange?()
        return newItems.count
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        onChange?()
    }

    func remove(ids: Set<UUID>) {
        guard items.contains(where: { ids.contains($0.id) }) else { return }
        items.removeAll { ids.contains($0.id) }
        onChange?()
    }

    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        onChange?()
    }

    @discardableResult
    func removeUnavailableItems() -> Int {
        let previousCount = items.count
        items.removeAll { !Self.isSupportedItem($0.url) }
        let removedCount = previousCount - items.count
        if removedCount > 0 {
            onChange?()
        }
        return removedCount
    }

    static func isSupportedItem(_ url: URL) -> Bool {
        ShelfItem.kind(for: url) != nil
    }
}
