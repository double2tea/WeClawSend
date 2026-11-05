import AVFoundation
import AppKit
import Combine
import CoreText
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

enum BasketConversionAction: String, CaseIterable, Identifiable, Sendable, Codable {
    case mp4
    case mov
    case m4a
    case mkv
    case webm
    case mp3
    case wav
    case aiff
    case flac
    case opus
    case jpeg
    case png
    case pdf
    case txt
    case rtf
    case compressPDF

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp4: "转 MP4"
        case .mov: "封装 MOV"
        case .m4a: "提取音频"
        case .mkv: "转 MKV"
        case .webm: "转 WebM"
        case .mp3: "转 MP3"
        case .wav: "转 WAV"
        case .aiff: "转 AIFF"
        case .flac: "转 FLAC"
        case .opus: "转 Opus"
        case .jpeg: "转 JPG"
        case .png: "转 PNG"
        case .pdf: "转 PDF"
        case .txt: "转 TXT"
        case .rtf: "转 RTF"
        case .compressPDF: "压缩 PDF"
        }
    }

    var systemImage: String {
        switch self {
        case .mp4: "film"
        case .mov: "film.stack"
        case .m4a: "waveform"
        case .mkv, .webm: "film"
        case .mp3, .wav, .aiff, .flac, .opus: "waveform"
        case .jpeg: "photo"
        case .png: "photo.on.rectangle"
        case .pdf: "doc.richtext"
        case .txt: "doc.plaintext"
        case .rtf: "text.document"
        case .compressPDF: "doc.zipper"
        }
    }

    var detail: String {
        switch self {
        case .mp4: "视频转码"
        case .mov: "保留编码"
        case .m4a: "AAC 音频"
        case .mkv: "多编码容器"
        case .webm: "VP9 / AV1"
        case .mp3: "兼容分享"
        case .wav, .aiff: "PCM 无损"
        case .flac: "无损压缩"
        case .opus: "高效音频"
        case .jpeg: "适合分享"
        case .png: "保留透明"
        case .pdf: "文字重排"
        case .txt: "仅保留文字"
        case .rtf: "保留文字格式"
        case .compressPDF: "缩小文件"
        }
    }

    var fileExtension: String {
        if self == .jpeg { return "jpg" }
        if self == .compressPDF { return "pdf" }
        return rawValue
    }

    var isImage: Bool { self == .jpeg || self == .png }
    var isDocument: Bool { self == .pdf || self == .txt || self == .rtf || self == .compressPDF }

    var category: BasketConversionCategory {
        switch self {
        case .mp4, .mov, .mkv, .webm: .video
        case .m4a, .mp3, .wav, .aiff, .flac, .opus: .audio
        case .jpeg, .png: .image
        case .pdf, .txt, .rtf, .compressPDF: .document
        }
    }

    func accepts(_ url: URL) -> Bool {
        guard ShelfItem.kind(for: url) == .file else { return false }
        if isDocument {
            let fileExtension = url.pathExtension.lowercased()
            if self == .compressPDF { return fileExtension == "pdf" }
            return ["txt", "md", "markdown", "rtf", "docx"].contains(fileExtension)
                || (self == .txt && fileExtension == "pdf")
        }
        guard
              let type = UTType(filenameExtension: url.pathExtension)
        else { return false }
        if isImage { return type.conforms(to: .image) }
        if category == .audio { return type.conforms(to: .audio) || type.conforms(to: .movie) }
        return type.conforms(to: .movie)
    }

    var requiresFFmpeg: Bool {
        [.mkv, .webm, .mp3, .wav, .aiff, .flac, .opus].contains(self)
    }

    var videoCodecs: [String] {
        switch self {
        case .mp4: ["h264", "hevc", "av1"]
        case .mov: ["copy", "h264", "hevc", "prores"]
        case .mkv: ["h264", "hevc", "vp9", "av1"]
        case .webm: ["vp9", "av1"]
        default: []
        }
    }
}

enum BasketConversionCategory: String, CaseIterable, Identifiable, Sendable, Codable {
    case video
    case audio
    case image
    case document

    var id: String { rawValue }
    var title: String {
        switch self {
        case .video: "视频"
        case .audio: "音频"
        case .image: "图片"
        case .document: "文档"
        }
    }
    var systemImage: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .document: "doc.richtext"
        }
    }
    var maximumSizeKey: String { "BasketConversion\(rawValue.capitalized)MaximumSizeMB" }
    var targetPercentKey: String { "BasketConversion\(rawValue.capitalized)TargetPercent" }
}

enum BasketVideoSize: String, CaseIterable, Identifiable, Sendable, Codable {
    case original
    case hd720
    case hd1080
    case uhd4K

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "原尺寸"
        case .hd720: "720p"
        case .hd1080: "1080p"
        case .uhd4K: "4K"
        }
    }

    func preset(hevc: Bool) -> String {
        switch (self, hevc) {
        case (.original, false): AVAssetExportPresetHighestQuality
        case (.original, true): AVAssetExportPresetHEVCHighestQuality
        case (.hd720, false): AVAssetExportPreset1280x720
        case (.hd1080, false): AVAssetExportPreset1920x1080
        case (.uhd4K, false): AVAssetExportPreset3840x2160
        case (.hd720, true): AVAssetExportPresetHEVC1920x1080
        case (.hd1080, true): AVAssetExportPresetHEVC1920x1080
        case (.uhd4K, true): AVAssetExportPresetHEVC3840x2160
        }
    }
}

struct BasketConversionSizeLimit: Codable, Sendable {
    var maximum: Int
    var percent: Int
}

struct BasketConversionSettings: Sendable, Codable {
    static let enabledKey = "BasketConversionEnabled"
    static let quickActionsKey = "BasketConversionQuickActions"
    static let defaultQuickActions = BasketConversionAction.allCases.map(\.rawValue).joined(separator: ",")
    static let videoSizeKey = "BasketConversionVideoSize"
    static let videoHEVCKey = "BasketConversionVideoHEVC"
    static let jpegQualityKey = "BasketConversionJPEGQuality"
    static let imageMaxPixelKey = "BasketConversionImageMaxPixel"
    static let outputFolderKey = "BasketConversionOutputFolder"
    static let besideOriginalKey = "BasketConversionBesideOriginal"
    static let nameSuffixKey = "BasketConversionNameSuffix"
    static let keepOriginalNameKey = "BasketConversionKeepOriginalName"
    static let maximumSizeMBKey = "BasketConversionMaximumSizeMB"
    static let targetPercentKey = "BasketConversionTargetPercent"
    static let networkOptimizedKey = "BasketConversionNetworkOptimized"
    static let retainMetadataKey = "BasketConversionRetainMetadata"
    static let audioBitrateKey = "BasketConversionAudioBitrate"
    static let audioSampleRateKey = "BasketConversionAudioSampleRate"
    static let audioChannelsKey = "BasketConversionAudioChannels"
    static let jpegBackgroundKey = "BasketConversionJPEGBackground"
    static let pdfPaperKey = "BasketConversionPDFPaper"
    static let pdfLandscapeKey = "BasketConversionPDFLandscape"
    static let pdfMarginKey = "BasketConversionPDFMargin"
    static let documentFontSizeKey = "BasketConversionDocumentFontSize"
    static let pdfJPEGKey = "BasketConversionPDFJPEG"
    static let pdfScreenKey = "BasketConversionPDFScreen"

