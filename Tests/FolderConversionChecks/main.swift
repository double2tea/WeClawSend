import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct FolderConversionChecks {
    @MainActor
    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("weclaw-folder-check-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let folder = root.appendingPathComponent("素材")
        let nested = folder.appendingPathComponent("子目录/更深")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let first = folder.appendingPathComponent("同名.png")
        let second = nested.appendingPathComponent("同名.png")
        try png.write(to: first)
        try png.write(to: second)
        try Data("skip".utf8).write(to: folder.appendingPathComponent("说明.txt"))
        try manager.createSymbolicLink(at: folder.appendingPathComponent("链接.png"), withDestinationURL: first)
        try manager.createSymbolicLink(at: folder.appendingPathComponent("目录链接"), withDestinationURL: nested)
        let package = folder.appendingPathComponent("忽略.app")
        try manager.createDirectory(at: package, withIntermediateDirectories: true)
        try png.write(to: package.appendingPathComponent("内部.png"))
        var settings = BasketConversionSettings()
        settings.outputFolder = root.appendingPathComponent("outputs")
        settings.besideOriginal = false
        settings.nameSuffix = "-转换"
        settings.keepOriginalName = false
        let shallow = try BasketConversionPlanner.plan(urls: [folder], action: .jpeg, includeSubfolders: false, settings: settings)
        precondition(shallow.entries.count == 1 && shallow.entries[0].input.lastPathComponent == "同名.png")
        precondition(shallow.skippedCount == 4)
        let controller = BasketConversionController()
        let shelf = ShelfModel()
        precondition(controller.start(urls: [folder, folder], action: .jpeg, shelf: shelf, includeSubfolders: true, settings: settings))
        precondition(controller.isScanning)
        try await wait(controller)
        precondition(controller.errorMessage == nil && controller.outputs.count == 2,
                     "\(controller.errorMessage ?? "") \(controller.queue.map(\.displayName))")
        precondition(Set(controller.queue.map(\.displayName)) == ["素材/同名.png", "素材/子目录/更深/同名.png"],
                     "\(controller.queue.map(\.displayName))")
        precondition(controller.queue.allSatisfy { $0.state == .completed } && controller.progress == 1)
        precondition(controller.skippedCount == 4 && controller.resultURLs.count == 1 && shelf.urls.count == 2)
        let result = controller.resultURLs[0]
        precondition(manager.fileExists(atPath: result.appendingPathComponent("同名-转换.jpg").path))
        precondition(manager.fileExists(atPath: result.appendingPathComponent("子目录/更深/同名-转换.jpg").path))
        let firstBytes = try Data(contentsOf: first)
        let secondBytes = try Data(contentsOf: second)
        precondition(firstBytes == png && secondBytes == png)
        precondition(controller.start(urls: [folder], action: .jpeg, shelf: shelf, settings: settings))
        try await wait(controller)
        precondition(controller.resultURLs[0].lastPathComponent == "素材-转换结果 (2)")
        precondition(controller.start(urls: [folder, first], action: .jpeg, shelf: shelf, settings: settings))
        try await wait(controller)
        precondition(controller.errorMessage == nil && controller.outputs.count == 1 && controller.resultURLs.count == 1)
        settings.besideOriginal = true
        precondition(controller.start(urls: [folder], action: .jpeg, shelf: shelf, settings: settings))
        try await wait(controller)
        precondition(controller.errorMessage == nil && controller.resultURLs[0].deletingLastPathComponent().resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
        let broken = root.appendingPathComponent("broken")
        try manager.createDirectory(at: broken, withIntermediateDirectories: true)
        try png.write(to: broken.appendingPathComponent("01.png"))
        try Data("invalid".utf8).write(to: broken.appendingPathComponent("02.png"))
        try png.write(to: broken.appendingPathComponent("03.png"))
        precondition(controller.start(urls: [broken], action: .jpeg, shelf: shelf, settings: settings))
        try await wait(controller)
        precondition(controller.queue.map(\.state) == [.completed, .failed, .skipped])
        precondition(controller.outputs.count == 1 && controller.resultURLs.count == 1)
        let empty = root.appendingPathComponent("empty")
        try manager.createDirectory(at: empty, withIntermediateDirectories: true)
        precondition(controller.start(urls: [empty], action: .jpeg, shelf: shelf, settings: settings))
        try await wait(controller)
        precondition(controller.errorMessage != nil && controller.outputs.isEmpty && controller.queue.isEmpty)
        precondition(controller.start(urls: [folder], action: .jpeg, shelf: shelf, includeSubfolders: true, settings: settings))
        controller.cancel()
        try await wait(controller)
        precondition(controller.status.hasPrefix("已取消") && controller.resultURLs.isEmpty)
        print("Folder conversion recursion, filtering, structure, sources, result intake, collision, failure and cancellation passed")
    }

    @MainActor
    static func wait(_ controller: BasketConversionController) async throws {
        let deadline = Date().addingTimeInterval(30)
        while controller.isRunning {
            precondition(Date() < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
