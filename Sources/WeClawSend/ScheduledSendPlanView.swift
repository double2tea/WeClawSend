import SwiftUI

struct ScheduledSendPlanView: View {
    let plan: ScheduledSendPlan
    let sendNow: () -> Void
    let reschedule: (Date) -> Void
    let cancel: () -> Void

    @State private var showsCustomTimePicker = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 11) {
                    previewGrid

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(planTitle)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(statusText(now: context.date))
                                .font(.system(size: 10.5, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(statusColor)
                        }

                        Text(planDetail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text("\(sourceTitle) · \(scheduledSendTimeText(plan.scheduledAt))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                if let message = plan.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(plan.status == .needsAttention ? Brand.warning : Brand.danger)
                        .lineLimit(2)
                }

                HStack(spacing: 10) {
                    Button("立即发送", action: sendNow)
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Brand.accent)

                    Menu {
                        ForEach(ScheduledSendPreset.allCases) { preset in
                            Button(preset.title) {
                                reschedule(preset.scheduledAt())
                            }
                        }
                        Divider()
                        Button("自定义时间…") {
                            showsCustomTimePicker = true
                        }
                    } label: {
                        Label("改时间", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Spacer()

                    Button("取消计划", role: .destructive, action: cancel)
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Brand.danger)
                }
            }
            .padding(.vertical, 10)
        }
        .sheet(isPresented: $showsCustomTimePicker) {
            ScheduledSendDatePicker(itemDescription: planTitle, confirm: reschedule)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("待发送：\(planTitle)")
    }

    private var previewGrid: some View {
        let columns = [
            GridItem(.fixed(24), spacing: 2),
            GridItem(.fixed(24), spacing: 2)
        ]
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(Array(plan.items.prefix(4))) { item in
                FileThumbnailView(url: item.fileURL, width: 24, height: 20, cornerRadius: 4)
            }
        }
        .frame(width: 50, height: 42, alignment: .center)
        .overlay(alignment: .bottomTrailing) {
            if plan.items.count > 4 {
                Text("+\(plan.items.count - 4)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .frame(minHeight: 13)
                    .background(Capsule().fill(Brand.action))
                    .offset(x: 3, y: 3)
            }
        }
    }

    private var planTitle: String {
        guard plan.items.count != 1 else { return plan.items[0].fileName }
        return "\(plan.items.count) 个文件"
    }

    private var planDetail: String {
        let bytes = plan.items.reduce(Int64.zero) { $0 + $1.byteCount }
        let sample = plan.items.first?.fileName ?? "待发送"
        return "\(formatBytes(bytes)) · \(sample)"
    }

    private var sourceTitle: String {
        switch plan.source.lowercased() {
        case "app": "主界面"
        case "file-basket", "basket": "文件篮"
        case "davinci", "davinci-resolve": "DaVinci Resolve"
        case "premiere": "Premiere Pro"
        case "api", "local-api": "本地 API"
        default: plan.source.isEmpty ? "WeClaw Send" : plan.source
        }
    }

    private func statusText(now: Date) -> String {
        switch plan.status {
        case .scheduled: scheduledSendCountdown(to: plan.scheduledAt, now: now)
        case .needsAttention: "需要处理"
        case .sending: "正在发送"
        case .sent: "完成"
        case .cancelled: "已取消"
        case .failed: "失败"
        }
    }

    private var statusColor: Color {
        switch plan.status {
        case .scheduled: Brand.warning
        case .needsAttention: Brand.warning
        case .sending: Brand.accent
        case .sent: Brand.success
        case .cancelled: .secondary
        case .failed: Brand.danger
        }
    }
}
