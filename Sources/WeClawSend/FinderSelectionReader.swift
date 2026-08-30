import AppKit
import ApplicationServices

enum FinderSelectionError: LocalizedError {
    case finderNotFrontmost
    case emptySelection
    case automationDenied
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .finderNotFrontmost:
            "请先在 Finder 中选择项目，再使用 Finder 快捷键"
        case .emptySelection:
            "Finder 中没有选中的项目"
        case .automationDenied:
            "WeClaw Send 没有 Finder 自动化权限。请前往系统设置 → 隐私与安全性 → 自动化，允许控制 Finder"
        case let .executionFailed(message):
            "无法读取 Finder 所选项目：\(message)"
        }
    }
}

@MainActor
enum FinderSelectionReader {
    static func requestAutomationPermission() throws {
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        let status = AEDeterminePermissionToAutomateTarget(
            finder.aeDesc,
            typeWildCard,
            typeWildCard,
            true
        )
        guard status != noErr else { return }
        if status == errAEEventNotPermitted {
            throw FinderSelectionError.automationDenied
        }
        throw FinderSelectionError.executionFailed("Apple Events 错误 \(status)")
    }

    static func selectedURLs() throws -> [URL] {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
            throw FinderSelectionError.finderNotFrontmost
        }

        let source = """
        tell application "Finder"
            set selectedItems to selection as alias list
            set selectedPaths to {}
            repeat with selectedItem in selectedItems
                set end of selectedPaths to POSIX path of selectedItem
            end repeat
            return selectedPaths
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            throw FinderSelectionError.executionFailed("Apple Events 脚本无效")
        }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let errorNumber = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            if errorNumber == -1743 {
                throw FinderSelectionError.automationDenied
            }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "未知错误"
            throw FinderSelectionError.executionFailed(message)
        }

        let urls = urls(from: descriptor)
        guard !urls.isEmpty else {
            throw FinderSelectionError.emptySelection
        }
        return urls
    }

    nonisolated static func urls(from descriptor: NSAppleEventDescriptor) -> [URL] {
        guard descriptor.descriptorType == typeAEList else {
            guard let path = descriptor.stringValue, !path.isEmpty else { return [] }
            return [URL(fileURLWithPath: path).standardizedFileURL]
        }

        var urls: [URL] = []
        var seenPaths = Set<String>()
        let itemCount = descriptor.numberOfItems
        guard itemCount > 0 else { return [] }
        for index in 1...itemCount {
            guard let path = descriptor.atIndex(index)?.stringValue, !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard seenPaths.insert(url.path).inserted else { continue }
            urls.append(url)
        }
        return urls
    }
}
