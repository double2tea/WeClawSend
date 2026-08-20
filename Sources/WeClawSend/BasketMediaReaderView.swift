import AVFoundation
import AppKit
import Combine
import SwiftUI

/// In-window audio/video reader.  Uses AVPlayer instead of QLPreviewView so
/// opening and leaving the reader does not tear down Quick Look's media
/// pipeline — that path crashes after a few expand/return cycles.
struct BasketMediaReaderView: View {
    private static let playbackRates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    let url: URL

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var playback = BasketMediaPlayback()

    private var isAudio: Bool {
        BasketReaderRouter.isAudioFile(url)
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
            waveform
            controls
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: url) {
            await playback.load(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: BasketMediaPlayback.togglePlayNotification)) { notification in
            guard let target = notification.object as? URL,
                  target.standardizedFileURL == url.standardizedFileURL
            else {
                return
            }
            playback.togglePlay()
        }
        .onDisappear {
            playback.shutdown()
        }
        .onExitCommand {
            playback.pause()
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("媒体阅读器：\(url.lastPathComponent)")
    }

    @ViewBuilder
    private var stage: some View {
        if playback.isLoading {
            BasketReaderLoadingView(
                title: isAudio ? "正在打开音频…" : "正在打开视频…",
                detail: url.lastPathComponent,
                systemImage: isAudio ? "waveform" : "film"
            )
        } else if let message = playback.errorMessage {
            BasketReaderErrorView(
                title: "无法播放",
                message: message,
                systemImage: "play.slash",
                actionTitle: "在原应用中打开",
                action: { NSWorkspace.shared.open(url) }
            )
        } else if playback.hasVideo {
            BasketMediaVideoView(player: playback.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .onTapGesture(perform: playback.togglePlay)
        }
    }

    private var waveform: some View {
        BasketMediaWaveformView(
            samples: playback.waveform,
            progress: playback.progress,
            isLoading: playback.isWaveformLoading
        ) { fraction in
            playback.seek(toFraction: fraction)
        }
        .frame(height: isAudio ? 96 : 52)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { playback.displayTime },
                    set: { playback.scrub(to: $0) }
                ),
                in: 0...max(playback.duration, 0.001),
                onEditingChanged: { editing in
                    playback.setScrubbing(editing)
                }
            )
            .controlSize(.small)
            .disabled(playback.duration <= 0)

            HStack(spacing: 10) {
                Text(BasketMediaPlayback.formatTime(playback.displayTime))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42, alignment: .leading)

                Spacer(minLength: 4)

                controlButton("后退 10 秒", systemImage: "gobackward.10") {
                    playback.skip(by: -10)
                }
                Button(action: playback.togglePlay) {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help(playback.isPlaying ? "暂停（空格）" : "播放（空格）")
                .accessibilityLabel(playback.isPlaying ? "暂停" : "播放")
                controlButton("前进 10 秒", systemImage: "goforward.10") {
                    playback.skip(by: 10)
                }

                Menu {
                    ForEach(Self.playbackRates, id: \.self) { rate in
                        Button {
                            playback.setRate(rate)
                        } label: {
                            if playback.rate == rate {
                                Label(Self.rateLabel(rate), systemImage: "checkmark")
                            } else {
                                Text(Self.rateLabel(rate))
                            }
                        }
                    }
                } label: {
                    Text(Self.rateLabel(playback.rate))
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(minWidth: 36)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("播放速度")
                .accessibilityLabel("播放速度 \(Self.rateLabel(playback.rate))")

                Spacer(minLength: 4)

                Text(BasketMediaPlayback.formatTime(playback.duration))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .buttonStyle(.plain)
    }

    private func controlButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .help(title)
        .accessibilityLabel(title)
    }

    private static func rateLabel(_ rate: Float) -> String {
        if rate == 1 { return "1×" }
        if rate == 0.5 { return "0.5×" }
        if rate == 0.75 { return "0.75×" }
        if rate == 1.25 { return "1.25×" }
        if rate == 1.5 { return "1.5×" }
        return String(format: "%.2g×", rate)
    }
}

@MainActor
final class BasketMediaPlayback: ObservableObject {
    static let togglePlayNotification = Notification.Name("WeClawSend.basketMediaTogglePlay")

    static func requestTogglePlay(for url: URL) {
        NotificationCenter.default.post(
            name: togglePlayNotification,
            object: url.standardizedFileURL
        )
    }

    let player = AVPlayer()