    var videoSize: BasketVideoSize
    var videoHEVC: Bool
    var jpegQuality: Double
    var imageMaxPixel: Int
    var outputFolder: URL
    var besideOriginal: Bool
    var nameSuffix: String
    var keepOriginalName: Bool
    var maximumSizeMB: Int
    var targetPercent: Int
    var networkOptimized: Bool
    var retainMetadata: Bool
    var audioBitrate: Int
    var audioSampleRate: Int
    var audioChannels: Int
    var jpegBackground: String
    var pdfPaper: String
    var pdfLandscape: Bool
    var pdfMargin: Double
    var documentFontSize: Double
    var pdfJPEG: Bool
    var pdfScreen: Bool
    var categoryLimits: [BasketConversionCategory: BasketConversionSizeLimit]
    var useFFmpeg = false
    var videoCodec = "h264"
    var videoCRF = 23
    var videoBitrateKbps = 0
    var frameRate = 0
    var encoderSpeed = "medium"
    var ffmpegPath = "/opt/homebrew/bin/ffmpeg"
    var audioVideoOnly: Bool?

    init(defaults: UserDefaults = .standard) {
        videoSize = BasketVideoSize(rawValue: defaults.string(forKey: Self.videoSizeKey) ?? "") ?? .hd1080
        videoHEVC = defaults.bool(forKey: Self.videoHEVCKey)
        jpegQuality = defaults.object(forKey: Self.jpegQualityKey) == nil
            ? 0.85 : defaults.double(forKey: Self.jpegQualityKey)
        imageMaxPixel = defaults.integer(forKey: Self.imageMaxPixelKey)
        let path = defaults.string(forKey: Self.outputFolderKey) ?? ""
        outputFolder = path.isEmpty ? Self.defaultOutputFolder : URL(fileURLWithPath: path)
        besideOriginal = defaults.bool(forKey: Self.besideOriginalKey)
        nameSuffix = defaults.string(forKey: Self.nameSuffixKey) ?? "-转换"
        keepOriginalName = defaults.bool(forKey: Self.keepOriginalNameKey)
        maximumSizeMB = defaults.integer(forKey: Self.maximumSizeMBKey)
        targetPercent = defaults.integer(forKey: Self.targetPercentKey)
        networkOptimized = defaults.object(forKey: Self.networkOptimizedKey) as? Bool ?? true
        retainMetadata = defaults.object(forKey: Self.retainMetadataKey) as? Bool ?? true
        audioBitrate = defaults.object(forKey: Self.audioBitrateKey) as? Int ?? 192
        audioSampleRate = defaults.integer(forKey: Self.audioSampleRateKey)
        audioChannels = defaults.integer(forKey: Self.audioChannelsKey)
        jpegBackground = defaults.string(forKey: Self.jpegBackgroundKey) ?? "white"
        pdfPaper = defaults.string(forKey: Self.pdfPaperKey) ?? "a4"
        pdfLandscape = defaults.bool(forKey: Self.pdfLandscapeKey)
        pdfMargin = defaults.object(forKey: Self.pdfMarginKey) as? Double ?? 42
        documentFontSize = defaults.object(forKey: Self.documentFontSizeKey) as? Double ?? 12
        pdfJPEG = defaults.bool(forKey: Self.pdfJPEGKey)
        pdfScreen = defaults.bool(forKey: Self.pdfScreenKey)
        categoryLimits = Dictionary(uniqueKeysWithValues: BasketConversionCategory.allCases.map { category in
            (category, BasketConversionSizeLimit(
                maximum: defaults.object(forKey: category.maximumSizeKey) as? Int ?? defaults.integer(forKey: Self.maximumSizeMBKey),
                percent: defaults.object(forKey: category.targetPercentKey) as? Int ?? defaults.integer(forKey: Self.targetPercentKey)
            ))
        })
    }

    func byteLimit(inputBytes: Int64, category: BasketConversionCategory? = nil) -> Int64? {
        let maximum = category.flatMap { categoryLimits[$0]?.maximum } ?? maximumSizeMB
        let percent = category.flatMap { categoryLimits[$0]?.percent } ?? targetPercent
        let absolute = maximum > 0 ? Int64(maximum) * 1_048_576 : nil
        let relative = percent > 0 ? max(1, inputBytes * Int64(percent) / 100) : nil
        return [absolute, relative].compactMap { $0 }.min()
    }

    var isValid: Bool {
        jpegQuality.isFinite && (0.1...1).contains(jpegQuality)
            && [0, 1280, 1920, 2560, 3840].contains(imageMaxPixel)
            && !(!useFFmpeg && videoHEVC && videoSize == .hd720)
            && (0...10_240).contains(maximumSizeMB)
            && (targetPercent == 0 || (1...100).contains(targetPercent))
            && categoryLimits.values.allSatisfy { (0...10_240).contains($0.maximum) && (0...100).contains($0.percent) }
            && [64, 96, 128, 160, 192, 256, 320].contains(audioBitrate)
            && [0, 22_050, 44_100, 48_000].contains(audioSampleRate)
            && [0, 1, 2].contains(audioChannels)
            && ["white", "black"].contains(jpegBackground)
            && ["a4", "letter"].contains(pdfPaper)
            && pdfMargin.isFinite && (18...72).contains(pdfMargin)
            && documentFontSize.isFinite && (8...24).contains(documentFontSize)
            && ["copy", "h264", "hevc", "prores", "vp9", "av1"].contains(videoCodec)
            && (0...51).contains(videoCRF)
            && (0...500_000).contains(videoBitrateKbps)
            && [0, 24, 25, 30, 50, 60].contains(frameRate)
            && ["fast", "medium", "slow"].contains(encoderSpeed)
            && nameSuffix.count <= 40
            && !nameSuffix.contains(where: { $0 == "/" || $0 == ":" || $0.isNewline })
    }

    static var defaultOutputFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WeClaw Send 转换", isDirectory: true)
    }
}

