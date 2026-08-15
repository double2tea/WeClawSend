import SwiftUI

enum ScheduledSendPreset: Int, CaseIterable, Identifiable {
    case tenSeconds = 10
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .tenSeconds: "10 秒后"
        case .oneMinute: "1 分钟后"
        case .fiveMinutes: "5 分钟后"
        case .fifteenMinutes: "15 分钟后"
        case .thirtyMinutes: "30 分钟后"
        case .oneHour: "1 小时后"
        }
    }

    func scheduledAt(relativeTo now: Date = .now) -> Date {
        now.addingTimeInterval(TimeInterval(rawValue))
    }
}

struct ScheduledSendDatePicker: View {
    @Environment(\.dismiss) private var dismiss

    let itemDescription: String
    let confirm: (Date) -> Void

    @State private var scheduledAt = Date.now.addingTimeInterval(300)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("自定义发送时间")
                    .font(.system(size: 16, weight: .semibold))
                Text(itemDescription)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            DatePicker(
                "发送时间",
                selection: $scheduledAt,
                in: Date.now.addingTimeInterval(10)...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("加入待发送") {
                    confirm(scheduledAt)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(scheduledAt <= Date.now.addingTimeInterval(5))
            }
        }
        .padding(20)
        .frame(width: 330)
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
