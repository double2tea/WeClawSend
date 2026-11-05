import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

@main
struct ConversionChecks {
    @MainActor
    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("weclaw-conversion-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "WeClawSend.ConversionChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? manager.removeItem(at: root)
        }
        defaults.set(root.appendingPathComponent("output").path, forKey: BasketConversionSettings.outputFolderKey)
        let settings = BasketConversionSettings(defaults: defaults)
        var legacySettingsJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        legacySettingsJSON.removeValue(forKey: "audioVideoOnly")
        let restoredTrackSettings = try JSONDecoder().decode(
            BasketConversionSettings.self, from: JSONSerialization.data(withJSONObject: legacySettingsJSON)
        )
        precondition(restoredTrackSettings.audioVideoOnly == nil)
        precondition(settings.videoSize == .hd1080 && !settings.videoHEVC && settings.jpegQuality == 0.85)
        precondition(settings.imageMaxPixel == 0)
        let support = FFmpegSupport(defaults: defaults, installFolder: root.appendingPathComponent("tools"))
        if ProcessInfo.processInfo.environment["WECLAW_TEST_FFMPEG_INSTALL"] == "1" {
            support.install()
        } else {
            support.detect()
        }
        let toolDeadline = Date().addingTimeInterval(240)
        while support.isBusy {
            precondition(Date() < toolDeadline, "FFmpeg setup timed out")
            try await Task.sleep(for: .milliseconds(100))
        }
        if ProcessInfo.processInfo.environment["WECLAW_TEST_FFMPEG_INSTALL"] == "1" {
            precondition(support.isAvailable, support.errorMessage ?? support.status)
        }
        if support.isAvailable {
            precondition(!support.encoders.isEmpty)
            precondition(defaults.string(forKey: FFmpegSupport.pathKey) == support.path)
            print("FFmpeg detection/setup and encoder verification passed: \(support.path)")
            defaults.set("/usr/bin/true", forKey: FFmpegSupport.pathKey)
            let repairedSupport = FFmpegSupport(defaults: defaults, installFolder: root.appendingPathComponent("tools"))
            repairedSupport.detect()
            while repairedSupport.isBusy {
                precondition(Date() < toolDeadline)
                try await Task.sleep(for: .milliseconds(50))
            }
            precondition(repairedSupport.isAvailable)
            repairedSupport.select(URL(fileURLWithPath: "/usr/bin/true"))
            while repairedSupport.isBusy {
                precondition(Date() < toolDeadline)
                try await Task.sleep(for: .milliseconds(50))
            }
            precondition(!repairedSupport.isAvailable && repairedSupport.errorMessage != nil)
        }
        let presetStore = BasketConversionPresetStore(defaults: defaults)
        let initialCount = presetStore.presets.count
        precondition(initialCount == 28)
        precondition(Set(presetStore.presets.map(\.id)).count == initialCount)
        precondition(presetStore.presets.allSatisfy { $0.settings.isValid })
        precondition(presetStore.presets.filter(\.isEnabled).count == 5)
        let videoCompression = presetStore.presets.first { $0.name == "视频压缩 · 20 MiB" }!
        precondition(videoCompression.settings.useFFmpeg)
        precondition(videoCompression.settings.byteLimit(inputBytes: 100_000_000, category: .video) == 20 * 1_048_576)
        let pdfCompression = presetStore.presets.first { $0.action == .compressPDF }!
        precondition(pdfCompression.settings.pdfJPEG && pdfCompression.settings.pdfScreen)
        precondition(Set(presetStore.presets.map(\.action)) == Set(BasketConversionAction.allCases))
        let versionOnePresets = Array(presetStore.presets.prefix(18))
        defaults.set(try JSONEncoder().encode(versionOnePresets), forKey: BasketConversionPresetStore.storageKey)
        defaults.set(1, forKey: BasketConversionPresetStore.defaultPresetVersionKey)
        let versionTwoStore = BasketConversionPresetStore(defaults: defaults)
        precondition(versionTwoStore.presets.count == 28)
        precondition(versionTwoStore.presets.prefix(18).map(\.id) == versionOnePresets.map(\.id))
        precondition(versionTwoStore.presets.dropFirst(18).allSatisfy { !$0.isEnabled })
        precondition(BasketConversionPresetStore(defaults: defaults).presets.count == 28)
        precondition(defaults.integer(forKey: BasketConversionPresetStore.defaultPresetVersionKey) == 2)
        let compression25 = versionTwoStore.presets.first { $0.name == "视频压缩 · 25 MiB" }!
        precondition(compression25.settings.useFFmpeg)
        precondition(compression25.settings.byteLimit(inputBytes: 100_000_000, category: .video) == 25 * 1_048_576)
        let opusPreset = versionTwoStore.presets.first { $0.action == .opus }!
        precondition(opusPreset.settings.audioBitrate == 64)
        var firstPreset = BasketConversionPreset(name: "分享 20 MiB", action: .mp4, settings: settings)
        firstPreset.settings.categoryLimits[.video] = BasketConversionSizeLimit(maximum: 20, percent: 0)
        precondition(presetStore.save(firstPreset))
        var secondPreset = firstPreset
        secondPreset.id = UUID()
        secondPreset.name = "分享 5 MiB"
        secondPreset.settings.categoryLimits[.video] = BasketConversionSizeLimit(maximum: 5, percent: 0)
        precondition(presetStore.save(secondPreset))
        let restoredPresets = BasketConversionPresetStore(defaults: defaults)
        precondition(restoredPresets.presets.count == initialCount + 2)
        precondition(restoredPresets.presets.first { $0.id == firstPreset.id }!.settings.byteLimit(inputBytes: 100_000_000, category: .video) == 20 * 1_048_576)
        precondition(restoredPresets.presets.first { $0.id == secondPreset.id }!.settings.byteLimit(inputBytes: 100_000_000, category: .video) == 5 * 1_048_576)
        restoredPresets.setEnabled(firstPreset.id, enabled: false)
        precondition(!BasketConversionPresetStore(defaults: defaults).presets.first { $0.id == firstPreset.id }!.isEnabled)
        var editedBuiltIn = restoredPresets.presets[0]
        editedBuiltIn.name = "我的分享设置"
        editedBuiltIn.settings.videoSize = .hd720
        editedBuiltIn.isEnabled = false
        precondition(restoredPresets.save(editedBuiltIn))
        let deletedBuiltInID = restoredPresets.presets[1].id
        restoredPresets.remove(deletedBuiltInID)
        let afterDeletion = BasketConversionPresetStore(defaults: defaults)
        precondition(!afterDeletion.presets.contains { $0.id == deletedBuiltInID })
        precondition(afterDeletion.presets.first { $0.id == editedBuiltIn.id }!.name == "我的分享设置")
        defaults.removeObject(forKey: BasketConversionPresetStore.defaultPresetVersionKey)
        let upgradedPresets = BasketConversionPresetStore(defaults: defaults)
        precondition(upgradedPresets.presets.count == initialCount + 1)
        precondition(!upgradedPresets.presets.first { $0.id == firstPreset.id }!.isEnabled)
        precondition(!upgradedPresets.presets.first { $0.id == editedBuiltIn.id }!.isEnabled)
        precondition(upgradedPresets.presets.first { $0.id == editedBuiltIn.id }!.settings.videoSize == .hd720)
        precondition(!upgradedPresets.presets.contains { $0.id == deletedBuiltInID })
        let legacyPresets = [firstPreset, secondPreset]
        defaults.set(try JSONEncoder().encode(legacyPresets), forKey: BasketConversionPresetStore.storageKey)
        defaults.removeObject(forKey: BasketConversionPresetStore.defaultPresetVersionKey)
        let migratedPresets = BasketConversionPresetStore(defaults: defaults)
        precondition(migratedPresets.presets.count == initialCount + 1)
        precondition(migratedPresets.presets[0].id == firstPreset.id)
        precondition(migratedPresets.presets[0].settings.categoryLimits[.video]?.maximum == 20)
        precondition(migratedPresets.presets.dropFirst(2).allSatisfy { !$0.isEnabled })
        restoredPresets.remove(firstPreset.id)
        restoredPresets.remove(secondPreset.id)
        for preset in restoredPresets.presets { restoredPresets.remove(preset.id) }
        precondition(BasketConversionPresetStore(defaults: defaults).presets.isEmpty)
        defaults.removeObject(forKey: BasketConversionPresetStore.storageKey)
        defaults.removeObject(forKey: BasketConversionPresetStore.defaultPresetVersionKey)
        defaults.set("jpeg", forKey: BasketConversionSettings.quickActionsKey)
        defaults.set(0.65, forKey: BasketConversionSettings.jpegQualityKey)
        let legacyStore = BasketConversionPresetStore(defaults: defaults)
        precondition(legacyStore.presets.filter(\.isEnabled).count == 1)
        precondition(legacyStore.presets.first(where: \.isEnabled)?.action == .jpeg)
        precondition(legacyStore.presets.first(where: \.isEnabled)?.settings.jpegQuality == 0.65)
        defaults.removeObject(forKey: BasketConversionPresetStore.storageKey)
        defaults.set("", forKey: BasketConversionSettings.quickActionsKey)
        precondition(BasketConversionPresetStore(defaults: defaults).presets.allSatisfy { !$0.isEnabled })
        defaults.removeObject(forKey: BasketConversionSettings.quickActionsKey)
        defaults.removeObject(forKey: BasketConversionSettings.jpegQualityKey)
        print("Preset persistence, independent parameters, enable/disable and deletion passed")

