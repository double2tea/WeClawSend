import Foundation
import SwiftUI

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
        self.items = items.filter { Self.isRegularFile($0.url) }
    }

    @discardableResult
    func add(urls: [URL]) -> Int {
        var knownPaths = Set(items.map(\.path))
        let newItems = urls.compactMap { url -> ShelfItem? in
            let standardizedURL = url.standardizedFileURL
            guard Self.isRegularFile(standardizedURL) else { return nil }
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

    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        onChange?()
    }

    @discardableResult
    func removeUnavailableItems() -> Int {
        let previousCount = items.count
        items.removeAll { !Self.isRegularFile($0.url) }
        let removedCount = previousCount - items.count
        if removedCount > 0 {
            onChange?()
        }
        return removedCount
    }

    static func isRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }
}
