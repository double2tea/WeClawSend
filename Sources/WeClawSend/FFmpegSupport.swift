import Combine
import CryptoKit
import Foundation

enum FFmpegProcess {
    static func run(
        _ executable: URL,
        arguments: [String],
        duration: Double? = nil,
        progress: @Sendable (Double) async -> Void = { _ in }
    ) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("weclaw-process-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let logURL = folder.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        let progressURL = folder.appendingPathComponent("progress.log")
        FileManager.default.createFile(atPath: progressURL.path, contents: nil)
        let progressReader = try FileHandle(forReadingFrom: progressURL)
        defer { try? progressReader.close() }
        var pendingProgress = ""
        var nextProgressRead = Date.distantPast
        let process = Process()
        process.executableURL = executable
        process.arguments = duration == nil ? arguments
            : ["-progress", progressURL.path, "-stats_period", "0.25"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if let duration, Date() >= nextProgressRead {
                    nextProgressRead = Date().addingTimeInterval(0.25)
                    let data = try progressReader.readToEnd() ?? Data()
                    pendingProgress += String(decoding: data, as: UTF8.self)
                    let lines = pendingProgress.components(separatedBy: "\n")
                    pendingProgress = lines.last ?? ""
                    for line in lines.dropLast() where line.hasPrefix("out_time_us=") {
                        if let microseconds = Double(line.dropFirst("out_time_us=".count)) {
                            await progress(max(0, min(1, microseconds / 1_000_000 / duration)))
                        }
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            if process.isRunning { process.terminate() }
            await Task.detached { process.waitUntilExit() }.value
            throw error
        }
        let text = try String(contentsOf: logURL, encoding: .utf8)
        guard process.terminationStatus == 0 else {
            throw BasketConversionError.engine("程序退出，状态码 \(process.terminationStatus)：\(text.suffix(2000))")
        }
        return text
    }
}

@MainActor
final class FFmpegSupport: ObservableObject {
    static let shared = FFmpegSupport()
    static let pathKey = "BasketConversionFFmpegPath"
    @Published private(set) var path: String
    @Published private(set) var status = "尚未检测"
    @Published private(set) var isBusy = false
    @Published private(set) var isAvailable = false
    @Published private(set) var encoders: Set<String> = []
    @Published private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    private let defaults: UserDefaults
    private let installFolder: URL

    nonisolated static var managedFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WeClawSend/Tools", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard, installFolder: URL = FFmpegSupport.managedFolder) {
        self.defaults = defaults
        self.installFolder = installFolder
        path = defaults.string(forKey: Self.pathKey) ?? ""
    }

    func detect() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        status = "正在检测本机 FFmpeg…"
        task = Task {
            defer { isBusy = false }
            let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map { "\($0)/ffmpeg" }
            let candidates = [path, installFolder.appendingPathComponent("ffmpeg").path,
                              "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] + searchPaths
            var seen: Set<String> = []
            var failures: [String] = []
            for candidate in candidates where !candidate.isEmpty && seen.insert(candidate).inserted
                && FileManager.default.isExecutableFile(atPath: candidate) {
                do {
                    try await verify(candidate)
                    return
                } catch {
                    failures.append("\(candidate)：\(error.localizedDescription)")
                }
            }
            isAvailable = false
            encoders = []
            if failures.isEmpty {
                path = ""
                status = "未找到 FFmpeg"
                errorMessage = "未找到可执行的 FFmpeg。"
            } else {
                status = "FFmpeg 不可用"
                errorMessage = failures.joined(separator: "\n")
            }
        }
    }

    func select(_ url: URL) {
        guard !isBusy else { return }
        path = url.path
        isBusy = true
        errorMessage = nil
        status = "正在验证所选 FFmpeg…"
        task = Task {
            defer { isBusy = false }
            do {
                try await verify(url.path)
            } catch {
                isAvailable = false
                encoders = []
                status = "FFmpeg 不可用"
                errorMessage = "\(url.path)：\(error.localizedDescription)"
            }
        }
    }

    func install() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        task = Task {
            defer { isBusy = false }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("weclaw-ffmpeg-\(UUID())")
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                status = "下载 FFmpeg…"
                #if arch(arm64)
                let architecture = "arm64"
                #else
                let architecture = "amd64"
                #endif
                let url = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(architecture)/release/ffmpeg.zip")!
                let (download, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let resolved = http.url, resolved.scheme == "https",
                      resolved.host == "ffmpeg.martin-riedl.de" else {
                    throw BasketConversionError.engine("FFmpeg 下载失败，请重试。")
                }
                let archive = staging.appendingPathComponent("ffmpeg.zip")
                try FileManager.default.moveItem(at: download, to: archive)
                status = "校验下载内容…"
                let (checksumData, checksumResponse) = try await URLSession.shared.data(from: URL(string: resolved.absoluteString + ".sha256")!)
                guard (checksumResponse as? HTTPURLResponse)?.statusCode == 200,
                      let checksum = String(data: checksumData, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first else {
                    throw BasketConversionError.engine("无法取得 FFmpeg 校验信息，安装已停止。")
                }
                let digest = try await Task.detached {
                    let data = try Data(contentsOf: archive, options: .mappedIfSafe)
                    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }.value
                guard digest == checksum.lowercased() else {
                    throw BasketConversionError.engine("FFmpeg 校验不一致，安装已停止。")
                }
                let extracted = staging.appendingPathComponent("extracted")
                _ = try await FFmpegProcess.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: [
                    "-x", "-k", archive.path, extracted.path,
                ])
                let binary = extracted.appendingPathComponent("ffmpeg")
                let values = try binary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw BasketConversionError.engine("FFmpeg 下载包内容不正确。")
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                _ = try await FFmpegProcess.run(binary, arguments: ["-version"])
                try FileManager.default.createDirectory(at: installFolder, withIntermediateDirectories: true)
                let destination = installFolder.appendingPathComponent("ffmpeg")
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: binary)
                } else {
                    try FileManager.default.moveItem(at: binary, to: destination)
                }
                try await verify(destination.path)
            } catch {
                status = "安装未完成"
                errorMessage = error.localizedDescription
            }
        }
    }

    private func verify(_ candidate: String) async throws {
        let executable = URL(fileURLWithPath: candidate)
        let version = try await FFmpegProcess.run(executable, arguments: ["-version"])
        guard version.hasPrefix("ffmpeg version") else {
            throw BasketConversionError.engine("所选程序不是 FFmpeg。")
        }
        let output = try await FFmpegProcess.run(executable, arguments: ["-hide_banner", "-encoders"])
        encoders = Set(output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0].count == 6,
                  fields[0].first == "V" || fields[0].first == "A" else { return nil }
            return String(fields[1])
        })
        path = candidate
        defaults.set(candidate, forKey: Self.pathKey)
        isAvailable = true
        status = String(version.split(separator: "\n").first ?? "FFmpeg 已就绪")
    }
}
