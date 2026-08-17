import SwiftUI

struct ScheduledSendTimingPicker: View {
    let itemDescription: String
    let previewURLs: [URL]
    let showsHeading: Bool
    let canSendImmediately: Bool
    let cancel: () -> Void
    let sendImmediately: () -> Void
    let schedule: (Int) -> Void

    @State private var customMinutes: String
    @FocusState private var customMinutesFocused: Bool

    init(
        itemDescription: String,
        previewURLs: [URL] = [],
        showsHeading: Bool = true,
        canSendImmediately: Bool,
        initialDelaySeconds: Int = ScheduledSendDelay.defaultSeconds,
        cancel: @escaping () -> Void,
        sendImmediately: @escaping () -> Void,
        schedule: @escaping (Int) -> Void
    ) {
        self.itemDescription = itemDescription
        self.previewURLs = previewURLs
        self.showsHeading = showsHeading
        self.canSendImmediately = canSendImmediately
        self.cancel = cancel
        self.sendImmediately = sendImmediately
        self.schedule = schedule

        if ScheduledSendDelay.isValid(seconds: initialDelaySeconds),
           initialDelaySeconds.isMultiple(of: 60) {
            _customMinutes = State(initialValue: String(initialDelaySeconds / 60))
        } else {
            _customMinutes = State(initialValue: "15")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeading {
                VStack(alignment: .leading, spacing: 3) {
                    Text("选择发送时间")
                        .font(.system(size: 15, weight: .semibold))
                    Text(itemDescription)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if !previewURLs.isEmpty {
                previewRow
            }

            Text("点选一个时间，立即加入待发送")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                spacing: 6
            ) {
                ForEach(ScheduledSendPreset.allCases) { preset in
                    DelayPresetChip(preset: preset) {
                        schedule(preset.rawValue)
                        cancel()
                    }
                }
            }

            HStack(spacing: 8) {
                Text("自定义")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("分钟", text: $customMinutes)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .multilineTextAlignment(.trailing)
                    .focused($customMinutesFocused)
                    .onSubmit(confirmSchedule)
                Text("分钟后")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Button("确定", action: confirmSchedule)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(customDelaySeconds == nil ? .secondary : Brand.accent)
                    .disabled(customDelaySeconds == nil)
            }

            if customMinutesFocused || customDelaySeconds != nil {
                Text(estimatedSendText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Button("取消", action: cancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("立即发送") {
                    sendImmediately()
                    cancel()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(canSendImmediately ? Brand.accent : .secondary)
                .disabled(!canSendImmediately)
                .help(canSendImmediately ? "不建立计划，直接发送" : "登录微信后才能立即发送")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var previewRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(previewURLs.prefix(4).enumerated()), id: \.offset) { _, url in
                FileThumbnailView(
                    url: url,
                    width: 40,
                    height: 30,
                    cornerRadius: 7,
                    policy: .visualContentOnly
                )
            }
            if previewURLs.count > 4 {
                Text("+\(previewURLs.count - 4)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Brand.surface)
                    )
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private var customDelaySeconds: Int? {
        guard let minutes = Int(customMinutes) else { return nil }
        return ScheduledSendDelay.seconds(customMinutes: minutes)
    }

    private var estimatedSendText: String {
        guard let customDelaySeconds else { return "请输入有效的分钟数" }
        let sendAt = Date.now.addingTimeInterval(TimeInterval(customDelaySeconds))
        return "确定后将于 \(sendAt.formatted(date: .omitted, time: .shortened)) 发送"
    }

    private func confirmSchedule() {
        guard let customDelaySeconds else { return }
        schedule(customDelaySeconds)
        cancel()
    }
}

private struct DelayPresetChip: View {
    let preset: ScheduledSendPreset
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(preset.compactTitle)
                .font(.system(size: 11.5, weight: isHovered ? .semibold : .medium))
                .foregroundStyle(isHovered ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: Brand.radiusControl, style: .continuous)
                        .fill(isHovered ? Brand.action : Brand.surface)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Brand.radiusControl, style: .continuous)
                        .stroke(Brand.hairline, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(preset.compactTitle)后发送")
    }
}

struct ScheduledSendCustomDelayPicker: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let itemDescription: String
    let confirm: (Int) -> Void

    @State private var customMinutes: String

    init(
        title: String = "自定义延时",
        itemDescription: String,
        initialMinutes: Int = 15,
        confirm: @escaping (Int) -> Void
    ) {
        self.title = title
        self.itemDescription = itemDescription
        self.confirm = confirm
        _customMinutes = State(initialValue: String(initialMinutes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(itemDescription)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                TextField("分钟", text: $customMinutes)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(confirmSelection)
                Text("分钟后")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("确定", action: confirmSelection)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(customDelaySeconds == nil ? .secondary : Brand.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(customDelaySeconds == nil)
            }
        }
        .padding(18)
        .frame(width: 300)
    }

    private var customDelaySeconds: Int? {
        guard let minutes = Int(customMinutes) else { return nil }
        return ScheduledSendDelay.seconds(customMinutes: minutes)
    }

    private func confirmSelection() {
        guard let customDelaySeconds else { return }
        dismiss()
        confirm(customDelaySeconds)
    }
}

func scheduledSendTimeText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.doesRelativeDateFormatting = true
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

func scheduledSendCountdown(to date: Date, now: Date = .now) -> String {
    let remaining = Int(date.timeIntervalSince(now).rounded(.up))
    guard remaining > 0 else { return "已到发送时间" }
    if remaining < 60 { return "\(remaining) 秒后" }
    let minutes = remaining / 60
    if minutes < 60 { return "\(minutes) 分钟后" }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    return remainingMinutes == 0
        ? "\(hours) 小时后"
        : "\(hours) 小时 \(remainingMinutes) 分钟后"
}
