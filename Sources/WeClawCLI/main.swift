import Foundation

private let usage = """
用法：weclaw <命令>
  status                          查看服务和微信连接状态
  send <文件路径>                 发送文件或加入文件篮（由 App 设置决定）
  schedule <秒数> <文件路径>...   创建延时发送计划
  schedules                       列出发送计划
  show <计划 ID>                  查看计划
  reschedule <计划 ID> <秒数>     修改计划时间
  cancel <计划 ID>                取消计划
  send-now <计划 ID>              立即触发计划
  help                            显示帮助

命令成功时 JSON 输出到 stdout；错误 JSON 输出到 stderr，退出码非零。
App 必须运行且在设置中启用本地接口。发送及定时计划会产生真实发送行为。
"""

private struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func absolutePath(_ path: String) -> String {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        .standardizedFileURL.path
}

@main
struct WeClawCLI {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            let data = try! JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription], options: [.sortedKeys])
            FileHandle.standardError.write(data + Data("\n".utf8))
            exit(1)
        }
    }

    static func run(_ args: [String]) async throws {
        guard let command = args.first else { print(usage); return }
        if command == "help" || command == "--help" || command == "-h" {
            guard args.count == 1 else { throw CLIError(message: usage) }
            print(usage)
            return
        }
        var method = "GET"
        var path = ""
        var body: [String: Any]?
        switch command {
        case "status" where args.count == 1:
            path = "/health"
        case "send" where args.count == 2:
            method = "POST"; path = "/send"
            body = ["file_path": absolutePath(args[1])]
        case "schedule" where args.count >= 3:
            guard let seconds = Int64(args[1]), seconds > 0 else { throw CLIError(message: "秒数必须为正整数") }
            method = "POST"; path = "/scheduled-sends"
            body = ["delay_seconds": seconds, "source": "cli", "items": args.dropFirst(2).map { ["file_path": absolutePath($0)] }]
        case "schedules" where args.count == 1:
            path = "/scheduled-sends"
        case "show", "cancel", "send-now", "reschedule":
            let expected = command == "reschedule" ? 3 : 2
            guard args.count == expected, let id = UUID(uuidString: args[1]) else { throw CLIError(message: usage) }
            path = "/scheduled-sends/\(id.uuidString)"
            if command == "cancel" { method = "DELETE" }
            if command == "send-now" { method = "POST"; path += "/send-now" }
            if command == "reschedule" {
                guard let seconds = Int64(args[2]), seconds > 0 else { throw CLIError(message: "秒数必须为正整数") }
                method = "PATCH"; body = ["delay_seconds": seconds]
            }
        default:
            throw CLIError(message: usage)
        }
        let port = ProcessInfo.processInfo.environment["WECLAW_CLI_PORT"] ?? "18790"
        guard let number = UInt16(port), number > 0 else { throw CLIError(message: "WECLAW_CLI_PORT 无效") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(number)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 600
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CLIError(message: "无效的 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else {
            FileHandle.standardError.write(data + Data("\n".utf8))
            exit(1)
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
