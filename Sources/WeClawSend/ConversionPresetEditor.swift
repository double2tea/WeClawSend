import SwiftUI

struct ConversionPresetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BasketConversionPresetStore.shared
    @State var preset: BasketConversionPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑转换预设").font(.headline)
            ScrollView(.vertical, showsIndicators: true) {
                ConversionPresetFields(preset: $preset)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                    .padding(.trailing, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CompactScrollViewConfigurator())
            }
            .frame(height: 400)
            if let error = store.errorMessage { Text(error).foregroundStyle(Brand.danger) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { if store.save(preset) { dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !preset.settings.isValid)
            }
        }
        .pickerStyle(.menu)
        .padding(20).frame(width: 370).font(.system(size: 11)).controlSize(.small)
    }
}

struct ConversionPresetFields: View {
    @Binding var preset: BasketConversionPreset
    var showsCategorySelector = true
    @ObservedObject private var ffmpeg = FFmpegSupport.shared
    @State private var showsAdvanced = false

    private var sizeLimit: Binding<BasketConversionSizeLimit> {
        Binding(
            get: { preset.settings.categoryLimits[preset.action.category] ?? BasketConversionSizeLimit(maximum: 0, percent: 0) },
            set: { preset.settings.categoryLimits[preset.action.category] = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConversionFormRow("预设名称") { TextField("例如：视频压到 20 MiB", text: $preset.name).textFieldStyle(.roundedBorder) }
            if showsCategorySelector {
                ConversionFormRow("文件类型") {
                    Picker("文件类型", selection: Binding(
                        get: { preset.action.category },
                        set: { category in
                            if let action = BasketConversionAction.allCases.first(where: { $0.category == category }) { preset.action = action }
                        }
                    )) {
                        ForEach(BasketConversionCategory.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            ConversionFormRow("输出格式") {
                Picker("输出格式", selection: $preset.action) {
                    ForEach(BasketConversionAction.allCases.filter { $0.category == preset.action.category }) { action in
                        Text(action.title).tag(action)
                    }
                }.labelsHidden()
            }
            Toggle("在快捷面板与右键中显示", isOn: $preset.isEnabled)
            Divider().padding(.vertical, 4)
            switch preset.action.category {
            case .video: videoFields
            case .audio: audioFields
            case .image: imageFields
            case .document: documentFields
            }
            Divider().padding(.vertical, 4)
            ConversionFormRow("每文件上限") {
                HStack {
                    TextField("0", value: sizeLimit.maximum, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 78)
                    Text("MiB").foregroundStyle(.secondary)
                }
            }
            ConversionFormRow("压缩目标") {
                Picker("压缩目标", selection: sizeLimit.percent) {
                    Text("不限制比例").tag(0)
                    ForEach([25, 50, 75], id: \.self) { Text("原文件的 \($0)% 以内").tag($0) }
                }.labelsHidden()
            }
            Text("上限填 0 为不限；同时设置时取较小目标，无法达标会提示。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !preset.settings.isValid {
                Text("参数无效：大小为 0–10240 MiB，码率为有效范围，请检查输入。")
                    .foregroundStyle(Brand.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: preset.action) { _, action in
            if action.requiresFFmpeg { preset.settings.useFFmpeg = true }
            if action.isImage || action.isDocument { preset.settings.useFFmpeg = false }
            if action == .opus { preset.settings.audioSampleRate = 48_000 }
            if !action.videoCodecs.isEmpty && !action.videoCodecs.contains(preset.settings.videoCodec) {
                preset.settings.videoCodec = action.videoCodecs[0]
            }
        }
        .onChange(of: preset.settings.videoHEVC) { _, hevc in
            if hevc && preset.settings.videoSize == .hd720 { preset.settings.videoSize = .hd1080 }
        }
        .pickerStyle(.menu)
    }

    private var engineFields: some View {
        Group {
            ConversionFormRow("转换引擎") {
                Picker("转换引擎", selection: $preset.settings.useFFmpeg) {
                    if !preset.action.requiresFFmpeg { Text("系统").tag(false) }
                    Text("FFmpeg").tag(true)
                }.labelsHidden()
            }
            .onChange(of: preset.settings.useFFmpeg) { _, usesFFmpeg in
                if !usesFFmpeg, preset.settings.videoHEVC, preset.settings.videoSize == .hd720 {
                    preset.settings.videoSize = .hd1080
                }
            }
            if preset.settings.useFFmpeg || preset.action.requiresFFmpeg { FFmpegSetupView() }
        }
    }

    private var videoFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            engineFields
            if preset.settings.useFFmpeg {
                ConversionFormRow("轨道") {
                    Picker("轨道", selection: Binding(
                        get: { preset.settings.audioVideoOnly == true },
                        set: { preset.settings.audioVideoOnly = $0 }
                    )) {
                        Text("保留全部轨道").tag(false)
                        Text("仅音视频").tag(true)
                    }.labelsHidden()
                }
                if preset.settings.audioVideoOnly == true {
                    Text("保留所有音视频轨道，移除字幕、封面及数据轨道。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ConversionFormRow("视频编码") {
                    Picker("视频编码", selection: $preset.settings.videoCodec) {
                        ForEach(preset.action.videoCodecs, id: \.self) { Text(codecTitle($0)).tag($0) }
                    }.labelsHidden()
                }
                if preset.settings.videoCodec != "copy" {
                    resolutionField
                    if preset.settings.videoCodec != "prores" {
                        ConversionFormRow("视频码率") {
                            HStack {
                                TextField("0", value: $preset.settings.videoBitrateKbps, format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 78)
                                Text("kbps").foregroundStyle(.secondary)
                            }
                        }
                        if preset.settings.videoBitrateKbps == 0 {
                            ConversionFormRow("质量 CRF") {
                                Stepper("\(preset.settings.videoCRF)", value: $preset.settings.videoCRF, in: 0...51)
                            }
                        }
                        Text("码率填 0 使用 CRF，数值越低质量越高；设置大小目标时改按目标预算码率。")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup("高级参数", isExpanded: $showsAdvanced) {
                        VStack(spacing: 12) {
                            ConversionFormRow("帧率") {
                                Picker("帧率", selection: $preset.settings.frameRate) {
                                    Text("跟随源文件").tag(0)
                                    ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                                }.labelsHidden()
                            }
                            ConversionFormRow("编码速度") {
                                Picker("编码速度", selection: $preset.settings.encoderSpeed) {
                                    Text("快速").tag("fast")
                                    Text("均衡").tag("medium")
                                    Text("精细").tag("slow")
                                }.labelsHidden()
                            }
                            audioQualityFields
                        }.padding(.top, 8)
                    }
                }
            } else if preset.action == .mp4 {
                ConversionFormRow("视频编码") {
                    Picker("视频编码", selection: $preset.settings.videoHEVC) {
                        Text("H.264").tag(false)
                        Text("H.265 / HEVC").tag(true)
                    }.labelsHidden()
                }
                resolutionField
            } else {
                Text("系统 MOV 为换封装，保留原编码。转 ProRes 或其它编码可选 FFmpeg。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("优化网络播放", isOn: $preset.settings.networkOptimized)
                .disabled(![.mp4, .mov].contains(preset.action))
            Toggle("保留媒体元数据", isOn: $preset.settings.retainMetadata)
        }
    }

    private var resolutionField: some View {
        ConversionFormRow("分辨率上限") {
            Picker("分辨率上限", selection: $preset.settings.videoSize) {
                ForEach(BasketVideoSize.allCases.filter {
                    preset.settings.useFFmpeg || !preset.settings.videoHEVC || $0 != .hd720
                }) { Text($0.title).tag($0) }
            }.labelsHidden()
        }
    }

    private var audioFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            engineFields
            audioQualityFields
            Toggle("保留媒体元数据", isOn: $preset.settings.retainMetadata)
            Text("提取第一个音轨。WAV / AIFF 为 16-bit PCM，FLAC 为无损压缩；音频大小目标做输出校验。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var audioQualityFields: some View {
        Group {
            if ![.wav, .aiff, .flac].contains(preset.action) {
                ConversionFormRow("音频码率") {
                    Picker("音频码率", selection: $preset.settings.audioBitrate) {
                        ForEach([64, 96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                    }.labelsHidden()
                }
            }
            ConversionFormRow("采样率") {
                Picker("采样率", selection: $preset.settings.audioSampleRate) {
                    Text("跟随源文件").tag(0)
                    if preset.action != .opus {
                        Text("22.05 kHz").tag(22_050)
                        Text("44.1 kHz").tag(44_100)
                    }
                    Text("48 kHz").tag(48_000)
                }.labelsHidden()
            }
            ConversionFormRow("声道") {
                Picker("声道", selection: $preset.settings.audioChannels) {
                    Text("跟随源文件").tag(0)
                    Text("单声道").tag(1)
                    Text("立体声").tag(2)
                }.labelsHidden()
            }
        }
    }

    private var imageFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConversionFormRow("图片长边") {
                Picker("图片长边", selection: $preset.settings.imageMaxPixel) {
                    Text("原尺寸").tag(0)
                    ForEach([1280, 1920, 2560, 3840], id: \.self) { Text("\($0) px").tag($0) }
                }.labelsHidden()
            }
            if preset.action == .jpeg {
                ConversionFormRow("JPG 质量") {
                    HStack {
                        Slider(value: $preset.settings.jpegQuality, in: 0.1...1, step: 0.05)
                        Text(preset.settings.jpegQuality, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                    }
                }
                ConversionFormRow("透明背景") {
                    Picker("透明背景", selection: $preset.settings.jpegBackground) {
                        Text("白色").tag("white")
                        Text("黑色").tag("black")
                    }.labelsHidden()
                }
            }
            Text("保持宽高比，不放大小图；PNG 保留透明。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var documentFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            if preset.action == .pdf {
                ConversionFormRow("纸张") {
                    Picker("纸张", selection: $preset.settings.pdfPaper) {
                        Text("A4").tag("a4")
                        Text("US Letter").tag("letter")
                    }.labelsHidden()
                }
                ConversionFormRow("方向") {
                    Picker("方向", selection: $preset.settings.pdfLandscape) {
                        Text("纵向").tag(false)
                        Text("横向").tag(true)
                    }.labelsHidden()
                }
                ConversionFormRow("页边距") {
                    Picker("页边距", selection: $preset.settings.pdfMargin) {
                        Text("窄 · 18 pt").tag(18.0)
                        Text("标准 · 42 pt").tag(42.0)
                        Text("宽 · 72 pt").tag(72.0)
                    }.labelsHidden()
                }
            }
            if [.pdf, .rtf].contains(preset.action) {
                ConversionFormRow("纯文本字号") {
                    Picker("纯文本字号", selection: $preset.settings.documentFontSize) {
                        ForEach([10, 12, 14, 16, 18], id: \.self) { Text("\($0) pt").tag(Double($0)) }
                    }.labelsHidden()
                }
            }
            if preset.action == .compressPDF {
                Toggle("图片使用 JPEG 编码", isOn: $preset.settings.pdfJPEG)
                Toggle("图片优化为屏幕显示", isOn: $preset.settings.pdfScreen)
            }
            Text("PDF 为文字重排；扫描件不执行 OCR。PDF 压缩可能降低图片清晰度，请核对输出。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codecTitle(_ codec: String) -> String {
        switch codec {
        case "copy": "原编码 · 换封装"
        case "h264": "H.264"
        case "hevc": "H.265 / HEVC"
        case "prores": "Apple ProRes 422 HQ"
        case "vp9": "VP9"
        case "av1": "AV1"
        default: codec
        }
    }
}
