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

enum FileBasketColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case graphite
    case blue
    case green
    case orange
    case pink
    case purple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .graphite: "石墨"
        case .blue: "蓝色"
        case .green: "绿色"
        case .orange: "橙色"
        case .pink: "粉色"
        case .purple: "紫色"
        }
    }

    var color: Color {
        switch self {
        case .graphite: Color.primary
        case .blue: Color(red: 0.22, green: 0.48, blue: 0.86)
        case .green: Color(red: 0.20, green: 0.58, blue: 0.38)
        case .orange: Color(red: 0.88, green: 0.48, blue: 0.16)
        case .pink: Color(red: 0.86, green: 0.36, blue: 0.55)
        case .purple: Color(red: 0.50, green: 0.36, blue: 0.82)
        }
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

    var isTextDocument: Bool {
        guard kind == .file else { return false }
        return switch url.pathExtension.lowercased() {
        case "txt", "md", "markdown": true
        default: false
        }
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
    @Published private(set) var title: String
    @Published private(set) var items: [ShelfItem]
    @Published private(set) var color: FileBasketColor
    @Published private(set) var backgroundOpacity: Double
    var onChange: (() -> Void)?

    var urls: [URL] {
        items.map(\.url)
    }

    init(
        id: UUID = UUID(),
        title: String = "文件篮",
        items: [ShelfItem] = [],
        color: FileBasketColor = .graphite,
        backgroundOpacity: Double = 0.9
    ) {
        self.id = id
        self.title = title
        self.items = items.filter { Self.isSupportedItem($0.url) }
        self.color = color
        self.backgroundOpacity = Self.normalizedOpacity(backgroundOpacity)
    }

    @discardableResult
    func rename(to proposedTitle: String) -> Bool {
        let normalized = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != title else { return false }
        title = normalized
        onChange?()
        return true
    }

    func setAppearance(color: FileBasketColor, backgroundOpacity: Double) {
        let normalizedOpacity = Self.normalizedOpacity(backgroundOpacity)
        guard self.color != color || self.backgroundOpacity != normalizedOpacity else { return }
        self.color = color
        self.backgroundOpacity = normalizedOpacity
        onChange?()
    }

    func itemContentDidChange() {
        objectWillChange.send()
        onChange?()
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

    func restore(items restoredItems: [ShelfItem], at originalIndexes: [Int]) {
        guard restoredItems.count == originalIndexes.count else { return }
        var updatedItems = items
        var knownPaths = Set(updatedItems.map(\.path))
        for (item, index) in zip(restoredItems, originalIndexes).sorted(by: { $0.1 < $1.1 }) {
            guard Self.isSupportedItem(item.url), knownPaths.insert(item.path).inserted else { continue }
            updatedItems.insert(item, at: min(max(index, 0), updatedItems.count))
        }
        guard updatedItems != items else { return }
        items = updatedItems
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

    private static func normalizedOpacity(_ value: Double) -> Double {
        min(max(value, 0.55), 1)
    }
}