struct BasketConversionPreset: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String
    var isEnabled = true
    var action: BasketConversionAction
    var settings: BasketConversionSettings

    var summary: String {
        var parts = [action.fileExtension.uppercased()]
        if action.category == .video {
            if action == .mov && !settings.useFFmpeg || settings.useFFmpeg && settings.videoCodec == "copy" {
                parts.append("保留原编码")
            } else {
                parts.append(settings.useFFmpeg ? settings.videoCodec.uppercased() : (settings.videoHEVC ? "HEVC" : "H.264"))
                parts.append(settings.videoSize.title)
            }
        } else if action.category == .audio {
            if [.m4a, .mp3, .opus].contains(action) { parts.append("\(settings.audioBitrate) kbps") }
        } else if action.isImage {
            parts.append(settings.imageMaxPixel == 0 ? "原尺寸" : "\(settings.imageMaxPixel) px")
        }
        if let limit = settings.categoryLimits[action.category] {
            if limit.maximum > 0 { parts.append("≤\(limit.maximum) MiB") }
            if limit.percent > 0 { parts.append("≤\(limit.percent)%") }
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class BasketConversionPresetStore: ObservableObject {
    static let shared = BasketConversionPresetStore()
    static let storageKey = "BasketConversionPresetsV1"
    static let defaultPresetVersionKey = "BasketConversionDefaultPresetVersion"
    private static let removedPresetIDsKey = "BasketConversionRemovedPresetIDs"
    @Published private(set) var presets: [BasketConversionPreset] = []
    @Published private(set) var errorMessage: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                presets = try JSONDecoder().decode([BasketConversionPreset].self, from: data)
            } catch {
                errorMessage = "无法读取转换预设：\(error.localizedDescription)"
                return
            }
            if defaults.integer(forKey: Self.defaultPresetVersionKey) < 2 {
                let removedIDs = Set(defaults.stringArray(forKey: Self.removedPresetIDsKey) ?? [])
                let additions = Self.defaultPresets(defaults: defaults).filter { candidate in
                    !presets.contains { $0.id == candidate.id }
                        && !removedIDs.contains(candidate.id.uuidString)
                }.map { preset in
                    var preset = preset
                    preset.isEnabled = false
                    return preset
                }
                if persist(presets + additions) {
                    defaults.set(2, forKey: Self.defaultPresetVersionKey)
                }
            }
        } else {
            var initial = Self.defaultPresets(defaults: defaults)
            if let legacyActions = defaults.string(forKey: BasketConversionSettings.quickActionsKey) {
                let enabledActions = Set(legacyActions.split(separator: ",").map(String.init))
                initial = initial.map { preset in
                    var preset = preset
                    preset.isEnabled = false
                    return preset
                }
                let legacySettings = BasketConversionSettings(defaults: defaults)
                let legacy = BasketConversionAction.allCases.filter { !$0.requiresFFmpeg }.map { action in
                    BasketConversionPreset(
                        name: action.title,
                        isEnabled: enabledActions.contains(action.rawValue),
                        action: action,
                        settings: legacySettings
                    )
                }
                initial = legacy + initial
            }
            if persist(initial) {
                defaults.set(2, forKey: Self.defaultPresetVersionKey)
            }
        }
    }

    private static func defaultPresets(defaults: UserDefaults) -> [BasketConversionPreset] {
        var base = BasketConversionSettings(defaults: defaults)
        base.videoSize = .hd1080
        base.videoHEVC = false
        base.jpegQuality = 0.85
        base.imageMaxPixel = 0
        base.maximumSizeMB = 0
        base.targetPercent = 0
        base.categoryLimits = [:]
        base.networkOptimized = true
        base.retainMetadata = true
        base.audioBitrate = 192
        base.audioSampleRate = 0
        base.audioChannels = 0
        base.jpegBackground = "white"
        base.pdfPaper = "a4"
        base.pdfLandscape = false
        base.pdfMargin = 42
        base.documentFontSize = 12
        base.pdfJPEG = false
        base.pdfScreen = false

        func preset(
            _ number: Int, _ name: String, _ action: BasketConversionAction,
            enabled: Bool = false,
            configure: (inout BasketConversionSettings) -> Void = { _ in }
        ) -> BasketConversionPreset {
            var settings = base
            settings.useFFmpeg = action.requiresFFmpeg
            configure(&settings)
            return BasketConversionPreset(
                id: UUID(uuidString: String(format: "6F6B7D40-254A-4A81-9E26-%012d", number))!,
                name: name, isEnabled: enabled, action: action, settings: settings
            )
        }

        return [
            preset(1, "视频分享 · 1080p", .mp4, enabled: true),
            preset(2, "视频压缩 · 20 MiB", .mp4, enabled: true) {
                $0.useFFmpeg = true
                $0.categoryLimits[.video] = BasketConversionSizeLimit(maximum: 20, percent: 0)
            },
            preset(3, "视频轻量 · 720p", .mp4) {
                $0.videoSize = .hd720
            },
            preset(4, "高效视频 · HEVC", .mp4) {
                $0.videoHEVC = true
            },
            preset(5, "剪辑中间片 · ProRes", .mov) {
                $0.useFFmpeg = true
                $0.videoCodec = "prores"
                $0.videoSize = .original
            },
            preset(6, "MOV 换封装", .mov),
            preset(7, "网页视频 · WebM", .webm) {
                $0.videoCodec = "vp9"
            },
            preset(8, "提取音频 · M4A", .m4a, enabled: true),
            preset(9, "音频分享 · MP3", .mp3),
            preset(10, "剪辑音频 · WAV 48 kHz", .wav) {
                $0.audioSampleRate = 48_000
            },
            preset(11, "无损音频 · FLAC", .flac),
            preset(12, "图片分享 · JPG 1920px", .jpeg, enabled: true) {
                $0.imageMaxPixel = 1920
            },
            preset(13, "图片压缩 · 1 MiB", .jpeg) {
                $0.imageMaxPixel = 1920
                $0.jpegQuality = 0.75
                $0.categoryLimits[.image] = BasketConversionSizeLimit(maximum: 1, percent: 0)
            },
            preset(14, "透明图片 · PNG", .png),
            preset(15, "文档转 PDF · A4", .pdf),
            preset(16, "提取纯文本 · TXT", .txt),
            preset(17, "富文本文档 · RTF", .rtf),
            preset(18, "PDF 压缩 · 屏幕阅读", .compressPDF, enabled: true) {
                $0.pdfJPEG = true
                $0.pdfScreen = true
            },
            preset(19, "视频转码 · MKV", .mkv),
            preset(20, "视频压缩 · 25 MiB", .mp4) {
                $0.useFFmpeg = true
                $0.categoryLimits[.video] = BasketConversionSizeLimit(maximum: 25, percent: 0)
            },
            preset(21, "高效视频 · HEVC 原尺寸", .mp4) {
                $0.videoHEVC = true
                $0.videoSize = .original
            },
            preset(22, "音乐分享 · MP3 320 kbps", .mp3) {
                $0.audioBitrate = 320
            },
            preset(23, "高效语音 · Opus", .opus) {
                $0.audioBitrate = 64
            },
            preset(24, "剪辑音频 · AIFF 48 kHz", .aiff) {
                $0.audioSampleRate = 48_000
            },
            preset(25, "轻量分享图 · JPG 1280px", .jpeg) {
                $0.imageMaxPixel = 1280
                $0.jpegQuality = 0.8
            },
            preset(26, "轻量透明图 · PNG 1280px", .png) {
                $0.imageMaxPixel = 1280
            },
            preset(27, "横版文稿 · PDF A4", .pdf) {
                $0.pdfLandscape = true
            },
            preset(28, "紧凑文稿 · PDF 9 pt", .pdf) {
                $0.documentFontSize = 9
                $0.pdfMargin = 28
            }
        ]
    }

    @discardableResult
    func save(_ preset: BasketConversionPreset) -> Bool {
        guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              preset.settings.isValid else {
            errorMessage = "预设名称或参数无效。"
            return false
        }
        var updated = presets
        if let index = updated.firstIndex(where: { $0.id == preset.id }) {
            updated[index] = preset
        } else {
            updated.append(preset)
        }
        return persist(updated)
    }

    func remove(_ id: UUID) {
        if persist(presets.filter { $0.id != id }),
           Self.defaultPresets(defaults: defaults).contains(where: { $0.id == id }) {
            var removedIDs = Set(defaults.stringArray(forKey: Self.removedPresetIDsKey) ?? [])
            removedIDs.insert(id.uuidString)
            defaults.set(removedIDs.sorted(), forKey: Self.removedPresetIDsKey)
        }
    }

    func setEnabled(_ id: UUID, enabled: Bool) {
        guard var preset = presets.first(where: { $0.id == id }) else { return }
        preset.isEnabled = enabled
        _ = save(preset)
    }

    private func persist(_ updated: [BasketConversionPreset]) -> Bool {
        do {
            let data = try JSONEncoder().encode(updated)
            defaults.set(data, forKey: Self.storageKey)
            presets = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = "无法保存转换预设：\(error.localizedDescription)"
            return false
        }
    }
}

