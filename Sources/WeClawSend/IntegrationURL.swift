import Foundation

enum IntegrationURL {
    static let scheme = "weclaw-send"

    static func sendRequest(from url: URL) throws -> SendRequest {
        guard url.scheme == scheme,
              url.host == "send",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.path.isEmpty,
              url.fragment == nil else {
            throw BackendError.rejected("不支持的集成链接")
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw BackendError.rejected("集成链接无效")
        }

        let queryItems = components.queryItems ?? []
        let allowedNames = Set(["file_path", "file_name"])
        guard queryItems.allSatisfy({ allowedNames.contains($0.name) }) else {
            throw BackendError.rejected("集成链接包含未知参数")
        }
        guard Set(queryItems.map(\.name)).count == queryItems.count else {
            throw BackendError.rejected("集成链接包含重复参数")
        }
        guard let filePath = queryItems.first(where: { $0.name == "file_path" })?.value,
              !filePath.isEmpty else {
            throw BackendError.rejected("集成链接缺少文件路径")
        }
        guard (filePath as NSString).isAbsolutePath else {
            throw BackendError.rejected("集成链接中的文件路径必须是绝对路径")
        }

        let fileName = queryItems.first(where: { $0.name == "file_name" })?.value
        if let fileName, fileName.isEmpty {
            throw BackendError.rejected("集成链接中的文件名不能为空")
        }
        return SendRequest(filePath: filePath, fileName: fileName)
    }
}
