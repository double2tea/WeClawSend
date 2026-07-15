import CoreImage.CIFilterBuiltins
import SwiftUI

struct ServicesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    weChatSection
                    settingsSection
                    localAPISection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            Divider().opacity(0.4)
            footer
        }
        .onAppear {
            model.refreshLaunchAtLogin()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                model.showsServices = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("返回发送")

            VStack(alignment: .leading, spacing: 1) {
                Text("设置")
                    .font(.system(size: 13, weight: .semibold))
                Text(Brand.name)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button {
                Task { await model.refreshServices() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("刷新状态")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var weChatSection: some View {
        compactCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    statusDot(model.weChatStatus.isOnline ? Brand.success : Brand.danger)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("微信登录")
                            .font(.system(size: 12, weight: .semibold))
                        Text(weChatSubtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    if model.isLoggingIn || model.loginQRCodeContent != nil || model.needsVerificationCode {
                        Button("取消") {
                            model.cancelWeChatLogin()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    } else {
                        Button(model.weChatStatus.isOnline ? "重新登录" : "扫码登录") {
                            model.beginWeChatLogin()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                if let content = model.loginQRCodeContent, let image = qrCodeImage(content) {
                    VStack(spacing: 8) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 132, height: 132)
                            .padding(8)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Text(model.loginMessage)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if model.needsVerificationCode {
                            HStack(spacing: 6) {
                                TextField("配对码", text: $model.verificationCode)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                                    .frame(width: 100)
                                    .onSubmit { model.submitVerificationCode() }
                                Button("确认") {
                                    model.submitVerificationCode()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Brand.action)
                                .controlSize(.mini)
                                .disabled(
                                    model.verificationCode
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                        .isEmpty
                                )
                            }
                        } else if model.isLoggingIn {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else if model.isLoggingIn {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(model.loginMessage.isEmpty ? "正在生成二维码…" : model.loginMessage)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                } else if !model.weChatStatus.isOnline {
                    Text("登录后可从菜单栏拖放文件发送到微信。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }

                if model.weChatStatus.isOnline {
                    Divider().opacity(0.35)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(Brand.warning)
                        Text("微信限制发送时，App 会提示你给 ClawBot 发一条消息；收到后会自动重试。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var settingsSection: some View {
        compactCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("应用设置")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 6)

                settingRow(
                    icon: "power",
                    title: "登录时自动启动",
                    subtitle: "开机后菜单栏自动运行",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )

                if model.launchAtLoginRequiresApproval {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Brand.warning)
                        Text("已被系统阻止，请在「登录项」中允许。")
                            .font(.system(size: 10))
                            .foregroundStyle(Brand.warning)
                        Spacer(minLength: 4)
                        Button("打开") {
                            model.openLoginItemsSettings()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                    }
                    .padding(.vertical, 4)
                }

                Divider().opacity(0.35).padding(.vertical, 6)

                settingRow(
                    icon: "film",
                    title: "发送时 .mp4 显示为 .m4v",
                    subtitle: "只改微信附件名，不改本地文件",
                    isOn: Binding(
                        get: { model.autoRenameMP4ToM4V },
                        set: { model.setAutoRenameMP4ToM4V($0) }
                    )
                )
            }
        }
    }

    private var localAPISection: some View {
        compactCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    statusDot(bridgeStatusColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("本地接口")
                            .font(.system(size: 12, weight: .semibold))
                        Text(bridgeSubtitle)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(bridgeStatusLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }

                Divider().opacity(0.35).padding(.vertical, 6)

                settingRow(
                    icon: "network",
                    title: "启用本地接口",
                    subtitle: "供 Premiere、DaVinci 和本机脚本调用",
                    isOn: Binding(
                        get: { model.localAPIEnabled },
                        set: { model.setLocalAPIEnabled($0) }
                    )
                )

                Text("菜单栏发送不依赖此接口。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("独立应用 · 无需其它后台")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Link(destination: Brand.githubURL) {
                Image(nsImage: Brand.githubMarkImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("在 GitHub 查看项目")
            .accessibilityLabel("GitHub")

            Link(destination: Brand.supportEmailURL) {
                Image(systemName: "envelope")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("发送邮件至 double_tea@foxmail.com")
            .accessibilityLabel("邮件联系")
            Spacer()
            Button("退出") {
                model.quit()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func settingRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.05)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Brand.action)
                .accessibilityLabel(title)
                .accessibilityHint(subtitle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private func statusDot(_ color: Color) -> some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.15))
                .frame(width: 22, height: 22)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
    }

    private func compactCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Brand.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Brand.hairline, lineWidth: 1)
            }
    }

    private var bridgeStatusLabel: String {
        if !model.localAPIEnabled { return "已关闭" }
        switch model.bridgeStatus {
        case .checking: return "启动中"
        case .online: return "运行中"
        case .offline: return "失败"
        }
    }

    private var bridgeSubtitle: String {
        if !model.localAPIEnabled { return "已关闭" }
        switch model.bridgeStatus {
        case .checking: return "正在启动"
        case .online: return "127.0.0.1:18790"
        case .offline: return "启动失败"
        }
    }

    private var bridgeStatusColor: Color {
        if !model.localAPIEnabled { return .secondary }
        switch model.bridgeStatus {
        case .checking: return .secondary
        case .online: return Brand.success
        case .offline: return Brand.danger
        }
    }

    private var weChatSubtitle: String {
        if case let .online(account) = model.weChatStatus {
            if let account, !account.isEmpty {
                return "已登录 · \(account)"
            }
            return "已登录，可直接发送"
        }
        return "未登录"
    }

    private func qrCodeImage(_ content: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        let context = CIContext()
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