enum BasketConversionError: LocalizedError {
    case invalidSettings
    case unsupported(String)
    case incompatibleMedia(String)
    case imageDecode(String)
    case animatedImage(String)
    case imageEncode
    case cleanupFailed(String, String)
    case document(String)
    case sizeExceeded(Int64, Int64)
    case incompleteMedia
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            "转换参数无效，请在设置中重新选择。"
        case let .unsupported(name):
            "此预设不支持「\(name)」。请选择匹配的文件类型或普通文件夹。"
        case let .incompatibleMedia(name):
            "系统无法按此预设导出「\(name)」。MOV 换封装要求原编码可装入 MOV；MP4 转码需要系统支持解码。"
        case let .imageDecode(name):
            "无法读取图片「\(name)」。"
        case let .animatedImage(name):
            "「\(name)」包含多帧，请使用静态图片，避免丢失动画或页面。"
        case .imageEncode:
            "无法编码或写入图片。"
        case let .cleanupFailed(path, reason):
            "转换失败，且无法清理未完成文件「\(path)」：\(reason)"
        case let .document(reason):
            reason
        case let .sizeExceeded(actual, limit):
            "结果为 \(ByteCountFormatter.string(fromByteCount: actual, countStyle: .file))，超过目标 \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))。请降低分辨率、图片尺寸或放宽大小限制；未完成文件已移除。"
        case .incompleteMedia:
            "大小限制无法容纳完整内容。请降低分辨率或放宽限制；截短结果不会加入文件篮。"
        case let .engine(message): message
        }
    }
}