        let input = root.appendingPathComponent("透明.png")
        let context = CGContext(
            data: nil, width: 2048, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        let originalBytes = try Data(contentsOf: input)
        var inheritedImage = BasketConversionPreset(name: "图片", action: .jpeg, settings: settings)
        inheritedImage.settings.useFFmpeg = true
        let imageController = BasketConversionController()
        precondition(imageController.start(urls: [input], preset: inheritedImage, shelf: ShelfModel()))
        imageController.cancel()
        try await wait(imageController)
        precondition(BasketConversionAction.jpeg.accepts(input))
        precondition(!BasketConversionAction.mp4.accepts(input))
        precondition(!BasketConversionAction.jpeg.accepts(root))
        let link = root.appendingPathComponent("link.png")
        try manager.createSymbolicLink(at: link, withDestinationURL: input)
        precondition(!BasketConversionAction.jpeg.accepts(link))

        defaults.set(1280, forKey: BasketConversionSettings.imageMaxPixelKey)
        let controller = BasketConversionController()
        let shelf = ShelfModel()
        precondition(controller.start(
            urls: [input, input], action: .jpeg, shelf: shelf,
            settings: BasketConversionSettings(defaults: defaults)
        ))
        precondition(!controller.start(urls: [input], action: .png, shelf: shelf, settings: settings))
        try await wait(controller)
        precondition(controller.errorMessage == nil && controller.outputs.count == 1 && shelf.items.count == 2)
        precondition(controller.queue.count == 1 && controller.queue[0].state == .completed)
        precondition(controller.queue[0].output == controller.outputs[0] && controller.progress == 1)
        let jpegURL = controller.outputs[0]
        let jpegSource = CGImageSourceCreateWithURL(jpegURL as CFURL, nil)!
        precondition(CGImageSourceGetType(jpegSource) as String? == UTType.jpeg.identifier)
        let jpegImage = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil)!
        precondition(jpegImage.width == 1280 && jpegImage.height == 640)
        let bitmap = NSBitmapImageRep(cgImage: jpegImage)
        let white = bitmap.colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
        precondition(white.redComponent > 0.98 && white.greenComponent > 0.98 && white.blueComponent > 0.98)
        let worker = BasketConversionWorker()
        let pngURL = try await worker.convert(input, action: .png, settings: settings)
        let pngImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(pngURL as CFURL, nil)!, 0, nil)!
        precondition(pngImage.width == 2048 && pngImage.height == 1024)
        let alpha = NSBitmapImageRep(cgImage: pngImage).colorAt(x: 0, y: 0)!.alphaComponent
        precondition(alpha < 0.01)
        let unchangedImageBytes = try Data(contentsOf: input)
        precondition(unchangedImageBytes == originalBytes)

        let invalid = root.appendingPathComponent("损坏.png")
        try Data("invalid".utf8).write(to: invalid)
        precondition(!controller.start(urls: [input, link], action: .png, shelf: shelf, settings: settings))
        precondition(controller.errorMessage != nil && !controller.isRunning)
        precondition(controller.start(urls: [input, invalid, pngURL], action: .png, shelf: shelf, settings: settings))
        try await wait(controller)
        precondition(controller.outputs.count == 1 && controller.errorMessage != nil)
        precondition(controller.queue.map(\.state) == [.completed, .failed, .skipped])
        precondition(controller.queue[1].message != nil)
        let entries = try manager.contentsOfDirectory(at: settings.outputFolder, includingPropertiesForKeys: nil)
        precondition(entries.count == 3)
        precondition(entries.allSatisfy { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true })
        precondition(jpegURL.lastPathComponent == "透明-转换.jpg")
        precondition(controller.outputs[0].lastPathComponent == "透明-转换 (2).png")

        let gif = root.appendingPathComponent("动画.gif")
        let gifDestination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil)!
        CGImageDestinationAddImage(gifDestination, image, nil)
        CGImageDestinationAddImage(gifDestination, image, nil)
        precondition(CGImageDestinationFinalize(gifDestination))
        do {
            _ = try await worker.convert(gif, action: .png, settings: settings)
            preconditionFailure("Animated images must be rejected")
        } catch BasketConversionError.animatedImage {}

        defaults.set(1.5, forKey: BasketConversionSettings.jpegQualityKey)
        precondition(!controller.start(
            urls: [input], action: .jpeg, shelf: shelf,
            settings: BasketConversionSettings(defaults: defaults)
        ))
        defaults.set(0.85, forKey: BasketConversionSettings.jpegQualityKey)
        precondition(controller.start(urls: [input], action: .png, shelf: shelf, settings: settings))
        controller.cancel()
        try await wait(controller)
        precondition(controller.outputs.isEmpty && controller.status.hasPrefix("已取消"))

        let audioURL = root.appendingPathComponent("audio.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100)) * 0.1
        }
        do {
            let audioFile = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try audioFile.write(from: buffer)
        }
        print("Image conversion and cancellation checks passed")
        precondition(BasketConversionAction.m4a.accepts(audioURL))
        let m4a = try await worker.convert(audioURL, action: .m4a, settings: settings)
        let audioTracks = try await AVURLAsset(url: m4a).loadTracks(withMediaType: .audio)
        precondition(audioTracks.count == 1)
        defaults.set(128, forKey: BasketConversionSettings.audioBitrateKey)
        defaults.set(48_000, forKey: BasketConversionSettings.audioSampleRateKey)
        defaults.set(2, forKey: BasketConversionSettings.audioChannelsKey)
        let customAudio = try await worker.convert(audioURL, action: .m4a, settings: BasketConversionSettings(defaults: defaults))
        let customTracks = try await AVURLAsset(url: customAudio).loadTracks(withMediaType: .audio)
        let customDescriptions = try await customTracks[0].load(.formatDescriptions)
        let customFormat = CMAudioFormatDescriptionGetStreamBasicDescription(customDescriptions[0])!.pointee
        precondition(customFormat.mSampleRate == 48_000 && customFormat.mChannelsPerFrame == 2)
        defaults.removeObject(forKey: BasketConversionSettings.audioBitrateKey)
        defaults.removeObject(forKey: BasketConversionSettings.audioSampleRateKey)
        defaults.removeObject(forKey: BasketConversionSettings.audioChannelsKey)
        print("AAC audio export passed")
        if ProcessInfo.processInfo.environment["WECLAW_TEST_FFMPEG_INSTALL"] == "1" {
            var installedSettings = settings
            installedSettings.useFFmpeg = true
            installedSettings.ffmpegPath = support.path
            let installedOutput = try await worker.convert(audioURL, action: .mp3, settings: installedSettings)
            let installedOutputSize = try installedOutput.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            precondition(installedOutputSize > 0)
            print("Downloaded FFmpeg successfully converted a real MP3")
        }

        let videoURL = root.appendingPathComponent("video.mov")
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180,
            ]
        )
        writer.add(videoInput)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<25 {
            while !videoInput.isReadyForMoreMediaData {
                precondition(writer.status == .writing)
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixelBuffer: CVPixelBuffer?
            precondition(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer) == kCVReturnSuccess)
            precondition(adaptor.append(pixelBuffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 25)))
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed)
        let sourceVideoBytes = try Data(contentsOf: videoURL)
        let probeCandidates = [URL(fileURLWithPath: support.path).deletingLastPathComponent().appendingPathComponent("ffprobe").path]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/ffprobe" }
        let probePath = probeCandidates.first { manager.isExecutableFile(atPath: $0) }
        if support.isAvailable, let probePath {
            var extended = settings
            extended.useFFmpeg = true
            extended.ffmpegPath = support.path
            extended.audioSampleRate = 48_000
            for action in [BasketConversionAction.mp3, .wav, .aiff, .flac, .opus] {
                let encoder: [BasketConversionAction: String] = [.mp3: "libmp3lame", .wav: "pcm_s16le", .aiff: "pcm_s16be", .flac: "flac", .opus: "libopus"]
                guard support.encoders.contains(encoder[action]!) else {
                    print("SKIP \(action.rawValue): encoder unavailable")
                    continue
                }
                let converted = try await worker.convert(audioURL, action: action, settings: extended)
                let convertedSize = try converted.resourceValues(forKeys: [.fileSizeKey]).fileSize!
                precondition(convertedSize > 0)
                let probe = try await FFmpegProcess.run(URL(fileURLWithPath: probePath), arguments: [
                    "-v", "error", "-show_entries", "stream=codec_name,sample_rate", "-of", "csv=p=0", converted.path,
                ])
                let expected: [BasketConversionAction: String] = [.mp3: "mp3", .wav: "pcm_s16le", .aiff: "pcm_s16be", .flac: "flac", .opus: "opus"]
                precondition(probe.contains(expected[action]!) && probe.contains("48000"))
            }
            for (action, codec) in [(BasketConversionAction.mkv, "h264"), (.webm, "vp9"), (.mp4, "hevc"), (.mov, "prores"), (.mp4, "av1")] {
                let encoder = ["h264": "libx264", "vp9": "libvpx-vp9", "hevc": "libx265", "prores": "prores_ks", "av1": "libsvtav1"]
                guard support.encoders.contains(encoder[codec]!) else {
                    print("SKIP \(codec): encoder unavailable")
                    continue
                }
                extended.videoCodec = codec
                extended.videoSize = .original
                extended.encoderSpeed = "fast"
                let converted = try await worker.convert(videoURL, action: action, settings: extended)
                let probe = try await FFmpegProcess.run(URL(fileURLWithPath: probePath), arguments: [
                    "-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", converted.path,
                ])
                precondition(probe.contains(codec))
            }
            print("FFmpeg real format checks passed: MP3, WAV, AIFF, FLAC, Opus, MKV/H.264, WebM/VP9, MP4/HEVC, MOV/ProRes")
        } else {
            print("SKIP FFmpeg format checks: verified FFmpeg or ffprobe unavailable")
        }
        if support.isAvailable && support.encoders.contains("libx264") && support.encoders.contains("aac") {
            let executable = URL(fileURLWithPath: support.path)
            let portraitSource = root.appendingPathComponent("portrait.mov")
            _ = try await FFmpegProcess.run(executable, arguments: [
                "-v", "error", "-nostdin", "-n", "-f", "lavfi", "-i", "color=s=1080x1920:r=25:d=0.2",
                "-c:v", "libx264", "-preset", "ultrafast", portraitSource.path,
            ])
            var regression = settings
            regression.useFFmpeg = true
            regression.ffmpegPath = support.path
            let portraitOutput = try await worker.convert(portraitSource, action: .mp4, settings: regression)
            let portraitTracks = try await AVURLAsset(url: portraitOutput).loadTracks(withMediaType: .video)
            let portraitSize = try await portraitTracks[0].load(.naturalSize)
            precondition(abs(portraitSize.width - 1080) <= 1 && abs(portraitSize.height - 1920) <= 1)

            let rotatedSource = root.appendingPathComponent("rotated.mov")
            _ = try await FFmpegProcess.run(executable, arguments: [
                "-v", "error", "-nostdin", "-n", "-display_rotation:v:0", "90", "-i", portraitSource.path,
                "-c", "copy", rotatedSource.path,
            ])
            let rotatedOutput = try await worker.convert(rotatedSource, action: .mp4, settings: regression)
            let rotatedTracks = try await AVURLAsset(url: rotatedOutput).loadTracks(withMediaType: .video)
            let rotatedSize = try await rotatedTracks[0].load(.naturalSize)
            precondition(abs(rotatedSize.width - 1920) <= 1 && abs(rotatedSize.height - 1080) <= 1)

            let subtitles = root.appendingPathComponent("captions.srt")
            try "1\n00:00:00,000 --> 00:00:00,800\nCaption\n".write(to: subtitles, atomically: true, encoding: .utf8)
            let multiSource = root.appendingPathComponent("multi.mov")
            _ = try await FFmpegProcess.run(executable, arguments: [
                "-v", "error", "-nostdin", "-n", "-f", "lavfi", "-i", "color=s=320x180:r=25:d=2",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                "-f", "lavfi", "-i", "sine=frequency=880:duration=2", "-i", subtitles.path,
                "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s",
                "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-c:s", "mov_text", multiSource.path,
            ])
            regression.videoCodec = "copy"
            let copied = try await worker.convert(multiSource, action: .mov, settings: regression)
            let copiedAudio = try await AVURLAsset(url: copied).loadTracks(withMediaType: .audio)
            precondition(copiedAudio.count == 2)
            regression.videoCodec = "h264"
            let transcoded = try await worker.convert(multiSource, action: .mp4, settings: regression)
            let transcodedAudio = try await AVURLAsset(url: transcoded).loadTracks(withMediaType: .audio)
            precondition(transcodedAudio.count == 2)
            if let probePath {
                for result in [copied, transcoded] {
                    let streams = try await FFmpegProcess.run(URL(fileURLWithPath: probePath), arguments: [
                        "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", result.path,
                    ])
                    precondition(streams.split(separator: "\n").filter { $0 == "audio" }.count == 2)
                    precondition(streams.split(separator: "\n").contains("subtitle"))
                }
                regression.audioVideoOnly = true
                let audioVideoOutput = try await worker.convert(multiSource, action: .mp4, settings: regression)
                let audioVideoStreams = try await FFmpegProcess.run(URL(fileURLWithPath: probePath), arguments: [
                    "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", audioVideoOutput.path,
                ])
                precondition(audioVideoStreams.split(separator: "\n").filter { $0 == "audio" }.count == 2)
                precondition(!audioVideoStreams.contains("subtitle") && !audioVideoStreams.contains("data"))
                regression.audioVideoOnly = nil
                let payload = root.appendingPathComponent("track-data.bin")
                try Data(repeating: 42, count: 640).write(to: payload)
                let dataSource = root.appendingPathComponent("data-track.mov")
                _ = try await FFmpegProcess.run(executable, arguments: [
                    "-v", "error", "-nostdin", "-n", "-i", videoURL.path, "-f", "data", "-i", payload.path,
                    "-map", "0:v", "-map", "1:0", "-c", "copy", "-tag:d", "gpmd", dataSource.path,
                ])
                let sourceData = try Data(contentsOf: dataSource)
                var unknownData = sourceData
                let tag = Data("gpmd".utf8)
                while let range = unknownData.range(of: tag) {
                    unknownData.replaceSubrange(range, with: Data("zzzz".utf8))
                }
                let unknownSource = root.appendingPathComponent("unknown-track.mov")
                try unknownData.write(to: unknownSource)
                do {
                    _ = try await worker.convert(unknownSource, action: .mp4, settings: regression)
                    preconditionFailure("Unknown data track must fail in preserve-all mode")
                } catch BasketConversionError.engine(let message) {
                    precondition(message.contains("codec none") && message.contains("仅音视频"))
                }
                regression.audioVideoOnly = true
                let compatibleOutput = try await worker.convert(unknownSource, action: .mp4, settings: regression)
                let compatibleStreams = try await FFmpegProcess.run(URL(fileURLWithPath: probePath), arguments: [
                    "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", compatibleOutput.path,
                ])
                precondition(compatibleStreams.trimmingCharacters(in: .whitespacesAndNewlines) == "video")
                let originalTrackData = try Data(contentsOf: unknownSource)
                precondition(originalTrackData == unknownData)
                regression.audioVideoOnly = nil
                print("Unknown data-track failure reproduced; explicit audio/video mode succeeds and retains all audio tracks")
            } else {
                print("SKIP subtitle stream probe: ffprobe unavailable")
            }
            let extractedAudio = try await worker.convert(multiSource, action: .m4a, settings: settings)
            let extractedDuration = try await AVURLAsset(url: extractedAudio).load(.duration).seconds
            precondition(abs(extractedDuration - 1) < 0.1)
            let delayedSource = root.appendingPathComponent("delayed.mov")
            _ = try await FFmpegProcess.run(executable, arguments: [
                "-v", "error", "-nostdin", "-n", "-i", videoURL.path,
                "-itsoffset", "0.5", "-i", audioURL.path, "-map", "0:v", "-map", "1:a", "-c", "copy", delayedSource.path,
            ])
            let delayedAudio = try await worker.convert(delayedSource, action: .m4a, settings: settings)
            let delayedDuration = try await AVURLAsset(url: delayedAudio).load(.duration).seconds
            precondition(abs(delayedDuration - 1) < 0.1)
            if support.encoders.contains("libvpx-vp9") && support.encoders.contains("libopus") {
                regression.videoCodec = "vp9"
                do {
                    _ = try await worker.convert(multiSource, action: .webm, settings: regression)
                    preconditionFailure("Incompatible subtitles must not be silently dropped")
                } catch BasketConversionError.engine {}
            }
            print("Portrait, rotation, all audio/subtitle tracks, short and delayed audio regressions passed")
        } else {
            print("SKIP media regression fixtures: libx264 / AAC unavailable")
        }

        let slowEngine = root.appendingPathComponent("slow-ffmpeg")
        let started = root.appendingPathComponent("conversion-started")
        try """
        #!/bin/sh
        trap 'exit 0' TERM
        progress_file=""
        previous=""
        for argument in "$@"; do
            if [ "$previous" = "-progress" ]; then progress_file="$argument"; fi
            previous="$argument"
            output="$argument"
        done
        echo partial > "$output"
        printf 'out_time_us=500000\\nprogress=continue\\n' > "$progress_file"
        touch '\(started.path)'
        while :; do sleep 0.05; done
        """.write(to: slowEngine, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowEngine.path)
        var slowSettings = settings
        slowSettings.useFFmpeg = true
        slowSettings.ffmpegPath = slowEngine.path
        let activeShelf = ShelfModel()
        let activeController = BasketConversionController()
        precondition(activeController.start(urls: [videoURL, videoURL, root.appendingPathComponent("queued.mov")], action: .mp4, shelf: activeShelf, settings: slowSettings) == false)
        let queuedVideo = root.appendingPathComponent("queued.mov")
        try manager.copyItem(at: videoURL, to: queuedVideo)
        precondition(activeController.start(urls: [videoURL, queuedVideo], action: .mp4, shelf: activeShelf, settings: slowSettings))
        let startDeadline = Date().addingTimeInterval(10)
        while !manager.fileExists(atPath: started.path) {
            precondition(Date() < startDeadline && activeController.isRunning)
            try await Task.sleep(for: .milliseconds(10))
        }
        let progressDeadline = Date().addingTimeInterval(5)
        while activeController.progress == nil {
            precondition(Date() < progressDeadline && activeController.isRunning)
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(abs(activeController.progress! - 0.25) < 0.05)
        precondition(activeController.currentFileName == videoURL.lastPathComponent)
        precondition(activeController.completedCount == 0 && activeController.totalCount == 2)
        precondition(activeController.queue.map(\.state) == [.running, .waiting])
        precondition(abs(activeController.queue[0].progress! - 0.5) < 0.05)
        activeController.cancel()
        precondition(activeController.isCancelling && activeController.progressLabel == "正在取消")
        try await wait(activeController)
        precondition(activeController.status.hasPrefix("已取消") && activeController.outputs.isEmpty)
        precondition(!activeController.isCancelling)
        precondition(activeShelf.items.count == 2)
        precondition(activeController.queue.allSatisfy { $0.state == .cancelled && $0.output == nil })
        let remainingFiles = try manager.contentsOfDirectory(at: settings.outputFolder, includingPropertiesForKeys: nil)
        precondition(!remainingFiles.contains { $0.lastPathComponent.hasPrefix(".weclaw-") })
        print("Active conversion cancellation terminates process and removes partial output")

        for hevc in [false, true] {
            print("Checking MP4 export: \(hevc ? "HEVC" : "H.264")")
            defaults.set(hevc, forKey: BasketConversionSettings.videoHEVCKey)
            let mp4 = try await worker.convert(
                videoURL, action: .mp4, settings: BasketConversionSettings(defaults: defaults)
            )
            let asset = AVURLAsset(url: mp4)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            precondition(tracks.count == 1)
            let descriptions = try await tracks[0].load(.formatDescriptions)
            let codec = CMFormatDescriptionGetMediaSubType(descriptions[0])
            precondition(codec == (hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264))
            let size = try await tracks[0].load(.naturalSize)
            precondition(size.width <= 1920 && size.height <= 1080)
        }
        let mov = try await worker.convert(videoURL, action: .mov, settings: settings)
        let movTracks = try await AVURLAsset(url: mov).loadTracks(withMediaType: .video)
        let descriptions = try await movTracks[0].load(.formatDescriptions)
        precondition(CMFormatDescriptionGetMediaSubType(descriptions[0]) == kCMVideoCodecType_H264)
        let unchangedVideoBytes = try Data(contentsOf: videoURL)
        precondition(unchangedVideoBytes == sourceVideoBytes)
        do {
            _ = try await worker.convert(videoURL, action: .m4a, settings: settings)
            preconditionFailure("A video without audio cannot export M4A")
        } catch BasketConversionError.incompatibleMedia {}
        let documentURL = root.appendingPathComponent("说明.txt")
        let documentText = "文件篮转换测试\n中文与 English 123\n" + String(repeating: "多页文字应完整保留。\n", count: 160) + "最终结尾-END"
        try documentText.write(to: documentURL, atomically: true, encoding: .utf8)
        precondition(BasketConversionAction.pdf.accepts(documentURL))
        let pdfURL = try await worker.convert(documentURL, action: .pdf, settings: settings)
        let pdfDocument = PDFDocument(url: pdfURL)!
        precondition(pdfDocument.pageCount > 1)
        defaults.set("letter", forKey: BasketConversionSettings.pdfPaperKey)
        defaults.set(true, forKey: BasketConversionSettings.pdfLandscapeKey)
        defaults.set(18.0, forKey: BasketConversionSettings.pdfMarginKey)
        defaults.set(18.0, forKey: BasketConversionSettings.documentFontSizeKey)
        let customPDF = try await worker.convert(documentURL, action: .pdf, settings: BasketConversionSettings(defaults: defaults))
        let customPage = PDFDocument(url: customPDF)!.page(at: 0)!
        precondition(customPage.bounds(for: .mediaBox).size == CGSize(width: 792, height: 612))
        precondition(PDFDocument(url: customPDF)!.string!.contains("最终结尾-END"))
        for key in [
            BasketConversionSettings.pdfPaperKey, BasketConversionSettings.pdfLandscapeKey,
            BasketConversionSettings.pdfMarginKey, BasketConversionSettings.documentFontSizeKey,
        ] { defaults.removeObject(forKey: key) }
        let extracted = try await worker.convert(pdfURL, action: .txt, settings: settings)
        let extractedText = try String(contentsOf: extracted, encoding: .utf8)
        precondition(extractedText.contains("文件篮转换测试") && extractedText.contains("最终结尾-END"))
        let rtfURL = try await worker.convert(documentURL, action: .rtf, settings: settings)
        let textURL = try await worker.convert(rtfURL, action: .txt, settings: settings)
        let text = try String(contentsOf: textURL, encoding: .utf8)
        precondition(text == documentText)
        let docxURL = root.appendingPathComponent("word.docx")
        let attributed = NSAttributedString(string: "DOCX 中文文字", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let docxData = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        try docxData.write(to: docxURL)
        let wordTextURL = try await worker.convert(docxURL, action: .txt, settings: settings)
        let wordText = try String(contentsOf: wordTextURL, encoding: .utf8)
        precondition(wordText.contains("DOCX 中文文字"))
        let wordPDF = try await worker.convert(docxURL, action: .pdf, settings: settings)
        precondition(PDFDocument(url: wordPDF)?.string?.contains("DOCX 中文文字") == true)
        let blankPDF = root.appendingPathComponent("scanned.pdf")
        let blank = PDFDocument()
        blank.insert(PDFPage(image: NSImage(cgImage: image, size: .zero))!, at: 0)
        precondition(blank.write(to: blankPDF))
        do {
            _ = try await worker.convert(blankPDF, action: .txt, settings: settings)
            preconditionFailure("Scanned PDFs must not become empty text files")
        } catch BasketConversionError.document {}

        defaults.set(true, forKey: BasketConversionSettings.besideOriginalKey)
        defaults.set(true, forKey: BasketConversionSettings.keepOriginalNameKey)
        let beside = try await worker.convert(documentURL, action: .txt, settings: BasketConversionSettings(defaults: defaults))
        precondition(beside.deletingLastPathComponent().path == root.path)
        precondition(beside.lastPathComponent == "说明 (2).txt")
        let stillOriginal = try String(contentsOf: documentURL, encoding: .utf8)
        precondition(stillOriginal == documentText)
        defaults.set(false, forKey: BasketConversionSettings.besideOriginalKey)
        defaults.set(false, forKey: BasketConversionSettings.keepOriginalNameKey)
        defaults.set("-分享", forKey: BasketConversionSettings.nameSuffixKey)
        let renamed = try await worker.convert(documentURL, action: .txt, settings: BasketConversionSettings(defaults: defaults))
        precondition(renamed.lastPathComponent == "说明-分享.txt")
        defaults.set(1, forKey: BasketConversionSettings.maximumSizeMBKey)
        defaults.set(50, forKey: BasketConversionSettings.targetPercentKey)
        precondition(BasketConversionSettings(defaults: defaults).byteLimit(inputBytes: 4_000_000) == 1_048_576)
        precondition(BasketConversionSettings(defaults: defaults).byteLimit(inputBytes: 100_000) == 50_000)
        defaults.set(0, forKey: BasketConversionCategory.audio.maximumSizeKey)
        defaults.set(0, forKey: BasketConversionCategory.audio.targetPercentKey)
        precondition(BasketConversionSettings(defaults: defaults).byteLimit(inputBytes: 100_000, category: .audio) == nil)
        precondition(BasketConversionSettings(defaults: defaults).byteLimit(inputBytes: 100_000, category: .image) == 50_000)
        defaults.removeObject(forKey: BasketConversionCategory.audio.maximumSizeKey)
        defaults.removeObject(forKey: BasketConversionCategory.audio.targetPercentKey)
        do {
            _ = try await worker.convert(documentURL, action: .txt, settings: BasketConversionSettings(defaults: defaults))
            preconditionFailure("An oversized document must fail")
        } catch BasketConversionError.sizeExceeded {}
        defaults.set(0, forKey: BasketConversionSettings.targetPercentKey)
        let limitedMP4 = try await worker.convert(videoURL, action: .mp4, settings: BasketConversionSettings(defaults: defaults))
        let limitedBytes = try limitedMP4.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        precondition(limitedBytes <= 1_048_576)
        let limitedDuration = try await AVURLAsset(url: limitedMP4).load(.duration).seconds
        precondition(limitedDuration > 0.7)
        defaults.set(1, forKey: BasketConversionSettings.targetPercentKey)
        do {
            _ = try await worker.convert(videoURL, action: .mp4, settings: BasketConversionSettings(defaults: defaults))
            preconditionFailure("An impossibly small target must fail")
        } catch BasketConversionError.sizeExceeded {
        } catch BasketConversionError.incompleteMedia {
        }
        defaults.set(0, forKey: BasketConversionSettings.targetPercentKey)
        defaults.set(0, forKey: BasketConversionSettings.maximumSizeMBKey)
        defaults.set(0, forKey: BasketConversionSettings.imageMaxPixelKey)
        defaults.set(1.0, forKey: BasketConversionSettings.jpegQualityKey)
        let noisyURL = root.appendingPathComponent("texture.png")
        let noiseContext = CGContext(
            data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 512 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let pixels = noiseContext.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 12345
        for index in 0..<(512 * 512) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[index * 4] = UInt8(truncatingIfNeeded: seed >> 24)
            pixels[index * 4 + 1] = UInt8(truncatingIfNeeded: seed >> 16)
            pixels[index * 4 + 2] = UInt8(truncatingIfNeeded: seed >> 8)
            pixels[index * 4 + 3] = 255
        }
        let noiseDestination = CGImageDestinationCreateWithURL(noisyURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(noiseDestination, noiseContext.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(noiseDestination))
        let largeJPG = try await worker.convert(noisyURL, action: .jpeg, settings: BasketConversionSettings(defaults: defaults))
        defaults.set(25, forKey: BasketConversionSettings.targetPercentKey)
        let compressedJPG = try await worker.convert(largeJPG, action: .jpeg, settings: BasketConversionSettings(defaults: defaults))
        let largeSize = try largeJPG.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        let compressedSize = try compressedJPG.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        precondition(compressedSize <= largeSize / 4)
        let compressedImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(compressedJPG as CFURL, nil)!, 0, nil)!
        precondition(compressedImage.width == 512 && compressedImage.height == 512)
        print("JPG target compression: \(largeSize) → \(compressedSize) bytes (target ≤25%)")
        defaults.set(0, forKey: BasketConversionSettings.targetPercentKey)
        let sourcePDF = root.appendingPathComponent("图文.pdf")
        let imagePDF = PDFDocument()
        imagePDF.insert(pdfDocument.page(at: 0)!.copy() as! PDFPage, at: 0)
        let noisyImage = NSImage(contentsOf: noisyURL)!
        imagePDF.insert(PDFPage(image: noisyImage)!, at: 1)
        let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 40, height: 30), forType: .text, withProperties: nil)
        annotation.contents = "保留批注"
        imagePDF.page(at: 0)!.addAnnotation(annotation)
        precondition(imagePDF.write(to: sourcePDF))
        let originalPDFBytes = try Data(contentsOf: sourcePDF)
        precondition(BasketConversionAction.compressPDF.accepts(sourcePDF))
        precondition(!BasketConversionAction.compressPDF.accepts(noisyURL))
        precondition(controller.start(
            urls: [sourcePDF], action: .compressPDF, shelf: shelf,
            settings: BasketConversionSettings(defaults: defaults)
        ))
        try await wait(controller)
        precondition(controller.errorMessage == nil && controller.outputs.count == 1)
        let compressedPDF = controller.outputs[0]
        let compressedDocument = PDFDocument(url: compressedPDF)!
        precondition(compressedDocument.pageCount == 2)
        precondition(compressedDocument.string == PDFDocument(url: sourcePDF)?.string)
        precondition(compressedDocument.page(at: 0)?.annotations.contains { $0.contents == "保留批注" } == true)
        precondition(shelf.items.contains { $0.path == compressedPDF.path })
        let unchangedPDFBytes = try Data(contentsOf: sourcePDF)
        precondition(unchangedPDFBytes == originalPDFBytes)
        let compressedPDFBytes = try compressedPDF.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        precondition(compressedPDFBytes < originalPDFBytes.count)
        print("PDF compression: \(originalPDFBytes.count) → \(compressedPDFBytes) bytes; pages, text and annotation retained")
        defaults.set(1, forKey: BasketConversionSettings.targetPercentKey)
        precondition(controller.start(
            urls: [sourcePDF], action: .compressPDF, shelf: shelf,
            settings: BasketConversionSettings(defaults: defaults)
        ))
        try await wait(controller)
        precondition(controller.outputs.isEmpty && controller.errorMessage != nil)
        let encryptedPDF = root.appendingPathComponent("加密.pdf")
        precondition(imagePDF.write(to: encryptedPDF, withOptions: [
            .ownerPasswordOption: "owner-test-only",
            .userPasswordOption: "test-only",
        ]))
        precondition(PDFDocument(url: encryptedPDF)?.isEncrypted == true)
        defaults.set(0, forKey: BasketConversionSettings.targetPercentKey)
        precondition(controller.start(
            urls: [encryptedPDF], action: .compressPDF, shelf: shelf,
            settings: BasketConversionSettings(defaults: defaults)
        ))
        try await wait(controller)
        precondition(controller.outputs.isEmpty && controller.errorMessage?.contains("加密") == true)
        for template in versionTwoStore.presets.dropFirst(18) {
            var presetSettings = template.settings
            presetSettings.outputFolder = root.appendingPathComponent("new-preset-outputs")
            presetSettings.besideOriginal = false
            presetSettings.nameSuffix = "-\(template.action.rawValue)"
            presetSettings.ffmpegPath = support.path
            let presetInput: URL
            switch template.action.category {
            case .video: presetInput = videoURL
            case .audio: presetInput = audioURL
            case .image: presetInput = input
            case .document: presetInput = documentURL
            }
            if (presetSettings.useFFmpeg || template.action.requiresFFmpeg) && !support.isAvailable {
                print("SKIP new preset \(template.name): verified FFmpeg unavailable")
                continue
            }
            let output = try await worker.convert(presetInput, action: template.action, settings: presetSettings)
            let outputSize = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            precondition(outputSize > 0)
            if template.action.isImage {
                let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
                let result = CGImageSourceCreateImageAtIndex(source, 0, nil)!
                precondition(result.width == 1280 && result.height == 640)
                if template.action == .png {
                    precondition(result.alphaInfo != .none && result.alphaInfo != .noneSkipLast && result.alphaInfo != .noneSkipFirst)
                }
            } else if template.action == .pdf {
                let document = PDFDocument(url: output)!
                precondition(document.string?.contains("最终结尾-END") == true)
                let bounds = document.page(at: 0)!.bounds(for: .mediaBox)
                precondition((bounds.width > bounds.height) == presetSettings.pdfLandscape)
            } else if template.action.category == .audio, let probePath {
                let probe = try await FFmpegProcess.run(URL(fileURLWithPath: probePath), arguments: [
                    "-v", "error", "-show_entries", "stream=codec_name,sample_rate,bit_rate", "-of", "csv=p=0", output.path,
                ])
                switch template.action {
                case .mp3: precondition(probe.contains("mp3") && probe.contains("320000"))
                case .opus: precondition(probe.contains("opus"))
                case .aiff: precondition(probe.contains("pcm_s16be") && probe.contains("48000"))
                default: preconditionFailure("Unexpected new audio preset")
                }
            } else if template.name == "高效视频 · HEVC 原尺寸" {
                let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
                let size = try await tracks[0].load(.naturalSize)
                let descriptions = try await tracks[0].load(.formatDescriptions)
                precondition(size == CGSize(width: 320, height: 180))
                precondition(CMFormatDescriptionGetMediaSubType(descriptions[0]) == kCMVideoCodecType_HEVC)
            }
            print("New preset output verified: \(template.name)")
        }
        let outputEntries = try manager.contentsOfDirectory(at: settings.outputFolder, includingPropertiesForKeys: nil)
        precondition(!outputEntries.contains { $0.lastPathComponent.hasPrefix(".weclaw-") })
        print("Conversion checks passed: media, images, documents, PDF pagination, output naming, collision preservation, size limits, cleanup and cancellation")
    }

    @MainActor
    private static func wait(_ controller: BasketConversionController) async throws {
        let deadline = Date().addingTimeInterval(30)
        while controller.isRunning {
            precondition(Date() < deadline, "Conversion timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