    @Published private(set) var isLoading = true
    @Published private(set) var isWaveformLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasVideo = false
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var rate: Float = 1
    @Published private(set) var waveform: [Float] = []

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var rateObserver: NSKeyValueObservation?
    private var isScrubbing = false
    private var scrubTime: Double = 0
    private var generation = 0

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(displayTime / duration, 0), 1)
    }

    var displayTime: Double {
        isScrubbing ? scrubTime : currentTime
    }

    func load(_ url: URL) async {
        shutdownPreservingRate()
        generation += 1
        let token = generation
        isLoading = true
        errorMessage = nil
        hasVideo = false
        duration = 0
        currentTime = 0
        waveform = []
        isWaveformLoading = true

        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isPlayable)
            guard playable else {
                throw BasketMediaLoadError.notPlayable
            }
            let assetDuration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(assetDuration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard token == generation else { return }
            hasVideo = !videoTracks.isEmpty
            duration = seconds.isFinite && seconds > 0 ? seconds : 0
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            player.actionAtItemEnd = .pause
            installObservers(for: item)
            isLoading = false
        } catch {
            guard token == generation else { return }
            isLoading = false
            isWaveformLoading = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "系统无法解码该音视频。"
            return
        }

        let samples = await Self.makeWaveform(url: url)
        guard token == generation else { return }
        waveform = samples
        isWaveformLoading = false
    }

    func shutdown() {
        generation += 1
        removeObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        isScrubbing = false
        isLoading = false
        isWaveformLoading = false
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard duration > 0 else { return }
        if currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        player.play()
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying {
            player.rate = newRate
        }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func seek(toFraction fraction: Double) {
        seek(to: max(duration, 0) * min(max(fraction, 0), 1))
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(duration, 0))
        currentTime = clamped
        scrubTime = clamped
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func scrub(to seconds: Double) {
        scrubTime = seconds
        if isScrubbing {
            currentTime = seconds
        }
    }

    func setScrubbing(_ editing: Bool) {
        if editing {
            isScrubbing = true
            player.pause()
        } else {
            isScrubbing = false
            seek(to: scrubTime)
            if isPlaying {
                player.play()
                player.rate = rate
            }
        }
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func shutdownPreservingRate() {
        removeObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        isScrubbing = false
    }

    private func installObservers(for item: AVPlayerItem) {
        removeObservers()
        let interval = CMTime(seconds: 1.0 / 15.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isScrubbing else { return }
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite {
                    self.currentTime = min(max(seconds, 0), self.duration)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.player.pause()
            }
        }
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = self.player.rate > 0
            }
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        rateObserver?.invalidate()
        rateObserver = nil
    }

    nonisolated static func makeWaveform(url: URL, binCount: Int = 240) async -> [Float] {
        await Task.detached(priority: .utility) {
            await Self.readWaveform(url: url, binCount: binCount)
        }.value
    }

    nonisolated private static func readWaveform(url: URL, binCount: Int) async -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            return []
        }
        guard let track = tracks.first else { return [] }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            return []
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 8_000,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let durationTime: CMTime
        do {
            durationTime = try await asset.load(.duration)
        } catch {
            return []
        }
        let duration = CMTimeGetSeconds(durationTime)
        guard duration.isFinite, duration > 0 else { return [] }
        let samplesPerBin = max((duration * 8_000) / Double(binCount), 1)
        var bins = [Float](repeating: 0, count: binCount)
        var sampleIndex = 0

        while reader.status == .reading, let buffer = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(buffer) }
            guard let dataBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer, length >= 2 else { continue }
            let sampleCount = length / MemoryLayout<Int16>.size
            dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
                for index in 0..<sampleCount {
                    let bin = min(Int(Double(sampleIndex) / samplesPerBin), binCount - 1)
                    let amplitude = abs(Float(samples[index]) / Float(Int16.max))
                    if amplitude > bins[bin] {
                        bins[bin] = amplitude
                    }
                    sampleIndex += 1
                }
            }
        }
        return bins
    }
}

private enum BasketMediaLoadError: LocalizedError {
    case notPlayable

    var errorDescription: String? {
        switch self {
        case .notPlayable:
            "系统无法播放该文件。"
        }
    }
}

private struct BasketMediaVideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> BasketMediaPlayerView {
        let view = BasketMediaPlayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: BasketMediaPlayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    static func dismantleNSView(_ view: BasketMediaPlayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

private final class BasketMediaPlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

private struct BasketMediaWaveformView: View {
    let samples: [Float]
    let progress: Double
    let isLoading: Bool
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                if samples.isEmpty {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Capsule()
                            .fill(Brand.controlAccent.opacity(0.35))
                            .frame(width: max(size.width * progress, 2))
                    }
                } else {
                    Canvas { context, canvasSize in
                        let count = samples.count
                        let barWidth = canvasSize.width / CGFloat(count)
                        let played = CGFloat(progress) * canvasSize.width
                        for index in 0..<count {
                            let amplitude = max(CGFloat(samples[index]), 0.04)
                            let height = max(amplitude * canvasSize.height * 0.9, 2)
                            let x = CGFloat(index) * barWidth
                            let rect = CGRect(
                                x: x + barWidth * 0.2,
                                y: (canvasSize.height - height) / 2,
                                width: max(barWidth * 0.6, 1),
                                height: height
                            )
                            let color = x < played
                                ? Brand.controlAccent
                                : Color.primary.opacity(0.22)
                            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard size.width > 0 else { return }
                        onSeek(min(max(value.location.x / size.width, 0), 1))
                    }
            )
        }
        .accessibilityLabel("波形进度")
        .accessibilityValue("\(Int((progress * 100).rounded()))%")
    }
}