actor BasketConversionWorker {
    func plan(
        urls: [URL], action: BasketConversionAction, includeSubfolders: Bool,
        settings: BasketConversionSettings
    ) throws -> BasketConversionBatch {
        try BasketConversionPlanner.plan(
            urls: urls, action: action, includeSubfolders: includeSubfolders, settings: settings
        )
    }

    func convert(
        _ input: URL,
        action: BasketConversionAction,
        settings: BasketConversionSettings,
        outputFolder: URL? = nil,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> URL {
        try Task.checkCancellation()
        let inputBytes = Int64(try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let byteLimit = settings.byteLimit(inputBytes: inputBytes, category: action.category)
        let outputFolder = outputFolder
            ?? (settings.besideOriginal ? input.deletingLastPathComponent() : settings.outputFolder)
        let directory = outputFolder.appendingPathComponent(".weclaw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory
            .appendingPathComponent("result")
            .appendingPathExtension(action.fileExtension)
        do {
            if action.isImage {
                try autoreleasepool {
                    try convertImage(input, output: output, action: action, settings: settings, byteLimit: byteLimit)
                }
            } else if action.isDocument {
                try autoreleasepool {
                    try convertDocument(input, output: output, action: action, settings: settings)
                }
            } else {
                if settings.useFFmpeg || action.requiresFFmpeg {
                    try await convertWithFFmpeg(input, output: output, action: action, settings: settings, byteLimit: byteLimit, progress: progress)
                } else {
                    try await convertMedia(input, output: output, action: action, settings: settings, byteLimit: byteLimit, progress: progress)
                }
            }
            try Task.checkCancellation()
            let outputBytes = Int64(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            if let byteLimit, outputBytes > byteLimit {
                throw BasketConversionError.sizeExceeded(outputBytes, byteLimit)
            }
            let base = input.deletingPathExtension().lastPathComponent
                + (settings.keepOriginalName ? "" : settings.nameSuffix)
            var destination = outputFolder.appendingPathComponent(base).appendingPathExtension(action.fileExtension)
            var counter = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = outputFolder.appendingPathComponent("\(base) (\(counter))")
                    .appendingPathExtension(action.fileExtension)
                counter += 1
            }
            try FileManager.default.moveItem(at: output, to: destination)
            try FileManager.default.removeItem(at: directory)
            return destination
        } catch {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                throw BasketConversionError.cleanupFailed(directory.path, error.localizedDescription)
            }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func convertMedia(
        _ input: URL,
        output: URL,
        action: BasketConversionAction,
        settings: BasketConversionSettings,
        byteLimit: Int64?,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let asset = AVURLAsset(url: input)
        let mediaType: AVMediaType = action == .m4a ? .audio : .video
        guard try await !asset.loadTracks(withMediaType: mediaType).isEmpty else {
            throw BasketConversionError.incompatibleMedia(input.lastPathComponent)
        }
        if action == .m4a {
            try await convertAudio(asset, output: output, settings: settings, progress: progress)
            return
        }
        let preset: String
        let fileType: AVFileType
        switch action {
        case .mp4:
            preset = settings.videoSize.preset(hevc: settings.videoHEVC)
            fileType = .mp4
        case .mov:
            preset = AVAssetExportPresetPassthrough
            fileType = .mov
        case .m4a:
            preset = AVAssetExportPresetAppleM4A
            fileType = .m4a
        case .mkv, .webm, .mp3, .wav, .aiff, .flac, .opus:
            preconditionFailure("Extended formats use FFmpeg")
        case .jpeg, .png, .pdf, .txt, .rtf, .compressPDF:
            preconditionFailure("Image actions use ImageIO")
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset),
              exporter.supportedFileTypes.contains(fileType)
        else {
            throw BasketConversionError.incompatibleMedia(input.lastPathComponent)
        }
        exporter.shouldOptimizeForNetworkUse = settings.networkOptimized && action == .mp4
        if !settings.retainMetadata { exporter.metadata = [] }
        if let byteLimit, action == .mp4 || action == .m4a {
            exporter.fileLengthLimit = byteLimit
        }
        let states = exporter.states(updateInterval: 0.25)
        let monitoring = Task {
            for await state in states {
                if case .exporting(let value) = state {
                    await progress(value.fractionCompleted)
                }
            }
        }
        defer { monitoring.cancel() }
        try await exporter.export(to: output, as: fileType)
        let inputDuration = try await asset.load(.duration).seconds
        let outputDuration = try await AVURLAsset(url: output).load(.duration).seconds
        guard inputDuration.isFinite, outputDuration.isFinite,
              abs(inputDuration - outputDuration) <= 0.25 else {
            throw BasketConversionError.incompleteMedia
        }
    }

    private func convertWithFFmpeg(
        _ input: URL,
        output: URL,
        action: BasketConversionAction,
        settings: BasketConversionSettings,
        byteLimit: Int64?,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        guard settings.ffmpegPath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: settings.ffmpegPath) else {
            throw BasketConversionError.engine("请在预设中选择本机可执行的 FFmpeg。")
        }
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-i", input.path]
        if !settings.retainMetadata { arguments += ["-map_metadata", "-1", "-map_chapters", "-1"] }
        if action.category == .video {
            guard action.videoCodecs.contains(settings.videoCodec) else {
                throw BasketConversionError.engine("所选容器不支持此预设编码。")
            }
            if settings.audioVideoOnly == true {
                arguments += ["-map", "0:V", "-map", "0:a?", "-c", "copy"]
                if [.mp4, .mov].contains(action) { arguments += ["-write_tmcd", "0"] }
            } else {
                arguments += ["-map", "0", "-c", "copy"]
            }
            let encoders = ["h264": "libx264", "hevc": "libx265", "vp9": "libvpx-vp9", "av1": "libsvtav1", "prores": "prores_ks", "copy": "copy"]
            arguments += ["-c:v", encoders[settings.videoCodec]!]
            if settings.videoCodec == "copy" {
                arguments += ["-c:a", "copy"]
            } else {
                let dimension: Int
                switch settings.videoSize {
                case .original: dimension = 0
                case .hd720: dimension = 1280
                case .hd1080: dimension = 1920
                case .uhd4K: dimension = 3840
                }
                if dimension > 0 {
                    let shortSide = dimension * 9 / 16
                    arguments += ["-vf", "scale=w='min(iw,if(gte(dar,1),\(dimension),\(shortSide)))':h='min(ih,if(gte(dar,1),\(shortSide),\(dimension)))':force_original_aspect_ratio=decrease:force_divisible_by=2"]
                }
                if settings.frameRate > 0 { arguments += ["-r", "\(settings.frameRate)"] }
                if settings.videoCodec == "prores" {
                    arguments += ["-profile:v", "3", "-pix_fmt", "yuv422p10le"]
                } else {
                    var bitrate = settings.videoBitrateKbps
                    if let byteLimit {
                        let asset = AVURLAsset(url: input)
                        let duration = try await asset.load(.duration).seconds
                        let audioTrackCount = try await asset.loadTracks(withMediaType: .audio).count
                        guard duration.isFinite, duration > 0 else { throw BasketConversionError.incompleteMedia }
                        let budget = Int(Double(byteLimit) * 8 * 0.94 / duration / 1000)
                            - settings.audioBitrate * audioTrackCount
                        guard budget >= 64 else {
                            throw BasketConversionError.engine("大小目标过小，无法容纳完整音视频。")
                        }
                        bitrate = bitrate > 0 ? min(bitrate, budget) : budget
                    }
                    if bitrate > 0 {
                        arguments += ["-b:v", "\(bitrate)k"]
                    } else {
                        arguments += ["-crf", "\(settings.videoCRF)"]
                        if settings.videoCodec == "vp9" { arguments += ["-b:v", "0"] }
                    }
                    if ["h264", "hevc"].contains(settings.videoCodec) {
                        arguments += ["-preset", settings.encoderSpeed, "-pix_fmt", "yuv420p"]
                    } else if settings.videoCodec == "av1" {
                        let speed = switch settings.encoderSpeed {
                        case "fast": "10"
                        case "slow": "4"
                        default: "7"
                        }
                        arguments += ["-preset", speed]
                    } else if settings.videoCodec == "vp9" {
                        let speed = switch settings.encoderSpeed {
                        case "fast": "5"
                        case "slow": "1"
                        default: "3"
                        }
                        arguments += ["-cpu-used", speed]
                    }
                }
                arguments += ["-c:a", action == .webm ? "libopus" : "aac", "-b:a", "\(settings.audioBitrate)k"]
            }
            if settings.networkOptimized && [.mp4, .mov].contains(action) { arguments += ["-movflags", "+faststart"] }
        } else {
            let encoders: [BasketConversionAction: String] = [
                .m4a: "aac", .mp3: "libmp3lame", .wav: "pcm_s16le",
                .aiff: "pcm_s16be", .flac: "flac", .opus: "libopus",
            ]
            guard let encoder = encoders[action] else { throw BasketConversionError.unsupported(input.lastPathComponent) }
            arguments += ["-map", "0:a:0", "-vn", "-c:a", encoder]
            if [.m4a, .mp3, .opus].contains(action) { arguments += ["-b:a", "\(settings.audioBitrate)k"] }
        }
        if settings.videoCodec != "copy" || action.category == .audio {
            if settings.audioSampleRate > 0 { arguments += ["-ar", "\(settings.audioSampleRate)"] }
            if settings.audioChannels > 0 { arguments += ["-ac", "\(settings.audioChannels)"] }
        }
        arguments.append(output.path)
        let duration = try await AVURLAsset(url: input).load(.duration).seconds
        do {
            _ = try await FFmpegProcess.run(
                URL(fileURLWithPath: settings.ffmpegPath), arguments: arguments,
                duration: duration.isFinite && duration > 0 ? duration : nil, progress: progress
            )
        } catch BasketConversionError.engine(let message) where action.category == .video {
            let guidance = settings.audioVideoOnly == true
                ? "转换失败。所选容器或编码可能不支持源文件中的音视频轨道。"
                : "转换失败。当前保留全部轨道，目标容器可能不支持其中的字幕或数据轨道。可在设置 → 转换中编辑此预设，将「轨道」改为「仅音视频」后重试；此选项会移除字幕、封面及数据轨道。"
            throw BasketConversionError.engine("\(guidance)\n\(message)")
        }
        try Task.checkCancellation()
    }

    private func convertAudio(
        _ asset: AVURLAsset,
        output: URL,
        settings: BasketConversionSettings,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = tracks[0]
        let segments = try await track.load(.segments).filter { !$0.isEmpty }
        guard let firstSegment = segments.first, let lastSegment = segments.last else {
            throw BasketConversionError.incompatibleMedia(asset.url.lastPathComponent)
        }
        let timeRange = CMTimeRange(
            start: firstSegment.timeMapping.target.start,
            end: CMTimeRangeGetEnd(lastSegment.timeMapping.target)
        )
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            throw BasketConversionError.incompatibleMedia(asset.url.lastPathComponent)
        }
        let sampleRate = settings.audioSampleRate == 0 ? format.pointee.mSampleRate : Double(settings.audioSampleRate)
        let channels = settings.audioChannels == 0 ? Int(format.pointee.mChannelsPerFrame) : settings.audioChannels
        let composition = AVMutableComposition()
        guard let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BasketConversionError.incompatibleMedia(asset.url.lastPathComponent)
        }
        try audioTrack.insertTimeRange(timeRange, of: track, at: .zero)
        let reader = try AVAssetReader(asset: composition)
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(readerOutput)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: settings.audioBitrate * 1000,
        ])
        guard writer.canAdd(writerInput) else {
            throw BasketConversionError.incompatibleMedia(asset.url.lastPathComponent)
        }
        writer.add(writerInput)
        if settings.retainMetadata { writer.metadata = try await asset.load(.metadata) }
        guard writer.startWriting(), reader.startReading() else {
            throw writer.error ?? reader.error ?? BasketConversionError.incompatibleMedia(asset.url.lastPathComponent)
        }
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        writer.startSession(atSourceTime: .zero)
        var nextProgressUpdate = Date.distantPast
        while reader.status == .reading {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw writer.error ?? BasketConversionError.incompatibleMedia(asset.url.lastPathComponent)
            }
            if !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            guard let sample = readerOutput.copyNextSampleBuffer() else { break }
            guard writerInput.append(sample) else {
                throw writer.error ?? BasketConversionError.incompatibleMedia(asset.url.lastPathComponent)
            }
            if Date() >= nextProgressUpdate {
                nextProgressUpdate = Date().addingTimeInterval(0.25)
                let fraction = CMSampleBufferGetPresentationTimeStamp(sample).seconds / timeRange.duration.seconds
                if fraction.isFinite { await progress(max(0, min(1, fraction))) }
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? BasketConversionError.incompleteMedia
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? BasketConversionError.incompleteMedia
        }
        let originalDuration = timeRange.duration.seconds
        let outputDuration = try await AVURLAsset(url: output).load(.duration).seconds
        guard originalDuration.isFinite, outputDuration.isFinite,
              abs(originalDuration - outputDuration) <= 0.25 else {
            throw BasketConversionError.incompleteMedia
        }
    }

    private func convertImage(
        _ input: URL,
        output: URL,
        action: BasketConversionAction,
        settings: BasketConversionSettings,
        byteLimit: Int64?
    ) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw BasketConversionError.imageDecode(input.lastPathComponent)
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw BasketConversionError.animatedImage(input.lastPathComponent)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw BasketConversionError.imageDecode(input.lastPathComponent)
        }
        let originalMax = max(width, height)
        let maxPixel = settings.imageMaxPixel == 0 ? originalMax : min(originalMax, settings.imageMaxPixel)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw BasketConversionError.imageDecode(input.lastPathComponent)
        }
        if action == .jpeg {
            guard let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { throw BasketConversionError.imageEncode }
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(CGColor(gray: settings.jpegBackground == "black" ? 0 : 1, alpha: 1))
            context.fill(rect)
            context.draw(image, in: rect)
            guard let flattened = context.makeImage() else { throw BasketConversionError.imageEncode }
            image = flattened
        }
        try Task.checkCancellation()
        let type = action == .jpeg ? UTType.jpeg : UTType.png
        var quality = settings.jpegQuality
        var lowerQuality = 0.1
        var upperQuality = settings.jpegQuality
        var bestData: Data?
        let attempts = action == .jpeg && byteLimit != nil ? 7 : 1
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data, type.identifier as CFString, 1, nil
            ) else { throw BasketConversionError.imageEncode }
            let outputOptions: [CFString: Any] = action == .jpeg
                ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
            CGImageDestinationAddImage(destination, image, outputOptions as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw BasketConversionError.imageEncode }
            if let byteLimit, Int64(data.length) > byteLimit {
                upperQuality = quality
                if attempt == attempts - 1, bestData == nil {
                    throw BasketConversionError.sizeExceeded(Int64(data.length), byteLimit)
                }
            } else {
                bestData = data as Data
                if attempt == 0 { break }
                lowerQuality = quality
            }
            quality = attempt == 0 ? lowerQuality : (lowerQuality + upperQuality) / 2
        }
        guard let bestData else { throw BasketConversionError.imageEncode }
        try bestData.write(to: output)
    }

    private func convertDocument(
        _ input: URL,
        output: URL,
        action: BasketConversionAction,
        settings: BasketConversionSettings
    ) throws {
        if action == .compressPDF {
            guard let document = PDFDocument(url: input), document.pageCount > 0, !document.isEncrypted else {
                throw BasketConversionError.document("PDF 无法打开、没有页面或已加密，无法压缩。")
            }
            let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
            guard let filter = QuartzFilter(url: filterURL) else {
                throw BasketConversionError.document("系统 PDF 压缩滤镜不可用。")
            }
            let options: [PDFDocumentWriteOption: Any] = [
                PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter,
                .saveImagesAsJPEGOption: settings.pdfJPEG,
                .optimizeImagesForScreenOption: settings.pdfScreen,
            ]
            guard document.write(to: output, withOptions: options),
                  let compressed = PDFDocument(url: output),
                  compressed.pageCount == document.pageCount else {
                throw BasketConversionError.document("PDF 压缩失败或输出页数不完整。")
            }
            return
        }
        let document: NSAttributedString
        switch input.pathExtension.lowercased() {
        case "pdf":
            guard let pdf = PDFDocument(url: input), !pdf.isLocked,
                  let text = pdf.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BasketConversionError.document("PDF 没有可提取文字或已加密。扫描件需要 OCR，本功能不执行 OCR。")
            }
            document = NSAttributedString(string: text)
        case "txt", "md", "markdown":
            let text = try String(contentsOf: input, encoding: .utf8)
            document = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: settings.documentFontSize),
                .foregroundColor: NSColor.black,
            ])
        default:
            let type: NSAttributedString.DocumentType = input.pathExtension.lowercased() == "docx" ? .officeOpenXML : .rtf
            document = try NSAttributedString(
                url: input,
                options: [.documentType: type],
                documentAttributes: nil
            )
        }
        try Task.checkCancellation()
        if action == .txt {
            try document.string.write(to: output, atomically: true, encoding: .utf8)
        } else if action == .rtf {
            var hasAttachment = false
            document.enumerateAttribute(.attachment, in: NSRange(location: 0, length: document.length)) { value, _, stop in
                if value != nil { hasAttachment = true; stop.pointee = true }
            }
            guard !hasAttachment else {
                throw BasketConversionError.document("文档包含嵌入附件，无法完整保存为 RTF。可选择 TXT 提取正文。")
            }
            let data = try document.data(
                from: NSRange(location: 0, length: document.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            try data.write(to: output)
        } else {
            var unsupportedLayout = false
            document.enumerateAttributes(in: NSRange(location: 0, length: document.length)) { attributes, _, stop in
                if attributes[.attachment] != nil
                    || (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.isEmpty == false {
                    unsupportedLayout = true
                    stop.pointee = true
                }
            }
            guard !unsupportedLayout else {
                throw BasketConversionError.document("此文档含图片或表格，当前 PDF 导出仅支持文字排版。请从原文档应用导出 PDF。")
            }
            let paperSize = settings.pdfPaper == "letter"
                ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
            var mediaBox = CGRect(
                x: 0, y: 0,
                width: settings.pdfLandscape ? paperSize.height : paperSize.width,
                height: settings.pdfLandscape ? paperSize.width : paperSize.height
            )
            guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else {
                throw BasketConversionError.document("无法创建 PDF。")
            }
            defer { context.closePDF() }
            let framesetter = CTFramesetterCreateWithAttributedString(document)
            let path = CGPath(rect: mediaBox.insetBy(dx: settings.pdfMargin, dy: settings.pdfMargin), transform: nil)
            var position = 0
            repeat {
                try Task.checkCancellation()
                context.beginPDFPage(nil)
                let frame = CTFramesetterCreateFrame(
                    framesetter, CFRange(location: position, length: 0), path, nil
                )
                CTFrameDraw(frame, context)
                context.endPDFPage()
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 || document.length == 0 else {
                    throw BasketConversionError.document("文档内容无法排入 PDF 页面。")
                }
                position += visible.length
            } while position < document.length
        }
    }
}

enum BasketConversionQueueState: String, Sendable {
    case waiting = "等待中"
    case running = "转换中"
    case completed = "已完成"
    case failed = "失败"
    case cancelled = "已取消"
    case skipped = "未执行"

    var systemImage: String {
        switch self {
        case .waiting: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        case .skipped: "minus.circle"
        }
    }
}

struct BasketConversionQueueItem: Identifiable, Sendable {
    let id = UUID()
    let input: URL
    let displayName: String
    var state: BasketConversionQueueState = .waiting
    var progress: Double?
    var output: URL?
    var message: String?

    init(input: URL, displayName: String? = nil) {
        self.input = input
        self.displayName = displayName ?? input.lastPathComponent
    }
}

struct BasketConversionBatch: Sendable {
    struct Entry: Sendable {
        let input: URL
        let outputFolder: URL
        let relativePath: String
        let resultFolder: URL?
    }

    let entries: [Entry]
    let skippedCount: Int
}

enum BasketConversionPlanner {
    static func plan(
        urls: [URL],
        action: BasketConversionAction,
        includeSubfolders: Bool,
        settings: BasketConversionSettings
    ) throws -> BasketConversionBatch {
        var entries: [BasketConversionBatch.Entry] = []
        var seenInputs = Set<String>()
        var reservedFolders = Set<String>()
        var skipped = 0
        var seenRoots = Set<String>()
        for input in urls.map(\.standardizedFileURL) where seenRoots.insert(input.path).inserted {
            try Task.checkCancellation()
            switch ShelfItem.kind(for: input) {
            case .file:
                guard action.accepts(input) else {
                    throw BasketConversionError.unsupported(input.lastPathComponent)
                }
                if seenInputs.insert(input.path).inserted {
                    entries.append(.init(
                        input: input,
                        outputFolder: settings.besideOriginal
                            ? input.deletingLastPathComponent() : settings.outputFolder,
                        relativePath: input.lastPathComponent,
                        resultFolder: nil
                    ))
                }
            case .folder:
                let folder = input.resolvingSymlinksInPath()
                let parent = settings.besideOriginal
                    ? input.deletingLastPathComponent()
                    : settings.outputFolder
                let base = "\(input.lastPathComponent)-转换结果"
                var resultFolder = parent.appendingPathComponent(base, isDirectory: true)
                var counter = 2
                while FileManager.default.fileExists(atPath: resultFolder.path)
                    || reservedFolders.contains(resultFolder.path) {
                    resultFolder = parent.appendingPathComponent("\(base) (\(counter))", isDirectory: true)
                    counter += 1
                }
                reservedFolders.insert(resultFolder.path)
                var scanError: Error?
                var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
                if !includeSubfolders { options.insert(.skipsSubdirectoryDescendants) }
                guard let enumerator = FileManager.default.enumerator(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                    options: options,
                    errorHandler: { _, error in
                        scanError = error
                        return false
                    }
                ) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
                var folderEntries: [BasketConversionBatch.Entry] = []
                for case let file as URL in enumerator {
                    try Task.checkCancellation()
                    let values = try file.resourceValues(
                        forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
                    )
                    if values.isSymbolicLink == true {
                        skipped += 1
                    } else if values.isPackage == true {
                        enumerator.skipDescendants()
                        skipped += 1
                    } else if values.isRegularFile == true,
                              seenInputs.insert(file.resolvingSymlinksInPath().path).inserted {
                        if action.accepts(file) {
                            let relative = String(file.resolvingSymlinksInPath().path.dropFirst(prefix.count))
                            let relativeParent = (relative as NSString).deletingLastPathComponent
                            folderEntries.append(.init(
                                input: file,
                                outputFolder: relativeParent.isEmpty ? resultFolder
                                    : resultFolder.appendingPathComponent(relativeParent, isDirectory: true),
                                relativePath: "\(input.lastPathComponent)/\(relative)",
                                resultFolder: resultFolder
                            ))
                        } else {
                            skipped += 1
                        }
                    }
                }
                if let scanError { throw scanError }
                entries.append(contentsOf: folderEntries.sorted { $0.relativePath < $1.relativePath })
            default:
                throw BasketConversionError.unsupported(input.lastPathComponent)
            }
        }
        return BasketConversionBatch(
            entries: entries,
            skippedCount: skipped
        )
    }
}

@MainActor
final class BasketConversionController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var outputs: [URL] = []
    @Published var errorMessage: String?
    @Published private(set) var sizeSummary = ""
    @Published private(set) var progress: Double?
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var currentFileName = ""
    @Published private(set) var skippedCount = 0
    @Published private(set) var resultURLs: [URL] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var queue: [BasketConversionQueueItem] = []

    var progressLabel: String {
        if isCancelling { return "正在取消" }
        if isScanning { return "正在扫描" }
        if let progress { return progress.formatted(.percent.precision(.fractionLength(0))) }
        return "\(completedCount)/\(totalCount)"
    }

    private var task: Task<Void, Never>?
    private let worker = BasketConversionWorker()

    @discardableResult
    func start(
        urls: [URL], preset: BasketConversionPreset, shelf: ShelfModel,
        includeSubfolders: Bool = false
    ) -> Bool {
        var settings = preset.settings
        let output = BasketConversionSettings()
        settings.outputFolder = output.outputFolder
        settings.besideOriginal = output.besideOriginal
        settings.keepOriginalName = output.keepOriginalName
        settings.nameSuffix = output.nameSuffix
        if (preset.action.category == .video || preset.action.category == .audio)
            && (settings.useFFmpeg || preset.action.requiresFFmpeg) {
            guard FFmpegSupport.shared.isAvailable else {
                errorMessage = "FFmpeg 尚未就绪。请在设置 → 转换中点「检测本机」或「一键安装」。"
                return false
            }
            settings.ffmpegPath = FFmpegSupport.shared.path
        }
        return start(
            urls: urls, action: preset.action, shelf: shelf,
            includeSubfolders: includeSubfolders, settings: settings
        )
    }

    @discardableResult
    func start(
        urls: [URL],
        action: BasketConversionAction,
        shelf: ShelfModel,
        includeSubfolders: Bool = false,
        settings: BasketConversionSettings = BasketConversionSettings()
    ) -> Bool {
        guard !isRunning else { return false }
        guard !urls.isEmpty else {
            errorMessage = "请先选择文件，或直接将文件拖到转换按钮上。"
            return false
        }
        guard settings.isValid else {
            errorMessage = BasketConversionError.invalidSettings.localizedDescription
            return false
        }
        let containsFolders = urls.contains { ShelfItem.kind(for: $0) == .folder }
        let initialBatch: BasketConversionBatch?
        do {
            initialBatch = containsFolders ? nil : try BasketConversionPlanner.plan(
                urls: urls,
                action: action,
                includeSubfolders: includeSubfolders,
                settings: settings
            )
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        shelf.add(urls: urls)
        outputs = []
        resultURLs = []
        errorMessage = nil
        sizeSummary = ""
        progress = nil
        completedCount = 0
        totalCount = initialBatch?.entries.count ?? 0
        skippedCount = 0
        currentFileName = ""
        isCancelling = false
        isRunning = true
        isScanning = containsFolders
        queue = []
        status = containsFolders ? "正在扫描文件夹…" : "\(action.title) · 0/\(totalCount)"
        task = Task {
            defer {
                isRunning = false
                isScanning = false
                isCancelling = false
                task = nil
            }
            do {
                let batch: BasketConversionBatch
                if let initialBatch {
                    batch = initialBatch
                } else {
                    batch = try await worker.plan(
                        urls: urls, action: action, includeSubfolders: includeSubfolders, settings: settings
                    )
                }
                try Task.checkCancellation()
                isScanning = false
                skippedCount = batch.skippedCount
                totalCount = batch.entries.count
                guard !batch.entries.isEmpty else {
                    throw BasketConversionError.engine("没有匹配此预设的文件。可尝试开启「包含子文件夹」或选择其他预设。")
                }
                queue = batch.entries.map { BasketConversionQueueItem(input: $0.input, displayName: $0.relativePath) }
                var originalBytes: Int64 = 0
                var resultBytes: Int64 = 0
                for (index, entry) in batch.entries.enumerated() {
                    let input = entry.input
                    try Task.checkCancellation()
                    currentFileName = entry.relativePath
                    queue[index].state = .running
                    progress = index == 0 ? nil : Double(index) / Double(totalCount)
                    status = "\(action.title) · \(index + 1)/\(totalCount)"
                    let output = try await worker.convert(
                        input, action: action, settings: settings, outputFolder: entry.outputFolder
                    ) { fraction in
                        await self.updateProgress(fraction, index: index, count: batch.entries.count)
                    }
                    outputs.append(output)
                    queue[index].state = .completed
                    queue[index].progress = 1
                    queue[index].output = output
                    completedCount = outputs.count
                    let result = entry.resultFolder ?? output
                    if !resultURLs.contains(result) {
                        resultURLs.append(result)
                        shelf.add(urls: [result])
                    }
                    originalBytes += Int64(try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                    resultBytes += Int64(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                    sizeSummary = "\(ByteCountFormatter.string(fromByteCount: originalBytes, countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: resultBytes, countStyle: .file))"
                }
                status = "已转换 \(outputs.count) 个"
                progress = 1
            } catch {
                if error is CancellationError || Task.isCancelled {
                    for index in queue.indices where queue[index].state == .running || queue[index].state == .waiting {
                        queue[index].state = .cancelled
                    }
                    status = "已取消 · 完成 \(outputs.count)/\(totalCount)"
                } else {
                    for index in queue.indices {
                        if queue[index].state == .running {
                            queue[index].state = .failed
                            queue[index].message = error.localizedDescription
                        } else if queue[index].state == .waiting {
                            queue[index].state = .skipped
                        }
                    }
                    status = "转换失败 · 完成 \(outputs.count)/\(totalCount)"
                    errorMessage = error.localizedDescription
                }
            }
        }
        return true
    }

    func cancel() {
        guard isRunning else { return }
        isCancelling = true
        task?.cancel()
    }

    private func updateProgress(_ fraction: Double, index: Int, count: Int) {
        guard isRunning, !isCancelling, queue[index].state == .running, fraction.isFinite else { return }
        let overall = (Double(index) + max(0, min(0.99, fraction))) / Double(count)
        progress = max(progress ?? 0, min(0.99, overall))
        queue[index].progress = max(queue[index].progress ?? 0, max(0, min(0.99, fraction)))
    }

    func dismissStatus() {
        status = ""
    }
}
