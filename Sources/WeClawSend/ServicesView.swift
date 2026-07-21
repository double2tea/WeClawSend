import CoreImage.CIFilterBuiltins
import SwiftUI

struct ServicesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    weChatSection
                    settingsSection
                    localAPISection
                    updatesAndIntegrationsSection
                    feedbackSection
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
                Task {
                    if model.weChatCredentialSource == .openClaw {
                        await model.refreshOpenClawAccounts()
                    } else {
                        await model.refreshServices()
                    }
                    async let updates: Void = model.refreshAllUpdateStatuses(forceRefresh: true)
                    _ = await updates
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("刷新状态")

            Button {
                model.quit()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("退出")
            .accessibilityLabel("退出 WeClaw Send")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var weChatSection: some View {
        compactCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    statusDot(weChatStatusColor)
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
                    if model.weChatCredentialSource == .openClaw {
                        Button("刷新") {
                            Task { await model.refreshOpenClawAccounts() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(model.isLoadingOpenClawAccounts)
                    } else if model.isLoggingIn || model.loginQRCodeContent != nil || model.needsVerificationCode {
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

                Divider().opacity(0.35)

                HStack(spacing: 8) {
                    Text("登录方式")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker("登录方式", selection: Binding(
                        get: { model.weChatCredentialSource },
                        set: { model.setWeChatCredentialSource($0) }
                    )) {
                        ForEach(WeChatCredentialSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 154)
                }

                if model.weChatCredentialSource == .openClaw {
                    HStack(spacing: 8) {
                        Text("OpenClaw 账号")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if model.isLoadingOpenClawAccounts {
                            ProgressView().controlSize(.mini)
                        } else if model.openClawAccounts.isEmpty {
                            Text("未发现")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Brand.danger)
                        } else {
                            Picker("OpenClaw 账号", selection: Binding(
                                get: { model.selectedOpenClawAccountID },
                                set: { model.selectOpenClawAccount($0) }
                            )) {
                                ForEach(model.openClawAccounts) { account in
                                    Text(account.userID).tag(account.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .frame(maxWidth: 190)
                        }
                    }

                    Text("登录和收取消息由 OpenClaw 管理；WeClaw Send 只共享当前账号发送文件。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.weChatCredentialSource == .weClawSend,
                   let loginStep = model.loginStep {
                    VStack(alignment: .leading, spacing: 5) {
                        loginStepRow(
                            number: 1,
                            title: "使用微信扫码并确认",
                            step: .scanAndConfirm,
                            current: loginStep
                        )
                        loginStepRow(
                            number: 2,
                            title: "在 ClawBot 发送任意消息，完成会话绑定",
                            step: .bindConversation,
                            current: loginStep
                        )
                        loginStepRow(
                            number: 3,
                            title: "已连接，可以发送文件",
                            step: .connected,
                            current: loginStep
                        )
                    }
                    .padding(9)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    )
                }

                if model.weChatCredentialSource == .weClawSend,
                   let content = model.loginQRCodeContent,
                   let image = qrCodeImage(content) {
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
                } else if model.weChatCredentialSource == .weClawSend, model.isLoggingIn {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(model.loginMessage.isEmpty ? "正在生成二维码…" : model.loginMessage)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                } else if model.weChatCredentialSource == .weClawSend, !model.weChatStatus.isOnline {
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

                Divider().opacity(0.35).padding(.vertical, 6)

                settingRow(
                    icon: "bell",
                    title: "发送结果通知",
                    subtitle: "系统横幅；多文件合并为一条，不逐条刷屏",
                    isOn: Binding(
                        get: { model.sendResultNotificationsEnabled },
                        set: { model.setSendResultNotificationsEnabled($0) }
                    )
                )

                Divider().opacity(0.35).padding(.vertical, 6)

                HStack(spacing: 8) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("单文件大小上限")
                            .font(.system(size: 11.5, weight: .medium))
                        Text("较大文件仍可能被微信服务拒绝")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Picker("单文件大小上限", selection: Binding(
                        get: { model.sendSizeLimit },
                        set: { model.setSendSizeLimit($0) }
                    )) {
                        ForEach(SendSizeLimit.allCases) { limit in
                            Text(limit.title).tag(limit)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 92)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
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

    private var updatesAndIntegrationsSection: some View {
        compactCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("更新与编辑器集成")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 6)

                integrationActionRow(
                    icon: "arrow.down.circle",
                    title: "App 在线更新",
                    subtitle: model.appUpdateSubtitle,
                    buttonTitle: model.appUpdateButtonTitle,
                    isWorking: model.isAppUpdateBusy,
                    isDisabled: model.isCheckingAppUpdate,
                    action: model.updateApp
                )

                Divider().opacity(0.35).padding(.vertical, 6)

                premierePluginIntegrationRow

                Divider().opacity(0.35).padding(.vertical, 6)

                daVinciScriptsIntegrationRow
            }
        }
    }

    private var feedbackSection: some View {
        compactCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("反馈")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 6)

                integrationActionRow(
                    icon: "bubble.left.and.bubble.right",
                    title: "产品交流与反馈",
                    subtitle: "打开飞书文档，提交问题、建议或查看更新说明",
                    buttonTitle: "打开",
                    isWorking: false,
                    action: { openURL(Brand.feedbackURL) }
                )
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(model.weChatCredentialSource == .openClaw ? "与 OpenClaw 共用微信登录" : "独立应用 · 无需其它后台")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            SocialLinksView(appVersion: model.appVersion)
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
                .controlSize(.small)
                .tint(Brand.controlAccent)
                .accessibilityLabel(title)
                .accessibilityHint(subtitle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private func integrationActionRow(
        icon: String,
        title: String,
        subtitle: String,
        buttonTitle: String,
        isWorking: Bool,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
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
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isWorking {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.top, 4)
            } else {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(model.isUpdateOperationInProgress || isDisabled)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var premierePluginIntegrationRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.05)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Premiere Pro 插件")
                    .font(.system(size: 11.5, weight: .medium))
                Text(model.premierePluginSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if model.isPremierePluginBusy {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.top, 4)
            } else {
                HStack(spacing: 6) {
                    if model.canUninstallPremierePlugin {
                        Button("卸载") {
                            model.uninstallPremierePlugin()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(model.isUpdateOperationInProgress)
                    }
                    Button(model.premierePluginButtonTitle) {
                        model.installPremierePlugin()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(model.isUpdateOperationInProgress || model.isPremierePluginActionDisabled)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var daVinciScriptsIntegrationRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.05)))
            VStack(alignment: .leading, spacing: 1) {
                Text("DaVinci Resolve 脚本")
                    .font(.system(size: 11.5, weight: .medium))
                Text(model.daVinciScriptsSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if model.isDaVinciScriptsBusy {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.top, 4)
            } else {
                HStack(spacing: 6) {
                    if model.canRevealDaVinciScripts {
                        Button("显示路径") {
                            model.revealDaVinciScripts()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(model.isUpdateOperationInProgress)
                    }
                    if model.canUninstallDaVinciScripts {
                        Button("卸载") {
                            model.uninstallDaVinciScripts()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(model.isUpdateOperationInProgress)
                    }
                    Button(model.daVinciScriptsButtonTitle) {
                        model.installDaVinciScripts()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(model.isUpdateOperationInProgress || model.isDaVinciScriptsActionDisabled)
                }
            }
        }
        .frame(maxWidth: .infinity)
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
        if case .checking = model.weChatStatus {
            return model.loginMessage.isEmpty ? "正在检查连接" : model.loginMessage
        }
        if case let .online(account) = model.weChatStatus {
            if let account, !account.isEmpty {
                let source = model.weChatCredentialSource == .openClaw ? "OpenClaw" : "独立登录"
                return "\(source) · 已连接，可以发送文件 · \(account)"
            }
            return "已连接，可以发送文件"
        }
        return "未登录"
    }

    private var weChatStatusColor: Color {
        switch model.weChatStatus {
        case .checking: Brand.warning
        case .online: Brand.success
        case .offline: Brand.danger
        }
    }

    private func loginStepRow(
        number: Int,
        title: String,
        step: WeChatLoginStep,
        current: WeChatLoginStep
    ) -> some View {
        let isComplete = current == .connected || step.rawValue < current.rawValue
        let isActive = step == current && current != .connected
        return HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(isComplete || isActive ? Brand.accent : Color.primary.opacity(0.08))
                    .frame(width: 17, height: 17)
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text(String(number))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(isActive ? .white : .secondary)
                }
            }
            Text(title)
                .font(.system(size: 10.5, weight: isActive ? .medium : .regular))
                .foregroundStyle(isComplete || isActive ? .primary : .tertiary)
            Spacer(minLength: 0)
        }
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
